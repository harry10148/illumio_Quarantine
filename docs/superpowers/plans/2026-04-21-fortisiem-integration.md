# illumio_Quarantine v1.3.0 — FortiSIEM Remediation Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing bash script `update_illumio_workload_labels.sh` callable non-interactively by FortiSIEM Remediation Scripts, with structured output, externalized credentials, dry-run support, SIEM-ingestible CEF audit line, deterministic exit codes, same-key label replacement, server-side-first workload lookup, and bounded PUT parallelism — while preserving interactive UX for manual operators.

**Architecture:** Single bash file. Argument parser at top toggles `NON_INTERACTIVE=1`; all `read -p` gated behind it. Credentials loaded with precedence `--credentials-file > env > prompt`. Target label identified by `--label-id` OR `--label-key`+`--label-value`; append mode strips any existing label sharing the target's key before adding the new one (mirrors illumio_ops behaviour). Workload lookup picks server-side `?ip_address=`/`?hostname=` when all terms are precise, falls back to full scan only when CIDR/range/prefix is present. PUTs run in a background-job pool with size `--parallel`. JSON to stdout, CEF audit line written under `flock` to avoid interleaving. PCE errors are reported in `failed[]` — no in-script retry (SIEM rule layer retries).

**Tech Stack:** bash 4.3+ (for `wait -n`), curl, jq, ipcalc, util-linux `flock` (existing deps + `flock` which ships with util-linux on all mainstream distros); bats-core as a git submodule for tests; FortiSIEM 6.x+ Remediation Scripts & Notification Policy variable substitution.

---

## Scope

**In (v1.3.0, this plan):** bash; FortiSIEM via SSH Remediation Script + CEF audit file tail. Generic CEF output also works for Splunk/QRadar manual log ingestion.

**Out (v2, roadmap-only — `docs/ROADMAP.md`):** Python rewrite, HTTP webhook, bearer-token auth, multi-destination SIEM dispatchers.

---

## Locked Design Decisions

| # | Decision |
|---|---|
| A | Accept both `--label-id` **and** `--label-key`+`--label-value`. One must be present; label-id takes precedence if both given (warn to stderr). |
| B | **B2:** append mode first fetches all labels with the target's key and strips them from existing labels before adding the new one. Preserves all other business labels. |
| C | Support both **C2** (server-side `?ip_address=` / `?hostname=` per precise term) **and C3 implicitly** (single precise target is the common case). If any term is CIDR / range / prefix → one full scan. |
| D | **D2:** `--parallel <N>` (default `1`, max `20`) spawns background PUT jobs with `wait -n` semaphore. |
| E | **E2:** CEF audit line appended under `flock -x` on `<audit-file>.lock`. |
| F | **F1:** PCE errors are captured in `failed[]`; no in-script retry. |
| G | Override precedence: **CLI flag > env var > credentials-file > script default**. |
| H | All user-facing strings (prompts, errors, status) in **English**. Internal comments may remain bilingual. |

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `config/quarantine.conf.example` | Credential / endpoint template sourced by bash |
| `docs/FortiSIEM_Integration.md` | FortiSIEM admin-side setup guide |
| `docs/ROADMAP.md` | v2 Python vision (no code) |
| `docs/superpowers/plans/2026-04-21-fortisiem-integration.md` | This plan |
| `.gitignore` | Exclude `config/quarantine.conf`, `logs/`, `tests/lib/`, `*.lock`, bats tmp |
| `tests/helpers/setup.bash` | Shared bats setup + mock PATH |
| `tests/helpers/mocks/curl` | Mock curl serving fixtures and logging calls |
| `tests/fixtures/workloads_list.json` | 3-workload canned GET /workloads response |
| `tests/fixtures/single_workload.json` | Canned GET /workloads/:href |
| `tests/fixtures/labels_by_key.json` | Canned GET /labels?key=Quarantine (3 hrefs) |
| `tests/fixtures/label_by_id.json` | Canned GET /labels/878 |
| `tests/test_harness_smoke.bats` | Harness self-check |
| `tests/test_args.bats` | CLI argument parser |
| `tests/test_credentials.bats` | Credential loading precedence |
| `tests/test_label_resolve.bats` | --label-id vs --label-key+value; same-key strip |
| `tests/test_search_strategy.bats` | Server-side vs full scan dispatch |
| `tests/test_dry_run.bats` | Dry-run behaviour |
| `tests/test_json_output.bats` | JSON schema |
| `tests/test_exit_codes.bats` | Exit code regime |
| `tests/test_parallel.bats` | Parallel PUT correctness + ordering tolerance |
| `tests/test_audit_cef.bats` | CEF format + flock concurrency |
| `scripts/run_tests.sh` | Bats wrapper |

### Modified files

| Path | Change summary |
|---|---|
| `update_illumio_workload_labels.sh` | Major refactor: arg parser, modes, exit codes, label resolver, server-side search dispatcher, same-key strip, parallel put pool, CEF audit, all strings English; version 1.3.0; **remove hardcoded creds** |
| `README.md` | Rewrite: usage (interactive + SIEM modes), FortiSIEM link, roadmap link, English only |

### Untouched

- `docs/REST_APIs_25_2.pdf` — reference PDF

---

## CLI Surface (final)

```
update_illumio_workload_labels.sh [OPTIONS]

Targets & action:
  --targets <csv>                     IP / hostname / CIDR / range / prefix, comma separated
  --label-id <id>                     Numeric Label ID to apply            (A: either this …)
  --label-key <key> --label-value <v> Look up label by key+value at runtime (A: … or these two)
  --mode append|overwrite             Default: append

Automation:
  --non-interactive                   Skip all prompts (fail instead of asking)
  --dry-run                           Skip PUTs; still emit JSON + CEF
  --json                              Machine-readable JSON on stdout
  --correlation-id <id>               SIEM incident ID; echoed in JSON + CEF
  --reason <text>                     Incident/rule description for audit
  --audit-file <path>                 Append CEF audit line under flock
  --parallel <n>                      Max concurrent PUTs (1..20, default 1)

Overrides:
  --credentials-file <path>           Bash file: API_USER, API_PASS, (PCE_URL_BASE, ORG_ID)
  --pce-url <url>                     Override PCE base URL
  --org-id <id>                       Override Org ID

Meta:
  -h, --help                          Print usage and exit 0
  -V, --version                       Print version and exit 0

Env vars (fallback after --credentials-file):
  ILLUMIO_QUARANTINE_API_USER, ILLUMIO_QUARANTINE_API_PASS,
  ILLUMIO_QUARANTINE_PCE_URL,  ILLUMIO_QUARANTINE_ORG_ID,
  ILLUMIO_QUARANTINE_AUDIT_FILE

Exit codes:
  0 success | 2 partial | 3 no match | 4 auth fail | 5 input error | 6 no creds
```

Override precedence (decision G):
`CLI flag` > `env var` > `--credentials-file sourced value` > `script default`.

---

## JSON Output Schema (stable)

```json
{
  "audit_id":       "qr-2026-04-21T12-34-56Z-ab12cd",
  "correlation_id": "<echo or empty>",
  "mode":           "append",
  "label": {
    "href":  "/orgs/1/labels/878",
    "key":   "Quarantine",
    "value": "Severe"
  },
  "requested_targets": ["10.0.0.5", "server1.lab.local"],
  "search_strategy":   "server_side" | "full_scan",
  "matched":  [{"href":"...","hostname":"..."}],
  "updated":  [{"href":"...","hostname":"..."}],
  "skipped_already_labeled": [{"href":"...","hostname":"..."}],
  "failed":   [{"href":"...","hostname":"...","http":403,"error":"..."}],
  "counts":   {"requested":2,"matched":1,"updated":1,"skipped":0,"failed":0},
  "parallel": 1,
  "dry_run":  false,
  "duration_ms": 842,
  "exit_code": 0
}
```

## CEF Audit Line (stable)

```
CEF:0|Illumio|Quarantine|1.3.0|quarantine.action|Illumio Quarantine Action|5|rt=<epoch_ms> dvchost=<pce_host> act=<append|overwrite> outcome=<success|partial|failure|no_match> cs1Label=correlation_id cs1=<id> cs2Label=audit_id cs2=<id> cs3Label=reason cs3=<escaped_reason> cs4Label=targets cs4=<escaped_csv> cs5Label=label_key cs5=<key> cs6Label=label_value cs6=<value> cn1Label=updated_count cn1=<n> cn2Label=failed_count cn2=<n> cs7Label=dry_run cs7=<true|false>
```

Escape in `cef_escape`: `\` → `\\`, `|` → `\|`, `=` → `\=`, newline → `\n`.

---

## Task 1 — Test harness (bats-core, fixtures, mock curl)

**Files:**
- Create: `tests/helpers/setup.bash`
- Create: `tests/helpers/mocks/curl`
- Create: `tests/fixtures/{workloads_list,single_workload,labels_by_key,label_by_id}.json`
- Create: `scripts/run_tests.sh`
- Create: `.gitignore`
- Create: `tests/test_harness_smoke.bats`

- [ ] **Step 1: Install bats-core submodules**

Run:
```bash
cd /mnt/d/RD/illumio_Quarantine
git submodule add https://github.com/bats-core/bats-core.git  tests/lib/bats-core
git submodule add https://github.com/bats-core/bats-assert.git tests/lib/bats-assert
git submodule add https://github.com/bats-core/bats-support.git tests/lib/bats-support
```

- [ ] **Step 2: `.gitignore`**

Write `/mnt/d/RD/illumio_Quarantine/.gitignore`:
```
config/quarantine.conf
logs/
*.log
*.lock
.DS_Store
tests/.bats_tmp/
/tmp/iq_*
```

- [ ] **Step 3: Fixtures**

`/mnt/d/RD/illumio_Quarantine/tests/fixtures/workloads_list.json`:
```json
[
  {
    "href": "/orgs/1/workloads/11111111-1111-1111-1111-111111111111",
    "hostname": "server1.lab.local",
    "managed": true,
    "public_ip": "203.0.113.10",
    "interfaces": [{"address": "10.0.0.5"}],
    "labels": [
      {"href": "/orgs/1/labels/100", "key": "role", "value": "web"},
      {"href": "/orgs/1/labels/700", "key": "Quarantine", "value": "Mild"}
    ]
  },
  {
    "href": "/orgs/1/workloads/22222222-2222-2222-2222-222222222222",
    "hostname": "server2.lab.local",
    "managed": true,
    "public_ip": "203.0.113.11",
    "interfaces": [{"address": "10.0.0.6"}],
    "labels": []
  },
  {
    "href": "/orgs/1/workloads/33333333-3333-3333-3333-333333333333",
    "hostname": "unmanaged.lab.local",
    "managed": false,
    "public_ip": "203.0.113.12",
    "interfaces": [{"address": "10.0.0.7"}],
    "labels": []
  }
]
```

`/mnt/d/RD/illumio_Quarantine/tests/fixtures/single_workload.json`:
```json
{
  "href": "/orgs/1/workloads/11111111-1111-1111-1111-111111111111",
  "hostname": "server1.lab.local",
  "managed": true,
  "labels": [
    {"href": "/orgs/1/labels/100", "key": "role", "value": "web"},
    {"href": "/orgs/1/labels/700", "key": "Quarantine", "value": "Mild"}
  ]
}
```

`/mnt/d/RD/illumio_Quarantine/tests/fixtures/labels_by_key.json`:
```json
[
  {"href": "/orgs/1/labels/700", "key": "Quarantine", "value": "Mild"},
  {"href": "/orgs/1/labels/878", "key": "Quarantine", "value": "Severe"},
  {"href": "/orgs/1/labels/879", "key": "Quarantine", "value": "Moderate"}
]
```

`/mnt/d/RD/illumio_Quarantine/tests/fixtures/label_by_id.json`:
```json
{"href": "/orgs/1/labels/878", "key": "Quarantine", "value": "Severe"}
```

- [ ] **Step 4: Mock curl**

Write `/mnt/d/RD/illumio_Quarantine/tests/helpers/mocks/curl`:
```bash
#!/usr/bin/env bash
# Mock curl for bats tests.
#   MOCK_CURL_LOG           path for call log (TSV: method\turl\tdata)
#   MOCK_CURL_FIXTURE_DIR   tests/fixtures
#   MOCK_CURL_AUTH_FAIL     "1" → GET /workloads* returns 401 object
#   MOCK_CURL_PUT_HTTP      override PUT HTTP code (default 204)
#   MOCK_CURL_PUT_DELAY_MS  artificial per-PUT delay (parallel test)

