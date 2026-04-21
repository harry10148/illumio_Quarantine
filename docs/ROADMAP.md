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
