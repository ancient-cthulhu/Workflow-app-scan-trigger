# Veracode Workflow App - Issue Scan Trigger Script

Creates or closes GitHub issues across repositories in one or more GitHub organizations to trigger Veracode scans via the Veracode Workflow App. Handles archived repos, temporarily disabled Issues, duplicate prevention, rate limiting, scan pacing, stale scan detection, repo filtering, Veracode profile existence check, parallel processing, and multi-org runs with a CSV audit trail.

---

## How It Works

For each repository in the target organization, the script:

1. Skips archived repositories
2. Optionally filters repos by org/repo combination (`--org-repo-file`), name list (`--repo-file`), or wildcard pattern (`--repo-wildcard`)
3. Optionally skips repos that already have a Veracode application profile on the platform (`--veracode-skip-existing`)
4. Optionally checks for recent Veracode scans and skips repos scanned within N days (`--stale-days`)
5. Temporarily enables Issues if disabled (restores original state after)
6. Checks for an existing open trigger issue to avoid duplicates
7. Waits for a creation slot (`--create-interval`, `--batch-size`, `--max-inflight`)
8. Creates the trigger issue, then reads it back to confirm it actually exists
9. Writes a per-repo result row to the CSV audit trail
10. Proactively checks GitHub Core **and GraphQL** rate limits and sleeps until reset if either is low

Repos within an org are processed in parallel by a configurable thread pool (`--workers`). Each repo is one atomic work unit so the enable-issues / create-issue / restore-issues sequence stays consistent per repo while different repos run concurrently. Issue creation itself is serialized globally regardless of worker count.

> **Scans are not triggered directly.** The issue acts as a signal to the Veracode Workflow App, which initiates scans based on the `veracode.yml` configuration in each repository. If `issues.trigger` is not set to `true` in `veracode.yml`, no scan will start.

---

## Quickstart

Always dry run first.

```bash
# 1. See what would happen. No writes.
python script.py --dry-run --stale-days 30 --veracode-skip-existing my-github-org

# 2. Pilot on a slice, confirm scans complete end to end.
python script.py --repo-wildcard "api-*" --create-interval 30 --max-inflight 10 my-github-org

# 3. Bulk run, paced.
python script.py --org-file orgs.txt --stale-days 30 --veracode-skip-existing \
  --workers 5 --create-interval 25 --max-inflight 15 --batch-size 50 --batch-pause 1200
```

### Other common runs

```bash
# Single org
python script.py my-github-org

# Multiple orgs
python script.py --org-file orgs.txt

# Specific org/repo combinations
python script.py --org-repo-file org_repos.csv

# Specific repos
python script.py --repo-file repos.txt my-github-org

# Wildcard
python script.py --repo-wildcard "*-service" my-github-org

# Clean up
python script.py --delete --org-file orgs.txt
```

---

## Requirements

```bash
gh --version      # GitHub CLI v2+
python --version  # Python 3.10+
```

Stdlib only by default. `--veracode-skip-existing` additionally requires:

```bash
pip install veracode-api-signing requests
```

---

## Credentials

### GitHub.com and GHEC

```bash
gh auth login
# or
export GH_TOKEN=ghp_yourtoken
```

Use a token dedicated to this script. Do not reuse the Workflow App's token, and never use a workflow's `GITHUB_TOKEN`.

### GitHub Enterprise Server (GHES)

```bash
gh auth login --hostname github.mycompany.com
# or
export GH_ENTERPRISE_TOKEN=ghp_yourtoken
```

When using `--hostname`, the script injects `GH_HOST` into every `gh` call automatically. The script warns if `--hostname` points to a GHES instance but `GH_ENTERPRISE_TOKEN` is not set.

### Veracode (only required with `--veracode-skip-existing`)

```bash
export VERACODE_API_KEY_ID=your_api_id
export VERACODE_API_KEY_SECRET=your_api_secret
```

Or `~/.veracode/credentials`:

```ini
[default]
veracode_api_key_id = your_api_id
veracode_api_key_secret = your_api_secret
```

The API account needs read access to the Applications API (Security Lead, Reviewer, or Creator role).

### Required Permissions

| Operation | Required |
|-----------|----------|
| Create / close issues | Read access + permission to create issues |
| Enable Issues on repos where disabled | Admin permission on those repos |
| Read workflow run status (`--max-inflight`) | Actions read access |
| Query Veracode profiles | Veracode API account with read access to Applications |

---

## Veracode Workflow App Configuration (Required)

Each target repository must have `issues.trigger: true` in `veracode.yml` and include `"Veracode All Scans"` as a command under each scan type:

