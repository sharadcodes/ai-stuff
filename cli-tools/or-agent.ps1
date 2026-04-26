param(
    [Alias("f")]
    [switch]$IncludeFiles,

    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$Prompt,

    [string]$Model = "z-ai/glm-5-turbo",
    [int]$MaxSteps = 8,
    [int]$MaxOutputChars = 12000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:Root = (Get-Location).ProviderPath
$Script:ApiUrl = "https://openrouter.ai/api/v1/responses"
$Script:MoreStepsIncrement = 4
$Script:DefaultDirectoryEntries = 200
$Script:DefaultSearchMatches = 50
$Script:SkipDirectoryNames = @(".git", "node_modules", "venv", ".pytest_cache", "__pycache__")
$Script:ApiCallCount = 0
$Script:TotalCost = [decimal]0
$Script:HasCost = $false

function Write-Dim {
    param([string]$Text)
    Write-Host $Text -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Magenta
}

function Write-Strong {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Green
}

function Write-WarnLine {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Write-ErrorLine {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Red
}

function ConvertTo-AgentJson {
    param([object]$Value, [int]$Depth = 20)
    return ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function New-TextMessage {
    param(
        [ValidateSet("system", "user", "assistant")]
        [string]$Role,
        [string]$Text
    )

    $contentType = if ($Role -eq "assistant") { "output_text" } else { "input_text" }
    return [ordered]@{
        type    = "message"
        role    = $Role
        content = @(
            [ordered]@{
                type = $contentType
                text = $Text
            }
        )
    }
}

function Test-AgentProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-AgentProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if (-not (Test-AgentProperty -Object $Object -Name $Name)) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Resolve-AgentPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = "."
    }

    $combined = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path -Path $Script:Root -ChildPath $Path
    }

    try {
        return (Resolve-Path -LiteralPath $combined -ErrorAction Stop).ProviderPath
    } catch {
        $parent = Split-Path -Parent $combined
        if (-not $parent) {
            $parent = $Script:Root
        }
        $resolvedParent = (Resolve-Path -LiteralPath $parent -ErrorAction Stop).ProviderPath
        return (Join-Path -Path $resolvedParent -ChildPath (Split-Path -Leaf $combined))
    }
}

