#!/bin/bash

# ==============================================================================
# 腳本名稱: update_illumio_workload_labels.sh
# 描述:     根據多種條件 (IP、主機名、CIDR、IP 範圍、前綴) 尋找 Illumio Workloads，
#           並在用戶確認後，以指定模式（增加或覆蓋）為匹配到的 'managed' Workloads
#           添加/設置指定的 Label。
# 作者:     Harry
# 日期:     20250419
# 版本:     1.2.1 
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
# !!! 安全警告 !!!
# 此腳本包含硬編碼的 API 憑證 (API_USER, API_PASS)。
# 這是一個重大的安全風險。任何擁有此文件讀取權限的人都可以獲取這些憑證。
# 請考慮使用更安全的方法，例如環境變量、憑證管理工具 (如 Vault)，
# 或每次安全地提示輸入密碼，而不是硬編碼。
# 請確保文件權限設置嚴格 (例如：chmod 700)。
# ==============================================================================

# --- 配置 ---
PCE_URL_BASE="https://pce.lab.local:8443" # Illumio PCE API 的基礎 URL
ORG_ID="1"                               # 您的 Illumio Organization ID
API_VERSION="v2"                         # 要使用的 Illumio API 版本
CURL_OPTS="-s -k"                        # curl 選項 (-s 靜默, -k 忽略 SSL 校驗)

# --- 硬編碼憑證 (高安全風險!) ---
API_USER="你的API用戶名"               # API Key 用戶名
API_PASS='你的API密碼'                 # API Key 密鑰
# ------------------------------------

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

# --- 依賴檢查 ---
echo "正在檢查必要套件..."
command -v curl >/dev/null 2>&1 || { echo >&2 "錯誤：必要套件 'curl' 未安裝。請先安裝。"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "錯誤：必要套件 'jq' 未安裝。請先安裝。"; exit 1; }
command -v ipcalc >/dev/null 2>&1 || { echo >&2 "錯誤：必要套件 'ipcalc' 未安裝。請先安裝。"; exit 1; }
echo "所有必要套件已找到。"


# --- 用戶輸入 ---
echo
echo "請輸入要搜索的條件，可接受的格式範例如下："
echo "  - 單一 IP:      192.168.1.10"
echo "  - 主機名:       server.example.com"
echo "  - CIDR 網段:    10.0.0.0/24"
echo "  - IP 範圍:      172.16.10.5-172.16.10.20  或  172.16.10.5~172.16.10.20"
echo "  - IP 前綴:      192.168.1. (匹配 192.168.1.*)"
echo "  - 多個條件組合 (逗號分隔): 192.168.1.10,server.example.com,10.0.0.0/24,172.16.10.5-172.16.10.20"

read -e -p "請輸入搜索條件: " SEARCH_TERMS_RAW
read -e -p "請輸入要添加/設置的新 Label 的數字 ID (例如 878): " NEW_LABEL_ID


# --- 輸入驗證 ---
if [[ -z "$SEARCH_TERMS_RAW" ]]; then
    echo "錯誤：搜索條件不能為空。" >&2
    exit 1
fi
if ! [[ "$NEW_LABEL_ID" =~ ^[0-9]+$ ]]; then
    echo "錯誤：Label ID 必須是數字。" >&2
    exit 1
fi


