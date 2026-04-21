#!/bin/bash

# ==============================================================================
# 腳本名稱: update_illumio_workload_labels.sh
# 描述:     根據多種條件 (IP、主機名、CIDR、IP 範圍、前綴) 尋找 Illumio Workloads，
#           並在用戶確認後，以指定模式（增加或覆蓋）為匹配到的 'managed' Workloads
#           添加/設置指定的 Label。
# 作者:     Harry
# 日期:     20250419
# 版本:     1.3.0
#
# 依賴套件:
#   - curl:   用於發送 HTTP API 請求。
#   - jq:     用於解析 JSON 響應。
#   - ipcalc: 用於執行 CIDR 網路計算 (必需)。
#
# 使用方法:
#   ./update_illumio_workload_labels.sh
#   腳本將提示輸入搜索條件、Label ID 及更新模式。
#
# !!! SECURITY NOTES !!!
# PCE API credentials loaded by load_credentials() in this order:
#   CLI flags > env vars > --credentials-file > script defaults.
# Never commit credentials to source control. See config/quarantine.conf.example.
# ==============================================================================

# --- 配置 ---
API_VERSION="v2"                         # 要使用的 Illumio API 版本
CURL_OPTS="-s -k"                        # curl 選項 (-s 靜默, -k 忽略 SSL 校驗)

# Credentials are loaded by load_credentials() after argument parsing.
# Precedence: CLI flags > env vars > --credentials-file > script defaults.
API_USER=""
API_PASS=""
PCE_URL_BASE=""
ORG_ID=""

# --- 輔助函數 ---

# @description 將 IPv4 地址字符串轉換為其 32 位整數表示。
# @param $1 string IPv4 地址字符串 (例如: "192.168.1.1")。
# @return integer 整數表示，如果輸入無效則返回 -1。
ip_to_int() {
    local ip=$1
    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"

    if [[ -z "$o1" || -z "$o2" || -z "$o3" || -z "$o4" ]] || \
       ! [[ "$o1" =~ ^[0-9]+$ && "$o1" -le 255 ]] || \
       ! [[ "$o2" =~ ^[0-9]+$ && "$o2" -le 255 ]] || \
       ! [[ "$o3" =~ ^[0-9]+$ && "$o3" -le 255 ]] || \
       ! [[ "$o4" =~ ^[0-9]+$ && "$o4" -le 255 ]]; then
        echo "-1"; return 1
    fi
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    return 0
}

# @description 檢查給定的 IPv4 地址是否在指定的範圍內 (包含邊界)。
# @param $1 string 要檢查的 IPv4 地址。
# @param $2 string 範圍的起始 IPv4 地址。
# @param $3 string 範圍的結束 IPv4 地址。
# @return integer 如果 IP 在範圍內，退出狀態為 0，否則為 1 (或輸入無效)。
is_in_range() {
    local ip_to_check=$1
    local range_start=$2
    local range_end=$3
    local ip_int check_start_int check_end_int

    ip_int=$(ip_to_int "$ip_to_check")
    check_start_int=$(ip_to_int "$range_start")
    check_end_int=$(ip_to_int "$range_end")

    if [[ "$ip_int" == "-1" || "$check_start_int" == "-1" || "$check_end_int" == "-1" || "$check_start_int" -gt "$check_end_int" ]]; then
        return 1
    fi
    [[ "$ip_int" -ge "$check_start_int" && "$ip_int" -le "$check_end_int" ]]
}

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

# Target label state — resolved by resolve_target_label()
TARGET_LABEL_HREF=""
TARGET_LABEL_KEY=""
TARGET_LABEL_VALUE=""
SAME_KEY_HREFS_JSON="[]"

_urlenc() {
    printf '%s' "$1" | jq -sRr @uri
}

# @description Escape a value per ArcSight CEF (backslash, pipe, equals, CR, LF).
cef_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//|/\\|}"
    s="${s//=/\\=}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# @description Append one CEF:0 audit line to $AUDIT_FILE using flock for
