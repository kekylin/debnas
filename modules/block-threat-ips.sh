#!/bin/bash

# ==================== 常量定义 ====================
CONFIG_DIR="/etc/firewalld/ipthreat"
CONFIG_FILE="${CONFIG_DIR}/ipthreat.conf"
CRON_SCRIPT_PATH="${CONFIG_DIR}/firewalld_ipthreat.sh"
LOG_FILE="/var/log/firewalld_ipthreat.log"
LOG_DIR="/var/log"

DEFAULT_THREAT_LEVEL=50
DEFAULT_UPDATE_CRON="0 0,6,12,18 * * *"
ZONE="drop"
IPSET_NAME_IPV4="ipthreat_block"
IPSET_NAME_IPV6="ipthreat_block_ipv6"
declare -i MAX_RANGE_SIZE=1000
declare -i MAX_IP_LIMIT=65536

get_threat_list_url() {
    local threat_level="${1:-$DEFAULT_THREAT_LEVEL}"
    echo "https://lists.ipthreat.net/file/ipthreat-lists/threat/threat-${threat_level}.txt.gz"
}

# ==================== 日志输出模块 ====================
declare -A COLORS=(
    ["INFO"]=$'\e[0;36m'
    ["SUCCESS"]=$'\e[0;32m'
    ["WARNING"]=$'\e[0;33m'
    ["ERROR"]=$'\e[0;31m'
    ["RESET"]=$'\e[0m'
)

log_message() {
    local level="${1}" message="${2}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color="${COLORS[$level]}"
    local prefix="[${timestamp}] [${level}] "
    
    # 终端输出（带颜色）
    printf "%b%s%b\n" "${color}" "${prefix}${message}" "${COLORS[RESET]}"
    
    # 文件输出（无颜色）
    printf "%s%s\n" "${prefix}" "${message}" >> "${LOG_FILE}" 2>/dev/null || {
        printf "%b[ERROR] 写入日志文件失败：%s%b\n" "${COLORS[ERROR]}" "${LOG_FILE}" "${COLORS[RESET]}"
        return 1
    }
}

# ==================== 临时文件管理 ====================
declare -a TEMP_FILES=()

create_temp_files() {
    TEMP_FILES=()
    TEMP_GZ=$(mktemp /tmp/threat.XXXXXX.gz); TEMP_FILES+=("$TEMP_GZ")
    TEMP_TXT=$(mktemp /tmp/threat.XXXXXX.txt); TEMP_FILES+=("$TEMP_TXT")
    TEMP_IP_LIST_IPV4=$(mktemp /tmp/valid_ips_ipv4.XXXXXX.txt); TEMP_FILES+=("$TEMP_IP_LIST_IPV4")
    TEMP_IP_LIST_IPV6=$(mktemp /tmp/valid_ips_ipv6.XXXXXX.txt); TEMP_FILES+=("$TEMP_IP_LIST_IPV6")
}

cleanup_temp_files() {
    for file in "${TEMP_FILES[@]}"; do
        rm -f "$file"
    done
}

# ==================== 工具函数 ====================
check_ipset_exists() {
    local ipset_name="$1"
    firewall-cmd --permanent --get-ipsets | grep -qw "$ipset_name"
    return $?
}

check_ipset_bound() {
    local ipset_name="$1" zone="$2"
    firewall-cmd --permanent --zone="$zone" --list-sources | grep -qw "ipset:$ipset_name"
    return $?
}

validate_ipv4() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
        [[ $a -le 255 && $b -le 255 && $c -le 255 && $d -le 255 && $a -ge 0 ]]
    else
        return 1
    fi
}