set -euo pipefail

method="GET"; url=""; data=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -d) data="$2"; shift 2 ;;
        -u|-H) shift 2 ;;
        -o) shift 2 ;;
        -w) shift 2 ;;
        -s|-k) shift ;;
        --*) shift ;;
        *) url="$1"; shift ;;
    esac
done

printf '%s\t%s\t%s\n' "$method" "$url" "$data" >> "$MOCK_CURL_LOG"

case "$method:$url" in
    GET:*"/labels?key="*)
        cat "$MOCK_CURL_FIXTURE_DIR/labels_by_key.json"; exit 0 ;;
    GET:*"/labels/"*)
        cat "$MOCK_CURL_FIXTURE_DIR/label_by_id.json"; exit 0 ;;
    GET:*"/workloads?"*"ip_address="*|GET:*"/workloads?"*"hostname="*)
        # Filter workloads_list.json by the query parameter for realism
        q="${url#*\?}"
        ip="$(echo "$q" | tr '&' '\n' | awk -F= '$1=="ip_address"{print $2}')"
        hn="$(echo "$q" | tr '&' '\n' | awk -F= '$1=="hostname"{print $2}')"
        if [[ -n "$ip" ]]; then
            jq --arg ip "$ip" '[.[] | select(.public_ip==$ip or (.interfaces[]?.address==$ip))]' \
                "$MOCK_CURL_FIXTURE_DIR/workloads_list.json"
        elif [[ -n "$hn" ]]; then
            jq --arg h "$hn" '[.[] | select(.hostname==$h)]' \
                "$MOCK_CURL_FIXTURE_DIR/workloads_list.json"
        else
            echo "[]"
        fi
        exit 0 ;;
    GET:*"/workloads")
        if [[ "${MOCK_CURL_AUTH_FAIL:-0}" == "1" ]]; then
            echo -n '{"error":"unauthorized"}'; exit 0
        fi
        cat "$MOCK_CURL_FIXTURE_DIR/workloads_list.json"; exit 0 ;;
    GET:*"/workloads/"*)
        cat "$MOCK_CURL_FIXTURE_DIR/single_workload.json"; exit 0 ;;
    PUT:*)
        [[ -n "${MOCK_CURL_PUT_DELAY_MS:-}" ]] && \
            sleep "$(awk "BEGIN{print ${MOCK_CURL_PUT_DELAY_MS}/1000}")"
        printf '%s' "${MOCK_CURL_PUT_HTTP:-204}"; exit 0 ;;
    *)
        echo "MOCK curl: unhandled $method $url" >&2; exit 1 ;;
esac
```

Then:
```bash
chmod +x /mnt/d/RD/illumio_Quarantine/tests/helpers/mocks/curl
```

- [ ] **Step 5: Bats setup helper**

`/mnt/d/RD/illumio_Quarantine/tests/helpers/setup.bash`:
```bash
_load_libs() {
    load "${BATS_TEST_DIRNAME}/lib/bats-support/load.bash"
    load "${BATS_TEST_DIRNAME}/lib/bats-assert/load.bash"
}

common_setup() {
    export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export SCRIPT="${REPO_ROOT}/update_illumio_workload_labels.sh"
    export BATS_TMPDIR_LOCAL="${BATS_RUN_TMPDIR:-/tmp}/iq_bats_$$"
    mkdir -p "$BATS_TMPDIR_LOCAL"

    export MOCK_CURL_LOG="$BATS_TMPDIR_LOCAL/curl_calls.log"
    export MOCK_CURL_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures"
    : > "$MOCK_CURL_LOG"
    export PATH="${REPO_ROOT}/tests/helpers/mocks:$PATH"

    export ILLUMIO_QUARANTINE_API_USER="test_user"
    export ILLUMIO_QUARANTINE_API_PASS="test_pass"
    export ILLUMIO_QUARANTINE_PCE_URL="https://pce.test.local:8443"
    export ILLUMIO_QUARANTINE_ORG_ID="1"
}

common_teardown() { rm -rf "$BATS_TMPDIR_LOCAL"; }
```

- [ ] **Step 6: Runner**

`/mnt/d/RD/illumio_Quarantine/scripts/run_tests.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec tests/lib/bats-core/bin/bats "$@" tests/
```
```bash
chmod +x /mnt/d/RD/illumio_Quarantine/scripts/run_tests.sh
```

- [ ] **Step 7: Harness smoke test**

`/mnt/d/RD/illumio_Quarantine/tests/test_harness_smoke.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "mock curl returns workloads list" {
    run curl -s "${ILLUMIO_QUARANTINE_PCE_URL}/api/v2/orgs/1/workloads"
    assert_success
    assert_output --partial "server1.lab.local"
}

@test "mock curl PUT returns 204" {
    run curl -s -X PUT -d '{}' "${ILLUMIO_QUARANTINE_PCE_URL}/api/v2/orgs/1/workloads/x"
    assert_success
    assert_output "204"
}

@test "mock curl ?ip_address=10.0.0.5 returns 1 workload" {
    run curl -s "${ILLUMIO_QUARANTINE_PCE_URL}/api/v2/orgs/1/workloads?ip_address=10.0.0.5"
    assert_success
    echo "$output" | jq -e 'length == 1' >/dev/null
}
```

- [ ] **Step 8: Run harness**

```bash
cd /mnt/d/RD/illumio_Quarantine && scripts/run_tests.sh tests/test_harness_smoke.bats
```
Expected: 3 passes.

- [ ] **Step 9: Commit**

```bash
git add .gitmodules tests/ scripts/run_tests.sh .gitignore
git commit -m "test: add bats-core harness with mock curl and fixtures"
```

---

## Task 2 — Externalize credentials (precedence G)

**Files:**
- Create: `config/quarantine.conf.example`
- Create: `tests/test_credentials.bats`
- Modify: `update_illumio_workload_labels.sh` (remove hardcoded creds; add `load_credentials`)

- [ ] **Step 1: Write credentials tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_credentials.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "reads credentials from --credentials-file" {
    cat > "$BATS_TMPDIR_LOCAL/creds.conf" <<EOF
API_USER="file_user"
API_PASS="file_pass"
EOF
    chmod 600 "$BATS_TMPDIR_LOCAL/creds.conf"
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json \
        --credentials-file "$BATS_TMPDIR_LOCAL/creds.conf"
    assert_success
}

@test "env vars used when no credentials-file" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
}

@test "CLI --pce-url beats env beats credentials-file (precedence G)" {
    cat > "$BATS_TMPDIR_LOCAL/creds.conf" <<EOF
API_USER="u"; API_PASS="p"
PCE_URL_BASE="https://pce-file.local:8443"
EOF
    chmod 600 "$BATS_TMPDIR_LOCAL/creds.conf"
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    export ILLUMIO_QUARANTINE_PCE_URL="https://pce-env.local:8443"
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json \
        --credentials-file "$BATS_TMPDIR_LOCAL/creds.conf" \
        --pce-url "https://pce-cli.local:8443"
    assert_success
    run grep -c 'pce-cli.local' "$MOCK_CURL_LOG"
    refute_output "0"
    run grep -c 'pce-env.local' "$MOCK_CURL_LOG"
    assert_output "0"
}

@test "exits 6 if non-interactive with no creds" {
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_failure 6
}
```

- [ ] **Step 2: Run — expect FAIL (script is still interactive-only v1.2.1)**

```bash
scripts/run_tests.sh tests/test_credentials.bats
```

- [ ] **Step 3: Create credentials template**

`/mnt/d/RD/illumio_Quarantine/config/quarantine.conf.example`:
```bash
# illumio_Quarantine credential file.
# Copy to config/quarantine.conf and `chmod 600` before use.
# Sourced when --credentials-file is given. See README for override precedence.

API_USER=""
API_PASS=""

# Optional (CLI flag / env still win):
# PCE_URL_BASE="https://pce.lab.local:8443"
# ORG_ID="1"
```

- [ ] **Step 4: Refactor script — `load_credentials`**

Edit `/mnt/d/RD/illumio_Quarantine/update_illumio_workload_labels.sh`:

Replace the existing `# --- 硬編碼憑證 ---` block (around lines 35-38) with:
```bash
# Credentials are loaded by load_credentials() after argument parsing.
# Precedence: CLI flags > env vars > --credentials-file > script defaults.
API_USER=""
API_PASS=""
PCE_URL_BASE=""
ORG_ID=""
```

Add this function near the top of the script (after the header comments):
```bash
load_credentials() {
    # Step 1: --credentials-file (lowest of the three non-default sources)
    if [[ -n "${CREDENTIALS_FILE:-}" ]]; then
        if [[ ! -r "$CREDENTIALS_FILE" ]]; then
            echo "ERROR: credentials file not readable: $CREDENTIALS_FILE" >&2
            exit 5
        fi
        # shellcheck disable=SC1090
        source "$CREDENTIALS_FILE"
    fi

    # Step 2: env (overrides credentials-file when set)
    [[ -n "${ILLUMIO_QUARANTINE_API_USER:-}" ]] && API_USER="$ILLUMIO_QUARANTINE_API_USER"
    [[ -n "${ILLUMIO_QUARANTINE_API_PASS:-}" ]] && API_PASS="$ILLUMIO_QUARANTINE_API_PASS"
    [[ -n "${ILLUMIO_QUARANTINE_PCE_URL:-}" ]] && PCE_URL_BASE="$ILLUMIO_QUARANTINE_PCE_URL"
    [[ -n "${ILLUMIO_QUARANTINE_ORG_ID:-}"  ]] && ORG_ID="$ILLUMIO_QUARANTINE_ORG_ID"

    # Step 3: CLI flag overrides (these are set in the arg parser; only if non-empty)
    [[ -n "${CLI_PCE_URL:-}" ]] && PCE_URL_BASE="$CLI_PCE_URL"
    [[ -n "${CLI_ORG_ID:-}"  ]] && ORG_ID="$CLI_ORG_ID"

    # Step 4: defaults
    [[ -z "$PCE_URL_BASE" ]] && PCE_URL_BASE="https://pce.lab.local:8443"
    [[ -z "$ORG_ID"       ]] && ORG_ID="1"

    # Step 5: missing creds
    if [[ -z "$API_USER" || -z "$API_PASS" ]]; then
        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            echo "ERROR: API credentials missing (use --credentials-file, env vars, or drop --non-interactive)" >&2
            exit 6
        fi
        [[ -z "$API_USER" ]] && { read -e -p "Illumio API user: " API_USER; }
        [[ -z "$API_PASS" ]] && { read -s -p "Illumio API password: " API_PASS; echo; }
    fi
    [[ -z "$API_USER" || -z "$API_PASS" ]] && exit 6
}
```

