# FortiSIEM — Illumio Quarantine Integration

Wires `update_illumio_workload_labels.sh` v1.3.0 into FortiSIEM 7.5 so that
when an incident fires, the matching Illumio PCE workload is auto-quarantined
by label.

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

---

## 1. Prerequisites on the quarantine host (Linux)

```bash
sudo apt-get install -y curl jq ipcalc util-linux git
git clone <repo> /opt/illumio_Quarantine
cd /opt/illumio_Quarantine
git submodule update --init
```

### Credentials — env vars (recommended)

Put these in `/etc/environment` or a systemd `EnvironmentFile=`:

```bash
ILLUMIO_QUARANTINE_API_USER=api_xxxxxxxxxx
ILLUMIO_QUARANTINE_API_PASS=<PCE API secret>
ILLUMIO_QUARANTINE_PCE_URL=https://pce.lab.local:8443
ILLUMIO_QUARANTINE_ORG_ID=1
ILLUMIO_QUARANTINE_AUDIT_FILE=/var/log/illumio_quarantine.cef
```

This lets the FortiSIEM Remediation Script body stay short (it doesn't need
to repeat these values on every invocation).

### Credentials — conf file (alternative)

```bash
cp config/quarantine.conf.example config/quarantine.conf
chmod 600 config/quarantine.conf
# edit API_USER / API_PASS / PCE_URL_BASE / ORG_ID
```

The script auto-discovers `./config/quarantine.conf`, then
`$HOME/.config/illumio_quarantine/quarantine.conf`, then
`/etc/illumio_quarantine/quarantine.conf`.

### Local smoke

```bash
./update_illumio_workload_labels.sh \
    --targets "<test workload>" --label-key Quarantine --label-value Severe \
    --non-interactive --dry-run --json
```

Must exit 0 (or 3 if the test target is not in PCE) and emit JSON on stdout.

---

## 2. Register the quarantine host in FortiSIEM CMDB

In FortiSIEM 7.5, the Remediation Script executes **on the enforceOn device**
— here, the quarantine host itself. The host must be registered first.

1. Navigate to **CMDB → Devices**, pick an appropriate device group in the
   left pane (e.g. Linux).
2. Click **+** in the main pane to add a new device.
3. In the **Summary** tab:
   - **Name**: `illumio-quarantine` (or your hostname)
   - **Access IP**: the host's reachable IP from the Supervisor/Collector
   - **Vendor**: Linux (or Generic)
   - **Model / Version**: to taste
   - **Device/App Group**: Linux Servers
4. Save.

---

## 3. Create an SSH credential and bind it to the host

1. Navigate to **Admin → Setup → Credentials**.
2. In **Step 1: Enter Credentials** → click **+**:
   - **Name**: `illumio-quarantine-ssh`
   - **Device Type**: Generic or Linux
   - **Access Protocol**: **SSH**
   - **Port**: `22`
   - **Password Config**: Manual (or CyberArk)
   - **User Name**: a low-privilege user on the quarantine host (e.g. `fortisiem-remediator`)
   - **Password**: the user's password
3. **Save.**
4. In **Step 2: Enter IP Range to Credential Associations** → click **+**:
   - **IP/Host Name**: the quarantine host's IP
   - **Credentials**: pick `illumio-quarantine-ssh`
5. **Save.**

> **Note on SSH key auth:** the FortiSIEM UI credential store requires a
> password (or CyberArk). Backend SSH can use keys, but the out-of-the-box
> flow is password-based. For production, use CyberArk or accept a
> password-rotated service account.

### Harden the service account

On the quarantine host, restrict the service account to run only the script:

```bash
# /etc/sudoers.d/illumio-quarantine
fortisiem-remediator ALL=(root) NOPASSWD: /opt/illumio_Quarantine/update_illumio_workload_labels.sh
```

Disable shell access and allow only the specific command (SSH `ForceCommand`
pattern) if paranoid.

---

## 4. Register the Remediation Script

1. Navigate to **Resources → Automation → Remediations**, click **+**.
2. Fill in:
   - **Name**: `Illumio Quarantine Apply`
   - **Device Type**: Linux (or Generic — must match the device from step 2)
   - **Protocol**: **SSH**
   - **Remediation Script Name**: `illumio_quarantine_apply.sh` (label only — the script executed is what you put in Script Content)
   - **Remediation Script Content** (with env vars baked on the host):
     ```bash
     /opt/illumio_Quarantine/update_illumio_workload_labels.sh \
         --targets "${incidentSrcIpAddr}" \
         --label-key Quarantine --label-value Severe \
         --mode append \
         --non-interactive --json \
         --correlation-id "${incidentId}" \
         --reason "${ruleName}"
     ```
     Without env vars baked (explicit paths):
     ```bash
     /opt/illumio_Quarantine/update_illumio_workload_labels.sh \
         --targets "${incidentSrcIpAddr}" \
         --label-key Quarantine --label-value Severe \
         --mode append --non-interactive --json --parallel 4 \
         --correlation-id "${incidentId}" \
         --reason "${ruleName}" \
         --credentials-file /opt/illumio_Quarantine/config/quarantine.conf \
         --audit-file /var/log/illumio_quarantine.cef
     ```
   - **Description**: "Apply Quarantine:Severe label to Illumio workload matching the incident source IP."
