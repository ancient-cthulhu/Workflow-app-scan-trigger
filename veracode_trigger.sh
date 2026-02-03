#!/usr/bin/env bash

set -o pipefail

OUTPUT_FILE="vcbaseline.csv"
> "$OUTPUT_FILE"

ORG="${1:-}"
ISSUE_TITLE="Veracode Baseline Scans"
ISSUE_BODY="Veracode All Scans"

# Has the org name been provided as a parameter
if [[ -z "$ORG" ]]; then
  echo "Usage: $0 <github-org-name>"
  exit 1
fi

# Is the github cli installed
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is not installed."
  exit 1
fi

# Can we access the supplied org
echo "Checking access to organization: $ORG..."
if ! gh api "orgs/$ORG" --silent >/dev/null 2>&1; then
  echo "Error: You do not have access to the '$ORG' organization or it does not exist."
  exit 1
fi

total_count=0
iac_count=0
archived_count=0
created_count=0
skipped_existing_count=0
skipped_archived_count=0
skipped_issues_perm_count=0
failed_count=0

printf "repo,primary_language,issues_enabled,is_archived,action\n" >> "$OUTPUT_FILE"

# 1. Fetch repositories as TSV (reliable parsing)
# 2. Iterate using a while loop
while IFS=$'\t' read -r name_with_owner issues_enabled primary_lang is_archived; do
  echo "-------------------------------------------"
  echo "Processing $name_with_owner"
  total_count=$((total_count + 1))

  if [[ "$primary_lang" =~ ^(HCL|Bicep)$ ]]; then
    iac_count=$((iac_count + 1))
  fi

  if [[ "$is_archived" == "true" ]]; then
    archived_count=$((archived_count + 1))
    skipped_archived_count=$((skipped_archived_count + 1))
    echo "Repository is archived. Skipping."
    echo "$name_with_owner,$primary_lang,$issues_enabled,$is_archived,skipped_archived" >> "$OUTPUT_FILE"
    continue
  fi

  WAS_DISABLED=false
  if [[ "$issues_enabled" == "false" ]]; then
    echo "Issues are disabled. Temporarily enabling..."
    if ! gh repo edit "$name_with_owner" --enable-issues >/dev/null 2>&1; then
      echo "Could not enable issues. Skipping issue creation."
      skipped_issues_perm_count=$((skipped_issues_perm_count + 1))
      echo "$name_with_owner,$primary_lang,$issues_enabled,$is_archived,skipped_cant_enable_issues" >> "$OUTPUT_FILE"
      continue
    fi
    WAS_DISABLED=true
  fi

  existing_open_count=""
  existing_open_count=$(
    gh issue list \
      --repo "$name_with_owner" \
      --state open \
      --search "$ISSUE_TITLE in:title" \
      --json number \
      --jq 'length' 2>/dev/null || true
  )

  if [[ -n "$existing_open_count" && "$existing_open_count" != "0" ]]; then
    echo "Open issue with same title already exists. Skipping."
    skipped_existing_count=$((skipped_existing_count + 1))

    if [[ "$WAS_DISABLED" == true ]]; then
      echo "Restoring state: Disabling issues..."
      gh repo edit "$name_with_owner" --enable-issues=false >/dev/null 2>&1 || true
    fi

    echo "$name_with_owner,$primary_lang,$issues_enabled,$is_archived,skipped_existing_issue" >> "$OUTPUT_FILE"
    continue
  fi

  echo "Creating issue..."
  if gh issue create --repo "$name_with_owner" --title "$ISSUE_TITLE" --body "$ISSUE_BODY" >/dev/null 2>&1; then
    created_count=$((created_count + 1))
    action="created"
  else
    echo "Failed to create issue."
    failed_count=$((failed_count + 1))
    action="failed_create"
  fi

  if [[ "$WAS_DISABLED" == true ]]; then
    echo "Restoring state: Disabling issues..."
    gh repo edit "$name_with_owner" --enable-issues=false >/dev/null 2>&1 || true
  fi

  echo "$name_with_owner,$primary_lang,$issues_enabled,$is_archived,$action" >> "$OUTPUT_FILE"

done < <(
  gh repo list "$ORG" \
    --limit 1000 \
    --json nameWithOwner,hasIssuesEnabled,primaryLanguage,isArchived \
    --jq '.[] | [
      .nameWithOwner,
      (.hasIssuesEnabled|tostring),
      (.primaryLanguage.name // "N/A"),
      (.isArchived|tostring)
    ] | @tsv'
)

echo "Finished processing all repositories."
echo
echo "Repository Stats for Organization: $ORG"
echo "----------------------------------------------------------------"
echo "Total Repositories: $total_count"
echo "Archived Repositories: $archived_count"
echo "Skipped Archived: $skipped_archived_count"
echo "IaC Repositories: $iac_count (Primary language: HCL/Bicep)"
echo "Issues Permission Skips: $skipped_issues_perm_count"
echo "Skipped Existing Issues: $skipped_existing_count"
echo "Created Issues: $created_count"
echo "Failed Creates: $failed_count"
echo "CSV Output: $OUTPUT_FILE"
echo "----------------------------------------------------------------"
