
# Veracode Workflow App - Issue Scan Trigger Script

## Overview

This script is to be executed **locally using GitHub CLI** to create GitHub issues across repositories in a GitHub organization.  
These issues act as **triggers for the Veracode Workflow App**, initiating scans based on each repository's `veracode.yml` configuration.

The script is safe, idempotent, and auditable.

---

## What the Script Does

For each repository in the specified GitHub organization, the script:

1. Lists repositories using the GitHub CLI
2. Skips archived repositories
3. Checks whether Issues are enabled
4. Temporarily enables Issues if required
5. Creates a trigger issue
6. Avoids creating duplicate open issues
7. Restores the original Issues configuration
8. Generates a CSV report of all actions taken

---

## What the Script Does Not Do

- It does not run Veracode scans directly
- It does not modify source code
- It does not create issues in archived repositories
- It does not permanently change repository settings
- It does not permanently delete issues (closes them instead)

---

## System Requirements (Local PC)

### Supported Environments
- Linux
- macOS
- Windows via WSL2

### Required Tools
- Bash
- GitHub CLI (`gh`) v2+

Verify installation:
```bash
gh --version
```

---

## Authentication and Permissions

Authenticate the GitHub CLI before running the script:

```bash
gh auth login
```

The authenticated user must have:

- Read access to all target repositories
- Permission to create issues
- Admin permission on repositories where Issues may be disabled (recommended)

If the user cannot enable Issues on a repository, the script will safely skip issue creation and record the reason in the output.

---

## Veracode Workflow App Configuration (Required)

For issue-based triggers to work, each target repository **must allow issue triggers** in `veracode.yml` for each of the desired scan types (SAST, SCA, IaC).

### Required `veracode.yml` Configuration

```yaml
issues:
  trigger: true
  commands:
    - "Veracode All Scans"
```

### Important Notes

- If `issues.trigger` is set to `false`, the script will create the issue but **no scan will start**
- The command value **must exactly match** the Workflow App command name:  
  `Veracode All Scans`
- `veracode.yml` must already exist in the repository

This configuration mismatch is the most common reason scans do not trigger.

---

## Installation

1. Save the script as `veracode_trigger.sh`
2. Make it executable:
```bash
chmod +x veracode_trigger.sh
```

---

## Running the Script

### Trigger Scans / Create Issues Mode (Default)

Run the script with the GitHub organization name to create trigger issues:

```bash
./veracode_trigger.sh <github-org-name>
```

Example:
```bash
./veracode_trigger.sh my-github-org
```

### Delete Issues Mode

Run the script with the `--delete` flag to remove previously created trigger issues:

```bash
./veracode_trigger.sh --delete <github-org-name>
```

Example:
```bash
./veracode_trigger.sh --delete my-github-org
```

### Usage Help

Display usage information:

```bash
./veracode_trigger.sh
```

---

## Output

### CSV Report

A file named `vcbaseline.csv` is generated in the working directory.

#### Create Mode Fields:
- `repo`
- `primary_language`
- `issues_enabled`
- `is_archived`
- `action`

Common `action` values:
- `created`
- `skipped_archived`
- `skipped_existing_issue`
- `skipped_cant_enable_issues`
- `failed_create`

#### Delete Mode Fields:
- `repo`
- `primary_language`
- `is_archived`
- `issues_deleted`
- `action`

Common `action` values:
- `deleted`
- `partial_delete`
- `no_issues_found`
- `skipped_archived`

The CSV serves as the execution audit trail.

---

## Duplicate Protection

The script checks for an **open issue with the same title** before creating a new one.

To re-trigger scans:
- Use the `--delete` flag to clean up existing issues, then run in create mode again
- Close the existing issue manually, or
- Update the issue title in the script

---

## Intended Use

- Veracode onboarding at scale
- Organization-wide scan triggering
- Periodic re-scans
- Local DevSecOps automation
- Cleanup of trigger issues after scan completion

---

## Common Workflows

### Initial Scan Trigger
```bash
./veracode_trigger.sh my-github-org
```

### Cleanup After Scans Complete
```bash
./veracode_trigger.sh --delete my-github-org
```

### Re-trigger All Scans
```bash
# First, clean up existing issues
./veracode_trigger.sh --delete my-github-org

# Then, create new trigger issues
./veracode_trigger.sh my-github-org
```
