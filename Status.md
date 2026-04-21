# illumio_Quarantine — Status

**Last updated:** 2026-04-21 (planning session handoff + NotebookLM validation pass)
**Branch:** `main`
**Release target:** v1.3.0 (bash, FortiSIEM Remediation Script integration)

---

## Where we are

**Planning complete. Implementation not started.**

The 18-task implementation plan is finalized and locked at:

```
/mnt/d/RD/illumio_Quarantine/docs/superpowers/plans/2026-04-21-fortisiem-integration.md
```

All 8 design decisions (A/B/C/D/E/F/G/H) are resolved and embedded in the plan.

## What changed this session

- No source files edited. Only planning documents created.
- Created this session:
  - `docs/superpowers/plans/2026-04-21-fortisiem-integration.md` (the canonical plan)
  - `Status.md` (this file)
  - `Task.md` (task tracker)

## What did NOT change

- `update_illumio_workload_labels.sh` — still v1.2.1 interactive-only
- `README.md` — unmodified this session (git shows `M` from a prior session)
- No tests, no new config/, no FortiSIEM docs yet

## Scope

- **v1 (this plan):** bash-only, FortiSIEM via SSH Remediation Script + CEF audit file.
- **v2 (roadmap, not in this plan):** Python package + Flask webhook + multi-SIEM dispatchers.
  To be documented in `docs/ROADMAP.md` as Task 16 of the current plan.

## Design decisions locked

| # | Decision |
|---|---|
| A | Support both `--label-id` AND `--label-key`+`--label-value`. If both given, label-id wins with a stderr warning. |
| B | B2: append mode strips existing same-key labels before adding the new one (mirrors illumio_ops). |
| C | Support C2 (server-side `?ip_address=` / `?hostname=` per precise term) AND C3 (full-scan fallback when any term is CIDR/range/prefix). |
| D | D2: `--parallel N` (1..20, default 1), bash background jobs + `wait -n` semaphore. |
| E | E2: CEF audit line under `flock -x` on `<audit-file>.lock`. |
| F | F1: PCE errors → `failed[]`; no in-script retry. |
| G | Override precedence: CLI flag > env var > `--credentials-file` > script default. |
| H | All user-facing strings in English. Internal comments may remain bilingual. |

## Open questions

None. All design decisions resolved. Ready for execution.

## NotebookLM validation (2026-04-21)

Cross-checked the plan against the FortiSIEM 7.5 User Guide + External Systems
Guide, and the Illumio PCE REST API 25.2 guide (via NotebookLM skill).

**Technical route: confirmed sound.** No decision A–H needs to change.

Additions written into the plan as **Appendix A**:

- A.1 Vendor docs confirm C2 query semantics, PUT replace semantics, labels[] href-only,
  and that PCE **rejects** duplicate same-key label hrefs with 40x → B2 is a hard
  requirement, not a preference.
- A.2 New gotcha: `GET /labels?key=K&value=V` partial-matches on value;
  Task 4 resolver must apply an exact-value jq filter and add a distractor
  (e.g. `Severely`) to the fixture.
- A.3 Corrections for Task 15 UI paths and field names (Resources → Automation →
  Remediations, Protocol=SSH, Automation Policy for auto-trigger).
- A.4 Variable-substitution risk: FortiSIEM docs confirm `$token` substitution
  for notification templates / ticketing, but do **not** confirm it for the
  Remediation Script's Script Content field. Mitigation: test with ad-hoc
  "Remediate Incident" first, verify tokens expand in the CEF audit line,
  then wire the Automation Policy.
- A.5 Text snippet to insert at the top of `docs/FortiSIEM_Integration.md`
  when Task 15 is executed.

## Scope: FortiSIEM-only, no de-branding

v1.3.0 is FortiSIEM-specific. Each SIEM vendor's integration surface differs
too much to usefully abstract at v1. A vendor-neutral `docs/SIEM_Integration.md`
was briefly drafted this session and then deleted — `docs/FortiSIEM_Integration.md`
(Task 15) remains the single v1 integration guide. Multi-SIEM coverage is
deferred to v2 (see `docs/ROADMAP.md`).

## Next step

User will choose execution mode in the next session:

1. **Subagent-Driven** (recommended) — one fresh subagent per task, review between tasks.
2. **Inline Execution** — batch execution with checkpoints in the main session.

Both paths follow the same 18-task plan.

## Files to create (per plan)

- `config/quarantine.conf.example`
- `docs/FortiSIEM_Integration.md` — v1's primary integration guide; bash is FortiSIEM-specific, **keep the brand in v1 docs + user-facing strings that mention the SIEM**.
- `docs/ROADMAP.md`
- `.gitignore`
- `tests/helpers/setup.bash`, `tests/helpers/mocks/curl`
- `tests/fixtures/{workloads_list,single_workload,labels_by_key,label_by_id}.json`
- `tests/test_{harness_smoke,args,credentials,label_resolve,search_strategy,dry_run,json_output,exit_codes,parallel,audit_cef}.bats`
- `tests/lib/bats-{core,assert,support}` (git submodules)
- `scripts/run_tests.sh`

## Files to modify

- `update_illumio_workload_labels.sh` — refactor to v1.3.0
- `README.md` — rewrite for v1.3.0 (English, SIEM-ready)