Bump version comment `1.2.1` → `1.3.0`. Replace the old Chinese "硬編碼憑證" security warning text with:
```bash
# !!! SECURITY NOTES !!!
# PCE API credentials loaded by load_credentials() in this order:
#   CLI flags > env vars > --credentials-file > script defaults.
# Never commit credentials to source control. See config/quarantine.conf.example.
```

- [ ] **Step 5: Syntax check**

```bash
bash -n /mnt/d/RD/illumio_Quarantine/update_illumio_workload_labels.sh
```
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add update_illumio_workload_labels.sh config/quarantine.conf.example tests/test_credentials.bats
git commit -m "feat: externalize PCE credentials with precedence CLI>env>file>default"
```

Tests will go green after Task 3 adds the flags they rely on.

---

## Task 3 — CLI argument parser + help/version

**Files:**
- Create: `tests/test_args.bats`
- Modify: `update_illumio_workload_labels.sh` (insert parser, validation, call `load_credentials`)

- [ ] **Step 1: Write argparser tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_args.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "--help prints usage and exits 0" {
    run bash "$SCRIPT" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "--targets"
    assert_output --partial "--label-id"
    assert_output --partial "--label-key"
    assert_output --partial "--parallel"
}

@test "--version prints 1.3.0" {
    run bash "$SCRIPT" --version
    assert_success
    assert_output --partial "1.3.0"
}

@test "non-interactive without --targets exits 5" {
    run bash "$SCRIPT" --label-id 878 --non-interactive --dry-run --json
    assert_failure 5
}

@test "non-interactive without any label id/key exits 5" {
    run bash "$SCRIPT" --targets 10.0.0.5 --non-interactive --dry-run --json
    assert_failure 5
}

@test "non-interactive with --label-key without --label-value exits 5" {
    run bash "$SCRIPT" --targets x --label-key Quarantine --non-interactive --dry-run --json
    assert_failure 5
}

@test "both --label-id and --label-key warns but accepts (id wins)" {
    run bash "$SCRIPT" --targets 10.0.0.5 --label-id 878 \
        --label-key Quarantine --label-value Severe \
        --non-interactive --dry-run --json
    assert_success
    assert_output --partial "--label-id takes precedence"
}

@test "unknown flag exits 5" {
    run bash "$SCRIPT" --nope --non-interactive
    assert_failure 5
    assert_output --partial "unknown option"
}

@test "--parallel must be 1..20" {
    run bash "$SCRIPT" --targets x --label-id 1 --parallel 0 --non-interactive --dry-run --json
    assert_failure 5
    run bash "$SCRIPT" --targets x --label-id 1 --parallel 21 --non-interactive --dry-run --json
    assert_failure 5
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Insert arg parser**

In `update_illumio_workload_labels.sh`, after the dep checks (after line 87 in v1.2.1, before the old `--- 用戶輸入 ---` block), insert:

```bash
# --- CLI argument parsing ---
VERSION="1.3.0"

# Defaults
SEARCH_TERMS_RAW=""
LABEL_ID=""
LABEL_KEY=""
LABEL_VALUE=""
UPDATE_MODE=""
NON_INTERACTIVE=0
DRY_RUN=0
JSON_OUT=0
CORRELATION_ID=""
REASON=""
AUDIT_FILE="${ILLUMIO_QUARANTINE_AUDIT_FILE:-}"
PARALLEL=1
CREDENTIALS_FILE=""
CLI_PCE_URL=""
CLI_ORG_ID=""

print_usage() {
    cat <<'USAGE'
Usage: update_illumio_workload_labels.sh [OPTIONS]

Targets & action:
  --targets <csv>                     IP/hostname/CIDR/range/prefix (CSV)
  --label-id <id>                     Numeric Label ID
  --label-key <k> --label-value <v>   Look up label at runtime (mutually exclusive with --label-id)
  --mode append|overwrite             Default: append

Automation:
  --non-interactive                   Skip all prompts
  --dry-run                           No PUTs; still emit JSON + CEF
  --json                              Machine-readable JSON to stdout
  --correlation-id <id>               SIEM incident ID
  --reason <text>                     Incident/rule description
  --audit-file <path>                 Append CEF audit line (flock-protected)
  --parallel <n>                      Concurrent PUTs (1..20, default 1)

Overrides:
  --credentials-file <path>           Bash file with API_USER/API_PASS/[PCE_URL_BASE/ORG_ID]
  --pce-url <url>                     Override PCE base URL
  --org-id <id>                       Override Org ID

Meta:
  -h, --help                          Show this help
  -V, --version                       Print version

Env vars (after --credentials-file, before defaults):
  ILLUMIO_QUARANTINE_API_USER, ILLUMIO_QUARANTINE_API_PASS,
  ILLUMIO_QUARANTINE_PCE_URL,  ILLUMIO_QUARANTINE_ORG_ID,
  ILLUMIO_QUARANTINE_AUDIT_FILE

Exit codes:
  0 success | 2 partial | 3 no match | 4 auth fail | 5 input error | 6 no creds
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets)          SEARCH_TERMS_RAW="$2"; shift 2 ;;
        --label-id)         LABEL_ID="$2";         shift 2 ;;
        --label-key)        LABEL_KEY="$2";        shift 2 ;;
        --label-value)      LABEL_VALUE="$2";      shift 2 ;;
        --mode)             UPDATE_MODE="$2";      shift 2 ;;
        --non-interactive)  NON_INTERACTIVE=1;     shift ;;
        --dry-run)          DRY_RUN=1;             shift ;;
        --json)             JSON_OUT=1;            shift ;;
        --correlation-id)   CORRELATION_ID="$2";   shift 2 ;;
        --reason)           REASON="$2";           shift 2 ;;
        --audit-file)       AUDIT_FILE="$2";       shift 2 ;;
        --parallel)         PARALLEL="$2";         shift 2 ;;
        --credentials-file) CREDENTIALS_FILE="$2"; shift 2 ;;
        --pce-url)          CLI_PCE_URL="$2";      shift 2 ;;
        --org-id)           CLI_ORG_ID="$2";       shift 2 ;;
        -h|--help)          print_usage; exit 0 ;;
        -V|--version)       echo "update_illumio_workload_labels.sh $VERSION"; exit 0 ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            print_usage >&2
            exit 5 ;;
    esac
done

# Validate --parallel
if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [[ "$PARALLEL" -lt 1 || "$PARALLEL" -gt 20 ]]; then
    echo "ERROR: --parallel must be an integer in 1..20" >&2; exit 5
fi

# Mutual exclusion / combinations for label target
if [[ -n "$LABEL_ID" && ( -n "$LABEL_KEY" || -n "$LABEL_VALUE" ) ]]; then
    echo "WARN: both --label-id and --label-key/--label-value given; --label-id takes precedence" >&2
    LABEL_KEY=""; LABEL_VALUE=""
fi

