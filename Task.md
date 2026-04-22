# illumio_Quarantine — Active Task List

**Active goal:** Execute the 18-task plan at
`docs/superpowers/plans/2026-04-21-fortisiem-integration.md` to ship v1.3.0.

**Execution mode:** Subagent-driven (B-mode: small tasks compressed to spec-review-only, large tasks keep dual review).

**Progress:** 18/18 tasks complete on branch `v1.3.0-fortisiem`. 63/63 tests green.
2026-04-22: code-review remediation pass complete.

## 2026-04-22 code review follow-ups

- [x] **CR-1 (P1 security)** — Prevent auto-sourced `./config/quarantine.conf` from executing arbitrary shell code.
- [x] **CR-2 (P1 correctness)** — In `resolve_target_label`, validate/auth-check `same_resp` (`GET /labels?key=...`) before building `SAME_KEY_HREFS_JSON`.
- [x] **CR-3 (P1 correctness)** — Fix term classification so numeric-leading hyphen hostnames (e.g. `1-web`) are not treated as IP ranges.
- [x] **CR-4 (P1 security)** — Remove default `curl -k` behavior or gate it behind explicit opt-in flag.
- [x] **CR-4-docs** — Document TLS-default behavior and `--insecure` usage in README + FortiSIEM integration guide.

**Test runner:** `scripts/run_tests.sh` (exists AFTER Task 1).

---

## Task progress

Mark each task with its state as work proceeds:
`[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked

### Phase 1 — Harness & externalization
- [x] **Task 1** — Test harness: bats-core submodules, mock curl, fixtures, `.gitignore`, smoke test
      → `ea7fe4e`, `ecc069c` (runner double-run fix), `dbd5730` (+x on scripts)
- [x] **Task 2** — Externalize credentials (`--credentials-file`, env vars, `load_credentials` with precedence G)
      → `a9e8deb`
- [x] **Task 3** — CLI argument parser (`--targets`, `--label-id`, `--label-key`/`--label-value`, `--parallel`, `--help`, `--version`, etc.)
      → `eda0388`

### Phase 2 — Core logic
- [x] **Task 4** — Label resolution + same-key strip (decisions A + B2): `resolve_target_label`, append-mode PUT body refactor
      → `25893fb`, `12a5e00` (URL-encode + PUT-body guard fix)
      — Forward-merged Task 5's NON_INTERACTIVE gate around the confirm/mode prompts (flow only; text stays Chinese)
      — tests 1/2 of test_label_resolve.bats stay RED until Task 9 lands JSON emission
- [ ] **Task 5** — Non-interactive gates on confirmation + mode prompts
      (ℹ control flow already wrapped in Task 4; remaining work: replace Chinese strings per plan + add `refute_output --partial "Continue?"` test)
- [ ] **Task 6** — Search strategy dispatch (C2 + C3): `classify_term`, server-side per-term OR one full scan
- [ ] **Task 7** — `--dry-run` gates the PUT
- [ ] **Task 8** — `--correlation-id` / `--reason` header echo
- [ ] **Task 9** — `--json` output with stable schema + accumulators
- [x] **Task 10** — Exit code regime consolidation (0/2/3/4/5/6)
      → `tests/test_exit_codes.bats` (5 new tests); mock curl AUTH_FAIL covers all GETs;
        `resolve_target_label` now detects auth-fail response and exits 4 (was 5)

### Phase 3 — Scale + audit + security
- [x] **Task 11** — `--parallel N` PUT pool (D2): `put_one_workload`, `wait -n` semaphore, result aggregation
- [x] **Task 12** — CEF audit line with `flock` (E2): `cef_escape`, `emit_cef`, invoke before every exit path
- [x] **Task 13** — Security hardening: world-readable creds warning, final sweep of hardcoded-cred residue

### Phase 4 — Language + docs + release
- [x] **Task 14** — Language sweep (H): all user-facing strings → English
- [x] **Task 15** — `docs/FortiSIEM_Integration.md` with Appendix A.3/A.4/A.5 corrections
- [x] **Task 16** — `docs/ROADMAP.md` (v2 Python vision)
- [x] **Task 17** — `README.md` rewrite for v1.3.0

### Phase 5 — Acceptance
- [x] **Task 18** — End-to-end smoke on real PCE (SMOKE-001 on dc, SMOKE-003 on d-api)

### Post-E2E polish (driven by real-PCE findings)
- [x] Hostname-with-dash classification fix (`2244b8b`)
- [x] README + FortiSIEM guide expansion: env vars, CMDB, credential binding (`1148afc`)
- [x] PCE unreachable → exit 4 (was misleadingly exit 5) (`f5647e5`)
- [x] Default `--credentials-file` search path (`9273e4e`)
- [x] curl `--connect-timeout 10 --max-time 30` (`dbe7578`)
- [x] Script renamed to `illumio-quarantine.sh` (`3112844`)

### Phase 5 — Acceptance
- [ ] **Task 18** — End-to-end smoke on real PCE (manual checklist)

---

## How to resume

1. Read `Status.md` for a quick summary of where the project stands.
2. Open the canonical plan:
   `docs/superpowers/plans/2026-04-21-fortisiem-integration.md`
3. Ask the user which execution mode they want (subagent-driven vs inline).
4. Start at Task 1. Each task has TDD-style steps with complete code blocks.
5. Mark tasks `[x]` in this file as they complete; commit after each task.

## Reminders

- bash 4.3+ required for `wait -n`.
- `flock` is in util-linux — not a new dependency but note it.
- Do NOT skip the test-first step in each task. Tests are designed to fail
  before the implementation, pass after — that's the signal.
- Keep commits per-task as the plan specifies.
- The v1.2.1 script has Chinese user-facing strings. Task 14 does the full
  sweep to English — earlier tasks may introduce new English strings
  alongside existing Chinese; that's expected until Task 14 runs.
