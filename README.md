# illumio_Quarantine

Auto-quarantine Illumio PCE workloads by label. Callable interactively by an
operator or non-interactively by a SIEM/SOAR playbook (FortiSIEM primary).

**Current release: v1.3.0** (bash).

> Future v2 (Python + HTTP webhook) is planned — see `docs/ROADMAP.md`.

---

## Install

```bash
sudo apt-get install -y curl jq ipcalc util-linux git
git clone <repo> /opt/illumio_Quarantine
cd /opt/illumio_Quarantine
git submodule update --init              # for the test harness only
```

## Configure — two paths

### Path 1: config file (recommended for operators)

```bash
cp config/quarantine.conf.example config/quarantine.conf
chmod 600 config/quarantine.conf
# edit API_USER / API_PASS / PCE_URL_BASE / ORG_ID
```

The script auto-discovers a credentials file in this search order when
`--credentials-file` is not given:
1. `./config/quarantine.conf` (repo-local)
2. `$HOME/.config/illumio_quarantine/quarantine.conf`
3. `/etc/illumio_quarantine/quarantine.conf`

### Path 2: environment variables (recommended for SIEM/SOAR automation)

Bake these once into `/etc/environment`, systemd `EnvironmentFile=`, or the
SIEM agent's user profile:

```bash
ILLUMIO_QUARANTINE_API_USER=api_xxxxxxxxxx
ILLUMIO_QUARANTINE_API_PASS=<secret>
ILLUMIO_QUARANTINE_PCE_URL=https://pce.lab.local:8443
ILLUMIO_QUARANTINE_ORG_ID=1
ILLUMIO_QUARANTINE_AUDIT_FILE=/var/log/illumio_quarantine.cef
```

Env vars override the credentials file. CLI flags override env vars.

**Precedence**: `CLI flag` > `ILLUMIO_QUARANTINE_*` env var > `--credentials-file` parsed value > script default.

### TLS behavior (important)

- By default, `illumio-quarantine.sh` verifies the PCE TLS certificate.
- Use `--insecure` only in controlled lab/testing environments (for example, temporary self-signed cert setup).
- For production, install the proper CA chain on the host and do **not** use `--insecure`.

---

## Required vs optional arguments

### Required (non-interactive mode)

| Flag | What | Why required |
|---|---|---|
| `--targets <csv>` | IP/hostname/CIDR/range/prefix | Identifies who to act on — varies per call |
| **Exactly one of**:<br>`--label-id N`<br>**or**<br>`--label-key K --label-value V` | Which label to apply | Identifies the quarantine label |
| `--non-interactive` | Skip prompts | Required when invoked by SIEM (no TTY) |

### Credentials (one of)

| Source | How |
|---|---|
| Env vars (preferred for SIEM) | `ILLUMIO_QUARANTINE_API_USER` + `ILLUMIO_QUARANTINE_API_PASS` (+ optional `_PCE_URL`, `_ORG_ID`) |
| Credentials file (default search path) | Drop `quarantine.conf` at one of the 3 search paths (see above) |
| Explicit `--credentials-file <path>` | Overrides default search |

### Recommended for SIEM audit

| Flag | What | Env var alternative |
|---|---|---|
| `--json` | Structured stdout for SOAR to parse | — |
| `--correlation-id <id>` | SIEM incident ID — echoed in JSON + CEF, enables auto-close | — |
| `--reason <text>` | Human-readable cause — echoed to audit | — |
| `--audit-file <path>` | Append CEF line under flock (SIEM tails this) | `ILLUMIO_QUARANTINE_AUDIT_FILE` |

### Optional / tuning

| Flag | Default | Notes |
|---|---|---|
| `--mode append\|overwrite` | `append` | `append` preserves existing business labels; `overwrite` wipes |
| `--parallel N` | `1` | `1..20`; concurrent PUTs |
| `--dry-run` | off | Skip PUTs; still emit JSON + CEF |
| `--insecure` | off | Disable TLS certificate verification (`curl -k`), use only for controlled lab/testing |
| `--pce-url <url>` | from file/env | Override PCE base URL |
| `--org-id <id>` | from file/env | Override Org ID |

---

## Quick start — interactive (operator at a shell)

```bash
./illumio-quarantine.sh
# Uses ./config/quarantine.conf auto-discovery. Prompts for targets, label, mode, confirmation.
```

## Quick start — minimum non-interactive

```bash
export ILLUMIO_QUARANTINE_API_USER=api_xxx
export ILLUMIO_QUARANTINE_API_PASS=<secret>
export ILLUMIO_QUARANTINE_PCE_URL=https://pce.lab.local:8443
export ILLUMIO_QUARANTINE_ORG_ID=1

./illumio-quarantine.sh \
    --targets "10.0.0.5" --label-id 134 \
    --non-interactive
```

4 arguments. Everything else has sensible defaults.

## Quick start — full SIEM-ready

With environment variables baked in once:

```bash
./illumio-quarantine.sh \
    --targets "${incidentSrcIpAddr}" \
    --label-key Quarantine --label-value Severe \
    --non-interactive --json \
    --correlation-id "${incidentId}" \
    --reason "${ruleName}"
```

Lab-only (self-signed cert bootstrap):

```bash
./illumio-quarantine.sh \
    --targets "${incidentSrcIpAddr}" \
    --label-key Quarantine --label-value Severe \
    --non-interactive --json \
    --correlation-id "${incidentId}" \
    --reason "${ruleName}" \
    --insecure
```

Without env vars (explicit paths everywhere):

```bash
./illumio-quarantine.sh \
    --targets "10.0.0.5,server1.lab.local,10.20.30.0/24" \
    --label-key Quarantine --label-value Severe \
    --mode append --non-interactive --json --parallel 4 \
    --correlation-id "INC-12345" \
    --reason "Malware beaconing rule" \
    --credentials-file /opt/illumio_Quarantine/config/quarantine.conf \
    --audit-file /var/log/illumio_quarantine.cef
```

---

## FortiSIEM integration

See [`docs/FortiSIEM_Integration.md`](docs/FortiSIEM_Integration.md) for the
complete FortiSIEM 7.5 setup (CMDB registration, SSH credential binding,
Remediation Script body, Automation Policy trigger, CEF audit parser).

## CLI reference

```bash
./illumio-quarantine.sh --help
```

## JSON schema

See `docs/FortiSIEM_Integration.md` §Audit for the CEF field mapping. The
`--json` output contains:

```
audit_id, correlation_id, mode, label{href,key,value},
requested_targets[], search_strategy, matched[], updated[],
skipped_already_labeled[], failed[],
counts{requested,matched,updated,skipped,failed},
parallel, dry_run, duration_ms, exit_code
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (all matched workloads were updated or idempotently skipped) |
| 2 | Partial failure (some PUTs failed; check `failed[]` in JSON) |
| 3 | No managed workload matched any target |
| 4 | PCE unreachable or auth failure |
| 5 | Invalid input (bad flags, unknown label, ambiguous key/value) |
| 6 | Credentials missing |

## Tests

```bash
scripts/run_tests.sh
```

Single-test file:
```bash
scripts/run_tests.sh tests/test_args.bats
```