#              concurrent-writer safety. No-op when $AUDIT_FILE is unset/empty.
# @param $1 outcome: success | partial | no_match | failure
emit_cef() {
    [[ -z "${AUDIT_FILE:-}" ]] && return 0
    local outcome="$1"
    [[ -z "${AUDIT_ID:-}" ]] && AUDIT_ID="qr-$(date -u +%Y-%m-%dT%H-%M-%SZ)-early"
    local epoch_ms; epoch_ms=$(date +%s%3N)
    local pce_host; pce_host="${PCE_URL_BASE#https://}"; pce_host="${pce_host%%/*}"; pce_host="${pce_host%%:*}"
    local esc_reason;  esc_reason=$(cef_escape "${REASON:-}")
    local esc_targets; esc_targets=$(cef_escape "${SEARCH_TERMS_RAW:-}")
    local esc_cid;     esc_cid=$(cef_escape "${CORRELATION_ID:-}")
    local esc_key;     esc_key=$(cef_escape "${TARGET_LABEL_KEY:-}")
    local esc_val;     esc_val=$(cef_escape "${TARGET_LABEL_VALUE:-}")
    local dry;         dry=$([[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false)
    local updated_ct="${#J_UPDATED[@]}"
    local failed_ct="${#J_FAILED[@]}"

    local line
    line=$(printf 'CEF:0|Illumio|Quarantine|%s|quarantine.action|Illumio Quarantine Action|5|rt=%s dvchost=%s act=%s outcome=%s cs1Label=correlation_id cs1=%s cs2Label=audit_id cs2=%s cs3Label=reason cs3=%s cs4Label=targets cs4=%s cs5Label=label_key cs5=%s cs6Label=label_value cs6=%s cn1Label=updated_count cn1=%d cn2Label=failed_count cn2=%d cs7Label=dry_run cs7=%s' \
        "$VERSION" "$epoch_ms" "$pce_host" "${UPDATE_MODE:-}" "$outcome" \
        "$esc_cid" "$AUDIT_ID" "$esc_reason" "$esc_targets" \
        "$esc_key" "$esc_val" \
        "$updated_ct" "$failed_ct" "$dry")

    mkdir -p "$(dirname "$AUDIT_FILE")" 2>/dev/null || true
    local lock="${AUDIT_FILE}.lock"
    touch "$lock"
    (
        flock -x 9
        printf '%s\n' "$line" >> "$AUDIT_FILE"
    ) 9>"$lock"
}

resolve_target_label() {
    local base="${PCE_URL_BASE}/api/${API_VERSION}/orgs/${ORG_ID}"
    if [[ -n "$LABEL_ID" ]]; then
        local resp
        resp=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                   -H 'Accept: application/json' \
                   "${base}/labels/${LABEL_ID}")
        if echo "$resp" | jq -e 'type=="object" and (has("error") or has("unauthorized"))' >/dev/null 2>&1; then
            echo "ERROR: PCE authentication failed" >&2; emit_cef "failure"; exit 4
        fi
        if ! echo "$resp" | jq -e 'has("href")' >/dev/null 2>&1; then
            echo "ERROR: label id ${LABEL_ID} not found" >&2
            exit 5
        fi
        TARGET_LABEL_HREF="/orgs/${ORG_ID}/labels/${LABEL_ID}"
        TARGET_LABEL_KEY=$(echo   "$resp" | jq -r '.key')
        TARGET_LABEL_VALUE=$(echo "$resp" | jq -r '.value')
    else
        local resp enc_key
        enc_key=$(_urlenc "$LABEL_KEY")
        resp=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                   -H 'Accept: application/json' \
                   "${base}/labels?key=${enc_key}")
        if echo "$resp" | jq -e 'type=="object" and (has("error") or has("unauthorized"))' >/dev/null 2>&1; then
            echo "ERROR: PCE authentication failed" >&2; emit_cef "failure"; exit 4
        fi
        TARGET_LABEL_HREF=$(echo "$resp" | jq -r --arg v "$LABEL_VALUE" \
            '[.[] | select(.value==$v)][0].href // empty')
        if [[ -z "$TARGET_LABEL_HREF" ]]; then
            echo "ERROR: no label with key=${LABEL_KEY} value=${LABEL_VALUE}" >&2
            exit 5
        fi
        TARGET_LABEL_KEY="$LABEL_KEY"
        TARGET_LABEL_VALUE="$LABEL_VALUE"
    fi

    # Fetch all hrefs sharing TARGET_LABEL_KEY (used by B2 same-key strip)
    local same_resp enc_target_key
    enc_target_key=$(_urlenc "$TARGET_LABEL_KEY")
    same_resp=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                    -H 'Accept: application/json' \
                    "${base}/labels?key=${enc_target_key}")
    SAME_KEY_HREFS_JSON=$(echo "$same_resp" | jq -c '[.[].href]')
}