```yaml
issues:
  trigger: true
  commands:
    - "Veracode **** Scan"
    - "Veracode All Scans"
```

The command value must exactly match the Workflow App command name. This mismatch is the most common reason scans do not trigger after an issue is created.

---

## Command-Line Reference

| Flag | Description |
|------|-------------|
| `org` | Single org name (positional argument) |
| `--org-file FILE` | Text file with one org per line. `#` and blank lines ignored. Mutually exclusive with the positional org and `--org-repo-file`. |
| `--org-repo-file FILE` | CSV file with 2 columns: `org` and `repo`. Supports quoted values. Targets only the listed org/repo combinations. `#` and blank lines ignored. Mutually exclusive with the positional org, `--org-file`, `--repo-file` and `--repo-wildcard`. See [Org-Repo Filtering](#org-repo-filtering). |
| `--repo-file FILE` | Text file with one repo name per line (no org prefix). Mutually exclusive with `--repo-wildcard` and `--org-repo-file`. |
| `--repo-wildcard PATTERN` | Wildcard filter, case-insensitive. Mutually exclusive with `--repo-file` and `--org-repo-file`. |
| `--delete` | Close previously created trigger issues instead of creating new ones |
| `--dry-run` | Report what would happen. Makes no writes of any kind. Works in create and delete mode. |
| `--stale-days N` | Only create issues for repos not scanned in the last N days. Disabled by default. `0` disables. Ignored in delete mode. |
| `--veracode-skip-existing` | Query the Veracode platform once at startup and skip repos that already have a profile named `<org>/<repo>` (case-insensitive). |
| `--veracode-region {commercial,eu,federal}` | Veracode region (default: `commercial`) |
| `--workers N` | Parallel worker threads per org (default: `5`, max: `50`). Affects reads and skip paths only. Issue creation is always serial. |
| `--create-interval SECONDS` | **Minimum seconds between issue creations, global across all workers and orgs (default: `25`).** |
| `--batch-size N` | Pause after every N issues created (`0` = off) |
| `--batch-pause SECONDS` | Seconds to pause between batches so the Veracode queue drains (default: `900`) |
| `--max-inflight N` | Do not create a new issue while N triggered scans are still queued or running (`0` = off) |
| `--hostname HOSTNAME` | GitHub hostname. Omit for github.com. GHES: `github.mycompany.com`. GHEC: `myorg.ghe.com`. |
| `--output FILE` | CSV output path (default: `vcbaseline.csv`) |
| `--repo-limit N` | Max repos to fetch per org (default: `1000`). The script warns if a result hits this number, as the list may be truncated. |
| `--min-remaining N` | Pause when Core or GraphQL remaining <= N (default: `100`) |
| `--rl-check-every N` | Query the rate limit every N gh calls (default: `50`) |

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `GH_RL_MIN_REMAINING` | `100` | Same as `--min-remaining` |
| `GH_RL_CHECK_EVERY` | `50` | Same as `--rl-check-every` |
| `REPO_LIST_LIMIT` | `1000` | Same as `--repo-limit` |
| `GH_POINTS_PER_MIN` | `700` | Secondary-limit point budget (GitHub allows 900 REST / 2000 GraphQL) |
| `GH_CONTENT_PER_MIN` | `20` | Content writes per minute (GitHub allows 80) |
| `GH_CONTENT_PER_HOUR` | `140` | Content writes per hour (GitHub allows 500) |
| `GH_SEARCH_PER_MIN` | `25` | Issue-title searches per minute (GitHub allows 30) |

Flags take precedence over the env vars they share a default with.

---

## Pacing and Why It Matters

Creating hundreds of issues at once queues hundreds of Actions jobs. Those jobs sit waiting on the Veracode scan queue and on your Actions concurrency entitlement, and the `GITHUB_TOKEN` inside each job expires when the job finishes or at its maximum lifetime: 6 hours on GitHub-hosted runners, up to 24 hours on self-hosted. Jobs that queue too long die with a 401 or get cancelled. That is a pacing problem on this side, not a Workflow App bug.

Three controls, use them together:

| Control | Protects against |
|---------|------------------|
| `--create-interval` | GitHub's undisclosed issue-creation limit (fails silently, see below) |
| `--batch-size` / `--batch-pause` | Bulk floods that outrun the Veracode queue |
| `--max-inflight` | Actions jobs aging out past the 6h job / token lifetime |

Sizing `--max-inflight`: set it to roughly your Veracode concurrent-scan capacity, and never above your Actions concurrent-job entitlement. If your median scan is 30 minutes and the cap is 15, you drain about 30 scans/hour, so `--create-interval 120` matches. If a scan can approach 6 hours, `--max-inflight` is not optional.

`--max-inflight` costs one Actions API read per pending repo per poll (60s poll interval), so keep the cap modest.

---

## Rate Limit Handling

GitHub's published limits: 900 points/min for REST, 2,000 points/min for GraphQL, 100 concurrent requests shared across both, 80 content-generating requests/min and 500/hour, and at least 1 second between mutative requests. Some endpoints, including issue creation, have lower undisclosed content limits.

The script handles these automatically:

- **Primary limits**: checks Core **and** GraphQL buckets (`gh repo list`, `gh issue list` and `gh repo edit` are GraphQL, so Core alone never fires) and sleeps until whichever is closer to empty resets. State is shared across all worker threads.
- **Secondary limits**: a shared throttle enforces the point, content/min, content/hour and search/min budgets, plus a 1 second minimum gap between mutations, across every worker. A secondary-limit hit pauses **all** workers, not just the one that hit it, with exponential backoff, retried up to 3 times, honouring `Retry-After` where present.
- **Silent failures**: GitHub returns HTTP 200 with an error body when the GraphQL primary limit is hit, and 200 or 403 on secondary limits, so exit code alone is not proof. The script inspects response bodies and, after every issue creation, reads the issue back to confirm it exists. A create that reports success but produces no visible issue is recorded as `failed_silent_block`.
- **Auth failures** (bad credentials, 404, insufficient permissions): not retried, reported immediately, recorded in the CSV.
- **Veracode 429 / 5xx**: retried with backoff at startup, honouring `Retry-After`. Aborts the run after retries are exhausted, and also aborts if the platform returns zero profiles.

Rate limit pauses are logged to stderr so the CSV output stays clean.

---

## Parallel Processing

`--workers` controls reads and skip paths. Issue creation is serialized by `--create-interval` regardless, so raising workers does not increase creation risk.

| Workers | Use case |
|---------|----------|
| `1` | Sequential, easiest to debug |
| `3-5` | Conservative default |
| `8-15` | Typical runs of a few hundred repos |
| `20-30` | Read-heavy runs where most repos hit a fast skip path (`--stale-days`, `--veracode-skip-existing`) |
| `30-50` | Very large orgs, mostly skips |

Per-repo log lines are buffered and printed as one contiguous block prefixed `[N/total] org/repo`, in completion order. Use `--workers 1` for strict sequential output.

Wall-clock time on a create-heavy run is set by `--create-interval`, not by `--workers`. At the default 25s that is about 140 issues/hour.

---

## Repo Filtering

### By name list (`--repo-file`)

```text
# repos.txt
my-api
frontend-app
shared-lib
```

```bash
python script.py --repo-file repos.txt my-github-org
```

Case-insensitive. `#` and blank lines ignored.

### By wildcard (`--repo-wildcard`)

| Pattern | Matches |
|---------|---------|
| `example*` | Starts with "example" |
| `*example` | Ends with "example" |
| `*example*` | Contains "example" |
| `ex?mple` | Single character wildcard |
| `api-v[12]` | Character set |

Case-insensitive, applied to the repo name only, not the org prefix.

Both filters combine with `--stale-days`, `--veracode-skip-existing`, `--workers` and `--delete`.

---

## Org-Repo Filtering

Use `--org-repo-file` to target specific org/repo combinations without maintaining a separate `--repo-file` list per org. Useful when you want to run across multiple orgs but only on a subset of repositories in each.

### Filter by org/repo combination (`--org-repo-file`)

Create a CSV file with 2 columns, `org` and `repo`:

```csv
# org_repos.csv
# Comments start with #
my-org,api-service
my-org,frontend-app
other-org,backend-api
other-org,shared-lib
third-org,core-lib
```

Quoted values are supported:

```csv
"my-org","api-service"
"my-org","frontend-app"
"other-org","backend-api"
```

```bash
python script.py --org-repo-file org_repos.csv
```

The org list is derived from the file, so no positional org or `--org-file` is needed (and neither is allowed alongside it). Matching is case-insensitive. Lines starting with `#` and blank lines are ignored. The file is read with Python's CSV reader with quote support, so values containing special characters can be quoted safely.

Combines with `--stale-days`, `--veracode-skip-existing`, `--workers` and `--delete`:

```bash
# Only listed org/repo combinations not scanned in 30 days, 10 workers
python script.py --org-repo-file org_repos.csv --stale-days 30 --workers 10

# Skip repos with existing Veracode profiles
python script.py --org-repo-file org_repos.csv --veracode-skip-existing

# Close issues only on the listed org/repo combinations
python script.py --delete --org-repo-file org_repos.csv
```

---

## Veracode Profile Skip

`--veracode-skip-existing` fetches all application profiles from `appsec/v1/applications` once at startup, builds an in-memory set of lowercased names, then checks whether `<org>/<repo>` is present. The Workflow App always names profiles `<org>/<repo>`.

The check runs before any GitHub mutation, so repos with existing profiles are recorded as `skipped_veracode_profile_exists` without toggling Issues on.

**Fail-safe:** if the API is unreachable, errors after retries, or returns zero profiles, the script aborts before making any GitHub changes.

> **API cost:** one Veracode call per 500 profiles at startup, then in-memory. Pairs well with high `--workers`.

---

## Stale Scan Detection

`--stale-days N` queries check runs on each repo's default branch and looks for checks whose name starts with "veracode" (case-insensitive, matching SAST, SCA and IaC). If the most recent completed check is within the threshold, the repo is skipped.

```bash
python script.py --stale-days 30 my-github-org
```

> **Caveat:** check runs only exist for the **head commit of the default branch**. A repo that has been committed to since its last scan reports no checks and is treated as stale. Repos with no Veracode check history are also treated as stale.

> **API cost:** one additional API call per repo, parallelized under `--workers`.

---

## Large Deployments

Access to every org is validated before any processing, so a typo cannot produce a partial run.

```bash
# Orgs over 1,000 repos
python script.py --repo-limit 5000 my-github-org

# Very large, paced bulk run
GH_POINTS_PER_MIN=500 GH_CONTENT_PER_MIN=15 GH_CONTENT_PER_HOUR=140 \
python script.py --org-file orgs.txt \
  --repo-limit 10000 --stale-days 30 --veracode-skip-existing \
  --workers 15 --min-remaining 500 --rl-check-every 25 \
  --create-interval 25 --max-inflight 15 --batch-size 50 --batch-pause 1200 \
  2>&1 | tee vcbaseline.log
```

Run under `tmux` or `nohup`. Bulk runs are long by design.

### Resuming after a failure

The CSV is overwritten on each run. To retry only what did not get an issue:

```bash
awk -F, 'NR>1 && $9 !~ /^created/ {split($2,a,"/"); print a[2]}' vcbaseline.csv > retry.txt
python script.py my-github-org --repo-file retry.txt --output vcbaseline-retry.csv
```

---

## Output

`vcbaseline.csv` is written to the working directory (override with `--output`). One row per repository, all orgs in one file, filter by the `org` column. CSV writes are serialized across threads. Row order reflects completion order.

#### Create Mode

| Field | Description |
|-------|-------------|
| `org` | GitHub organization name |
| `repo` | Full `org/repo` name |
| `primary_language` | Repository primary language, or `N/A` |
| `issues_enabled` | Whether Issues were enabled before the run |
| `is_archived` | Whether the repository is archived |
| `veracode_profile_exists` | `true` / `false` with `--veracode-skip-existing`, empty otherwise |
| `last_check_date` | Timestamp of most recent Veracode check run |
| `days_since_check` | Days since the last Veracode check |
| `action` | Outcome, see below |

| `action` value | Meaning |
|----------------|---------|
| `created` | Issue created and verified present |
| `created_unverified` | Issue created but the read-back check itself errored. Verify manually. |
| `failed_silent_block` | Create returned success but no issue is visible. GitHub silently dropped it. Increase `--create-interval` and retry. |
| `created_restore_failed` | Created, but the repo's original issues-disabled state could not be restored. Manual cleanup may be required. |
| `dry_run_would_create` | `--dry-run` only. Would have created an issue. |
| `dry_run_needs_issues_enabled` | `--dry-run` only. Would have enabled Issues first. |
| `skipped_veracode_profile_exists` | Profile already exists on the Veracode platform |
| `skipped_recent_check` | Veracode check found within `--stale-days` |
| `skipped_existing_issue` | Open trigger issue already exists |
| `skipped_archived` | Repository is archived |
| `skipped_cant_enable_issues` | Issues could not be enabled (insufficient permissions) |
| `failed_create` | Issue creation API call failed |
| `failed_create_restore_failed` | Creation failed AND the issues-disabled state could not be restored |
| `failed_query_issues` | Could not check for existing issues; creation skipped to prevent duplicates |

#### Delete Mode

| Field | Description |
|-------|-------------|
| `org` | GitHub organization name |
| `repo` | Full `org/repo` name |
| `primary_language` | Repository primary language, or `N/A` |
| `is_archived` | Whether the repository is archived |
| `veracode_profile_exists` | `true` / `false` with `--veracode-skip-existing`, empty otherwise |
| `issues_deleted` | Number of issues closed |
| `action` | Outcome, see below |

| `action` value | Meaning |
|----------------|---------|
| `deleted` | All matching issues closed |
| `partial_delete` | Some issues closed, some failed |
| `dry_run_would_close` | `--dry-run` only. Would have closed the listed issues. |
| `no_issues_found` | No open trigger issues found |
| `skipped_archived` | Repository is archived |
| `skipped_veracode_profile_exists` | Profile exists on the platform, issues preserved |
| `failed_enable_issues` | Issues could not be enabled to reach the existing issue |
| `failed_query_issues` | Could not query issues; repository skipped |

---

## Duplicate Protection

Before creating an issue, the script searches for an open issue with the same title using a server-side title search (`in:title`). If the check fails, creation is skipped and recorded as `failed_query_issues`. This prevents duplicates when the existing-issue check cannot be completed.

To re-trigger scans:

- Use `--delete` to close existing issues, then run again in create mode
- Close the existing issue manually
- Update `ISSUE_TITLE` in the script

---

## Troubleshooting

- **Scans fail with 401 / expired token, or jobs are cancelled**
  - Too many scans queued at once. The job's `GITHUB_TOKEN` dies with the job (6h hosted, up to 24h self-hosted). Add `--max-inflight` and raise `--create-interval`.

- **Issues created but no scan ever starts**
  - Check `issues.trigger: true` and the exact command string in `veracode.yml`. If the script ran inside Actions with `GITHUB_TOKEN`, the issue event never triggers a workflow. Use a PAT or App token.

- **`failed_silent_block` rows in the CSV**
  - GitHub's undisclosed issue-creation limit dropped the issue while returning success. Raise `--create-interval`, lower `GH_CONTENT_PER_MIN` / `GH_CONTENT_PER_HOUR`, and retry those repos with `--repo-file`.

- **"API rate limit exceeded / HTTP 403 / secondary rate limit / submitted too quickly"**
  - Handled automatically, all workers pause. If frequent, tighten:
    ```bash
    python script.py --workers 3 --min-remaining 200 --rl-check-every 25 --org-file orgs.txt
    ```

- **Run feels slow**
  - Create-heavy runs are paced by `--create-interval`, by design. Read-heavy runs (`--delete`, `--stale-days`, `--veracode-skip-existing`) scale with `--workers`.

- **A repo was scanned recently but `--stale-days` still triggered it**
  - Check runs only exist for the default branch head. A commit since the last scan clears them.

- **"WORKER CRASHED" in stderr**
  - Unhandled exception on one repo. That repo counts as `failed`, the run continues. Re-run it with `--repo-file`.

- **"Cannot access the following org(s)" on startup**
  - Typo, or the token lacks access. No changes are made until every org is confirmed.

- **"Expected 2 columns (org, repo)" when using --org-repo-file**
  - A line has the wrong number of comma-separated columns. Each line must have exactly 2.

- **"org and repo cannot be empty" when using --org-repo-file**
  - One column is empty or whitespace only. Both values must be non-empty.

- **"No org-repo pairs found" when using --org-repo-file**
  - Every line is blank or starts with `#`. Add at least one uncommented pair.

- **"Invalid org name(s)" / "Invalid repo name(s)"**
  - Org names: alphanumeric and hyphens, must start and end alphanumeric, max 39 chars. Repo names: alphanumeric, hyphen, underscore, period, plus glob characters.

- **`created_restore_failed` or `failed_create_restore_failed` rows**
  - The script enabled Issues on a repo and could not re-disable them. Filter the CSV for these and disable Issues manually.

- **"Veracode profile fetch failed" or "returned 0 application profiles"**
  - Check credentials, that the account has read access to the Applications API, and that `--veracode-region` matches your account. Zero profiles aborts on purpose: the skip would match nothing and every repo would be triggered.

- **"SyntaxError" or unexpected failures**
  - Requires Python 3.10 or newer.

- **GHES: "authentication failed" or "Could not resolve host"**
  - Ensure `GH_ENTERPRISE_TOKEN` is set, `gh auth login --hostname your.ghes.host` has been run, and the host is reachable.

- **GHEC: targeting the wrong instance**
  - Use `--hostname myorg.ghe.com`. GHEC uses `GH_TOKEN`, not `GH_ENTERPRISE_TOKEN`.