validate_ipv6() {
    local ip=$1
    if [[ $ip =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]] ||
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,7}:$ ]] ||
       [[ $ip =~ ^:([0-9a-fA-F]{1,4}:){1,7}$ ]] ||
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}$ ]] ||
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}$ ]] ||
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}$ ]] ||
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}$ ]] ||
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}$ ]] ||
       [[ $ip =~ ^[0-9a-fA-F]{1,4}:(:[0-9a-fA-F]{1,4}){1,6}$ ]] ||
       [[ $ip =~ ^::([0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4}$ ]] ||
       [[ $ip =~ ^::$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_ip() {
    local ip=$1
    if validate_ipv4 "$ip"; then
        echo "ipv4"
        return 0
    elif validate_ipv6 "$ip"; then
        echo "ipv6"
        return 0
    else
        return 1
    fi
}

validate_cidr_ipv4() {
    local input=$1
    local prefix mask
    if [[ $input =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
        prefix=${BASH_REMATCH[1]}
        mask=${BASH_REMATCH[2]}
        if [[ ! $mask =~ ^[0-9]+$ ]] || [[ $mask -gt 32 ]] || [[ $mask -lt 0 ]]; then
            log_message "WARNING" "无效 IPv4 CIDR 掩码：$input"
            return 1
        fi
        if validate_ipv4 "$prefix"; then
            echo "$prefix $mask"
            return 0
        else
            log_message "WARNING" "无效 IPv4 CIDR 前缀：$input"
            return 1
        fi
    else
        return 1
    fi
}

parse_ip_range() {
    local input=$1 output_file_ipv4=$2 output_file_ipv6=$3
    local start_ip end_ip prefix mask ip_count protocol awk_output result

    [[ -z "$input" ]] && {
        log_message "WARNING" "空输入，跳过处理"
        return 1
    }

    local clean_ip=$(echo "$input" | cut -d'#' -f1 | tr -d '[:space:]')
    [[ -z "$clean_ip" ]] && {
        log_message "WARNING" "无效输入（提取后为空）：$input"
        return 1
    }

    result=$(validate_cidr_ipv4 "$clean_ip")
    if [[ $? -eq 0 ]]; then
        read -r prefix mask <<< "$result"
        ip_count=$((2 ** (32 - mask)))
        if ! [[ "$ip_count" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "计算 CIDR IP 数量失败：$clean_ip"
            return 1
        fi
        if [[ $ip_count -gt $MAX_IP_LIMIT ]]; then
            log_message "WARNING" "IPv4 CIDR 超出上限：$clean_ip（$ip_count 条）"
            return 1
        fi
        echo "$clean_ip" >> "$output_file_ipv4" || {
            log_message "ERROR" "写入 IPv4 CIDR 失败：$clean_ip"
            return 1
        }
        return 0
    fi

    if [[ $clean_ip =~ ^([0-9a-fA-F:]+)/([0-9]{1,3})$ ]]; then
        log_message "WARNING" "不支持 IPv6 CIDR 格式：$clean_ip"
        return 1
    fi

    if [[ $clean_ip =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})-([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$ ]]; then
        start_ip=${BASH_REMATCH[1]}
        end_ip=${BASH_REMATCH[2]}
        if ! validate_ipv4 "$start_ip"; then
            log_message "WARNING" "无效 IPv4 范围起始地址：$start_ip"
            return 1
        fi
        if ! validate_ipv4 "$end_ip"; then
            log_message "WARNING" "无效 IPv4 范围结束地址：$end_ip"
            return 1
        fi
        IFS='.' read -r a b c d <<< "$start_ip"
        start_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
        IFS='.' read -r a b c d <<< "$end_ip"
        end_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
        if [[ $start_num -gt $end_num ]]; then
            log_message "WARNING" "无效 IPv4 范围：$clean_ip（起始地址大于结束地址）"
            return 1
        fi
        ip_count=$((end_num - start_num + 1))
        if ! [[ "$ip_count" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "计算 IP 范围数量失败：$clean_ip"
            return 1
        fi
        if [[ $ip_count -gt $MAX_IP_LIMIT ]]; then
            log_message "WARNING" "IPv4 范围超出上限：$clean_ip（$ip_count 条）"
            return 1
        fi
        if [[ $ip_count -gt $MAX_RANGE_SIZE ]]; then
            log_message "WARNING" "IPv4 范围过大：$clean_ip（建议使用 CIDR）"
            return 1
        fi
        awk_output=$(awk -v start="$start_num" -v end="$end_num" \
            'BEGIN { for (i=start; i<=end; i++) { a=int(i/16777216); b=int((i%16777216)/65536); c=int((i%65536)/256); d=i%256; printf "%d.%d.%d.%d\n", a, b, c, d } }' 2>&1)
        if [[ $? -ne 0 ]]; then
            log_message "ERROR" "解析 IPv4 范围失败：$clean_ip"
            return 1
        fi
        echo "$awk_output" >> "$output_file_ipv4" || {
            log_message "ERROR" "写入 IPv4 范围失败：$clean_ip"
            return 1
        }
        return 0
    elif [[ $clean_ip =~ ^([0-9a-fA-F:]+)-([0-9a-fA-F:]+)$ ]]; then
        start_ip=${BASH_REMATCH[1]}
        end_ip=${BASH_REMATCH[2]}
        if ! validate_ipv6 "$start_ip" || ! validate_ipv6 "$end_ip"; then
            log_message "WARNING" "无效 IPv6 范围：$clean_ip"
            return 1
        fi
        echo "$start_ip" >> "$output_file_ipv6" || {
            log_message "ERROR" "写入 IPv6 范围起始地址失败：$start_ip"
            return 1
        }
        echo "$end_ip" >> "$output_file_ipv6" || {
            log_message "ERROR" "写入 IPv6 范围结束地址失败：$end_ip"
            return 1
        }
        return 0
    fi

    protocol=$(validate_ip "$clean_ip")
    if [[ $? -eq 0 ]]; then
        if [[ $protocol == "ipv4" ]]; then
            echo "$clean_ip" >> "$output_file_ipv4" || {
                log_message "ERROR" "写入 IPv4 地址失败：$clean_ip"
                return 1
            }
        else
            echo "$clean_ip" >> "$output_file_ipv6" || {
                log_message "ERROR" "写入 IPv6 地址失败：$clean_ip"
                return 1
            }
        fi
        return 0
    fi

    log_message "WARNING" "无效输入：$input"
    return 1
}

# ==================== 核心功能 ====================
check_dependencies() {
    local missing=0
    for cmd in firewall-cmd wget gzip awk sed grep sort comm head crontab; do
        if ! command -v "$cmd" &>/dev/null; then
            log_message "ERROR" "缺少依赖命令：$cmd（请安装）"
            missing=1
        fi
    done
    if ! systemctl is-active firewalld &>/dev/null; then
        log_message "ERROR" "Firewalld 服务未运行（请执行 systemctl start firewalld）"
        missing=1
    fi
    if ! systemctl is-active cron &>/dev/null; then
        log_message "ERROR" "Cron 服务未运行（请执行 systemctl start cron）"
        missing=1
    fi
    [[ $missing -eq 1 ]] && exit 1
}

configure_ipset() {
    local need_log_ipv4=0 need_log_ipv6=0

    if ! check_ipset_exists "$IPSET_NAME_IPV4"; then
        need_log_ipv4=1
        if ! firewall-cmd --permanent --new-ipset="$IPSET_NAME_IPV4" --type=hash:ip --option=family=inet --option=maxelem=$MAX_IP_LIMIT &>/dev/null; then
            log_message "ERROR" "配置 IPv4 IPSet 失败（请检查 Firewalld 配置）"
            exit 1
        fi
        RELOAD_NEEDED=1
    fi
    if ! check_ipset_bound "$IPSET_NAME_IPV4" "$ZONE"; then
        need_log_ipv4=1
        if ! firewall-cmd --permanent --zone="$ZONE" --add-source="ipset:$IPSET_NAME_IPV4" &>/dev/null; then
            log_message "ERROR" "配置 IPv4 IPSet 失败"
            exit 1
        fi
        RELOAD_NEEDED=1
    fi
    if [[ $need_log_ipv4 -eq 1 ]]; then
        log_message "INFO" "配置 IPv4 IPSet 于 drop 区域"
    fi

    if ! check_ipset_exists "$IPSET_NAME_IPV6"; then
        need_log_ipv6=1
        if ! firewall-cmd --permanent --new-ipset="$IPSET_NAME_IPV6" --type=hash:ip --option=family=inet6 --option=maxelem=$MAX_IP_LIMIT &>/dev/null; then
            log_message "ERROR" "配置 IPv6 IPSet 失败（请检查 Firewalld 配置）"
            exit 1
        fi
        RELOAD_NEEDED=1
    fi
    if ! check_ipset_bound "$IPSET_NAME_IPV6" "$ZONE"; then
        need_log_ipv6=1
        if ! firewall-cmd --permanent --zone="$ZONE" --add-source="ipset:$IPSET_NAME_IPV6" &>/dev/null; then
            log_message "ERROR" "配置 IPv6 IPSet 失败"
            exit 1
        fi
        RELOAD_NEEDED=1
    fi
    if [[ $need_log_ipv6 -eq 1 ]]; then
        log_message "INFO" "配置 IPv6 IPSet 于 drop 区域"
    fi
}

validate_zone() {
    if ! firewall-cmd --get-zones | grep -qw "$ZONE"; then
        log_message "ERROR" "无效 Firewalld 区域：$ZONE"
        exit 1
    fi
}

reload_firewalld() {
    if [[ $RELOAD_NEEDED -eq 1 ]]; then
        cmd_output=$(firewall-cmd --reload 2>&1)
        if [[ $? -ne 0 ]]; then
            log_message "ERROR" "Firewalld 规则重载失败：$cmd_output"
            return 1
        fi
        RELOAD_NEEDED=0
        log_message "SUCCESS" "Firewalld 规则重载成功"
    fi
}

download_threat_list() {
    # 确保 THREAT_LEVEL 已定义
    local threat_level="${THREAT_LEVEL:-$DEFAULT_THREAT_LEVEL}"
    if ! [[ "$threat_level" =~ ^[0-9]+$ ]] || [[ "$threat_level" -lt 0 || "$threat_level" -gt 100 ]]; then
        log_message "WARNING" "无效威胁等级：$threat_level，使用默认：$DEFAULT_THREAT_LEVEL"
        threat_level=$DEFAULT_THREAT_LEVEL
    fi
    log_message "INFO" "正在下载威胁等级 $threat_level 的 IP 列表"
    if ! wget -q "$(get_threat_list_url "$threat_level")" -O "$TEMP_GZ"; then
        log_message "ERROR" "下载威胁 IP 列表失败（威胁等级：$threat_level）"
        return 1
    fi
    if ! gzip -dc "$TEMP_GZ" > "$TEMP_TXT"; then
        log_message "ERROR" "解压威胁 IP 列表失败"
        rm -f "$TEMP_GZ"
        return 1
    fi
    rm -f "$TEMP_GZ"
    TEMP_FILES=("${TEMP_FILES[@]/$TEMP_GZ}")
    log_message "SUCCESS" "威胁 IP 列表下载完成（威胁等级：$threat_level）"
}

process_ip_list() {
    local input_file="$1" output_file_ipv4="$2" output_file_ipv6="$3" mode="$4"
    local temp_file_ipv4 temp_file_ipv6 existing_ips_file_ipv4 existing_ips_file_ipv6
    local ipv4_count ipv6_count current_ipv4_count current_ipv6_count
    local ipv4_remaining ipv6_remaining ipv4_to_add ipv6_to_add ipv4_skipped ipv6_skipped
    local input_ipv4_count input_ipv6_count total_input_count invalid_count valid_count

    temp_file_ipv4=$(mktemp /tmp/expanded_ips_ipv4.XXXXXX.txt); TEMP_FILES+=("$temp_file_ipv4")
    temp_file_ipv6=$(mktemp /tmp/expanded_ips_ipv6.XXXXXX.txt); TEMP_FILES+=("$temp_file_ipv6")
    existing_ips_file_ipv4=$(mktemp /tmp/existing_ips_ipv4.XXXXXX.txt); TEMP_FILES+=("$existing_ips_file_ipv4")
    existing_ips_file_ipv6=$(mktemp /tmp/existing_ips_ipv6.XXXXXX.txt); TEMP_FILES+=("$existing_ips_file_ipv6")
    : > "$temp_file_ipv4"
    : > "$temp_file_ipv6"

    local temp_input=$(mktemp /tmp/processed_input.XXXXXX.txt); TEMP_FILES+=("$temp_input")
    grep -v '^\s*$pkg: parse error near `\n' "$input_file" | grep -v '^\s*#' > "$temp_input" || {
        log_message "INFO" "IP 列表为空或仅包含注释，无需处理"
        cleanup_temp_files
        return 0
    }

    total_input_count=$(wc -l < "$temp_input")
    if ! [[ "$total_input_count" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "无法计算输入行数：$total_input_count"
        cleanup_temp_files
        return 1
    fi

    log_message "INFO" "正在解析 IP 列表，请稍候..."

    invalid_count=0
    valid_count=0
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if parse_ip_range "$ip" "$temp_file_ipv4" "$temp_file_ipv6"; then
            ((valid_count++))
        else
            ((invalid_count++))
        fi
    done < "$temp_input"

    if [[ $valid_count -gt 0 ]]; then
        log_message "INFO" "解析 IP 列表：$valid_count 条有效，$invalid_count 条无效"
    fi

    if [[ $invalid_count -eq $total_input_count ]]; then
        log_message "INFO" "所有输入 IP ($invalid_count 条) 无效，已跳过"
        cleanup_temp_files
        return 0
    fi

    if [[ ! -s "$temp_file_ipv4" && ! -s "$temp_file_ipv6" ]]; then
        log_message "ERROR" "无有效 IP（请检查输入格式）"
        cleanup_temp_files
        return 1
    fi

    if check_ipset_exists "$IPSET_NAME_IPV4"; then
        firewall-cmd --permanent --ipset="$IPSET_NAME_IPV4" --get-entries | sort > "$existing_ips_file_ipv4" 2>/dev/null
    else
        : > "$existing_ips_file_ipv4"
    fi
    if check_ipset_exists "$IPSET_NAME_IPV6"; then
        firewall-cmd --permanent --ipset="$IPSET_NAME_IPV6" --get-entries | sort > "$existing_ips_file_ipv6" 2>/dev/null
    else
        : > "$existing_ips_file_ipv6"
    fi
    wait

    if ! sort -u "$temp_file_ipv4" > "$output_file_ipv4" 2>/dev/null; then
        log_message "ERROR" "IPv4 IP 去重失败"
        cleanup_temp_files
        return 1
    fi
    if ! sort -u "$temp_file_ipv6" > "$output_file_ipv6" 2>/dev/null; then
        log_message "ERROR" "IPv6 IP 去重失败"
        cleanup_temp_files
        return 1
    fi

    input_ipv4_count=$(wc -l < "$output_file_ipv4")
    input_ipv6_count=$(wc -l < "$output_file_ipv6")
    if ! [[ "$input_ipv4_count" =~ ^[0-9]+$ && "$input_ipv6_count" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "无法计算输入 IP 数量：IPv4=$input_ipv4_count, IPv6=$input_ipv6_count"
        cleanup_temp_files
        return 1
    fi

    local new_output_ipv4=$(mktemp /tmp/new_output_ipv4.XXXXXX.txt); TEMP_FILES+=("$new_output_ipv4")
    local new_output_ipv6=$(mktemp /tmp/new_output_ipv6.XXXXXX.txt); TEMP_FILES+=("$new_output_ipv6")
    if [[ "$mode" == "add" ]]; then
        if ! comm -23 "$output_file_ipv4" "$existing_ips_file_ipv4" > "$new_output_ipv4" 2>/dev/null; then
            log_message "ERROR" "IPv4 IP 比较失败"
            cleanup_temp_files
            return 1
        fi
        if ! comm -23 "$output_file_ipv6" "$existing_ips_file_ipv6" > "$new_output_ipv6" 2>/dev/null; then
            log_message "ERROR" "IPv6 IP 比较失败"
            cleanup_temp_files
            return 1
        fi
    fi

    mv "$new_output_ipv4" "$output_file_ipv4" || {
        log_message "ERROR" "移动 IPv4 输出文件失败：$new_output_ipv4"
        cleanup_temp_files
        return 1
    }
    mv "$new_output_ipv6" "$output_file_ipv6" || {
        log_message "ERROR" "移动 IPv6 输出文件失败：$new_output_ipv6"
        cleanup_temp_files
        return 1
    }

    ipv4_count=$(wc -l < "$output_file_ipv4")
    ipv6_count=$(wc -l < "$output_file_ipv6")
    if ! [[ "$ipv4_count" =~ ^[0-9]+$ && "$ipv6_count" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "无法计算处理后 IP 数量：IPv4=$ipv4_count, IPv6=$ipv6_count"
        cleanup_temp_files
        return 1
    fi

    if check_ipset_exists "$IPSET_NAME_IPV4"; then
        current_ipv4_count=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV4" --get-entries | wc -l)
        if ! [[ "$current_ipv4_count" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "获取 IPv4 IPSet 计数失败：$current_ipv4_count"
            cleanup_temp_files
            return 1
        fi
    else
        current_ipv4_count=0
    fi
    if check_ipset_exists "$IPSET_NAME_IPV6"; then
        current_ipv6_count=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV6" --get-entries | wc -l)
        if ! [[ "$current_ipv6_count" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "获取 IPv6 IPSet 计数失败：$current_ipv6_count"
            cleanup_temp_files
            return 1
        fi
    else
        current_ipv6_count=0
    fi

    if [[ "$mode" == "add" ]]; then
        ipv4_remaining=$((MAX_IP_LIMIT - current_ipv4_count))
        ipv6_remaining=$((MAX_IP_LIMIT - current_ipv6_count))
        if ! [[ "$ipv4_remaining" =~ ^[0-9]+$ && "$ipv6_remaining" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "无法计算剩余 IP 数量：IPv4=$ipv4_remaining, IPv6=$ipv6_remaining"
            cleanup_temp_files
            return 1
        fi
        ipv4_to_add=$ipv4_count
        ipv6_to_add=$ipv6_count
        ipv4_skipped=0
        ipv6_skipped=0

        if [[ $ipv4_to_add -gt $ipv4_remaining ]]; then
            ipv4_skipped=$((ipv4_to_add - ipv4_remaining))
            ipv4_to_add=$ipv4_remaining
            head -n "$ipv4_to_add" "$output_file_ipv4" > "${output_file_ipv4}.tmp" && mv "${output_file_ipv4}.tmp" "$output_file_ipv4"
        fi
        if [[ $ipv6_to_add -gt $ipv6_remaining ]]; then
            ipv6_skipped=$((ipv6_to_add - ipv6_remaining))
            ipv6_to_add=$ipv6_remaining
            head -n "$ipv6_to_add" "$output_file_ipv6" > "${output_file_ipv6}.tmp" && mv "${output_file_ipv6}.tmp" "$output_file_ipv6"
        fi
    fi

    if [[ "$mode" == "add" ]]; then
        if [[ $input_ipv4_count -eq 0 && $input_ipv6_count -eq 0 ]]; then
            log_message "INFO" "无有效 IP 输入"
        elif [[ $ipv4_to_add -eq 0 && $ipv6_to_add -eq 0 ]]; then
            if [[ $input_ipv4_count -gt 0 || $input_ipv6_count -gt 0 ]]; then
                log_message "INFO" "输入 IP 已存在，无需添加"
            fi
        else
            if [[ $ipv4_skipped -gt 0 || $ipv6_skipped -gt 0 ]]; then
                log_message "WARNING" "超出上限 $MAX_IP_LIMIT，跳过 IPv4: $ipv4_skipped 条，IPv6: $ipv6_skipped 条"
            fi
        fi
    fi

    if [[ $ipv4_count -eq 0 && $ipv6_count -eq 0 ]]; then
        log_message "INFO" "无 IP 需要处理"
    else
        # 串行调用，确保日志和计数准确
        apply_ip_changes "$output_file_ipv4" "$IPSET_NAME_IPV4" "ipv4" "$mode"
        apply_ip_changes "$output_file_ipv6" "$IPSET_NAME_IPV6" "ipv6" "$mode"
        if [[ "$mode" == "add" ]]; then
            log_message "SUCCESS" "已添加 IPv4: $ipv4_to_add 条 IPv6: $ipv6_to_add 条"
        fi
    fi

    cleanup_temp_files
}

apply_ip_changes() {
    local ip_file="$1" ipset_name="$2" ip_type="$3" mode="$4"
    local ip_count_before ip_count_after
    local ipset_entries_before ipset_entries_after
    local ipset_max_entries

    if ! check_ipset_exists "$ipset_name"; then
        log_message "ERROR" "IPSet 不存在：$ipset_name"
        return 1
    fi

    # 获取添加前的IPSet条目数
    ipset_entries_before=$(firewall-cmd --permanent --ipset="$ipset_name" --get-entries | wc -l)
    if ! [[ "$ipset_entries_before" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "获取 IPSet 当前条目数失败：$ipset_entries_before"
        return 1
    fi

    if [[ "$mode" == "add" ]]; then
        if ! sort -u "$ip_file" > "$ip_file.tmp" 2>/dev/null; then
            log_message "ERROR" "去重失败：$ip_file"
            return 1
        fi
        mv "$ip_file.tmp" "$ip_file"
        ip_count_before=$(wc -l < "$ip_file")
        if ! [[ "$ip_count_before" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "无法计算输入 IP 数量：$ip_count_before"
            return 1
        fi
        if [[ $ip_count_before -eq 0 ]]; then
            log_message "INFO" "输入文件为空，无需添加"
            return 0
        fi

        if [[ $ip_count_before -gt $MAX_IP_LIMIT ]]; then
            log_message "WARNING" "输入 IP 数量超过 IPSet 上限：$ipset_name（$ip_count_before > $MAX_IP_LIMIT）"
            return 1
        fi

        if ! firewall-cmd --permanent --ipset="$ipset_name" --add-entries-from-file="$ip_file" &>/dev/null; then
            log_message "ERROR" "添加 IP 到 IPSet 失败：$ipset_name"
            return 1
        fi
    elif [[ "$mode" == "remove" ]]; then
        if ! sort -u "$ip_file" > "$ip_file.tmp" 2>/dev/null; then
            log_message "ERROR" "去重失败：$ip_file"
            return 1
        fi
        mv "$ip_file.tmp" "$ip_file"
        ip_count_before=$(wc -l < "$ip_file")
        if ! [[ "$ip_count_before" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "无法计算输入 IP 数量：$ip_count_before"
            return 1
        fi
        if [[ $ip_count_before -eq 0 ]]; then
            log_message "INFO" "输入文件为空，无需移除"
            return 0
        fi

        if ! firewall-cmd --permanent --ipset="$ipset_name" --remove-entries-from-file="$ip_file" &>/dev/null; then
            log_message "ERROR" "从 IPSet 移除 IP 失败：$ipset_name"
            return 1
        fi
    fi
    return 0
}

remove_all_ips() {
    local sources_ipv4 sources_ipv6 drop_xml_file="/etc/firewalld/zones/drop.xml"
    local ipset_bound_ipv4 ipset_bound_ipv6 drop_has_other_configs

    if ! check_ipset_exists "$IPSET_NAME_IPV4" && ! check_ipset_exists "$IPSET_NAME_IPV6"; then
        log_message "INFO" "未配置 IPSet"
        return
    fi

    sources_ipv4=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV4" --get-entries 2>/dev/null)
    sources_ipv6=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV6" --get-entries 2>/dev/null)

    if [[ -z "$sources_ipv4" && -z "$sources_ipv6" ]]; then
        log_message "INFO" "无封禁 IP"
    else
        if [[ -n "$sources_ipv4" ]]; then
            echo "$sources_ipv4" | tr ' ' '\n' > "$TEMP_IP_LIST_IPV4"
            apply_ip_changes "$TEMP_IP_LIST_IPV4" "$IPSET_NAME_IPV4" "ipv4" "remove"
        fi
        if [[ -n "$sources_ipv6" ]]; then
            echo "$sources_ipv6" | tr ' ' '\n' > "$TEMP_IP_LIST_IPV6"
            apply_ip_changes "$TEMP_IP_LIST_IPV6" "$IPSET_NAME_IPV6" "ipv6" "remove"
        fi
    fi

    ipset_bound_ipv4=$(firewall-cmd --permanent --zone=drop --list-sources | grep -w "ipset:$IPSET_NAME_IPV4" || true)
    ipset_bound_ipv6=$(firewall-cmd --permanent --zone=drop --list-sources | grep -w "ipset:$IPSET_NAME_IPV6" || true)

    if [[ -n "$ipset_bound_ipv4" ]]; then
        log_message "INFO" "从 drop 区域解绑 IPv4 IPSet"
        if ! firewall-cmd --permanent --zone=drop --remove-source="ipset:$IPSET_NAME_IPV4" &>/dev/null; then
            log_message "ERROR" "解绑 IPv4 IPSet 失败"
            return 1
        fi
        RELOAD_NEEDED=1
    fi
    if [[ -n "$ipset_bound_ipv6" ]]; then
        log_message "INFO" "从 drop 区域解绑 IPv6 IPSet"
        if ! firewall-cmd --permanent --zone=drop --remove-source="ipset:$IPSET_NAME_IPV6" &>/dev/null; then
            log_message "ERROR" "解绑 IPv6 IPSet 失败"
            return 1
        fi
        RELOAD_NEEDED=1
    fi

    if check_ipset_exists "$IPSET_NAME_IPV4"; then
        log_message "INFO" "删除 IPv4 IPSet：$IPSET_NAME_IPV4"
        if ! firewall-cmd --permanent --delete-ipset="$IPSET_NAME_IPV4" &>/dev/null; then
            log_message "ERROR" "删除 IPv4 IPSet 失败"
            return 1
        fi
        RELOAD_NEEDED=1
    fi
    if check_ipset_exists "$IPSET_NAME_IPV6"; then
        log_message "INFO" "删除 IPv6 IPSet：$IPSET_NAME_IPV6"
        if ! firewall-cmd --permanent --delete-ipset="$IPSET_NAME_IPV6" &>/dev/null; then
            log_message "ERROR" "删除 IPv6 IPSet 失败"
            return 1
        fi
        RELOAD_NEEDED=1
    fi

    drop_has_other_configs=$(firewall-cmd --permanent --zone=drop --list-all | grep -E "services:|ports:|protocols:|masquerade:|forward-ports:|source-ports:|icmp-blocks:|rich rules:" | grep -v "sources: $" || true)
    if [[ -z "$drop_has_other_configs" ]]; then
        if [[ -f "$drop_xml_file" ]]; then
            log_message "INFO" "删除 drop 区域配置文件：$drop_xml_file"
            if ! rm -f "$drop_xml_file"; then
                log_message "ERROR" "删除 drop 区域配置文件失败：$drop_xml_file"
                return 1
            fi
            RELOAD_NEEDED=1
        fi
    fi

    reload_firewalld
    log_message "SUCCESS" "已移除所有封禁 IP"
}

enable_auto_update() {
    local cron_schedule threat_level

    # 提示用户输入威胁等级
    read -p "请输入威胁等级（0-100，留空使用默认：$DEFAULT_THREAT_LEVEL）： " threat_level
    if [[ -z "$threat_level" ]]; then
        threat_level=$DEFAULT_THREAT_LEVEL
    elif ! [[ "$threat_level" =~ ^[0-9]+$ ]] || [[ "$threat_level" -lt 0 ]] || [[ "$threat_level" -gt 100 ]]; then
        log_message "WARNING" "无效威胁等级：$threat_level，使用默认：$DEFAULT_THREAT_LEVEL"
        threat_level=$DEFAULT_THREAT_LEVEL
    fi
    # 设置全局 THREAT_LEVEL 并导出
    THREAT_LEVEL=$threat_level
    export THREAT_LEVEL

    # 提示用户输入 Cron 规则
    echo -e "请输入 Cron 规则（留空使用默认：$DEFAULT_UPDATE_CRON）："
    read cron_schedule
    if [[ -z "$cron_schedule" ]]; then
        cron_schedule=$DEFAULT_UPDATE_CRON
    fi
    # 简单验证 Cron 规则格式 5 个字段 + 命令
    if ! echo "$cron_schedule" | grep -qE '^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+$'; then
        log_message "WARNING" "无效 Cron 规则：$cron_schedule，使用默认：$DEFAULT_UPDATE_CRON"
        cron_schedule=$DEFAULT_UPDATE_CRON
    fi

    # 强制覆盖配置文件
    if ! echo "THREAT_LEVEL=$threat_level" > "$CONFIG_FILE"; then
        log_message "ERROR" "写入配置文件失败：$CONFIG_FILE（请检查权限）"
        exit 1
    fi
    if ! echo "UPDATE_CRON=\"$cron_schedule\"" >> "$CONFIG_FILE"; then
        log_message "ERROR" "写入配置文件失败：$CONFIG_FILE（请检查权限）"
        exit 1
    fi
    chmod 644 "$CONFIG_FILE" 2>/dev/null || {
        log_message "ERROR" "设置配置文件权限失败：$CONFIG_FILE"
        exit 1
    }

    # 强制覆盖脚本文件
    if ! cp -f "$0" "$CRON_SCRIPT_PATH"; then
        log_message "ERROR" "复制脚本失败：$CRON_SCRIPT_PATH（请检查权限）"
        exit 1
    fi
    chmod +x "$CRON_SCRIPT_PATH" 2>/dev/null || {
        log_message "ERROR" "设置脚本执行权限失败：$CRON_SCRIPT_PATH"
        exit 1
    }

    # 移除旧的定时任务并添加新
    local temp_cron=$(mktemp); TEMP_FILES+=("$temp_cron")
    crontab -l > "$temp_cron" 2>/dev/null || true
    sed -i '/# IPThreat Firewalld Update/d' "$temp_cron"
    echo "$cron_schedule /bin/bash $CRON_SCRIPT_PATH --cron # IPThreat Firewalld Update" >> "$temp_cron"
    if ! crontab "$temp_cron"; then
        log_message "ERROR" "设置 crontab 失败（请检查 cron 服务）"
        cleanup_temp_files
        exit 1
    fi
    cleanup_temp_files
    log_message "SUCCESS" "启用自动更新：威胁等级 $threat_level，定时 $cron_schedule"

    # 执行更新
    update_threat_ips
}

disable_auto_update() {
    # 移除定时任务
    local temp_cron=$(mktemp); TEMP_FILES+=("$temp_cron")
    crontab -l > "$temp_cron" 2>/dev/null || true
    sed -i '/# IPThreat Firewalld Update/d' "$temp_cron"
    if ! crontab "$temp_cron"; then
        log_message "ERROR" "移除 crontab 失败（请检查 cron 服务）"
        cleanup_temp_files
        exit 1
    fi
    cleanup_temp_files

    # 清理防火墙配置
    remove_all_ips

    # 删除配置文件和脚本
    if [[ -f "$CONFIG_FILE" ]]; then
        log_message "INFO" "删除配置文件：$CONFIG_FILE"
        if ! rm -f "$CONFIG_FILE"; then
            log_message "ERROR" "删除配置文件失败：$CONFIG_FILE"
            exit 1
        fi
    fi
    if [[ -f "$CRON_SCRIPT_PATH" ]]; then
        log_message "INFO" "删除脚本文件：$CRON_SCRIPT_PATH"
        if ! rm -f "$CRON_SCRIPT_PATH"; then
            log_message "ERROR" "删除脚本文件失败：$CRON_SCRIPT_PATH"
            exit 1
        fi
    fi
    if [[ -d "$CONFIG_DIR" ]]; then
        log_message "INFO" "删除配置目录：$CONFIG_DIR"
        if ! rmdir "$CONFIG_DIR" 2>/dev/null; then
            log_message "WARNING" "配置目录 $CONFIG_DIR 非空或无法删除"
        fi
    fi

    log_message "SUCCESS" "已禁用自动更新并清理所有相关配置"
}

view_cron_jobs() {
    log_message "INFO" "查看当前定时任务..."
    local cron_jobs
    cron_jobs=$(crontab -l 2>/dev/null | grep '# IPThreat Firewalld Update' || true)
    if [[ -z "$cron_jobs" ]]; then
        log_message "INFO" "未设置任何与 IPThreat Firewalld 相关的定时任务"
    else
        echo "$cron_jobs" | while IFS= read -r line; do
            log_message "INFO" "定时任务：$line"
        done
    fi
}

check_ipset_needs_reset() {
    local sources_ipv4 sources_ipv6
    if check_ipset_exists "$IPSET_NAME_IPV4" && check_ipset_bound "$IPSET_NAME_IPV4" "$ZONE"; then
        sources_ipv4=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV4" --get-entries 2>/dev/null)
    fi
    if check_ipset_exists "$IPSET_NAME_IPV6" && check_ipset_bound "$IPSET_NAME_IPV6" "$ZONE"; then
        sources_ipv6=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV6" --get-entries 2>/dev/null)
    fi
    if [[ -n "$sources_ipv4" || -n "$sources_ipv6" ]]; then
        return 0
    fi
    return 1
}

update_threat_ips() {
    # 确保 THREAT_LEVEL 在当前作用域中可用
    local threat_level="${THREAT_LEVEL:-$DEFAULT_THREAT_LEVEL}"
    if ! [[ "$threat_level" =~ ^[0-9]+$ ]] || [[ "$threat_level" -lt 0 || "$threat_level" -gt 100 ]]; then
        log_message "WARNING" "无效威胁等级：$threat_level，使用默认：$DEFAULT_THREAT_LEVEL"
        THREAT_LEVEL=$DEFAULT_THREAT_LEVEL
    else
        THREAT_LEVEL=$threat_level
    fi
    export THREAT_LEVEL

    if check_ipset_needs_reset; then
        remove_all_ips
    else
        log_message "INFO" "IPSet 已存在且为空，跳过移除"
        configure_ipset
    fi
    download_threat_list && filter_and_add_ips
}

filter_and_add_ips() {
    [[ ! -f "$TEMP_TXT" ]] && {
        log_message "ERROR" "IP 列表文件不存在"
        cleanup_temp_files
        return 1
    }
    configure_ipset
    process_ip_list "$TEMP_TXT" "$TEMP_IP_LIST_IPV4" "$TEMP_IP_LIST_IPV6" "add"
    reload_firewalld
}

# ==================== 初始化函数 =================
init_manual() {
    # 初始化日志文件
    if [[ ! -d "$LOG_DIR" ]]; then
        log_message "INFO" "创建日志目录：$LOG_DIR"
        if ! mkdir -p "$LOG_DIR"; then
            log_message "ERROR" "创建日志目录失败：$LOG_DIR"
            exit 1
        fi
        chmod 755 "$LOG_DIR"
    fi
    if [[ ! -f "$LOG_FILE" ]]; then
        log_message "INFO" "创建日志文件：$LOG_FILE"
        if ! touch "$LOG_FILE"; then
            log_message "ERROR" "创日志文件失败：$LOG_FILE"
            exit 1
        fi
        chmod 644 "$LOG_FILE"
    fi
    if [[ ! -w "$LOG_FILE" ]]; then
        log_message "ERROR" "日志文件不可写：$LOG_FILE（请检查权限）"
        exit 1
    fi

    # 创建配置目录
    if [[ ! -d "$CONFIG_DIR" ]]; then
        log_message "INFO" "创建配置目录：$CONFIG_DIR"
        if ! mkdir -p "$CONFIG_DIR"; then
            log_message "ERROR" "创建配置目录失败：$CONFIG_DIR"
            cleanup_temp_files
            exit 1
        fi
        chmod 755 "$CONFIG_DIR"
    fi

    # 设置默认威胁等级
    THREAT_LEVEL=$DEFAULT_THREAT_LEVEL
}

init_cron() {
    # 检查日志文件
    if [[ ! -f "$LOG_FILE" ]]; then
        log_message "ERROR" "日志文件不存在：$LOG_FILE"
        exit 1
    fi
    if [[ ! -w "$LOG_FILE" ]]; then
        log_message "ERROR" "日志文件不可写：$LOG_FILE（请检查权限）"
        exit 1
    fi

    # 加载配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_message "ERROR" "配置文件不存在：$CONFIG_FILE"
        exit 1
    fi
    source <(grep -E '^(THREAT_LEVEL|UPDATE_CRON)=' "$CONFIG_FILE") || {
        log_message "ERROR" "加载配置文件失败：$CONFIG_FILE"
        cleanup_temp_files
        exit 1
    }
    # 验证威胁等级
    if ! [[ "$THREAT_LEVEL" =~ ^[0-9]+$ ]] || [[ "$THREAT_LEVEL" -lt 0 || "$THREAT_LEVEL" -gt 100 ]]; then
        THREAT_LEVEL=$DEFAULT_THREAT_LEVEL
        log_message "WARNING" "配置文件中的威胁等级无效，使用默认值：$THREAT_LEVEL"
    fi
    # 确保 THREAT_LEVEL 是全局变量
    export THREAT_LEVEL
}

# ==================== 菜单函数 =================
show_menu() {
    local ipv4_count=0 ipv6_count=0
    if check_ipset_exists "$IPSET_NAME_IPV4"; then
        ipv4_count=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV4" --get-entries | wc -l)
        [[ ! "$ipv4_count" =~ ^[0-9]+$ ]] && ipv4_count=0
    fi
    if check_ipset_exists "$IPSET_NAME_IPV6"; then
        ipv6_count=$(firewall-cmd --permanent --ipset="$IPSET_NAME_IPV6" --get-entries | wc -l)
        [[ ! "$ipv6_count" =~ ^[0-9]+$ ]] && ipv6_count=0
    fi

    local threat_level=$DEFAULT_THREAT_LEVEL
    if [[ -f "$CONFIG_FILE" ]]; then
        source <(grep -E '^THREAT_LEVEL=' "$CONFIG_FILE") 2>/dev/null
        if [[ "$THREAT_LEVEL" =~ ^[0-9]+$ ]] && [[ "$THREAT_LEVEL" -ge 0 ]] && [[ "$THREAT_LEVEL" -le 100 ]]; then
            threat_level=$THREAT_LEVEL
        else
            log_message "WARNING" "配置文件中的威胁等级无效，使用默认值：$DEFAULT_THREAT_LEVEL"
        fi
    fi

    echo "Firewalld IP 封禁管理"
    echo "工作区域: $ZONE"
    echo "威胁等级: $threat_level"
    echo "IP 使用： IPv4 $ipv4_count/$MAX_IP_LIMIT IPv6 $ipv6_count/$MAX_IP_LIMIT"
    echo "---------------------"
    echo "1. 启用自动更新"
    echo "2. 禁用自动更新"
    echo "3. 查看定时任务"
    echo "0. 退出"
    echo "---------------------"
    read -p "请选择操作: " choice
    case "$choice" in
        1)
            check_dependencies
            validate_zone
            init_manual
            create_temp_files
            trap 'cleanup_temp_files; log_message "ERROR" "脚本中断，已清理临时文件"; exit 1' INT TERM
            enable_auto_update
            cleanup_temp_files
            ;;
        2)
            create_temp_files
            trap 'cleanup_temp_files; log_message "ERROR" "脚本中断，已清理临时文件"; exit 1' INT TERM
            disable_auto_update
            cleanup_temp_files
            ;;
        3)
            view_cron_jobs
            ;;
        0)
            exit 0
            ;;
        *)
            log_message "WARNING" "无效选项：$choice"
            ;;
    esac
}

# ==================== 主函数 ===================
main() {
    local mode="manual"
    if [ "$1" == "--cron" ]; then
        mode="cron"
    fi

    create_temp_files
    trap 'cleanup_temp_files; log_message "ERROR" "脚本中断，已清理临时文件"; exit 1' INT TERM
    RELOAD_NEEDED=0

    if ! [[ "$MAX_IP_LIMIT" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "无效 MAX_IP_LIMIT：$MAX_IP_LIMIT"
        cleanup_temp_files
        exit 1
    fi

    if [ "$mode" == "manual" ]; then
        while true; do
            show_menu
        done
    else
        init_cron
        check_dependencies
        validate_zone
        update_threat_ips
        cleanup_temp_files
    fi
}

main "$@"