# @description Build PUT body, check idempotency, issue PUT, and classify outcome.
#              Designed to run as a background job; writes one JSON result file
#              into $result_dir so the main loop can aggregate after `wait`.
# @param $1 workload_href
# @param $2 hostname_display
# @param $3 existing_labels_json
# @param $4 result_dir
put_one_workload() {
    local workload_href="$1"
    local hostname_display="$2"
    local existing_labels_json="$3"
    local result_dir="$4"

    local put_body
    if [[ "$UPDATE_MODE" == "overwrite" ]]; then
        put_body=$(jq -nc --arg h "$TARGET_LABEL_HREF" \
                        '{labels:[{href:$h}]}')
    else
        put_body=$(jq -nc \
            --argjson existing "$existing_labels_json" \
            --argjson same_key "$SAME_KEY_HREFS_JSON" \
            --arg     h        "$TARGET_LABEL_HREF" \
            '{labels: (
                  ($existing | map(select(.href as $x | ($same_key | index($x)) | not)))
                + [{href:$h}]
            )}')
    fi

    local result_path
    result_path="$result_dir/$(echo "$workload_href" | tr / _).json"

    if [[ -z "$put_body" ]]; then
        jq -nc --arg href "$workload_href" --arg hn "$hostname_display" \
               --arg e   "failed to build PUT body" \
            '{kind:"failed",href:$href,hostname:$hn,http:0,error:$e}' > "$result_path"
        return 0
    fi

    # Idempotent skip (append only): identical label set → record "skipped"
    if [[ "$UPDATE_MODE" == "append" ]]; then
        local before after
        before=$(echo "$existing_labels_json" | jq -c 'sort_by(.href)')
        after=$(echo  "$put_body"             | jq -c '.labels | sort_by(.href)')
        if [[ "$before" == "$after" ]]; then
            jq -nc --arg href "$workload_href" --arg hn "$hostname_display" \
                '{kind:"skipped",href:$href,hostname:$hn}' > "$result_path"
            return 0
        fi
    fi

    local http_code curl_ec
    if [[ "$DRY_RUN" == "1" ]]; then
        http_code="000"; curl_ec=0
    else
        http_code=$(curl ${CURL_OPTS} -X PUT \
            -u "${API_USER}:${API_PASS}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$put_body" -o /dev/null -w "%{http_code}" \
            "${PCE_URL_BASE}/api/${API_VERSION}${workload_href}")
        curl_ec=$?
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        jq -nc --arg href "$workload_href" --arg hn "$hostname_display" \
            '{kind:"updated",dry_run:true,href:$href,hostname:$hn}' > "$result_path"
    elif [[ $curl_ec -ne 0 ]]; then
        jq -nc --arg href "$workload_href" --arg hn "$hostname_display" \
               --arg e "curl $curl_ec" \
            '{kind:"failed",href:$href,hostname:$hn,http:0,error:$e}' > "$result_path"
    elif [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
        jq -nc --arg href "$workload_href" --arg hn "$hostname_display" \
               --argjson http "$http_code" \
            '{kind:"updated",dry_run:false,href:$href,hostname:$hn,http:$http}' > "$result_path"
    else
        jq -nc --arg href "$workload_href" --arg hn "$hostname_display" \
               --argjson http "$http_code" \
            '{kind:"failed",href:$href,hostname:$hn,http:$http,error:("PCE returned "+($http|tostring))}' \
            > "$result_path"
    fi
}

