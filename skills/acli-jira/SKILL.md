---
name: acli-jira
description: Guide for managing Jira issues using the Atlassian CLI (acli). Use this when asked to search, create, edit, transition, or list Jira work items, epics, tasks, or subtasks.
---

# Jira Management with acli

Atlassian CLI (`acli`) interacts with Jira Cloud from the terminal. Authentication is already configured. Issue types available: `Epic`, `Task`, `Subtask`.

## Safety Rules

**CRITICAL: Follow these rules strictly:**

1. **NEVER use `--yes` flag** - This skips confirmation and is strictly forbidden
2. **ALWAYS ask for confirmation** before any EDIT, DELETE, TRANSITION, or CREATE operation
3. **READ-ONLY by default** - Only perform write operations (create/edit/transition) when explicitly requested
4. **No bulk operations without explicit approval** - For bulk edits via JQL, always show exactly how many issues will be affected and get explicit confirmation
5. **Use specific issue keys** - Prefer editing by specific issue keys rather than JQL queries when possible
6. **Show what will change** - Before executing, summarize exactly what will be modified
7. **No delete operations** - Do not perform any delete operations

## 1. When to use this skill
Use this skill when asked to:
- Search or list Jira issues, epics, or subtasks
- Create new tasks, subtasks, or epics
- Edit or rename existing issues
- Assign issues to team members
- Transition issue status (To Do / In Progress / Done)
- Add comments to issues
- List boards or sprints

## 2. First Step: List Available Projects

Always start by listing available projects to get the correct project keys:

```bash
acli jira project list --paginate
```

## 3. Reading All Issues

First, read all issues to understand the current state before making changes:

```bash
# List all issues in project
acli jira workitem search --jql "project = PROJ" --fields "key,summary,status,issuetype,assignee" --csv

# List all issues with pagination for large projects
acli jira workitem search --jql "project = PROJ" --paginate --csv
```

## 4. Searching Issues
Always use `--fields` with `--csv` for clean, parseable output. Use `--paginate` when results may exceed the default limit.

```bash
# Search by JQL
acli jira workitem search --jql "assignee = currentUser()" --fields "key,summary,status,assignee" --csv
acli jira workitem search --jql "labels in (AI)" --fields "key,summary,status,issuetype" --csv
acli jira workitem search --jql "status = 'In Progress'" --csv

# Get total count only
acli jira workitem search --jql "project = PROJ" --count

# Fetch all results (use when there are many issues)
acli jira workitem search --jql "labels in (AI)" --paginate --csv
```

## 5. Creating Issues

```bash
# Task
acli jira workitem create --summary "Title" --project "PROJ" --type "Task" --label "AI"

# Subtask under a parent
acli jira workitem create --summary "Title" --project "PROJ" --type "Subtask" --parent "PROJ-87" --label "AI"

# With assignee
acli jira workitem create --summary "Title" --project "PROJ" --type "Task" --assignee "user@example.com" --label "AI"
```

## 6. Editing Issues

```bash
# Rename
acli jira workitem edit --key "PROJ-87" --summary "New title"

# Assign to user
acli jira workitem edit --key "PROJ-87" --assignee "user@example.com"

# Self-assign
acli jira workitem edit --key "PROJ-87" --assignee "@me"

# Add labels
acli jira workitem edit --key "PROJ-87" --labels "AI,urgent"

# Bulk edit by JQL (always ask for confirmation first)
acli jira workitem edit --jql "labels in (AI)" --assignee "user@example.com"
```

## 7. Transitioning Status

```bash
acli jira workitem transition --key "PROJ-87" --status "In Progress"
acli jira workitem transition --key "PROJ-87" --status "Done"
acli jira workitem transition --key "PROJ-87" --status "To Do"
```

## 8. Other Operations

```bash
# View full issue details
acli jira workitem view --key "PROJ-87"

# Add a comment
acli jira workitem comment --key "PROJ-87" --comment "Update text here"

# Assign one or multiple issues
acli jira workitem assign --key "PROJ-87,PROJ-88" --assignee "user@example.com"

# List all boards
acli jira board search
```

## 9. Output Formats
- Default: Table — truncated for long values, avoid for parsing
- `--csv` — best for structured output and parsing
- `--json` — full raw JSON with all fields
- `--fields "key,summary,status"` — limit columns (combine with `--csv`)

## 10. Common JQL Reference

```bash
assignee = currentUser()          # Issues assigned to you
labels in (AI)                    # Issues with AI label
status = 'In Progress'            # Issues in progress
project = 'PROJ'                    # All issues in project PROJ
issuetype = 'Epic'                # Epics only
issuetype = 'Subtask'             # Subtasks only
assignee = 'user@example.com'     # Issues by specific user
summary ~ 'AI-101'                # Issues with AI-101 in title
parent = 'PROJ-87'                  # Subtasks of a specific parent
```

## Enforcement

**Remember to strictly enforce all safety rules mentioned in section "Safety Rules" before performing any write operations.**