function Test-PathAllowed {
    param([string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Script:Root)
    if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $root = $root + [System.IO.Path]::DirectorySeparatorChar
    }

    return ($full -eq $Script:Root) -or $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-ToolResult {
    param(
        [bool]$Ok,
        [hashtable]$Data = @{},
        [string]$ErrorMessage = $null
    )

    $result = [ordered]@{ ok = $Ok }
    foreach ($key in $Data.Keys) {
        $result[$key] = $Data[$key]
    }
    if ($ErrorMessage) {
        $result["error"] = $ErrorMessage
    }
    return $result
}

function Get-UsageObject {
    param([object]$Response)

    if (Test-AgentProperty -Object $Response -Name "usage") {
        return (Get-AgentProperty -Object $Response -Name "usage")
    }
    if (Test-AgentProperty -Object $Response -Name "response") {
        $inner = Get-AgentProperty -Object $Response -Name "response"
        if (Test-AgentProperty -Object $inner -Name "usage") {
            return (Get-AgentProperty -Object $inner -Name "usage")
        }
    }
    return $null
}

function Get-FirstUsageValue {
    param(
        [object]$Usage,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if (Test-AgentProperty -Object $Usage -Name $name) {
            $value = Get-AgentProperty -Object $Usage -Name $name
            if ($null -ne $value) {
                return $value
            }
        }
    }
    return $null
}

function ConvertTo-DecimalOrNull {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    try {
        return [decimal]::Parse(
            ([string]$Value),
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        return $null
    }
}

function Format-Cost {
    param([decimal]$Cost)

    return $Cost.ToString("0.########", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-UsageLine {
    param([object]$Response)

    $Script:ApiCallCount++
    $usage = Get-UsageObject -Response $Response
    if ($null -eq $usage) {
        Write-Dim "API call $Script:ApiCallCount usage: not returned"
        return
    }

    $inputTokens = Get-FirstUsageValue -Usage $usage -Names @("input_tokens", "prompt_tokens")
    $outputTokens = Get-FirstUsageValue -Usage $usage -Names @("output_tokens", "completion_tokens")
    $totalTokens = Get-FirstUsageValue -Usage $usage -Names @("total_tokens")
    $costValue = Get-FirstUsageValue -Usage $usage -Names @("cost", "total_cost")
    $cost = ConvertTo-DecimalOrNull -Value $costValue

    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $inputTokens) { $parts.Add("$inputTokens in") }
    if ($null -ne $outputTokens) { $parts.Add("$outputTokens out") }
    if ($null -ne $totalTokens) { $parts.Add("$totalTokens total") }
    if ($null -ne $cost) {
        $Script:TotalCost += $cost
        $Script:HasCost = $true
        $parts.Add("cost $(Format-Cost -Cost $cost)")
    } elseif ($null -ne $costValue) {
        $parts.Add("cost $costValue")
    } else {
        $parts.Add("cost not returned")
    }

    Write-Host ("API call {0}: {1}" -f $Script:ApiCallCount, ($parts -join " | ")) -ForegroundColor Blue
}

function Write-CostSummary {
    if ($Script:ApiCallCount -eq 0) {
        return
    }

    if ($Script:HasCost) {
        Write-Host ("Total model cost: {0} across {1} call(s)" -f (Format-Cost -Cost $Script:TotalCost), $Script:ApiCallCount) -ForegroundColor Blue
    } else {
        Write-Host ("Total model cost: not returned across {0} call(s)" -f $Script:ApiCallCount) -ForegroundColor Blue
    }
}

function Exit-Agent {
    param([int]$Code)

    Write-CostSummary
    exit $Code
}

function Get-EnvironmentContext {
    return New-ToolResult -Ok $true -Data @{
        cwd                = $Script:Root
        os                 = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        platform           = [System.Environment]::OSVersion.Platform.ToString()
        powershell_version = $PSVersionTable.PSVersion.ToString()
        timestamp          = (Get-Date).ToString("o")
    }
}

function Invoke-ListDirectoryTool {
    param([object]$Arguments)

    $path = [string](Get-AgentProperty -Object $Arguments -Name "path" -Default ".")
    $maxEntries = [int](Get-AgentProperty -Object $Arguments -Name "max_entries" -Default $Script:DefaultDirectoryEntries)
    if ($maxEntries -lt 1) { $maxEntries = 1 }
    if ($maxEntries -gt 1000) { $maxEntries = 1000 }

    $resolved = Resolve-AgentPath -Path $path
    if (-not (Test-PathAllowed -Path $resolved)) {
        return New-ToolResult -Ok $false -ErrorMessage "Path is outside the allowed root."
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        return New-ToolResult -Ok $false -ErrorMessage "Path is not a directory."
    }

    $items = @(Get-ChildItem -LiteralPath $resolved -Force | Sort-Object @{ Expression = { -not $_.PSIsContainer } }, Name)
    $selected = @($items | Select-Object -First $maxEntries)
    $entries = foreach ($item in $selected) {
        [ordered]@{
            name            = $item.Name
            type            = if ($item.PSIsContainer) { "directory" } else { "file" }
            size            = if ($item.PSIsContainer) { $null } else { $item.Length }
            last_write_time = $item.LastWriteTime.ToString("o")
        }
    }

    return New-ToolResult -Ok $true -Data @{
        path      = $resolved
        entries   = @($entries)
        truncated = ($items.Count -gt $selected.Count)
    }
}

function Invoke-ReadTextFileTool {
    param([object]$Arguments)

    if (-not (Test-AgentProperty -Object $Arguments -Name "path")) {
        return New-ToolResult -Ok $false -ErrorMessage "Missing required path."
    }

    $path = [string](Get-AgentProperty -Object $Arguments -Name "path")
    $maxChars = [int](Get-AgentProperty -Object $Arguments -Name "max_chars" -Default $MaxOutputChars)
    if ($maxChars -lt 1) { $maxChars = 1 }
    if ($maxChars -gt 100000) { $maxChars = 100000 }

    $resolved = Resolve-AgentPath -Path $path
    if (-not (Test-PathAllowed -Path $resolved)) {
        return New-ToolResult -Ok $false -ErrorMessage "Path is outside the allowed root."
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return New-ToolResult -Ok $false -ErrorMessage "Path is not a file."
    }

    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    $sampleLength = [Math]::Min($bytes.Length, 4096)
    for ($i = 0; $i -lt $sampleLength; $i++) {
        if ($bytes[$i] -eq 0) {
            return New-ToolResult -Ok $false -ErrorMessage "File appears to be binary."
        }
    }

    $content = [System.IO.File]::ReadAllText($resolved)
    $truncated = $content.Length -gt $maxChars
    if ($truncated) {
        $content = $content.Substring(0, $maxChars)
    }

    return New-ToolResult -Ok $true -Data @{
        path           = $resolved
        content        = $content
        chars_returned = $content.Length
        truncated      = $truncated
    }
}

function Invoke-SearchFilesTool {
    param([object]$Arguments)

    if (-not (Test-AgentProperty -Object $Arguments -Name "query")) {
        return New-ToolResult -Ok $false -ErrorMessage "Missing required query."
    }

    $query = [string](Get-AgentProperty -Object $Arguments -Name "query")
    $path = [string](Get-AgentProperty -Object $Arguments -Name "path" -Default ".")
    $maxMatches = [int](Get-AgentProperty -Object $Arguments -Name "max_matches" -Default $Script:DefaultSearchMatches)
    if ($maxMatches -lt 1) { $maxMatches = 1 }
    if ($maxMatches -gt 500) { $maxMatches = 500 }

    $resolved = Resolve-AgentPath -Path $path
    if (-not (Test-PathAllowed -Path $resolved)) {
        return New-ToolResult -Ok $false -ErrorMessage "Path is outside the allowed root."
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        return New-ToolResult -Ok $false -ErrorMessage "Path is not a directory."
    }

    $files = Get-ChildItem -LiteralPath $resolved -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $fullName = $_.FullName
            foreach ($skip in $Script:SkipDirectoryNames) {
                if ($fullName -match ("[\\/]" + [regex]::Escape($skip) + "[\\/]")) {
                    return $false
                }
            }
            return $true
        }

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        if ($matches.Count -ge $maxMatches) { break }
        try {
            $found = Select-String -LiteralPath $file.FullName -Pattern $query -SimpleMatch -ErrorAction Stop
            foreach ($match in $found) {
                $matches.Add([ordered]@{
                        path    = $file.FullName
                        line    = $match.LineNumber
                        preview = $match.Line.Trim()
                    })
                if ($matches.Count -ge $maxMatches) { break }
            }
        } catch {
            continue
        }
    }

    return New-ToolResult -Ok $true -Data @{
        query     = $query
        path      = $resolved
        matches   = @($matches)
        truncated = ($matches.Count -ge $maxMatches)
    }
}

function Test-DestructiveCommand {
    param([string]$Command)

    $patterns = @(
        "\bRemove-Item\b",
        "\brm\b",
        "\bdel\b",
        "\berase\b",
        "\brmdir\b",
        "\brd\b",
        "\bFormat-[A-Za-z]+\b",
        "\bgit\s+reset\b",
        "\bgit\s+clean\b",
        "\bStop-Service\b",
        "\bRestart-Computer\b",
        "\bshutdown\b"
    )

    foreach ($pattern in $patterns) {
        if ($Command -match $pattern) {
            return $true
        }
    }
    return $false
}

function Invoke-ApprovedPowerShellTool {
    param([object]$Arguments)

    if (-not (Test-AgentProperty -Object $Arguments -Name "command")) {
        return New-ToolResult -Ok $false -ErrorMessage "Missing required command."
    }

    $command = [string](Get-AgentProperty -Object $Arguments -Name "command")
    $description = [string](Get-AgentProperty -Object $Arguments -Name "description" -Default "")

    Write-Host ""
    Write-Strong "Proposed PowerShell command"
    if ($description.Trim()) {
        Write-Dim $description.Trim()
    }
    Write-Success $command
    Write-Dim "Folder: $Script:Root"
    if (Test-DestructiveCommand -Command $command) {
        Write-WarnLine "Warning: this command looks destructive. Review it carefully."
    }

    $choice = Read-Host "Run this command? [y/N]"
    if (([string]$choice).Trim().ToLowerInvariant() -ne "y") {
        return New-ToolResult -Ok $false -Data @{
            approved = $false
            command  = $command
        } -ErrorMessage "User denied command execution."
    }

    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) {
        $exe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh" } else { "powershell" }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.ArgumentList.Add("-NoProfile")
    $psi.ArgumentList.Add("-Command")
    $psi.ArgumentList.Add($command)
    $psi.WorkingDirectory = $Script:Root
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    Write-Dim "Running..."
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $combinedLength = $stdout.Length + $stderr.Length
    $truncated = $combinedLength -gt $MaxOutputChars
    if ($truncated) {
        $remaining = $MaxOutputChars
        if ($stdout.Length -gt $remaining) {
            $stdout = $stdout.Substring(0, $remaining)
            $stderr = ""
        } else {
            $remaining -= $stdout.Length
            if ($stderr.Length -gt $remaining) {
                $stderr = $stderr.Substring(0, $remaining)
            }
        }
    }

    return New-ToolResult -Ok ($process.ExitCode -eq 0) -Data @{
        approved         = $true
        command          = $command
        exit_code        = $process.ExitCode
        stdout           = $stdout
        stderr           = $stderr
        output_truncated = $truncated
    }
}

function Get-ToolDefinitions {
    return @(
        [ordered]@{
            type        = "function"
            name        = "get_environment_context"
            description = "Return safe local context: current directory, OS, PowerShell version, and timestamp. Does not read files or run commands."
            parameters  = [ordered]@{
                type       = "object"
                properties = [ordered]@{}
            }
        },
        [ordered]@{
            type        = "function"
            name        = "list_directory"
            description = "List files and folders under an allowed path. Read-only. Use before reading files when folder contents are unknown."
            parameters  = [ordered]@{
                type       = "object"
                properties = [ordered]@{
                    path        = [ordered]@{ type = "string"; description = "Directory path relative to the starting folder, or an allowed absolute path." }
                    max_entries = [ordered]@{ type = "integer"; description = "Maximum entries to return. Defaults to 200; capped at 1000." }
                }
            }
        },
        [ordered]@{
            type        = "function"
            name        = "read_text_file"
            description = "Read a text file under the allowed root. Read-only. Returns truncated content when needed."
            parameters  = [ordered]@{
                type       = "object"
                properties = [ordered]@{
                    path      = [ordered]@{ type = "string"; description = "File path relative to the starting folder, or an allowed absolute path." }
                    max_chars = [ordered]@{ type = "integer"; description = "Maximum characters to return." }
                }
                required   = @("path")
            }
        },
        [ordered]@{
            type        = "function"
            name        = "search_files"
            description = "Search text files recursively under an allowed directory. Read-only. Skips common dependency/cache folders."
            parameters  = [ordered]@{
                type       = "object"
                properties = [ordered]@{
                    query       = [ordered]@{ type = "string"; description = "Literal text to search for." }
                    path        = [ordered]@{ type = "string"; description = "Directory path to search. Defaults to current folder." }
                    max_matches = [ordered]@{ type = "integer"; description = "Maximum matches to return. Defaults to 50; capped at 500." }
                }
                required   = @("query")
            }
        },
        [ordered]@{
            type        = "function"
            name        = "execute_powershell"
            description = "Propose one PowerShell command to execute. The user must approve before it runs. Use for actions requiring shell execution or mutation."
            parameters  = [ordered]@{
                type       = "object"
                properties = [ordered]@{
                    command     = [ordered]@{ type = "string"; description = "Full PowerShell command to run after user approval." }
                    description = [ordered]@{ type = "string"; description = "Brief explanation of what the command does and why it is needed." }
                }
                required   = @("command")
            }
        }
    )
}

function Find-FunctionCalls {
    param([object]$Node)

    $found = New-Object System.Collections.Generic.List[object]

    function Visit {
        param([object]$Current)

        if ($null -eq $Current) { return }

        if ($Current -is [System.Collections.IEnumerable] -and -not ($Current -is [string])) {
            foreach ($item in $Current) {
                Visit -Current $item
            }
            return
        }

        if ((Test-AgentProperty -Object $Current -Name "type") -and
            (Get-AgentProperty -Object $Current -Name "type") -eq "function_call") {
            $found.Add($Current)
        }

        foreach ($property in $Current.PSObject.Properties) {
            if ($property.Value -is [System.Management.Automation.PSCustomObject] -or
                ($property.Value -is [System.Collections.IEnumerable] -and -not ($property.Value -is [string]))) {
                Visit -Current $property.Value
            }
        }
    }

    Visit -Current $Node
    return $found.ToArray()
}

function Get-OutputText {
    param([object]$Node)

    $parts = New-Object System.Collections.Generic.List[string]

    function VisitText {
        param([object]$Current)

        if ($null -eq $Current) { return }

        if ($Current -is [System.Collections.IEnumerable] -and -not ($Current -is [string])) {
            foreach ($item in $Current) {
                VisitText -Current $item
            }
            return
        }

        if ((Test-AgentProperty -Object $Current -Name "type") -and
            (Get-AgentProperty -Object $Current -Name "type") -eq "output_text" -and
            (Test-AgentProperty -Object $Current -Name "text")) {
            $parts.Add([string](Get-AgentProperty -Object $Current -Name "text"))
        }

        foreach ($property in $Current.PSObject.Properties) {
            if ($property.Value -is [System.Management.Automation.PSCustomObject] -or
                ($property.Value -is [System.Collections.IEnumerable] -and -not ($property.Value -is [string]))) {
                VisitText -Current $property.Value
            }
        }
    }

    VisitText -Current $Node
    return ($parts -join "`n")
}

function Parse-ToolArguments {
    param([object]$Call)

    if (-not (Test-AgentProperty -Object $Call -Name "arguments") -or $null -eq (Get-AgentProperty -Object $Call -Name "arguments")) {
        return [pscustomobject]@{}
    }
    $arguments = Get-AgentProperty -Object $Call -Name "arguments"
    if ($arguments -is [string]) {
        if ([string]::IsNullOrWhiteSpace($arguments)) {
            return [pscustomobject]@{}
        }
        return ($arguments | ConvertFrom-Json)
    }
    return $arguments
}

function Format-ToolArguments {
    param([object]$Arguments)

    $json = ConvertTo-AgentJson -Value $Arguments -Depth 10
    if ($json.Length -gt 2000) {
        return $json.Substring(0, 2000) + "... (truncated)"
    }
    return $json
}

function Write-ToolCallLine {
    param([object]$Call)

    $name = [string](Get-AgentProperty -Object $Call -Name "name")
    $arguments = Parse-ToolArguments -Call $Call

    Write-Host ""
    Write-Host "Tool: $name" -ForegroundColor Cyan

    if ($name -eq "execute_powershell") {
        $command = [string](Get-AgentProperty -Object $arguments -Name "command" -Default "")
        $description = [string](Get-AgentProperty -Object $arguments -Name "description" -Default "")
        if ($description.Trim()) {
            Write-Dim "Use: $($description.Trim())"
        }
        if ($command.Trim()) {
            Write-Success "Command: $command"
        }
        return
    }

    Write-Dim ("Args: " + (Format-ToolArguments -Arguments $arguments))
}

function Invoke-AgentTool {
    param([object]$Call)

    $name = [string](Get-AgentProperty -Object $Call -Name "name")
    try {
        $arguments = Parse-ToolArguments -Call $Call
        switch ($name) {
            "get_environment_context" { return Get-EnvironmentContext }
            "list_directory" { return Invoke-ListDirectoryTool -Arguments $arguments }
            "read_text_file" { return Invoke-ReadTextFileTool -Arguments $arguments }
            "search_files" { return Invoke-SearchFilesTool -Arguments $arguments }
            "execute_powershell" { return Invoke-ApprovedPowerShellTool -Arguments $arguments }
            default { return New-ToolResult -Ok $false -ErrorMessage "Unknown tool: $name" }
        }
    } catch {
        return New-ToolResult -Ok $false -ErrorMessage $_.Exception.Message
    }
}

function Add-ResponseOutputToConversation {
    param(
        [System.Collections.Generic.List[object]]$Conversation,
        [object]$Response
    )

    if (Test-AgentProperty -Object $Response -Name "output") {
        $outputItems = Get-AgentProperty -Object $Response -Name "output"
        foreach ($item in $outputItems) {
            $Conversation.Add($item)
        }
    }
}

function Add-ToolOutputToConversation {
    param(
        [System.Collections.Generic.List[object]]$Conversation,
        [object]$Call,
        [object]$Result
    )

    $callId = if (Test-AgentProperty -Object $Call -Name "call_id") {
        [string](Get-AgentProperty -Object $Call -Name "call_id")
    } else {
        [string](Get-AgentProperty -Object $Call -Name "id")
    }
    $Conversation.Add([ordered]@{
            type    = "function_call_output"
            id      = "fc_output_$([guid]::NewGuid().ToString("N"))"
            call_id = $callId
            output  = ConvertTo-AgentJson -Value $Result
        })
}

function Get-SystemPrompt {
    return @"
You are a careful CLI assistant running on Windows inside a PowerShell-only agent.

Use tools to inspect and act. Read-only tools may run automatically. The execute_powershell tool always requires user approval before execution.

Rules:
- Never claim a command ran unless a tool result says it ran.
- Prefer read-only inspection tools before proposing risky commands.
- Use execute_powershell for shell work, changes, package commands, tests, or anything that must run locally.
- Keep commands scoped to the current working directory unless the user explicitly asks otherwise.
- Avoid destructive commands unless the user clearly requested them.
- When done, return a concise final answer with what happened and any relevant command output summary.
"@
}

function Get-DirectoryContext {
    $result = Invoke-ListDirectoryTool -Arguments ([pscustomobject]@{
            path        = "."
            max_entries = $Script:DefaultDirectoryEntries
        })
    return ConvertTo-AgentJson -Value $result
}

function Invoke-OpenRouter {
    param([System.Collections.Generic.List[object]]$Conversation)

    $payload = [ordered]@{
        model             = $Model
        input             = @($Conversation)
        tools             = Get-ToolDefinitions
        tool_choice       = "auto"
        max_output_tokens = 5000
    }

    $headers = @{
        Authorization  = "Bearer $env:OPENROUTER_API_KEY"
        "Content-Type" = "application/json"
    }

    return Invoke-RestMethod -Uri $Script:ApiUrl -Method Post -Headers $headers -Body (ConvertTo-AgentJson -Value $payload -Depth 50) -TimeoutSec 120
}

if (-not $env:OPENROUTER_API_KEY) {
    Write-ErrorLine "Set OPENROUTER_API_KEY, then try again."
    exit 1
}

if ($Prompt.Count -eq 0) {
    Write-Host "Run: .\or-agent.ps1 [-f] <what you want to do>"
    Write-Dim "  -f / -IncludeFiles  include this folder's file list in the first prompt"
    exit 1
}

if ($MaxSteps -lt 1) {
    $MaxSteps = 1
}
if ($MaxOutputChars -lt 1000) {
    $MaxOutputChars = 1000
}

$userPrompt = ($Prompt -join " ")
if ($IncludeFiles) {
    $userPrompt = $userPrompt + "`n`nCurrent folder listing:`n" + (Get-DirectoryContext)
}

$conversation = [System.Collections.Generic.List[object]]::new()
$conversation.Add((New-TextMessage -Role "system" -Text (Get-SystemPrompt)))
$conversation.Add((New-TextMessage -Role "user" -Text $userPrompt))

$step = 0
$stepBudget = $MaxSteps

while ($true) {
    if ($step -ge $stepBudget) {
        $choice = Read-Host "Reached step limit $stepBudget. Continue for $Script:MoreStepsIncrement more steps? [y/N]"
        if (([string]$choice).Trim().ToLowerInvariant() -ne "y") {
            Write-Dim "Stopped: reached step limit and user chose not to continue."
            Exit-Agent 0
        }
        $stepBudget += $Script:MoreStepsIncrement
    }

    $step++
    Write-Step "Step $step/$stepBudget"
    Write-Dim "Asking the model..."

    try {
        $response = Invoke-OpenRouter -Conversation $conversation
    } catch {
        Write-ErrorLine "Something went wrong talking to the API."
        Write-Dim $_.Exception.Message
        Exit-Agent 1
    }

    Write-UsageLine -Response $response
    Add-ResponseOutputToConversation -Conversation $conversation -Response $response

    $calls = @(Find-FunctionCalls -Node $response)
    if ($calls.Count -eq 0) {
        $text = Get-OutputText -Node $response
        if ($text.Trim()) {
            Write-Host ""
            Write-Host $text.Trim()
            Exit-Agent 0
        }

        Write-ErrorLine "No tool call or final text came back. Try asking in a different way."
        Exit-Agent 1
    }

    foreach ($call in $calls) {
        Write-ToolCallLine -Call $call
        $toolResult = Invoke-AgentTool -Call $call
        Add-ToolOutputToConversation -Conversation $conversation -Call $call -Result $toolResult

        if ((Get-AgentProperty -Object $call -Name "name") -eq "execute_powershell" -and
            $toolResult.Contains("approved") -and
            -not $toolResult["approved"]) {
            Write-Dim "Cancelled."
            Exit-Agent 0
        }
    }
}