# --- 依賴檢查 ---
command -v curl >/dev/null 2>&1 || { echo >&2 "錯誤：必要套件 'curl' 未安裝。請先安裝。"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "錯誤：必要套件 'jq' 未安裝。請先安裝。"; exit 1; }
command -v ipcalc >/dev/null 2>&1 || { echo >&2 "錯誤：必要套件 'ipcalc' 未安裝。請先安裝。"; exit 1; }


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

# --json is structured output; refuse the footgun of mixing with interactive mode
if [[ "$JSON_OUT" == "1" && "$NON_INTERACTIVE" != "1" ]]; then
    echo "ERROR: --json requires --non-interactive" >&2
    exit 5
fi

load_credentials


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

resolve_target_label

if [[ "$JSON_OUT" != "1" ]]; then
    echo "illumio_Quarantine $VERSION"
    echo "label=${TARGET_LABEL_KEY}:${TARGET_LABEL_VALUE} (${TARGET_LABEL_HREF})"
    [[ -n "$CORRELATION_ID" ]] && echo "correlation_id=$CORRELATION_ID"
    [[ -n "$REASON"         ]] && echo "reason=$REASON"
fi

# Run-state accumulators for JSON emission
AUDIT_ID="qr-$(date -u +%Y-%m-%dT%H-%M-%SZ)-$(printf '%04x%02x' $((RANDOM)) $((RANDOM%256)))"
RUN_START_MS=$(date +%s%3N)
declare -a J_REQUESTED=()
declare -a J_MATCHED=()
declare -a J_UPDATED=()
declare -a J_SKIPPED=()
declare -a J_FAILED=()

hlog() { [[ "$JSON_OUT" != "1" ]] && echo "$@"; }


# --- 輸入解析 ---
IFS=',' read -ra SEARCH_TERMS <<< "$SEARCH_TERMS_RAW"
for i in "${!SEARCH_TERMS[@]}"; do
    # 清理每個搜索條件前後的空格
    SEARCH_TERMS[$i]=$(echo "${SEARCH_TERMS[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
done

# Seed J_REQUESTED from SEARCH_TERMS
for t in "${SEARCH_TERMS[@]}"; do
    [[ -z "$t" ]] && continue
    J_REQUESTED+=("$(jq -nc --arg t "$t" '$t')")
done


# --- Step 1: Fetch workloads (server-side per-term if all precise, else one full scan) ---
WORKLOADS_BASE="${PCE_URL_BASE}/api/${API_VERSION}/orgs/${ORG_ID}/workloads"
SEARCH_STRATEGY=""

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
        enc_term=$(_urlenc "$term")
        if [[ "$t" == "ip" ]]; then
            part=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                -H 'Accept: application/json' \
                "${WORKLOADS_BASE}?ip_address=${enc_term}")
        else
            part=$(curl -s -k -u "${API_USER}:${API_PASS}" \
                -H 'Accept: application/json' \
                "${WORKLOADS_BASE}?hostname=${enc_term}")
        fi
        if ! echo "$part" | jq -e 'type=="array"' >/dev/null 2>&1; then
            echo "ERROR: PCE returned non-array for term '${term}'" >&2; exit 4
        fi
        # Merge (dedup by href)
        api_response=$(jq -n --argjson a "$api_response" --argjson b "$part" \
            '$a + $b | unique_by(.href)')
    done
fi

# Auth / JSON validation
if ! echo "$api_response" | jq empty >/dev/null 2>&1; then
    echo "ERROR: PCE response is not valid JSON" >&2; emit_cef "failure"; exit 4
