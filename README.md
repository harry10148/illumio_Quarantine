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