# --- 輸入解析 ---
IFS=',' read -ra SEARCH_TERMS <<< "$SEARCH_TERMS_RAW"
for i in "${!SEARCH_TERMS[@]}"; do
    # 清理每個搜索條件前後的空格
    SEARCH_TERMS[$i]=$(echo "${SEARCH_TERMS[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
done


# --- 準備 API URL 和數據 ---
NEW_LABEL_HREF="/orgs/${ORG_ID}/labels/${NEW_LABEL_ID}"
echo "目標 Label Href: ${NEW_LABEL_HREF}"
WORKLOADS_URL="${PCE_URL_BASE}/api/${API_VERSION}/orgs/${ORG_ID}/workloads"


# --- 步驟 1: 獲取所有 Workloads ---
echo
echo "正在從 ${WORKLOADS_URL} 獲取 Workloads..."
api_response=$(curl ${CURL_OPTS} \
    -u "${API_USER}:${API_PASS}" \
    -H "Accept: application/json" \
    "${WORKLOADS_URL}")

# API 響應驗證
if [ $? -ne 0 ] || ! echo "$api_response" | jq empty > /dev/null 2>&1; then
    echo "錯誤：無法從 ${WORKLOADS_URL} 獲取 Workloads 或響應不是有效的 JSON。" >&2
    exit 1
fi
if ! echo "$api_response" | jq -e 'type == "array"' > /dev/null; then
    echo "錯誤：API 返回的不是預期的 JSON 數組。" >&2
    exit 1
fi

workload_count=$(echo "$api_response" | jq 'length')
echo "成功獲取 ${workload_count} 個 Workloads。"


# --- 步驟 2: 過濾 Workloads ---
echo
echo "正在分析匹配的 Workloads (僅限 managed: true)..."
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
            echo "  -> 找到匹配: ${hostname} (${workload_href})"
            ((found_count++))
        fi
        workloads_to_update["$key"]="$value_json" # 存儲或更新信息
    fi
done < <(echo "$api_response" | jq -c '.[]') # --- 結束外層循環 ---


# --- 步驟 3: 確認 ---
# 列出將受影響的 Workload 並請求用戶確認

# 檢查是否有匹配的 Workload
if [ ${#workloads_to_update[@]} -eq 0 ]; then
    echo
    echo "分析完成：找不到匹配任何搜索條件的 managed Workload。" >&2
    exit 0
fi

# 顯示將受影響的 Workload 列表
echo
echo "--------------------------------------------------"
echo "分析完成：以下 ${#workloads_to_update[@]} 個 managed Workloads 將受影響:"
echo "--------------------------------------------------"
for key in "${!workloads_to_update[@]}"; do
    workload_href=$(echo "$key" | tr '_' '/')
    stored_data_json="${workloads_to_update[$key]}"
    display_hostname=$(echo "$stored_data_json" | jq -r '.hostname // "N/A"')
    echo "  - ${display_hostname} (${workload_href})"
done
echo "--------------------------------------------------"

# 請求執行確認
read -e -p "是否要繼續？ (請輸入 'yes' 確認，其他任意鍵取消): " CONFIRMATION
if [[ "${CONFIRMATION,,}" != "yes" ]]; then
    echo "操作已取消。"
    exit 0
fi

# 請求更新模式確認
echo
echo "請選擇 Label 更新模式："
echo "  1) 增加 (保留現有標籤，並添加新的 Label: ${NEW_LABEL_HREF})"
echo "  2) 覆蓋 (移除所有現有標籤，僅設置新的 Label: ${NEW_LABEL_HREF})"
read -e -p "請輸入模式 (1 或 2): " UPDATE_MODE_CHOICE

UPDATE_MODE=""
if [[ "$UPDATE_MODE_CHOICE" == "1" ]]; then
    UPDATE_MODE="append"
    echo "已選擇 [增加] 模式。"
elif [[ "$UPDATE_MODE_CHOICE" == "2" ]]; then
    UPDATE_MODE="overwrite"
    echo "已選擇 [覆蓋] 模式。"
else
    echo "無效的選擇。操作已取消。" >&2
    exit 1
fi

echo "確認執行更新..."
echo "--------------------------------------------------"


# --- 步驟 4: 執行更新 ---
# 遍歷確認要更新的 Workload 並發送 API 請求

echo "開始更新 Labels..."
for key in "${!workloads_to_update[@]}"; do
    # 恢復 href 並提取存儲的信息
    workload_href=$(echo "$key" | tr '_' '/')
    stored_data_json="${workloads_to_update[$key]}"
    existing_labels_json=$(echo "$stored_data_json" | jq -c '.labels // []')
    hostname_display=$(echo "$stored_data_json" | jq -r '.hostname // "N/A"')

    # 檢查標籤是否已存在
    label_exists=$(echo "$existing_labels_json" | jq --arg new_href "$NEW_LABEL_HREF" 'map(select(.href == $new_href)) | length > 0')

    # 僅在 "增加" 模式下，如果標籤已存在則跳過
    if [[ "$UPDATE_MODE" == "append" && "$label_exists" == "true" ]]; then
        echo "Workload '${hostname_display}' (${workload_href}) 在 [增加] 模式下已包含 Label '${NEW_LABEL_HREF}'，跳過更新。"
        continue
    fi

    # 根據選擇的模式構造 PUT 請求體
    put_body=""
    if [[ "$UPDATE_MODE" == "overwrite" ]]; then
        # 覆蓋模式：僅包含新標籤
        put_body=$(jq -n --arg new_href "$NEW_LABEL_HREF" \
                       '{labels: [{href: $new_href}]}')
    else
        # 增加模式：合併現有標籤和新標籤
        put_body=$(jq -n --argjson existing "$existing_labels_json" \
                       --arg new_href "$NEW_LABEL_HREF" \
                       '{labels: ($existing + [{href: $new_href}])}')
    fi

    # 驗證請求體是否成功生成
    if [ $? -ne 0 ] || [[ -z "$put_body" ]]; then
         echo "錯誤：為 ${workload_href} 構造 PUT Body 失敗。" >&2
         continue
    fi

    # 發送 PUT 請求
    update_url="${PCE_URL_BASE}/api/${API_VERSION}${workload_href}"
    echo "正在更新 Workload '${hostname_display}' (${workload_href}) 使用 [${UPDATE_MODE}] 模式..."

    http_code=$(curl ${CURL_OPTS} -X PUT \
        -u "${API_USER}:${API_PASS}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$put_body" \
        -o /dev/null \
        -w "%{http_code}" \
        "${update_url}")
    curl_exit_code=$?

    # 處理請求結果
    if [ $curl_exit_code -ne 0 ]; then
        echo "錯誤：更新 Workload '${hostname_display}' (${workload_href}) 失敗 (curl 命令錯誤碼: ${curl_exit_code})。" >&2
    elif [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
        echo "  -> 成功更新 Labels (HTTP: ${http_code})"
    else
        echo "錯誤：更新 Workload '${hostname_display}' (${workload_href}) 失敗 (HTTP 狀態碼: ${http_code})。" >&2
    fi
done

echo "--------------------------------------------------"
echo "腳本執行完畢。"