fi
if echo "$api_response" | jq -e 'type=="object" and (has("error") or has("unauthorized"))' >/dev/null 2>&1; then
    echo "ERROR: PCE authentication failed" >&2; emit_cef "failure"; exit 4
fi
if ! echo "$api_response" | jq -e 'type=="array"' >/dev/null; then
    echo "ERROR: PCE response is not a JSON array" >&2; emit_cef "failure"; exit 4
fi


# --- 步驟 2: 過濾 Workloads ---
hlog
hlog "Analyzing matching workloads (managed: true only)..."
declare -A workloads_to_update # 存儲待更新 Workloads (鍵: href, 值: json{hostname, labels})
found_count=0                  # 唯一匹配的 Workload 計數

# --- 外層循環: 遍歷 Workloads ---
while IFS= read -r workload_json; do
    # 驗證讀取的行是否為有效 JSON 對象
    if ! echo "$workload_json" | jq -e 'type == "object"' > /dev/null; then continue; fi

    # 提取 href (必需)
    workload_href=$(echo "$workload_json" | jq -r '.href // empty')
    if [[ -z "$workload_href" ]]; then continue; fi

    # 過濾器: 檢查 managed 狀態
    is_managed=$(echo "$workload_json" | jq -r '.managed // "false"')
    if [[ "$is_managed" != "true" ]]; then continue; fi

    # 提取其他所需信息
    hostname=$(echo "$workload_json" | jq -r '.hostname // "N/A"')
    public_ip=$(echo "$workload_json" | jq -r '.public_ip // empty')
    interfaces_json=$(echo "$workload_json" | jq -c '.interfaces // []')
    labels_json=$(echo "$workload_json" | jq -c '[.labels[]? | {href: .href}] // []')

    match_found_for_this_workload=false

    # --- 內層循環: 遍歷搜索條件 ---
    for term in "${SEARCH_TERMS[@]}"; do
        term_matched_current_workload=false

        # 1. CIDR 匹配
        if [[ "$term" == */* ]]; then
            IFS='/' read -r input_network input_prefix <<< "$term"
            if [[ "$input_prefix" =~ ^[0-9]+$ ]] && [[ $input_prefix -le 32 ]]; then
                 # 檢查 Public IP
                 if [[ -n "$public_ip" && "$public_ip" != "null" ]]; then
                     calculated_network_output=$(ipcalc -n "${public_ip}/${input_prefix}" 2>/dev/null)
                     if [[ $? -eq 0 ]]; then
                         calculated_network=$(echo "$calculated_network_output" | grep -E '^(Network:|NETWORK=)' | head -n 1 | sed -E 's/^(Network:|NETWORK=)[[:space:]]*//; s|/.*||; s/[[:space:]]*$//')
                         if [[ -n "$calculated_network" && "$calculated_network" == "$input_network" ]]; then term_matched_current_workload=true; fi
                     fi
                 fi
                 # 檢查 Interface IPs (僅當 Public IP 不匹配)
                 if ! $term_matched_current_workload && [[ "$interfaces_json" != "[]" ]]; then
                     while IFS= read -r if_addr <&3; do
                         if_addr=$(echo "$if_addr" | jq -r '.')
                         if [[ -n "$if_addr" && "$if_addr" != "null" ]]; then
                            calculated_network_output=$(ipcalc -n "${if_addr}/${input_prefix}" 2>/dev/null)
                            if [[ $? -eq 0 ]]; then
                                calculated_network=$(echo "$calculated_network_output" | grep -E '^(Network:|NETWORK=)' | head -n 1 | sed -E 's/^(Network:|NETWORK=)[[:space:]]*//; s|/.*||; s/[[:space:]]*$//')
                                if [[ -n "$calculated_network" && "$calculated_network" == "$input_network" ]]; then term_matched_current_workload=true; break; fi
                            fi
                         fi
                     done 3< <(echo "$interfaces_json" | jq -c '.[].address') # 使用 FD 3 讀取接口 IP
                 fi
            fi
        # 2. 範圍匹配 (-)
        elif [[ "$term" == *-* ]]; then
            IFS='-' read -r range_start range_end <<< "$term"
            range_start=$(echo "$range_start" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            range_end=$(echo "$range_end" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # 檢查 Public IP
            if [[ -n "$public_ip" && "$public_ip" != "null" ]]; then
                if is_in_range "$public_ip" "$range_start" "$range_end"; then term_matched_current_workload=true; fi
            fi
            # 檢查 Interface IPs
            if ! $term_matched_current_workload && [[ "$interfaces_json" != "[]" ]]; then
                while IFS= read -r if_addr <&3; do
                    if_addr=$(echo "$if_addr" | jq -r '.')
                    if [[ -n "$if_addr" && "$if_addr" != "null" ]]; then
                        if is_in_range "$if_addr" "$range_start" "$range_end"; then term_matched_current_workload=true; break; fi
                    fi
                done 3< <(echo "$interfaces_json" | jq -c '.[].address')
            fi
        # 3. 範圍匹配 (~)
        elif [[ "$term" == *~* ]]; then
             IFS='~' read -r range_start range_end <<< "$term"
             range_start=$(echo "$range_start" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
             range_end=$(echo "$range_end" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
             # 檢查 Public IP
             if [[ -n "$public_ip" && "$public_ip" != "null" ]]; then
                 if is_in_range "$public_ip" "$range_start" "$range_end"; then term_matched_current_workload=true; fi
             fi
             # 檢查 Interface IPs
             if ! $term_matched_current_workload && [[ "$interfaces_json" != "[]" ]]; then
                 while IFS= read -r if_addr <&3; do
                     if_addr=$(echo "$if_addr" | jq -r '.')
                     if [[ -n "$if_addr" && "$if_addr" != "null" ]]; then
                         if is_in_range "$if_addr" "$range_start" "$range_end"; then term_matched_current_workload=true; break; fi
                     fi
                 done 3< <(echo "$interfaces_json" | jq -c '.[].address')
             fi
        # 4. 其他 (主機名 / 精確 IP / 前綴)
        else
            # 檢查主機名
            if [[ "$hostname" == "$term" ]]; then term_matched_current_workload=true; fi
            # 檢查 Public IP
            if ! $term_matched_current_workload && [[ "$public_ip" == "$term" ]]; then term_matched_current_workload=true; fi
            # 檢查 Interface IPs
            if ! $term_matched_current_workload && [[ "$interfaces_json" != "[]" ]]; then
                is_prefix=false
                if [[ "$term" == *. ]]; then is_prefix=true; fi # 判斷是否為前綴
                while IFS= read -r if_addr <&3; do
                    if_addr=$(echo "$if_addr" | jq -r '.')
                    if [[ -n "$if_addr" && "$if_addr" != "null" ]]; then
                        # 精確匹配
                        if [[ "$if_addr" == "$term" ]]; then term_matched_current_workload=true; break; fi
                        # 前綴匹配
                        if $is_prefix && [[ "$if_addr" == "$term"* ]]; then term_matched_current_workload=true; break; fi
                    fi
                done 3< <(echo "$interfaces_json" | jq -c '.[].address')
            fi
        fi # --- 結束條件匹配 ---

        # 如果當前條件匹配成功，跳出內層循環
        if $term_matched_current_workload; then
            match_found_for_this_workload=true
            break
        fi
    done # --- 結束內層循環 ---

    # 如果此 Workload 匹配了任何條件
    if $match_found_for_this_workload; then
        key=$(echo "$workload_href" | tr '/' '_') # 處理 href 作為 key
        value_json=$(jq -nc --arg hn "$hostname" --argjson lbls "$labels_json" '{hostname: $hn, labels: $lbls}')
        # 僅在首次匹配時打印消息和計數
        if [[ -z "${workloads_to_update[$key]}" ]]; then
            hlog "  -> match: ${hostname} (${workload_href})"
            J_MATCHED+=("$(jq -nc --arg h "$workload_href" --arg n "$hostname" \
                                  '{href:$h,hostname:$n}')")
            ((found_count++))
        fi
        workloads_to_update["$key"]="$value_json" # 存儲或更新信息
    fi
done < <(echo "$api_response" | jq -c '.[]') # --- 結束外層循環 ---


# --- 步驟 3: 確認 ---
# 列出將受影響的 Workload 並請求用戶確認

# 檢查是否有匹配的 Workload
if [ ${#workloads_to_update[@]} -eq 0 ]; then
    hlog "No managed workload matched any target." >&2
fi

# 顯示將受影響的 Workload 列表
hlog
hlog "--------------------------------------------------"
hlog "${#workloads_to_update[@]} managed workloads will be affected:"
hlog "--------------------------------------------------"
for key in "${!workloads_to_update[@]}"; do
    workload_href=$(echo "$key" | tr '_' '/')
    stored_data_json="${workloads_to_update[$key]}"
    display_hostname=$(echo "$stored_data_json" | jq -r '.hostname // "N/A"')
    hlog "  - ${display_hostname} (${workload_href})"
done
hlog "--------------------------------------------------"

if [[ "$NON_INTERACTIVE" != "1" && ${#workloads_to_update[@]} -gt 0 ]]; then
    read -e -p "Continue? (type 'yes' to confirm): " CONFIRMATION
    if [[ "${CONFIRMATION,,}" != "yes" ]]; then
        hlog "Cancelled."
        exit 0
    fi
fi

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

hlog "--------------------------------------------------"


# --- 步驟 4: 執行更新 ---
# 遍歷確認要更新的 Workload 並發送 API 請求

hlog "Updating labels (parallel=${PARALLEL})..."
RESULT_DIR=$(mktemp -d "/tmp/iq_results_XXXXXX")
active=0
for key in "${!workloads_to_update[@]}"; do
    workload_href=$(echo "$key" | tr '_' '/')
    stored_data_json="${workloads_to_update[$key]}"
    existing_labels_json=$(echo "$stored_data_json" | jq -c '.labels // []')
    hostname_display=$(echo "$stored_data_json" | jq -r '.hostname // "N/A"')

    put_one_workload "$workload_href" "$hostname_display" \
                     "$existing_labels_json" "$RESULT_DIR" &
    ((active++))
    if [[ $active -ge $PARALLEL ]]; then
        wait -n
        ((active--))
    fi
done
wait

# Aggregate per-workload result files into J_UPDATED / J_SKIPPED / J_FAILED
for f in "$RESULT_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    kind=$(jq -r '.kind' "$f")
    case "$kind" in
        updated)
            entry=$(jq -c 'if .dry_run then {href,hostname,dry_run:true}
                           else {href,hostname} end' "$f")
            J_UPDATED+=("$entry")
            if [[ "$(jq -r '.dry_run // false' "$f")" == "true" ]]; then
                hlog "  -> DRY-RUN success ($(jq -r '.hostname' "$f"))"
            else
                hlog "  -> updated (HTTP $(jq -r '.http' "$f")) $(jq -r '.hostname' "$f")"
            fi
            ;;
        skipped)
            J_SKIPPED+=("$(jq -c '{href,hostname}' "$f")")
            hlog "  -> skipped (already labeled) $(jq -r '.hostname' "$f")"
            ;;
        failed)
            J_FAILED+=("$(jq -c '{href,hostname,http,error}' "$f")")
            echo "ERROR: PUT $(jq -r '.href' "$f") failed ($(jq -r '.error' "$f"))" >&2
            ;;
    esac
done
rm -rf "$RESULT_DIR"

hlog "--------------------------------------------------"

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
case "$ec" in
    0) outcome="success" ;;
    2) outcome="partial" ;;
    3) outcome="no_match" ;;
    *) outcome="failure" ;;
esac
emit_cef "$outcome"
exit "$ec"