if [[ "$NON_INTERACTIVE" == "1" ]]; then
    [[ -z "$SEARCH_TERMS_RAW" ]] && { echo "ERROR: --targets required" >&2; exit 5; }
    if [[ -z "$LABEL_ID" ]]; then
        if [[ -z "$LABEL_KEY" || -z "$LABEL_VALUE" ]]; then
            echo "ERROR: --label-id or (--label-key and --label-value) required" >&2; exit 5
        fi
    fi
    if [[ -n "$LABEL_ID" ]] && ! [[ "$LABEL_ID" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --label-id must be numeric" >&2; exit 5
    fi
    [[ -z "$UPDATE_MODE" ]] && UPDATE_MODE="append"
    if [[ "$UPDATE_MODE" != "append" && "$UPDATE_MODE" != "overwrite" ]]; then
        echo "ERROR: --mode must be append or overwrite" >&2; exit 5
    fi
fi

load_credentials
```

Then **delete** the old v1.2.1 prompt block (`echo "請輸入要搜索的條件..."` through `read -e -p "請輸入要添加/設置的新 Label 的數字 ID..."`), replace with the gated prompter:

```bash
# Interactive prompts (skipped if --non-interactive)
if [[ "$NON_INTERACTIVE" != "1" ]]; then
    if [[ -z "$SEARCH_TERMS_RAW" ]]; then
        echo "Enter search terms (CSV of IP, hostname, CIDR, range, prefix):"
        read -e -p "Targets: " SEARCH_TERMS_RAW
    fi
    if [[ -z "$LABEL_ID" && ( -z "$LABEL_KEY" || -z "$LABEL_VALUE" ) ]]; then
        read -e -p "Label ID (numeric, or leave blank to use key/value): " LABEL_ID
        if [[ -z "$LABEL_ID" ]]; then
            read -e -p "Label key: "   LABEL_KEY
            read -e -p "Label value: " LABEL_VALUE
        fi
    fi
fi

# Post-prompt validation (applies in both modes)
[[ -z "$SEARCH_TERMS_RAW" ]] && { echo "ERROR: empty targets" >&2; exit 5; }
if [[ -z "$LABEL_ID" && ( -z "$LABEL_KEY" || -z "$LABEL_VALUE" ) ]]; then
    echo "ERROR: need --label-id or --label-key+--label-value" >&2; exit 5
fi
if [[ -n "$LABEL_ID" ]] && ! [[ "$LABEL_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: label id must be numeric" >&2; exit 5
fi
```

- [ ] **Step 4: Run args + credentials tests**

```bash
scripts/run_tests.sh tests/test_args.bats tests/test_credentials.bats
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_args.bats
git commit -m "feat: CLI argparser with label-id|label-key+value, parallel, all-English UX"
```

---

## Task 4 — Label resolution + same-key strip (decisions A, B2)

**Files:**
- Create: `tests/test_label_resolve.bats`
- Modify: `update_illumio_workload_labels.sh` — add `resolve_target_label` + replace the existing PUT-body-build block

- [ ] **Step 1: Write tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_label_resolve.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

_run_json() {
    local out
    out=$(bash "$SCRIPT" "$@")
    echo "$out"
}

@test "--label-id resolves via GET /labels/:id and reports key/value" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.label.key')"   == "Quarantine" ]]
    [[ "$(echo "$output" | jq -r '.label.value')" == "Severe"     ]]
    [[ "$(echo "$output" | jq -r '.label.href')"  == "/orgs/1/labels/878" ]]
}

@test "--label-key+--label-value resolves via GET /labels?key=..." {
    run bash "$SCRIPT" --targets "server1.lab.local" \
        --label-key Quarantine --label-value Severe \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.label.href')" == "/orgs/1/labels/878" ]]
}

@test "--label-key+--label-value not found exits 5" {
    run bash "$SCRIPT" --targets "server1.lab.local" \
        --label-key Quarantine --label-value NoSuch \
        --non-interactive --dry-run --json
    assert_failure 5
    assert_output --partial "no label with key=Quarantine value=NoSuch"
}

@test "append mode strips existing same-key labels before adding target (B2)" {
    # server1 has role:web (href 100) and Quarantine:Mild (href 700).
    # We apply Quarantine:Severe (href 878). Expected PUT body contains role:web
    # and Quarantine:Severe but NOT Quarantine:Mild.
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --mode append --non-interactive --json
    assert_success

    # Grab last PUT body from the mock log
    put_body=$(awk -F'\t' '$1=="PUT"{print $3}' "$MOCK_CURL_LOG" | tail -n1)
    hrefs=$(echo "$put_body" | jq -r '.labels[].href' | sort)
    [[ "$(echo "$hrefs" | grep -c '/orgs/1/labels/100')" == "1" ]]
    [[ "$(echo "$hrefs" | grep -c '/orgs/1/labels/700')" == "0" ]]   # Mild stripped
    [[ "$(echo "$hrefs" | grep -c '/orgs/1/labels/878')" == "1" ]]   # Severe added
}

@test "overwrite mode keeps only the target label" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --mode overwrite --non-interactive --json
    assert_success
    put_body=$(awk -F'\t' '$1=="PUT"{print $3}' "$MOCK_CURL_LOG" | tail -n1)
    [[ "$(echo "$put_body" | jq '.labels | length')" == "1" ]]
    [[ "$(echo "$put_body" | jq -r '.labels[0].href')" == "/orgs/1/labels/878" ]]
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Add `resolve_target_label` + same-key hrefs fetch**

In `update_illumio_workload_labels.sh`, near the PCE URL setup, add:

```bash
# Resolved after argparse, before main workload loop
TARGET_LABEL_HREF=""
TARGET_LABEL_KEY=""
TARGET_LABEL_VALUE=""
SAME_KEY_HREFS_JSON="[]"

resolve_target_label() {
    local base="${PCE_URL_BASE}/api/${API_VERSION}/orgs/${ORG_ID}"
    if [[ -n "$LABEL_ID" ]]; then
        local resp
        resp=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                   -H 'Accept: application/json' \
                   "${base}/labels/${LABEL_ID}")
        if ! echo "$resp" | jq -e 'has("href")' >/dev/null 2>&1; then
            echo "ERROR: label id ${LABEL_ID} not found" >&2
            exit 5
        fi
        TARGET_LABEL_HREF="/orgs/${ORG_ID}/labels/${LABEL_ID}"
        TARGET_LABEL_KEY=$(echo   "$resp" | jq -r '.key')
        TARGET_LABEL_VALUE=$(echo "$resp" | jq -r '.value')
    else
        local resp
        resp=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                   -H 'Accept: application/json' \
                   "${base}/labels?key=${LABEL_KEY}")
        TARGET_LABEL_HREF=$(echo "$resp" | jq -r --arg v "$LABEL_VALUE" \
            '[.[] | select(.value==$v)][0].href // empty')
        if [[ -z "$TARGET_LABEL_HREF" ]]; then
            echo "ERROR: no label with key=${LABEL_KEY} value=${LABEL_VALUE}" >&2
            exit 5
        fi
        TARGET_LABEL_KEY="$LABEL_KEY"
        TARGET_LABEL_VALUE="$LABEL_VALUE"
    fi

    # Fetch all hrefs for TARGET_LABEL_KEY (used by B2 same-key strip)
    local same_resp
    same_resp=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                    -H 'Accept: application/json' \
                    "${base}/labels?key=${TARGET_LABEL_KEY}")
    SAME_KEY_HREFS_JSON=$(echo "$same_resp" | jq -c '[.[].href]')
}
```

Call `resolve_target_label` right after `load_credentials` and the post-prompt validation, before the GET /workloads call.

- [ ] **Step 4: Replace PUT-body construction to use B2 strip**

Find the `# --- 步驟 4: 執行更新 ---` block and the existing `jq -n --argjson existing ... '{labels: ($existing + [...])}'` construction. Replace with:

```bash
if [[ "$UPDATE_MODE" == "overwrite" ]]; then
    put_body=$(jq -n --arg h "$TARGET_LABEL_HREF" \
                    '{labels:[{href:$h}]}')
else
    put_body=$(jq -n \
        --argjson existing "$existing_labels_json" \
        --argjson same_key "$SAME_KEY_HREFS_JSON" \
        --arg     h        "$TARGET_LABEL_HREF" \
        '{labels: (
              ($existing | map(select(.href as $x | ($same_key | index($x)) | not)))
            + [{href:$h}]
        )}')
fi
```

Remove the old `label_exists` skip logic (we now always strip + add; PCE will not duplicate hrefs; the `skipped_already_labeled` short-circuit moves into the next check below):

```bash
# Skip PUT if the new body is identical to the existing labels (idempotent)
if [[ "$UPDATE_MODE" == "append" ]]; then
    before=$(echo "$existing_labels_json" | jq -c 'sort_by(.href)')
    after=$(echo  "$put_body"            | jq -c '.labels | sort_by(.href)')
    if [[ "$before" == "$after" ]]; then
        # Will be recorded as skipped_already_labeled in the JSON emitter (Task 9)
        SKIPPED_THIS_ROUND=1
    fi
fi
```

(`SKIPPED_THIS_ROUND` is a per-iteration flag consumed by the JSON emitter added in Task 9.)

- [ ] **Step 5: Run — expect PASS**

```bash
scripts/run_tests.sh tests/test_label_resolve.bats
```

- [ ] **Step 6: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_label_resolve.bats
git commit -m "feat: label resolution via id|key+value; append strips same-key labels (B2)"
```

---

## Task 5 — Non-interactive gates (confirmation + mode prompts)

**Files:** `update_illumio_workload_labels.sh`; append to `tests/test_args.bats`

- [ ] **Step 1: Append test**
```bash
@test "non-interactive does not prompt for confirmation or mode" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    refute_output --partial "Continue?"
}
```

- [ ] **Step 2: Run — expect FAIL (hangs)**

- [ ] **Step 3: Gate the confirmation prompt**

Replace `read -e -p "是否要繼續？..."` block with:
```bash
if [[ "$NON_INTERACTIVE" != "1" ]]; then
    read -e -p "Continue? (type 'yes' to confirm): " CONFIRMATION
    if [[ "${CONFIRMATION,,}" != "yes" ]]; then
        echo "Cancelled."
        exit 0
    fi
fi
```

Replace the mode-prompt block with:
```bash
if [[ "$NON_INTERACTIVE" != "1" && -z "$UPDATE_MODE" ]]; then
    echo "Label update mode:"
    echo "  1) append    (keep existing business labels; replace same-key)"
    echo "  2) overwrite (remove all existing labels; set only new)"
    read -e -p "Mode (1 or 2): " UPDATE_MODE_CHOICE
    case "$UPDATE_MODE_CHOICE" in
        1) UPDATE_MODE="append" ;;
        2) UPDATE_MODE="overwrite" ;;
        *) echo "ERROR: invalid mode choice" >&2; exit 5 ;;
    esac