3. **Save.**

Repeat for a release action with a different `--label-value` (e.g. `Released`)
or `--mode overwrite`.

---

## 5. Triggering the remediation

### 5a. Ad-hoc (operator-driven — use this first to validate)

1. `Incidents → List` → select an incident.
2. `Actions → Remediate Incident`.
3. Select `Illumio Quarantine Apply`.
4. Pick the enforcement point (Supervisor or Collector).
5. Pick the target device (the quarantine host registered in step 2).
6. Run.

Inspect the CEF line in `/var/log/illumio_quarantine.cef` to verify tokens
expanded correctly. `cs1=<incidentId>`, `cs3=<ruleName>`, `cs4=<srcIpAddr>`.

### 5b. Automation Policy (unattended)

Only wire this after ad-hoc token substitution is verified.

1. Navigate to **Admin → Settings → General → Automation Policy**, click **+**.
2. Fill in:
   - **Severity**: the threshold(s) that should auto-quarantine (e.g. HIGH, CRITICAL)
   - **Rules**: the incident rules that should fire this policy
   - **Time Range**: active window (usually 24/7)
   - **Affected Items**: device scope — which source IPs/devices trigger this
3. **Action → Run Remediation/Script**:
   - **Script**: pick `Illumio Quarantine Apply`
   - **Run On**: Supervisor or a specific Collector
   - **Enforce On**: the quarantine host
4. **Save.**

> **Throttle warning.** FortiSIEM 7.5 Automation Policy does not expose a
> native rate-limit / cooldown / de-dupe for remediation actions. A noisy rule
> can trigger thousands of invocations. Mitigations:
> - Narrow the rule's match criteria so it fires sparingly
> - Add a deduplication window at the rule level (if supported by the rule type)
> - Monitor `cn1` / `cn2` counters in the CEF audit — a sudden spike is your
>   signal to tighten the rule

---

## 6. Audit ingestion (CEF)

Have FortiSIEM's Linux collector agent tail `/var/log/illumio_quarantine.cef`
and forward as CEF. Parser mapping:

```
Vendor=Illumio  Product=Quarantine  Version=1.3.0
EventId=quarantine.action  Severity=5
cs1 → correlationId   cs2 → auditId       cs3 → reason
cs4 → targets         cs5 → labelKey      cs6 → labelValue
cs7 → dryRun          cn1 → updatedCount  cn2 → failedCount
```

With `correlationId ↔ incidentId`, FortiSIEM can auto-close the incident
when the success event arrives.

---

## 7. Exit-code handling

| Code | Meaning | Suggested action |
|---|---|---|
| 0 | all matched, all quarantined | close incident |
| 2 | partial (some failed) | flag for operator; re-fire with same `correlation-id` to retry |
| 3 | no match (target not managed, unmanaged, or not in PCE) | note and close, or escalate |
| 4 | PCE unreachable or auth failure | page on-call; check VPN / PCE health / creds |
| 5 | invalid input (bad flags, unknown label, ambiguous key/value) | check rule template variables |
| 6 | credentials missing | check env vars / conf file / permissions |

---

## 8. Smoke test

SSH to the quarantine host as the service account and run:

```bash
/opt/illumio_Quarantine/update_illumio_workload_labels.sh \
    --targets "<test hostname>" --label-key Quarantine --label-value Severe \
    --mode append --non-interactive --dry-run --json \
    --correlation-id "SMOKE-001" --reason "FortiSIEM smoke test" \
    --audit-file /var/log/illumio_quarantine.cef
```

Verify:
- exit `0` (or `3` for a fake host — both OK)
- JSON on stdout with `dry_run:true`
- CEF line appended with matching `cs1=SMOKE-001`
- FortiSIEM Collector receives the CEF event within a minute
- In the FortiSIEM UI, `Incidents → Incidents View` shows the event (filter by `correlationId=SMOKE-001`)

When dry-run is clean, drop `--dry-run` and re-run to do a real label
application. Verify in the Illumio PCE GUI that the workload gains the
`Quarantine:Severe` label while preserving its existing business labels.
