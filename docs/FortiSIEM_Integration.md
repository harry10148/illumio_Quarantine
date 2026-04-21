# FortiSIEM — Illumio Quarantine Integration

Wires `update_illumio_workload_labels.sh` v1.3.0 into FortiSIEM so that when
an incident fires, a workload is auto-quarantined by label.

> **Compatibility note.** Vendor docs for FortiSIEM 7.5 do not definitively
> document whether `$token` substitution applies inside the custom Remediation
> Script's Script Content field (it applies for notification templates and
> ticketing integrations). Before wiring an automation policy to fire
> unattended, **verify on a test incident** that `${incidentSrcIpAddr}`,
> `${incidentId}`, and `${ruleName}` expand to real values by checking the
> emitted CEF line (`cs1`, `cs3`, `cs4`). If tokens arrive literal, either (a)
> wait for v2's HTTP webhook, or (b) pick a different token set — common
> working tokens include `$srcIpAddr`, `$incidentSrc`, `$incidentTarget`,
> `$incidentId`, `$ruleName`. Use ad-hoc "Remediate Incident" first, then
> switch to Automation Policy once token expansion is confirmed.

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

Register the script in FortiSIEM 7.5:

1. Navigate to **Resources → Automation → Remediations**, click **+**.
2. **Name:** `Illumio Quarantine Apply`
3. **Device Type:** the Illumio PCE device (or a generic Linux device registered as the SSH target).
4. **Protocol:** **SSH**
5. **Remediation Script Name:** `illumio_quarantine_apply.sh`
6. **Remediation Script Content:**
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
7. **Description:** "Apply Quarantine:Severe label to Illumio workloads matching the incident source IP."
8. Click **Save**.

Repeat for a release action with a different `--label-value` (e.g. `Released`)
or use `--mode overwrite`.

## Triggering the remediation

Two modes:

**Ad-hoc (operator-driven, recommended for first validation):**
1. `Incidents → List` → select an incident
2. `Actions → Remediate Incident`
3. Select `Illumio Quarantine Apply`, pick the enforcement point (Supervisor or Collector), target device, run.

**Automated (policy-driven):**
1. `Admin → Settings → General → Automation Policy` → create new policy.
2. Match the incident criteria you want to auto-remediate.
3. In the **Action** section, select **Run Remediation/Script**.
4. Pick `Illumio Quarantine Apply` + target device.
5. Save.

Variable expansion at fire time (pending the compatibility note at top):
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
