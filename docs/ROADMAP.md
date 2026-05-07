# illumio_Quarantine Roadmap

## v1.3.1 — bash, FortiSIEM-ready (this release)

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

### Security hardening (post-initial 1.3.1)

- Curl credentials moved off command line via `-K` config file (no `/proc/*/cmdline` exposure)
- CEF extension values: spaces escaped to prevent audit log forgery
- Audit file and lock refuse symbolic links (atomic creation + stat)
- Credentials auto-discovery no longer searches CWD-relative `~/.illumio_quarantine`
- Exit code 4 (auth failure) when all workload PUTs fail with 401/403 (was exit 2)
- Documentation and version strings sync to 1.3.1 across README, FortiSIEM Integration guide, and CEF parser map

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

---

---

# 中文說明 / Chinese

> **預設語言為英文。以下為繁體中文翻譯。**
> Default language is English. The section below is a Traditional Chinese translation.

---

# illumio_Quarantine 發展藍圖

## v1.3.1 — bash，支援 FortiSIEM（本次發布）

範圍：
- 非互動式 CLI：`--non-interactive`、`--json`、`--dry-run`
- 透過 `--label-id` 或 `--label-key`/`--label-value` 解析目標標籤
- Append-mode 在新增前移除現有同鍵值（same-key）的標籤（B2）
- 當所有條件精確時，於伺服器端進行 per-term workload 查詢；有 CIDR/range/prefix 時進行一次完整掃描
- `--parallel N` PUT pool（1..20）
- `--correlation-id` 往返傳遞；`--reason` 稽核
- flock 鎖定下的 CEF 稽核紀錄行
- 退出碼 0/2/3/4/5/6
- bats-core 測試套件
- 外部化憑證（CLI > env > file > default）

### 安全強化（1.3.1 後期）

- Curl 憑證透過 `-K` 設定檔移出命令列（不會暴露於 `/proc/*/cmdline`）
- CEF 擴展值：空格轉義以防止稽核日誌偽造
- 稽核檔案及鎖檔拒絕符號連結（原子建立 + stat）
- 憑證自動探測不再搜尋 CWD 相對路徑 `~/.illumio_quarantine`
- 當所有工作負載 PUT 請求都以 401/403 失敗時，返回退出碼 4（認證失敗）（原為退出碼 2）
- 文件與版本字符串在 README、FortiSIEM 整合指南及 CEF 解析器對應表中同步為 1.3.1

## v2.0.0 — Python，共存運行（計畫中）

狀態：尚未開始。v1 仍為正式生產版本。

目標：
1. HTTP webhook `POST /webhook/v1/quarantine/apply`（bearer-token）。
   解鎖無需 SSH 的 Splunk SOAR / QRadar SOAR 整合。
2. 直接 SIEM 發送器：syslog UDP/TCP/TLS + Splunk HEC。
3. 多目的地 SIEM（`config.siem.destinations[]`）。
4. 透過 pip 安裝的 `illumio-quarantine` console script。
5. systemd 服務範本。
6. `quarantine/release` 反向端點。

v2 非目標：
- 取代 bash v1——兩者將並存發布。
- GUI（委派給 `illumio_ops`）。

可能的佈局（獨立於 `illumio_ops`）：
```
illumio_quarantine/
├── cli.py  pce_client.py  workload_filter.py  audit.py
│   config.py  webhook.py  server.py
│   siem/{cef.py,json_line.py,transports.py}
└── tests/
```

## v2.1（暫定）

- Per-token 速率限制
- N 分鐘後自動釋放，除非被保留
- Multi-org PCE 路由

## 非計畫

- 取代 Illumio PCE
- Policy authoring（請見 `illumio_ops`）