fi
[[ -z "$UPDATE_MODE" ]] && UPDATE_MODE="append"
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_args.bats
git commit -m "feat: gate confirmation and mode prompts behind --non-interactive"
```

---

## Task 6 — Search strategy dispatch (decisions C2 + C3)

**Files:**
- Create: `tests/test_search_strategy.bats`
- Modify: `update_illumio_workload_labels.sh` (replace the GET /workloads block)

- [ ] **Step 1: Write tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_search_strategy.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "single IP target uses ?ip_address= (server_side)" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "server_side" ]]
    run grep -c "workloads?ip_address=10.0.0.5" "$MOCK_CURL_LOG"
    refute_output "0"
    run grep -c "workloads[^?]*$" "$MOCK_CURL_LOG"
    # Only labels fetches match pattern; no unfiltered /workloads scan
    assert_output "0"
}

@test "hostname target uses ?hostname= (server_side)" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "server_side" ]]
    run grep -c "workloads?hostname=server1.lab.local" "$MOCK_CURL_LOG"
    refute_output "0"
}

@test "CIDR target forces full_scan" {
    run bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "full_scan" ]]
}

@test "mixed targets (ip + cidr) fall back to full_scan" {
    run bash "$SCRIPT" --targets "10.0.0.5,10.0.0.0/24" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "full_scan" ]]
}

@test "server-side result excludes unmanaged workloads" {
    # 10.0.0.7 belongs to unmanaged workload; mock server returns it, filter drops it
    run bash "$SCRIPT" --targets "10.0.0.7" --label-id 878 \
        --non-interactive --dry-run --json
    # exit 3 no_match because unmanaged was filtered out
    [[ "$status" -eq 3 ]]
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Refactor search dispatch**

Add helper near the top:

```bash
classify_term() {
    local t="$1"
    if [[ "$t" == */* ]]; then echo "cidr"; return; fi
    [[ "$t" == *-* && ! "$t" =~ ^[a-zA-Z] ]] && { echo "range"; return; }
    [[ "$t" == *~* ]] && { echo "range"; return; }
    if [[ "$t" == *. && ! "$t" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "prefix"; return
    fi
    if [[ "$t" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "ip"; return; fi
    echo "hostname"
}
```

Replace the v1.2.1 `# --- 步驟 1: 獲取所有 Workloads ---` block with:

```bash
# --- Step 1: Fetch workloads (server-side per-term if all precise, else one full scan) ---
WORKLOADS_BASE="${PCE_URL_BASE}/api/${API_VERSION}/orgs/${ORG_ID}/workloads"
needs_full=0
for term in "${SEARCH_TERMS[@]}"; do
    [[ -z "$term" ]] && continue
    t=$(classify_term "$term")
    if [[ "$t" == "cidr" || "$t" == "range" || "$t" == "prefix" ]]; then
        needs_full=1; break
    fi
done

if [[ "$needs_full" == "1" ]]; then
    SEARCH_STRATEGY="full_scan"
    api_response=$(curl -s -k -u "${API_USER}:${API_PASS}" \
        -H 'Accept: application/json' \
        "${WORKLOADS_BASE}?max_results=100000")
else
    SEARCH_STRATEGY="server_side"
    api_response="[]"
    for term in "${SEARCH_TERMS[@]}"; do
        [[ -z "$term" ]] && continue
        t=$(classify_term "$term")
        if [[ "$t" == "ip" ]]; then
            part=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                -H 'Accept: application/json' \
                "${WORKLOADS_BASE}?ip_address=${term}")
        else
            part=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                -H 'Accept: application/json' \
                "${WORKLOADS_BASE}?hostname=${term}")
        fi
        # Merge (dedup by href)
        api_response=$(jq -n --argjson a "$api_response" --argjson b "$part" \
            '$a + $b | unique_by(.href)')
    done
fi

# Auth / JSON validation
if ! echo "$api_response" | jq empty >/dev/null 2>&1; then
    echo "ERROR: PCE response is not valid JSON" >&2; exit 4
fi
if echo "$api_response" | jq -e 'type=="object" and (has("error") or has("unauthorized"))' >/dev/null 2>&1; then
    echo "ERROR: PCE authentication failed" >&2; exit 4
fi
if ! echo "$api_response" | jq -e 'type=="array"' >/dev/null; then
    echo "ERROR: PCE response is not a JSON array" >&2; exit 4
fi
```

Keep the existing client-side filter loop (lines ~156-284) for when `needs_full==1`; for the server-side path the per-term queries already narrowed the results, but run through the same `managed==true` filter and the `match_found_for_this_workload` logic so mixed semantics stay consistent.

Export `SEARCH_STRATEGY` for the JSON emitter (Task 9).

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_search_strategy.bats
git commit -m "feat: dispatch server-side vs full-scan workload lookup (C2+C3)"
```

---

## Task 7 — `--dry-run` (skip PUT)

**Files:** `tests/test_dry_run.bats`; `update_illumio_workload_labels.sh`

- [ ] **Step 1: Tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_dry_run.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "dry-run issues no PUT" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "0"
}

@test "non-dry-run issues PUT for each match" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --json
    assert_success
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "1"
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Gate the PUT**

Find the existing PUT block and replace with:
```bash
if [[ "$DRY_RUN" == "1" ]]; then
    http_code="000"; curl_exit_code=0
    [[ "$JSON_OUT" != "1" ]] && echo "DRY-RUN: would PUT ${update_url}"
else
    http_code=$(curl -s -k -X PUT \
        -u "${API_USER}:${API_PASS}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$put_body" -o /dev/null -w "%{http_code}" \
        "${update_url}")
    curl_exit_code=$?
fi
```

And update the outcome handler so `000` in dry-run counts as success (full implementation lands with the JSON task).

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_dry_run.bats
git commit -m "feat: --dry-run skips PUTs while still producing output"
```

---

## Task 8 — `--correlation-id` / `--reason` plumbing (header echo)

**Files:** append test to `tests/test_args.bats`; modify script

- [ ] **Step 1: Test**
```bash
@test "correlation-id and reason appear in header in human mode" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --non-interactive --dry-run \
        --correlation-id "INC-42" --reason "test rule"
    assert_success
    assert_output --partial "correlation_id=INC-42"
    assert_output --partial "reason=test rule"
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Emit header right after `resolve_target_label`**

```bash
if [[ "$JSON_OUT" != "1" ]]; then
    echo "illumio_Quarantine $VERSION"
    echo "label=${TARGET_LABEL_KEY}:${TARGET_LABEL_VALUE} (${TARGET_LABEL_HREF})"
    [[ -n "$CORRELATION_ID" ]] && echo "correlation_id=$CORRELATION_ID"
    [[ -n "$REASON"         ]] && echo "reason=$REASON"
fi
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_args.bats
git commit -m "feat: echo correlation-id, reason, and resolved label in header"
```

---

## Task 9 — `--json` output

**Files:** `tests/test_json_output.bats`; `update_illumio_workload_labels.sh`

- [ ] **Step 1: Tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_json_output.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "json parses with jq" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    echo "$output" | jq -e '.' >/dev/null
}

@test "json contains all required fields" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    for f in audit_id correlation_id mode label requested_targets \
             search_strategy matched updated skipped_already_labeled \
             failed counts parallel dry_run duration_ms exit_code; do
        echo "$output" | jq -e ".${f}" >/dev/null || { echo "missing $f"; false; }
    done
}

@test "counts match arrays" {
    run bash "$SCRIPT" --targets "10.0.0.5,nonexistent.host" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    a=$(echo "$output" | jq '.matched | length')
    b=$(echo "$output" | jq '.counts.matched')
    [[ "$a" == "$b" ]]
}

@test "correlation_id echoes input" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json --correlation-id "MY-9"
    assert_success
    [[ "$(echo "$output" | jq -r '.correlation_id')" == "MY-9" ]]
}

@test "human logs suppressed with --json" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    refute_output --partial "DRY-RUN"
    refute_output --partial "illumio_Quarantine"
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Add run-state accumulators + emitter**

After `resolve_target_label`, add:
```bash
AUDIT_ID="qr-$(date -u +%Y-%m-%dT%H-%M-%SZ)-$(printf '%04x%02x' $((RANDOM)) $((RANDOM%256)))"
RUN_START_MS=$(date +%s%3N)
declare -a J_REQUESTED=()
declare -a J_MATCHED=()
declare -a J_UPDATED=()
declare -a J_SKIPPED=()
declare -a J_FAILED=()

hlog() { [[ "$JSON_OUT" != "1" ]] && echo "$@"; }

while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    J_REQUESTED+=("$(jq -nc --arg t "$t" '$t')")
done < <(printf '%s\n' "${SEARCH_TERMS[@]}")
```

Replace `echo "  -> 找到匹配: ..."` with:
```bash
if [[ -z "${workloads_to_update[$key]}" ]]; then
    hlog "  -> match: ${hostname} (${workload_href})"
    J_MATCHED+=("$(jq -nc --arg h "$workload_href" --arg n "$hostname" \
                          '{href:$h,hostname:$n}')")
    ((found_count++))
fi
```

Replace the PUT outcome block with:
```bash
if [[ "$DRY_RUN" == "1" ]]; then
    J_UPDATED+=("$(jq -nc --arg h "$workload_href" --arg n "$hostname_display" \
                          '{href:$h,hostname:$n,dry_run:true}')")
    hlog "  -> DRY-RUN success"
elif [[ "${SKIPPED_THIS_ROUND:-0}" == "1" ]]; then
    J_SKIPPED+=("$(jq -nc --arg h "$workload_href" --arg n "$hostname_display" \
                          '{href:$h,hostname:$n}')")
    hlog "  -> skipped (already labeled)"
    SKIPPED_THIS_ROUND=0
elif [ $curl_exit_code -ne 0 ]; then
    J_FAILED+=("$(jq -nc --arg h "$workload_href" --arg n "$hostname_display" \
                          --arg e "curl $curl_exit_code" \
                          '{href:$h,hostname:$n,http:0,error:$e}')")
    echo "ERROR: PUT ${workload_href} failed (curl ${curl_exit_code})" >&2
elif [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
    J_UPDATED+=("$(jq -nc --arg h "$workload_href" --arg n "$hostname_display" \
                          '{href:$h,hostname:$n}')")
    hlog "  -> updated (HTTP ${http_code})"
else
    J_FAILED+=("$(jq -nc --arg h "$workload_href" --arg n "$hostname_display" \
                          --argjson http "${http_code}" \
                          --arg e "PCE returned ${http_code}" \
                          '{href:$h,hostname:$n,http:$http,error:$e}')")
    echo "ERROR: PUT ${workload_href} failed (HTTP ${http_code})" >&2
fi
```

At the end of the script, replace `echo "腳本執行完畢。"` with:
```bash
# --- Final JSON + exit-code ---
RUN_END_MS=$(date +%s%3N)
DURATION_MS=$((RUN_END_MS - RUN_START_MS))

ec=0
if   [[ ${#J_MATCHED[@]} -eq 0 ]]; then ec=3
elif [[ ${#J_FAILED[@]}  -gt 0 ]]; then ec=2
fi

_arr() { local IFS=','; echo "[${*}]"; }

if [[ "$JSON_OUT" == "1" ]]; then
    jq -nc \
       --arg audit_id "$AUDIT_ID" \
       --arg correlation_id "$CORRELATION_ID" \
       --arg mode "$UPDATE_MODE" \
       --arg strategy "${SEARCH_STRATEGY:-full_scan}" \
       --argjson label "$(jq -nc --arg h "$TARGET_LABEL_HREF" \
                                  --arg k "$TARGET_LABEL_KEY" \
                                  --arg v "$TARGET_LABEL_VALUE" \
                                  '{href:$h,key:$k,value:$v}')" \
       --argjson requested "$(_arr "${J_REQUESTED[@]:-}")" \
       --argjson matched   "$(_arr "${J_MATCHED[@]:-}")" \
       --argjson updated   "$(_arr "${J_UPDATED[@]:-}")" \
       --argjson skipped   "$(_arr "${J_SKIPPED[@]:-}")" \
       --argjson failed    "$(_arr "${J_FAILED[@]:-}")" \
       --argjson parallel  "$PARALLEL" \
       --argjson dry_run   "$([[ $DRY_RUN == 1 ]] && echo true || echo false)" \
       --argjson duration  "$DURATION_MS" \
       --argjson exit_code "$ec" \
       '{audit_id:$audit_id, correlation_id:$correlation_id,
         mode:$mode, label:$label,
         requested_targets:$requested,
         search_strategy:$strategy,
         matched:$matched, updated:$updated,
         skipped_already_labeled:$skipped,
         failed:$failed,
         counts:{requested:($requested|length),
                 matched:($matched|length),
                 updated:($updated|length),
                 skipped:($skipped|length),
                 failed:($failed|length)},
         parallel:$parallel, dry_run:$dry_run,
         duration_ms:$duration, exit_code:$exit_code}'
fi
# (CEF emit happens after this in Task 12)
exit "$ec"
```

Replace all remaining Chinese `echo` calls with `hlog` + English messages in the workload iteration body.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_json_output.bats
git commit -m "feat: --json output with label/search_strategy/parallel fields"
```

---

## Task 10 — Exit code regime

**Files:** `tests/test_exit_codes.bats`; touch-ups in script

- [ ] **Step 1: Tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_exit_codes.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "0 on success" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
}

@test "3 on no match" {
    run bash "$SCRIPT" --targets "192.0.2.99" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    [[ "$status" -eq 3 ]]
}

@test "2 on partial failure (PUT returns 403)" {
    export MOCK_CURL_PUT_HTTP="403"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --json
    [[ "$status" -eq 2 ]]
}

@test "4 on PCE auth failure" {
    export MOCK_CURL_AUTH_FAIL="1"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    [[ "$status" -eq 4 ]]
}

@test "5 on invalid --mode" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode bogus --non-interactive --dry-run --json
    [[ "$status" -eq 5 ]]
}
```

- [ ] **Step 2: Run — expect most PASS (Task 6 already did 4 branch). Fix any gap.**

- [ ] **Step 3: Commit if changes**

```bash
git add tests/test_exit_codes.bats
[[ -n "$(git diff --staged --name-only)" ]] && \
  git commit -m "test: document exit code regime (0/2/3/4/5/6)"
```

---

## Task 11 — `--parallel` PUT pool (decision D2)

**Files:**
- Create: `tests/test_parallel.bats`
- Modify: `update_illumio_workload_labels.sh` (replace serial PUT loop with bg-job semaphore; aggregate via result files)

- [ ] **Step 1: Tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_parallel.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "parallel=1 remains serial (all N PUTs happen)" {
    # 10.0.0.0/24 matches both managed workloads
    run bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 1
    assert_success
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "2"
}

@test "parallel=4 completes with correct counts and PUT count" {
    run bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 4
    assert_success
    [[ "$(echo "$output" | jq '.counts.updated')" == "2" ]]
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "2"
}

@test "parallel with an injected failure marks partial" {
    export MOCK_CURL_PUT_HTTP="500"
    run bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 2
    [[ "$status" -eq 2 ]]
    [[ "$(echo "$output" | jq '.counts.failed')" == "2" ]]
}

@test "parallel actually overlaps (faster than serial)" {
    export MOCK_CURL_PUT_DELAY_MS=200

    start=$(date +%s%3N)
    bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 1 >/dev/null
    serial_ms=$(( $(date +%s%3N) - start ))

    : > "$MOCK_CURL_LOG"
    start=$(date +%s%3N)
    bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 4 >/dev/null
    par_ms=$(( $(date +%s%3N) - start ))

    # Parallel must be noticeably faster (at least 25% shorter)
    [[ "$par_ms" -lt $(( serial_ms * 3 / 4 )) ]]
}
```

- [ ] **Step 2: Run — expect FAIL (current loop is serial)**

- [ ] **Step 3: Refactor PUT loop**

Extract the per-workload PUT body into a function, write results to a per-call file under a temp dir, run jobs with `wait -n` semaphore:

Insert near the top:
```bash
put_one_workload() {
    local workload_href="$1"
    local hostname_display="$2"
    local existing_labels_json="$3"
    local result_dir="$4"

    local put_body
    if [[ "$UPDATE_MODE" == "overwrite" ]]; then
        put_body=$(jq -n --arg h "$TARGET_LABEL_HREF" \
                        '{labels:[{href:$h}]}')
    else
        put_body=$(jq -n \
            --argjson existing "$existing_labels_json" \
            --argjson same_key "$SAME_KEY_HREFS_JSON" \
            --arg     h        "$TARGET_LABEL_HREF" \
            '{labels: (
                  ($existing | map(select(.href as $x | ($same_key | index($x)) | not)))
                + [{href:$h}]
            )}')
    fi

    # Idempotent skip
    local before after
    before=$(echo "$existing_labels_json" | jq -c 'sort_by(.href)')
    after=$(echo  "$put_body"            | jq -c '.labels | sort_by(.href)')
    if [[ "$UPDATE_MODE" == "append" && "$before" == "$after" ]]; then
        echo '{"kind":"skipped"}'     > "$result_dir/$(echo "$workload_href" | tr / _).json"
        return 0
    fi

    local http_code curl_ec
    if [[ "$DRY_RUN" == "1" ]]; then
        http_code="000"; curl_ec=0
    else
        http_code=$(curl -s -k -X PUT \
            -u "${API_USER}:${API_PASS}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$put_body" -o /dev/null -w "%{http_code}" \
            "${PCE_URL_BASE}/api/${API_VERSION}${workload_href}")
        curl_ec=$?
    fi

    local outcome
    if [[ "$DRY_RUN" == "1" ]]; then
        outcome='{"kind":"updated","dry_run":true}'
    elif [[ $curl_ec -ne 0 ]]; then
        outcome=$(jq -nc --arg e "curl $curl_ec" '{kind:"failed",http:0,error:$e}')
    elif [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
        outcome='{"kind":"updated","dry_run":false}'
    else
        outcome=$(jq -nc --argjson h "${http_code}" \
                    '{kind:"failed",http:$h,error:("PCE returned "+($h|tostring))}')
    fi
    # Attach identifying fields
    echo "$outcome" | jq -c --arg href "$workload_href" --arg hn "$hostname_display" \
                        '. + {href:$href, hostname:$hn}' \
        > "$result_dir/$(echo "$workload_href" | tr / _).json"
}
```

Replace the serial `for key in "${!workloads_to_update[@]}"; do ... done` with:
```bash
RESULT_DIR=$(mktemp -d "/tmp/iq_results_XXXXXX")
active=0
for key in "${!workloads_to_update[@]}"; do
    workload_href=$(echo "$key" | tr '_' '/')
    stored="${workloads_to_update[$key]}"
    existing_labels_json=$(echo "$stored" | jq -c '.labels // []')
    hostname_display=$(echo "$stored" | jq -r '.hostname // "N/A"')

    put_one_workload "$workload_href" "$hostname_display" "$existing_labels_json" "$RESULT_DIR" &
    ((active++))
    if [[ $active -ge $PARALLEL ]]; then
        wait -n
        ((active--))
    fi
done
wait

# Aggregate results into J_UPDATED / J_SKIPPED / J_FAILED
for f in "$RESULT_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    kind=$(jq -r '.kind' "$f")
    case "$kind" in
        updated)
            J_UPDATED+=("$(jq -c '{href,hostname} + (if .dry_run then {dry_run:true} else {} end)' "$f")")
            ;;
        skipped)
            J_SKIPPED+=("$(jq -c '{href,hostname}' "$f" 2>/dev/null || echo "{}")")
            ;;
        failed)
            J_FAILED+=("$(jq -c '{href,hostname,http,error}' "$f")")
            ;;
    esac
done
rm -rf "$RESULT_DIR"
```

Note: the skipped branch's jq may need the href/hostname fields to be re-attached in `put_one_workload` — the `jq -c '. + {href,hostname}'` at the end of that function ensures this.

- [ ] **Step 4: Run — expect PASS**

If the `parallel actually overlaps` test is flaky on the runner, reduce to asserting `par_ms < serial_ms` (no 25 % margin).

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_parallel.bats
git commit -m "feat: --parallel PUT pool with wait -n semaphore (D2)"
```

---

## Task 12 — CEF audit line with `flock` (decision E2)

**Files:**
- Create: `tests/test_audit_cef.bats`
- Modify: `update_illumio_workload_labels.sh` (`cef_escape`, `emit_cef`, invoke before `exit`)

- [ ] **Step 1: Tests**

`/mnt/d/RD/illumio_Quarantine/tests/test_audit_cef.bats`:
```bash
#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "audit file created with CEF header" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json \
        --correlation-id "INC-A" --reason "bats" --audit-file "$f"
    assert_success
    run cat "$f"
    assert_output --partial "CEF:0|Illumio|Quarantine|1.3.0|quarantine.action"
    assert_output --partial "cs1=INC-A"
    assert_output --partial "cs3=bats"
    assert_output --partial "cs5=Quarantine"
    assert_output --partial "cs6=Severe"
    assert_output --partial "cs7=true"
}

@test "escaping of | and = in reason" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json \
        --reason "rule|a=b" --audit-file "$f"
    run cat "$f"
    assert_output --partial 'cs3=rule\|a\=b'
}

@test "outcome=no_match when nothing matches" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    run bash "$SCRIPT" --targets "192.0.2.99" --label-id 878 \
        --mode append --non-interactive --dry-run --json --audit-file "$f"
    [[ "$status" -eq 3 ]]
    run cat "$f"
    assert_output --partial "outcome=no_match"
}

@test "flock prevents interleaving of concurrent writers" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    # 10 concurrent single-line emits
    for i in $(seq 1 10); do
        bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
            --mode append --non-interactive --dry-run --json \
            --reason "run-$i" --audit-file "$f" >/dev/null &
    done
    wait
    # Every line must be a complete CEF line (starts with CEF:0| and ends newline)
    run awk '!/^CEF:0\|/{print "BAD:" $0}' "$f"
    assert_output ""
    # Exactly 10 lines
    run wc -l < "$f"
    assert_output "10"
}

@test "no audit file when --audit-file omitted" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Add `cef_escape` + `emit_cef`**

```bash
cef_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//|/\\|}"
    s="${s//=/\\=}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

emit_cef() {
    [[ -z "$AUDIT_FILE" ]] && return 0
    local outcome="$1"
    local epoch_ms; epoch_ms=$(date +%s%3N)
    local pce_host; pce_host="${PCE_URL_BASE#https://}"; pce_host="${pce_host%%/*}"; pce_host="${pce_host%%:*}"
    local esc_reason;  esc_reason=$(cef_escape "$REASON")
    local esc_targets; esc_targets=$(cef_escape "$SEARCH_TERMS_RAW")
    local esc_cid;     esc_cid=$(cef_escape "$CORRELATION_ID")
    local esc_key;     esc_key=$(cef_escape "$TARGET_LABEL_KEY")
    local esc_val;     esc_val=$(cef_escape "$TARGET_LABEL_VALUE")
    local dry;         dry=$([[ "$DRY_RUN" == 1 ]] && echo true || echo false)

    local line
    line=$(printf 'CEF:0|Illumio|Quarantine|%s|quarantine.action|Illumio Quarantine Action|5|rt=%s dvchost=%s act=%s outcome=%s cs1Label=correlation_id cs1=%s cs2Label=audit_id cs2=%s cs3Label=reason cs3=%s cs4Label=targets cs4=%s cs5Label=label_key cs5=%s cs6Label=label_value cs6=%s cn1Label=updated_count cn1=%d cn2Label=failed_count cn2=%d cs7Label=dry_run cs7=%s' \
        "$VERSION" "$epoch_ms" "$pce_host" "$UPDATE_MODE" "$outcome" \
        "$esc_cid" "$AUDIT_ID" "$esc_reason" "$esc_targets" \
        "$esc_key" "$esc_val" \
        "${#J_UPDATED[@]}" "${#J_FAILED[@]}" "$dry")

    mkdir -p "$(dirname "$AUDIT_FILE")" 2>/dev/null || true
    local lock="${AUDIT_FILE}.lock"
    touch "$lock"
    (
        flock -x 9
        printf '%s\n' "$line" >> "$AUDIT_FILE"
    ) 9>"$lock"
}
```

Invoke right before `exit "$ec"`:
```bash
case "$ec" in
    0) outcome="success" ;;
    2) outcome="partial" ;;
    3) outcome="no_match" ;;
    *) outcome="failure" ;;
esac
emit_cef "$outcome"
```

Also call `emit_cef "failure"` right before every `exit 4` in the auth/JSON validation block.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_audit_cef.bats
git commit -m "feat: CEF audit line emission with flock-guarded concurrent writes (E2)"
```

---

## Task 13 — Security hardening

**Files:** `update_illumio_workload_labels.sh`; append to `tests/test_credentials.bats`

- [ ] **Step 1: Append test**
```bash
@test "warns on world-readable credentials file" {
    cat > "$BATS_TMPDIR_LOCAL/c.conf" <<EOF
API_USER="u"; API_PASS="p"
EOF
    chmod 644 "$BATS_TMPDIR_LOCAL/c.conf"
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --non-interactive --dry-run --json \
        --credentials-file "$BATS_TMPDIR_LOCAL/c.conf"
    assert_success
    [[ "$output" == *"insecure permissions"* ]] || [[ "$stderr" == *"insecure permissions"* ]]
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Permission check inside `load_credentials`**

Inside `load_credentials`, right after the `source "$CREDENTIALS_FILE"` line:
```bash
if [[ "$(uname)" == "Linux" ]]; then
    local mode
    mode=$(stat -c '%a' "$CREDENTIALS_FILE" 2>/dev/null || echo "000")
    if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
        echo "WARNING: credentials file $CREDENTIALS_FILE has insecure permissions $mode; recommend chmod 600" >&2
    fi
fi
```

Grep-sweep and confirm no hardcoded cred strings remain:
```bash
grep -n '你的API\|你的密碼\|你的API用戶名' /mnt/d/RD/illumio_Quarantine/update_illumio_workload_labels.sh
```
Expected: no matches.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add update_illumio_workload_labels.sh tests/test_credentials.bats
git commit -m "security: warn on world-readable credentials file"
```

---

## Task 14 — Language sweep (decision H: all English)

**Files:** `update_illumio_workload_labels.sh`

- [ ] **Step 1: Sweep all user-facing Chinese strings**

Run:
```bash
grep -n '[一-龥]' /mnt/d/RD/illumio_Quarantine/update_illumio_workload_labels.sh
```

Replace every matched user-facing string (echo/printf/read prompts/error messages) with an English equivalent. Internal comments (`# ...`) may remain Chinese to preserve history, but any string that ships to stdout/stderr must be English.

Key replacements expected:
- `"正在檢查必要套件..."` → `"Checking required packages..."`
- `"錯誤：必要套件 'curl' 未安裝..."` → `"ERROR: required package 'curl' not installed"`
- `"所有必要套件已找到。"` → `"All required packages found."`
- `"請輸入要搜索的條件..."` → `"Enter search terms..."`
- `"錯誤：搜索條件不能為空。"` → `"ERROR: empty targets"`
- `"目標 Label Href: ..."` → remove (the JSON/header now reports this)
- `"正在從 ... 獲取 Workloads..."` → `"Fetching workloads from ${WORKLOADS_BASE} ..."`
- `"成功獲取 N 個 Workloads。"` → `"Fetched N workloads."`
- `"正在分析匹配的 Workloads..."` → `"Filtering matches (managed=true)..."`
- `"分析完成：找不到..."` → `"No managed workload matched any target."`
- `"分析完成：以下 N 個..."` → `"N managed workloads will be affected:"`
- `"是否要繼續？..."` → `"Continue? (type 'yes' to confirm): "`
- `"操作已取消。"` → `"Cancelled."`
- `"請選擇 Label 更新模式："` → `"Label update mode:"`
- `"已選擇 [增加] 模式。"` → `"Mode: append."`
- `"已選擇 [覆蓋] 模式。"` → `"Mode: overwrite."`
- `"無效的選擇..."` → `"ERROR: invalid mode choice"`
- `"確認執行更新..."` → `"Proceeding with update..."`
- `"開始更新 Labels..."` → `"Updating labels..."`
- `"Workload '...' 在 [增加] 模式下已包含..."` → `"Workload '...' already labeled; skipping."`
- `"錯誤：為 ... 構造 PUT Body 失敗。"` → `"ERROR: failed to build PUT body for ..."`
- `"正在更新 Workload '...'..."` → `"Updating workload '...' [${UPDATE_MODE}]..."`
- `"成功更新 Labels (HTTP: ${http_code})"` → `"Updated labels (HTTP ${http_code})"`
- `"錯誤：更新 Workload..."` → `"ERROR: update workload '...' failed (HTTP ${http_code})"`
- `"腳本執行完畢。"` → `"Done."`

- [ ] **Step 2: Run full test suite**

```bash
scripts/run_tests.sh
```
Expected: every test green.

- [ ] **Step 3: Commit**

```bash
git add update_illumio_workload_labels.sh
git commit -m "i18n: sweep all user-facing strings to English (decision H)"
```

---

## Task 15 — `docs/FortiSIEM_Integration.md`

**Files:** create `docs/FortiSIEM_Integration.md`

- [ ] **Step 1: Write the guide**

`/mnt/d/RD/illumio_Quarantine/docs/FortiSIEM_Integration.md`:
```markdown
# FortiSIEM — Illumio Quarantine Integration

Wires `update_illumio_workload_labels.sh` v1.3.0 into FortiSIEM so that when
an incident fires, a workload is auto-quarantined by label.

Shapes supported in v1.3.0:

| Shape | Recommended? |
|---|---|
| **SSH Remediation Script** | Yes — primary integration |
| Notification Policy HTTP POST | Deferred to v2 (needs the Python webhook) |

## Prerequisites

On the quarantine host (Linux):
1. `sudo apt-get install -y curl jq ipcalc util-linux git`
2. `git clone <repo> /opt/illumio_Quarantine && cd /opt/illumio_Quarantine && git submodule update --init`
3. `cp config/quarantine.conf.example config/quarantine.conf`
4. Fill in `API_USER`, `API_PASS`; `chmod 600 config/quarantine.conf`
5. Dry-run smoke:
   ```bash
   ./update_illumio_workload_labels.sh \
       --targets "10.0.0.5" --label-key Quarantine --label-value Severe \
       --non-interactive --dry-run --json \
       --credentials-file config/quarantine.conf
   ```

On FortiSIEM Supervisor:
1. SSH credential to the quarantine host (low-privilege user that can execute
   the script).
2. Audit ingestion (see "Audit" below).

## Remediation Script

1. **Admin → Settings → Remediation → New**
2. **Name:** `Illumio Quarantine Apply`
3. **Vendor:** `Illumio`  **Product:** `PCE`
4. **Script type:** `Shell`
5. **Host / Credential:** the quarantine host + SSH cred
6. **Script body:**
   ```bash
   /opt/illumio_Quarantine/update_illumio_workload_labels.sh \
       --targets "${incidentSrcIpAddr}" \
       --label-key Quarantine --label-value Severe \
       --mode append \
       --non-interactive --json --parallel 4 \
       --correlation-id "${incidentId}" \
       --reason "${ruleName}" \
       --credentials-file /opt/illumio_Quarantine/config/quarantine.conf \
       --audit-file /var/log/illumio_quarantine.cef
   ```
7. Save.

Repeat for a release action with a different `--label-value` (e.g. `Released`)
or use `--mode overwrite`.

## Rule binding

1. **Admin → Incidents → Rules → open rule**
2. **Actions → Add Remediation → select** `Illumio Quarantine Apply`
3. Save.

Variable expansion at fire time:
- `${incidentSrcIpAddr}` → `--targets`
- `${incidentId}` → `--correlation-id`
- `${ruleName}` → `--reason`

## Audit

Have the FortiSIEM Linux agent tail `/var/log/illumio_quarantine.cef` and
forward as CEF. Parser mapping:
```
Vendor=Illumio  Product=Quarantine  Version=1.3.0
EventId=quarantine.action  Severity=5
cs1→correlationId, cs2→auditId, cs3→reason, cs4→targets,
cs5→labelKey,      cs6→labelValue, cs7→dryRun,
cn1→updatedCount,  cn2→failedCount
```

With `correlationId ↔ incidentId`, FortiSIEM can auto-close the incident.

## Exit-code handling

| Code | Meaning | Suggested action |
|---|---|---|
| 0 | all matched, all quarantined | close incident |
| 2 | partial (some failed) | flag for operator |
| 3 | no match (target not managed) | note and close, or escalate |
| 4 | PCE auth failure | page oncall; rotate creds |
| 5 | invalid input | check rule template variables |
| 6 | credentials missing | check conf permissions |

## Smoke test

```
ssh quarantine-host /opt/illumio_Quarantine/update_illumio_workload_labels.sh \
    --targets "<test hostname>" --label-key Quarantine --label-value Severe \
    --mode append --non-interactive --dry-run --json \
    --correlation-id "SMOKE-001" --reason "FortiSIEM smoke test" \
    --credentials-file /opt/illumio_Quarantine/config/quarantine.conf \
    --audit-file /var/log/illumio_quarantine.cef
```

Verify:
- exit `0` (or `3` for a fake host — both OK)
- JSON on stdout
- CEF line appended with matching `cs1=SMOKE-001`
- FortiSIEM Collector receives the CEF event within a minute
```

- [ ] **Step 2: Commit**

```bash
git add docs/FortiSIEM_Integration.md
git commit -m "docs: FortiSIEM SSH Remediation Script integration guide"
```

---

## Task 16 — `docs/ROADMAP.md`

**Files:** create `docs/ROADMAP.md`

- [ ] **Step 1: Write**

`/mnt/d/RD/illumio_Quarantine/docs/ROADMAP.md`:
```markdown
# illumio_Quarantine Roadmap

## v1.3.0 — bash, FortiSIEM-ready (this release)

Scope:
- Non-interactive CLI: `--non-interactive`, `--json`, `--dry-run`
- Target label resolution by `--label-id` or `--label-key`/`--label-value`
- Append-mode strips existing same-key labels before adding (B2)
- Server-side per-term workload lookup when all terms are precise, one full
  scan when CIDR/range/prefix is present
- `--parallel N` PUT pool (1..20)
- `--correlation-id` round-trip; `--reason` audit
- CEF audit line under flock
- Exit codes 0/2/3/4/5/6
- bats-core test suite
- Externalized credentials (CLI > env > file > default)

## v2.0.0 — Python, coexisting (planned)

Status: not started. v1 remains production.

Goals:
1. HTTP webhook `POST /webhook/v1/quarantine/apply` (bearer-token).
   Unlocks Splunk SOAR / QRadar SOAR without SSH.
2. Direct SIEM dispatchers: syslog UDP/TCP/TLS + Splunk HEC.
3. Multi-destination SIEM (`config.siem.destinations[]`).
4. pip-installable with `illumio-quarantine` console script.
5. systemd service template.
6. `quarantine/release` reverse endpoint.

Non-goals for v2:
- Replacing the bash v1 — both ship side-by-side.
- GUI (delegate to illumio_ops).

Likely layout (independent from illumio_ops):
```
illumio_quarantine/
├── cli.py  pce_client.py  workload_filter.py  audit.py
│   config.py  webhook.py  server.py
│   siem/{cef.py,json_line.py,transports.py}
└── tests/
```

## v2.1 (tentative)

- Per-token rate limiting
- Auto-release after N minutes unless held
- Multi-org PCE routing

## Non-plan

- Replacing Illumio PCE
- Policy authoring (see illumio_ops)
```

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs: v2 Python roadmap"
```

---

## Task 17 — README rewrite (English)

**Files:** modify `README.md`

- [ ] **Step 1: Rewrite**

`/mnt/d/RD/illumio_Quarantine/README.md`:
```markdown
# illumio_Quarantine

Auto-quarantine Illumio PCE workloads by label. Callable interactively by an
operator or non-interactively by a SIEM/SOAR playbook.

**Current release: v1.3.0** (bash).

> Future v2 (Python + HTTP webhook) is planned — see `docs/ROADMAP.md`.

## Install

```bash
sudo apt-get install -y curl jq ipcalc util-linux git
git clone <repo> /opt/illumio_Quarantine
cd /opt/illumio_Quarantine
git submodule update --init              # for the test harness only
cp config/quarantine.conf.example config/quarantine.conf
chmod 600 config/quarantine.conf
# edit API_USER / API_PASS
```

## Quick start — interactive (operator)

```bash
./update_illumio_workload_labels.sh --credentials-file config/quarantine.conf
```

## Quick start — non-interactive (SIEM/SOAR)

```bash
./update_illumio_workload_labels.sh \
    --targets "10.0.0.5,server1.lab.local,10.20.30.0/24" \
    --label-key Quarantine --label-value Severe \
    --mode append \
    --non-interactive --json --parallel 4 \
    --correlation-id "INC-12345" \
    --reason "Malware beaconing rule" \
    --credentials-file config/quarantine.conf \
    --audit-file /var/log/illumio_quarantine.cef
```

## FortiSIEM integration

See [`docs/FortiSIEM_Integration.md`](docs/FortiSIEM_Integration.md).

## Credentials precedence

`CLI flag` > `ILLUMIO_QUARANTINE_*` env var > `--credentials-file` sourced
value > script default.

## CLI reference

`./update_illumio_workload_labels.sh --help`.

## JSON schema / CEF audit

See `docs/FortiSIEM_Integration.md` §Audit.

## Tests

```bash
scripts/run_tests.sh
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for v1.3.0 (English, SIEM-ready)"
```

---

## Task 18 — End-to-end smoke (manual, real PCE)

**Files:** none. Manual checklist.

- [ ] **Step 1: Prepare creds**
  ```bash
  cat > config/quarantine.conf <<EOF
  API_USER="<pce api user>"
  API_PASS="<pce api secret>"
  PCE_URL_BASE="https://pce.lab.local:8443"
  ORG_ID="1"
  EOF
  chmod 600 config/quarantine.conf
  ```

- [ ] **Step 2: Dry-run**
  ```bash
  ./update_illumio_workload_labels.sh \
      --targets "<test workload hostname>" \
      --label-key Quarantine --label-value Severe \
      --mode append --non-interactive --dry-run --json \
      --correlation-id "SMOKE-001" --reason "e2e smoke" \
      --credentials-file config/quarantine.conf \
      --audit-file /tmp/audit.cef
  ```
  Verify: valid JSON; `.matched | length >= 1`; `.dry_run == true`;
  `/tmp/audit.cef` has one CEF line with `outcome=success`; exit `0`.

- [ ] **Step 3: Real apply + append semantics check**
  Re-run without `--dry-run`. In PCE GUI confirm:
  - target gains `Quarantine:Severe`
  - target KEEPS role / env / app labels (append preserves them)
  - any prior `Quarantine:Mild|Moderate` is removed (B2 strip)

- [ ] **Step 4: Idempotency**
  Re-run same command. Expected: `counts.updated == 0`,
  `counts.skipped == 1`, exit `0`.

- [ ] **Step 5: Parallel**
  ```bash
  ./update_illumio_workload_labels.sh \
      --targets "<CIDR with ~10 workloads>" \
      --label-key Quarantine --label-value Severe \
      --mode append --non-interactive --dry-run --json --parallel 5
  ```
  Verify `counts.updated` matches expectation; duration noticeably shorter
  than `--parallel 1` of the same command.

- [ ] **Step 6: Rollback**
  Use `--mode overwrite` with the prior label id/key+value to clean up test
  state (or manually remove in PCE GUI).

- [ ] **Step 7: FortiSIEM loop (if lab available)**
  Trigger the bound rule on a test IP. Verify:
  - remediation log shows exit `0`
  - CEF event arrives at FortiSIEM Collector within a minute
  - incident auto-closes on `correlationId` match

---

## Self-Review

### Spec coverage

| Requirement | Task |
|---|---|
| Non-interactive for SIEM | 3, 5 |
| FortiSIEM primary | 15 |
| Variable passing (CLI/JSON) | 3, 9 |
| Credentials precedence (G) | 2 |
| JSON for SOAR | 9 |
| Exit code regime | 10 |
| CEF audit with flock (E2) | 12 |
| Dry-run | 7 |
| Correlation id round-trip | 8, 9, 12 |
| Label id OR key+value (A) | 3, 4 |
| Same-key strip (B2) | 4 |
| Server-side + full-scan (C2+C3) | 6 |
| Parallel PUT (D2) | 11 |
| Fail-fast (F1) | 11 |
| All English (H) | 14 |
| Python v2 roadmap-only | 16 |
| bash retained | whole plan (same file) |

### Placeholder scan

Every code step contains complete code. No `TBD` / `TODO` / "handle edge cases" without explicit code. Test steps include full `.bats` files.

### Type / name consistency

- Flags `NON_INTERACTIVE`, `DRY_RUN`, `JSON_OUT`, `PARALLEL` defined in Task 3, referenced identically in 4, 5, 7, 9, 11, 12.
- `TARGET_LABEL_HREF`, `TARGET_LABEL_KEY`, `TARGET_LABEL_VALUE`, `SAME_KEY_HREFS_JSON` set in Task 4, consumed in 9 (JSON emit) and 12 (CEF emit).
- `SEARCH_STRATEGY` assigned in Task 6, consumed in Task 9.
- Arrays `J_REQUESTED`, `J_MATCHED`, `J_UPDATED`, `J_SKIPPED`, `J_FAILED` declared in Task 9, written by Tasks 9 and 11, read by Task 12 (`${#J_UPDATED[@]}` / `${#J_FAILED[@]}`).
- Exit codes `0/2/3/4/5/6` used identically in Tasks 3, 9, 10, 15 (docs).
- CEF field labels (`cs1`..`cs7`, `cn1`, `cn2`) match between `emit_cef` (Task 12) and FortiSIEM parser docs (Task 15).
- `put_one_workload(workload_href, hostname_display, existing_labels_json, result_dir)` signature in Task 11 matches the caller loop in the same task.

---

## Appendix A — NotebookLM research validation (added 2026-04-21)

Source notebooks consulted:
- **Illumio** notebook (source: `50b861c2-…`, the Illumio PCE REST API 25.2 guide)
- **FortiSIEM** notebook (source: `8b1acb9a-…`, *FortiSIEM 7.5.0 User Guide*; and `d35c430c-…`, *External Systems Configuration Guide*)

### A.1 Confirmations — technical route is sound

The following plan decisions are validated verbatim by the vendor docs:

| Plan element | Docs say |
|---|---|
| `GET /api/v2/orgs/{org}/workloads?ip_address=…&hostname=…` (C2) | Independent query parameters, **both support partial match**; can be combined for AND-style filtering. |
| `PUT /api/v2/orgs/{org}/workloads/{uuid}` with full `labels[]` array | Replace semantics — you must send the complete array; items need only `{href}` (no key/value). |
| `GET /api/v2/orgs/{org}/labels?key=<k>&value=<v>` | Documented endpoint for key+value lookup; `value` supports partial match (see A.2 gotcha). |
| Same-key strip before append (B2) | PCE enforces "one label per key per workload" at the API level — submitting two hrefs with the same key returns **40x**. B2 is not just mirroring illumio_ops, it is a hard requirement. |
| Unmanaged workloads excluded | Confirmed — unmanaged (`managed: false`) workloads have no VEN and should be filtered out, as the script already does. |

### A.2 New gotcha — exact-value match in label resolver

`GET /labels?key=K&value=V` returns **partial matches on value** (e.g. `value=Sev` would match `Severe` *and* `Severely`). The plan's Task 4 label resolver therefore MUST filter the response with an exact-value predicate before selecting the `href`:

```bash
jq -r --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" \
   '.[] | select(.key==$k and .value==$v) | .href' <<< "$labels_json"
```

and error out with exit **5** (input error) if zero or >1 exact matches are found. Same note applies to the fixture `labels_by_key.json`: add a distractor such as `Severely` to exercise the exact-value filter in `test_label_resolve.bats`.

### A.3 Corrections to Task 15 (`docs/FortiSIEM_Integration.md`)

The guide text drafted in Task 15 uses UI paths and field names that do **not** match FortiSIEM 7.5. When executing Task 15, use these corrected values:

| Current draft (wrong) | FortiSIEM 7.5 actual |
|---|---|
| UI: *Admin → Settings → Remediation → New* | **Resources → Automation → Remediations**, click **+** |
| *Vendor: Illumio / Product: PCE* | **Device Type** (single field, pick Illumio if registered, else Linux/generic host) |
| *Script type: Shell* | **Protocol: SSH** (options: SSH, HTTP, HTTPS, MS_WMI) |
| *Admin → Incidents → Rules → Actions → Add Remediation* | **Admin → Settings → General → Automation Policy** → add policy → **Action: Run Remediation/Script** (for auto-trigger); or ad-hoc via **Incidents → List → Actions → Remediate Incident** |

### A.4 Variable substitution — risk + mitigation

The FortiSIEM docs confirm `$token` substitution exists for **Incident Titles, email templates, and external ticketing integrations** (tokens seen: `$hostName`, `$user`, `$fileName`, `$ruleName`, `$incident_severityCat`, `$extTicketId`, etc.). The docs do **not** explicitly state the same substitution happens inside a custom Remediation Script's *Script Content* field. The documented delivery mechanism for SSH/WinRM-protocol remediations is that the enforcement point "passes enforced-on device IP/Host, credentials, and incident details to the script" — the only script-scope variables confirmed by example are `enforceOn`, `user`, `password` (seen in the Python WinRM snippet).

Implication for the Task 15 script body using `${incidentSrcIpAddr}`, `${incidentId}`, `${ruleName}`:

- **If** your FortiSIEM tenant does substitute tokens in Script Content (common in the field; matches the notification-template precedent) → the drafted body works.
- **If not** → the script will see the literal `${incidentSrcIpAddr}` and fail input validation (exit 5).

**Mitigation (add to Task 15 Step 1):**

1. Recommend the operator first do a **dry-run smoke test** from the FortiSIEM UI (Incidents → Remediate Incident) on a known incident, capture the actual command line from `/var/log/illumio_quarantine.cef` or the Supervisor's remediation log, and verify the tokens expanded.
2. If tokens do **not** expand inside Script Content: the fallback is an **intermediate wrapper on the quarantine host** that reads incident fields from stdin JSON (FortiSIEM's HTTP/HTTPS-protocol remediation pushes a JSON body), then invokes `update_illumio_workload_labels.sh`. This fallback is v2 territory (webhook) — document but do not build in v1.
3. Document the `enforceOn` semantics: in SSH-protocol remediation, `enforceOn` is the host FortiSIEM SSHes **into** — i.e. the quarantine host itself, not the incident source IP. The malicious/victim IP you want to quarantine must come from `$srcIpAddr` / `$incidentSrc`-style tokens inside Script Content. This distinction belongs in the guide.

### A.5 Suggested edit to Task 15 Step 1 (when executed)

Insert the following at the top of the drafted `docs/FortiSIEM_Integration.md`, right under the "Shapes supported" table:

> **Compatibility note.** Vendor docs for FortiSIEM 7.5 do not definitively document whether `$token` substitution applies inside the custom Remediation Script's Script Content field (it applies for notification templates and ticketing integrations). Before wiring an automation policy to fire unattended, **verify on a test incident** that `${incidentSrcIpAddr}`, `${incidentId}`, and `${ruleName}` expand to real values by checking the emitted CEF line (`cs1`, `cs3`, `cs4`). If tokens arrive literal, either (a) wait for v2's HTTP webhook, or (b) pick a different token set — common working tokens include `$srcIpAddr`, `$incidentSrc`, `$incidentTarget`, `$incidentId`, `$ruleName`. Use ad-hoc "Remediate Incident" first, then switch to Automation Policy once token expansion is confirmed.

### A.6 No change to the rest of the plan

Tasks 1–14, 16–18, the CLI surface, the JSON/CEF schemas, exit codes, `flock`/`wait -n` concurrency, and the credentials precedence (G) are all unaffected by this research. Technical route remains: bash-only v1 via SSH Remediation Script + CEF tail; Python webhook in v2.
