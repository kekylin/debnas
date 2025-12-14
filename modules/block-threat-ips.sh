#!/bin/bash
# Firewalld-IPThreat 自动化威胁情报更新系统

set -euo pipefail
IFS=$'\n\t'

# 设置标准 PATH：cron 环境 PATH 可能不完整，需显式设置标准系统路径
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ==================== 运行模式检测 ====================
declare RUN_MODE="manual"
if [[ "${1:-}" == "--cron" ]]; then
    RUN_MODE="cron"
fi

# ==================== 日志模块加载 ====================
if [[ "$RUN_MODE" == "manual" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -f "${SCRIPT_DIR}/lib/core/logging.sh" ]]; then
        # shellcheck source=lib/core/logging.sh
        source "${SCRIPT_DIR}/lib/core/logging.sh"
    else
        echo "错误：无法加载日志模块 ${SCRIPT_DIR}/lib/core/logging.sh" >&2
        exit 1
    fi
    if [[ -f "${SCRIPT_DIR}/lib/system/dependency.sh" ]]; then
        # shellcheck source=lib/system/dependency.sh
        source "${SCRIPT_DIR}/lib/system/dependency.sh"
    else
        echo "错误：无法加载依赖检查模块 ${SCRIPT_DIR}/lib/system/dependency.sh" >&2
        exit 1
    fi
    if [[ -f "${SCRIPT_DIR}/lib/core/constants.sh" ]]; then
        # shellcheck source=lib/core/constants.sh
        source "${SCRIPT_DIR}/lib/core/constants.sh"
    else
        echo "错误：无法加载常量模块 ${SCRIPT_DIR}/lib/core/constants.sh" >&2
        exit 1
    fi
else
    # 定时任务模式：最小化日志函数，无颜色输出，格式与交互模式一致
    get_timestamp() {
        if [[ "${LOG_TIMESTAMP:-1}" -eq 1 ]]; then
            date '+%Y-%m-%d %H:%M:%S'
        else
            echo ""
        fi
    }
    log_status() {
        local status="$1" message="$2"
        local ts
        ts=$(get_timestamp)
        if [[ -n "$ts" ]]; then
            printf "[%s] %s %s\n" "$status" "$ts" "$message" >&2
        else
            printf "[%s] %s\n" "$status" "$message" >&2
        fi
    }
    log_success() { log_status "SUCCESS" "$1"; }
    log_warning() { log_status "WARNING" "$1"; }
    log_info()    { log_status "INFO" "$1"; }
    log_error()   { log_status "FAIL" "$1"; }
    log_fatal()   { log_status "FAIL" "$1"; }
fi

# ==================== 常量定义 ====================
REQUIRED_CMDS=(firewall-cmd ipset wget gzip awk sed grep sort comm head crontab sipcalc)

DATA_DIR="/var/lib/firewalld-ipthreat"
LOG_DIR="/var/log"
TEMP_DIR="/tmp/debian-homenas"
CONFIG_FILE="${DATA_DIR}/ipthreat.conf"
CRON_SCRIPT_PATH="${DATA_DIR}/firewalld_ipthreat.sh"
LOG_FILE="/var/log/firewalld-ipthreat.log"

DEFAULT_THREAT_LEVEL=50
DEFAULT_UPDATE_CRON="0 0 * * *"
ZONE="drop"
IPSET_NAME_IPV4="ipthreat_block_ipv4"
IPSET_NAME_IPV6="ipthreat_block_ipv6"

# hash:net 类型支持 CIDR，MAX_IP_LIMIT 表示 CIDR 条目数限制（非单个 IP 数量）
declare -i MAX_IP_LIMIT=65536
# IP 范围格式限制：威胁情报列表主要使用 CIDR，IP 范围格式较少且通常较小，保留此限制用于兼容性
declare -i MAX_RANGE_SIZE=256

get_threat_list_url() {
    local threat_level="${1:-$DEFAULT_THREAT_LEVEL}"
    echo "https://lists.ipthreat.net/file/ipthreat-lists/threat/threat-${threat_level}.txt.gz"
}

# ==================== 日志输出模块 ====================
# 统一日志输出函数：同时输出到终端和日志文件
# 参数：level - 日志级别（SUCCESS/INFO/WARNING/ERROR/FATAL），message - 日志消息
log_message() {
    local level="${1}" message="${2}"
    local timestamp prefix
    
    case "$level" in
        "SUCCESS") log_success "$message" ;;
        "INFO")    log_info "$message" ;;
        "WARNING") log_warning "$message" ;;
        "ERROR")   log_error "$message" ;;
        "FATAL")   log_fatal "$message" ;;
        *)         log_info "$message" ;;
    esac
    
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    prefix="[${timestamp}] [${level}] "
    printf "%s%s\n" "${prefix}" "${message}" >> "${LOG_FILE}" 2>/dev/null || {
        log_error "写入日志文件失败：${LOG_FILE}"
        return 1
    }
}

# ==================== 临时文件管理 ====================
declare -a TEMP_FILES=()
declare -i NORMAL_EXIT=0
TEMP_GZ=""
TEMP_TXT=""
TEMP_IP_LIST_IPV4=""
TEMP_IP_LIST_IPV6=""

init_temp_dir() {
    if [[ ! -d "$TEMP_DIR" ]]; then
        mkdir -p "$TEMP_DIR" || {
            log_error "创建临时目录失败：${TEMP_DIR}"
            exit 1
        }
        chmod 700 "$TEMP_DIR" || {
            log_error "设置临时目录权限失败：${TEMP_DIR}"
            exit 1
        }
    fi
}

# 创建临时文件并返回路径
# 参数：prefix - 文件名前缀，suffix - 文件扩展名（默认 .txt）
# 返回：临时文件路径
create_temp_file() {
    local prefix="$1" suffix="${2:-.txt}"
    local temp_file
    init_temp_dir
    temp_file=$(mktemp "${TEMP_DIR}/${prefix}.XXXXXX${suffix}")
    TEMP_FILES+=("$temp_file")
    echo "$temp_file"
}

create_temp_files() {
    init_temp_dir
    TEMP_FILES=()
    TEMP_GZ=$(create_temp_file "threat" ".gz")
    TEMP_TXT=$(create_temp_file "threat" ".txt")
    TEMP_IP_LIST_IPV4=$(create_temp_file "valid_ips_ipv4" ".txt")
    TEMP_IP_LIST_IPV6=$(create_temp_file "valid_ips_ipv6" ".txt")
}

cleanup_temp_files() {
    for file in "${TEMP_FILES[@]}"; do
        rm -f "$file" 2>/dev/null || true
    done
    TEMP_FILES=()
    if [[ -d "$TEMP_DIR" ]] && [[ -z "$(ls -A "$TEMP_DIR" 2>/dev/null)" ]]; then
        rmdir "$TEMP_DIR" 2>/dev/null || true
    fi
}

# 退出清理函数：区分正常退出和异常退出
cleanup_on_exit() {
    cleanup_temp_files
    if [[ $NORMAL_EXIT -eq 0 ]]; then
        log_message "ERROR" "脚本中断，已清理临时文件"
    fi
}

# ==================== 工具函数 ====================
# 安全读取用户输入：使用临时文件传递返回值，避免 set +e/set -e 混用
# 参数：prompt - 提示信息，default_value - 默认值
# 返回：用户输入或默认值，退出码 0 表示成功，1 表示失败
safe_read() {
    local prompt="$1" default_value="${2:-}"
    local input="" read_status=0 temp_file
    
    init_temp_dir
    temp_file=$(mktemp "${TEMP_DIR}/safe_read.XXXXXX" 2>/dev/null || echo "/tmp/safe_read_$$")
    TEMP_FILES+=("$temp_file")
    
    if [[ -n "$prompt" ]]; then
        printf "%s" "$prompt" >&2
    fi
    
    (
        read -r input || true
        read_status=$?
        printf "%s|%s\n" "$read_status" "${input:-}" > "$temp_file" 2>/dev/null || true
        exit 0
    ) || true
    
    if [[ -f "$temp_file" ]] && IFS='|' read -r read_status input < "$temp_file" 2>/dev/null; then
        rm -f "$temp_file" 2>/dev/null || true
        local new_files=()
        for f in "${TEMP_FILES[@]}"; do
            [[ "$f" != "$temp_file" ]] && new_files+=("$f")
        done
        TEMP_FILES=("${new_files[@]}")
        
        if ! [[ "$read_status" =~ ^[0-9]+$ ]]; then
            echo "$default_value"
            return 1
        fi
        
        if [[ $read_status -ne 0 ]]; then
            echo "$default_value"
            return 1
        fi
        echo "${input:-$default_value}"
        return 0
    else
        rm -f "$temp_file" 2>/dev/null || true
        local new_files=()
        for f in "${TEMP_FILES[@]}"; do
            [[ "$f" != "$temp_file" ]] && new_files+=("$f")
        done
        TEMP_FILES=("${new_files[@]}")
        echo "$default_value"
        return 1
    fi
}

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

# 使用 sipcalc 验证 IPv4 地址（支持 CIDR 格式）
# 参数：ip - IP 地址或 CIDR
# 返回：0 表示有效，1 表示无效
validate_ipv4() {
    local ip=$1 sipcalc_output
    if sipcalc_output=$(sipcalc "$ip" 2>/dev/null); then
        if echo "$sipcalc_output" | grep -qiE "(ipv4|ipv4addr)"; then
            return 0
        fi
    fi
    return 1
}

# 使用 sipcalc 验证 IPv6 地址（支持 CIDR 格式）
# 参数：ip - IP 地址或 CIDR
# 返回：0 表示有效，1 表示无效
validate_ipv6() {
    local ip=$1 sipcalc_output
    if sipcalc_output=$(sipcalc "$ip" 2>/dev/null); then
        if echo "$sipcalc_output" | grep -qiE "(ipv6|ipv6addr)"; then
            return 0
        fi
    fi
    return 1
}

# 使用 sipcalc 验证 IP 地址并返回类型
# 参数：ip - IP 地址或 CIDR
# 返回：输出 "ipv4" 或 "ipv6"，退出码 0 表示有效，1 表示无效
validate_ip() {
    local ip=$1 sipcalc_output
    if sipcalc_output=$(sipcalc "$ip" 2>/dev/null); then
        if echo "$sipcalc_output" | grep -qiE "(ipv4|ipv4addr)"; then
            echo "ipv4"
            return 0
        elif echo "$sipcalc_output" | grep -qiE "(ipv6|ipv6addr)"; then
            echo "ipv6"
            return 0
        fi
    fi
    return 1
}

# 使用 sipcalc 验证 IPv4 CIDR 格式并提取前缀和掩码
# 参数：input - CIDR 格式字符串
# 返回：输出 "前缀 掩码"，退出码 0 表示有效，1 表示无效
validate_cidr_ipv4() {
    local input=$1 prefix mask sipcalc_output
    if sipcalc_output=$(sipcalc "$input" 2>/dev/null); then
        if echo "$sipcalc_output" | grep -qiE "(ipv4|ipv4addr)"; then
            if [[ $input =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
                prefix=${BASH_REMATCH[1]}
                mask=${BASH_REMATCH[2]}
                if [[ ! $mask =~ ^[0-9]+$ ]] || [[ $mask -gt 32 ]] || [[ $mask -lt 0 ]]; then
                    log_message "WARNING" "无效 IPv4 CIDR 掩码：$input"
                    return 1
                fi
                echo "$prefix $mask"
                return 0
            fi
        fi
    fi
    return 1
}

# ==================== IP 解析处理模块 ====================
# 清理输入：移除注释和空白字符
# 参数：input - 原始输入字符串
# 返回：清理后的字符串，退出码 0 表示成功，1 表示输入为空
normalize_ip_input() {
    local input="$1"
    [[ -z "$input" ]] && return 1
    echo "$input" | cut -d'#' -f1 | tr -d '[:space:]'
}

# 处理 IPv4 CIDR 格式
# 参数：cidr - CIDR 字符串，output_file - 输出文件路径
# 返回：0 表示成功，1 表示失败
process_ipv4_cidr() {
    local cidr="$1" output_file="$2"
    local result prefix mask
    result=$(validate_cidr_ipv4 "$cidr")
    if [[ -n "$result" ]]; then
        read -r prefix mask <<< "$result"
        echo "$cidr" >> "$output_file" || {
            log_message "ERROR" "写入 IPv4 CIDR 失败：$cidr"
            return 1
        }
        return 0
    fi
    return 1
}

# 处理 IPv6 CIDR 格式
# 参数：cidr - CIDR 字符串，output_file - 输出文件路径
# 返回：0 表示成功，1 表示失败
process_ipv6_cidr() {
    local cidr="$1" output_file="$2"
    local ipv6_prefix ipv6_mask
    if [[ $cidr =~ ^([0-9a-fA-F:]+)/([0-9]{1,3})$ ]]; then
        ipv6_prefix=${BASH_REMATCH[1]}
        ipv6_mask=${BASH_REMATCH[2]}
        if [[ ! "$ipv6_mask" =~ ^[0-9]+$ ]] || [[ "$ipv6_mask" -gt 128 ]] || [[ "$ipv6_mask" -lt 0 ]]; then
            log_message "WARNING" "无效 IPv6 CIDR 掩码：$cidr"
            return 1
        fi
        if ! validate_ipv6 "$cidr"; then
            log_message "WARNING" "无效 IPv6 CIDR 格式：$cidr"
            return 1
        fi
        echo "$cidr" >> "$output_file" || {
            log_message "ERROR" "写入 IPv6 CIDR 失败：$cidr"
            return 1
        }
        return 0
    fi
    return 1
}

# 展开 IPv4 范围为单个 IP 列表
# 参数：start_num - 起始 IP 数值，end_num - 结束 IP 数值
# 返回：输出展开后的 IP 列表
expand_ipv4_range() {
    local start_num="$1" end_num="$2"
    awk -v start="$start_num" -v end="$end_num" \
        'BEGIN { for (i=start; i<=end; i++) { a=int(i/16777216); b=int((i%16777216)/65536); c=int((i%65536)/256); d=i%256; printf "%d.%d.%d.%d\n", a, b, c, d } }'
}

# 处理 IPv4 范围格式
# 参数：range - IP 范围字符串（格式：start-end），output_file - 输出文件路径
# 返回：0 表示成功，1 表示失败
process_ipv4_range() {
    local range="$1" output_file="$2"
    local start_ip end_ip start_num end_num ip_count
    if [[ $range =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})-([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$ ]]; then
        start_ip=${BASH_REMATCH[1]}
        end_ip=${BASH_REMATCH[2]}
        if ! validate_ipv4 "$start_ip" || ! validate_ipv4 "$end_ip"; then
            log_message "WARNING" "无效 IPv4 范围地址：$range"
            return 1
        fi
        IFS='.' read -r a b c d <<< "$start_ip"
        start_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
        IFS='.' read -r a b c d <<< "$end_ip"
        end_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
        if [[ $start_num -gt $end_num ]]; then
            log_message "WARNING" "无效 IPv4 范围：$range（起始地址大于结束地址）"
            return 1
        fi
        ip_count=$((end_num - start_num + 1))
        if ! [[ "$ip_count" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "计算 IP 范围数量失败：$range"
            return 1
        fi
        if [[ $ip_count -gt $MAX_RANGE_SIZE ]]; then
            log_message "WARNING" "IPv4 范围过大：$range（$ip_count 条，建议使用 CIDR 格式）"
            return 1
        fi
        local awk_output
        if ! awk_output=$(expand_ipv4_range "$start_num" "$end_num" 2>&1); then
            log_message "ERROR" "解析 IPv4 范围失败：$range"
            return 1
        fi
        echo "$awk_output" >> "$output_file" || {
            log_message "ERROR" "写入 IPv4 范围失败：$range"
            return 1
        }
        return 0
    fi
    return 1
}

# 处理 IPv6 范围格式
# 参数：range - IP 范围字符串（格式：start-end），output_file - 输出文件路径
# 返回：0 表示成功，1 表示失败
process_ipv6_range() {
    local range="$1" output_file="$2"
    local start_ip end_ip
    if [[ $range =~ ^([0-9a-fA-F:]+)-([0-9a-fA-F:]+)$ ]]; then
        start_ip=${BASH_REMATCH[1]}
        end_ip=${BASH_REMATCH[2]}
        if ! validate_ipv6 "$start_ip" || ! validate_ipv6 "$end_ip"; then
            log_message "WARNING" "无效 IPv6 范围：$range"
            return 1
        fi
        echo "$start_ip" >> "$output_file" || {
            log_message "ERROR" "写入 IPv6 范围起始地址失败：$start_ip"
            return 1
        }
        echo "$end_ip" >> "$output_file" || {
            log_message "ERROR" "写入 IPv6 范围结束地址失败：$end_ip"
            return 1
        }
        return 0
    fi
    return 1
}

# 处理单个 IP 地址
# 参数：ip - IP 地址，output_file_ipv4 - IPv4 输出文件，output_file_ipv6 - IPv6 输出文件
# 返回：0 表示成功，1 表示失败
process_single_ip() {
    local ip="$1" output_file_ipv4="$2" output_file_ipv6="$3"
    local protocol
    protocol=$(validate_ip "$ip")
    if [[ -n "$protocol" ]]; then
        if [[ $protocol == "ipv4" ]]; then
            echo "$ip" >> "$output_file_ipv4" || {
                log_message "ERROR" "写入 IPv4 地址失败：$ip"
                return 1
            }
        else
            echo "$ip" >> "$output_file_ipv6" || {
                log_message "ERROR" "写入 IPv6 地址失败：$ip"
                return 1
            }
        fi
        return 0
    fi
    return 1
}

# 解析 IP 范围：按优先级尝试处理（CIDR > 范围 > 单个IP）
# 参数：input - 输入字符串，output_file_ipv4 - IPv4 输出文件，output_file_ipv6 - IPv6 输出文件
# 返回：0 表示成功，1 表示失败
parse_ip_range() {
    local input="$1" output_file_ipv4="$2" output_file_ipv6="$3"
    local clean_ip
    
    [[ -z "$input" ]] && {
        log_message "WARNING" "空输入，跳过处理"
        return 1
    }
    
    clean_ip=$(normalize_ip_input "$input")
    [[ -z "$clean_ip" ]] && {
        log_message "WARNING" "无效输入（提取后为空）：$input"
        return 1
    }
    
    if process_ipv4_cidr "$clean_ip" "$output_file_ipv4"; then
        return 0
    fi
    if process_ipv6_cidr "$clean_ip" "$output_file_ipv6"; then
        return 0
    fi
    if process_ipv4_range "$clean_ip" "$output_file_ipv4"; then
        return 0
    fi
    if process_ipv6_range "$clean_ip" "$output_file_ipv6"; then
        return 0
    fi
    if process_single_ip "$clean_ip" "$output_file_ipv4" "$output_file_ipv6"; then
        return 0
    fi
    
    log_message "WARNING" "无效输入：$input"
    return 1
}

# ==================== 核心功能 ====================
# 检查服务状态
# 返回：0 表示所有服务运行中，1 表示有服务未运行
check_services() {
    local missing=0
    if ! systemctl is-active firewalld &>/dev/null; then
        log_message "ERROR" "Firewalld 服务未运行（请执行 systemctl start firewalld）"
        missing=1
    fi
    if ! systemctl is-active cron &>/dev/null; then
        log_message "ERROR" "Cron 服务未运行（请执行 systemctl start cron）"
        missing=1
    fi
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    return 0
}

# ==================== 通用 IPSet 操作模块 ====================
# 配置单个 IPSet：创建并绑定到区域
# 参数：ipset_name - IPSet 名称，ip_family - IP 族（inet/inet6），ip_type - 类型标识（IPv4/IPv6）
# 返回：0 表示无需重载，1 表示需要重载
configure_single_ipset() {
    local ipset_name="$1" ip_family="$2" ip_type="$3"
    local need_log=0 need_reload=0
    
    if ! check_ipset_exists "$ipset_name"; then
        need_log=1
        if ! firewall-cmd --permanent --new-ipset="$ipset_name" --type=hash:net --option=family="$ip_family" --option=maxelem=$MAX_IP_LIMIT &>/dev/null; then
            log_message "ERROR" "配置 $ip_type IPSet 失败（请检查 Firewalld 配置）"
            exit 1
        fi
        need_reload=1
    fi
    if ! check_ipset_bound "$ipset_name" "$ZONE"; then
        need_log=1
        if ! firewall-cmd --permanent --zone="$ZONE" --add-source="ipset:$ipset_name" &>/dev/null; then
            log_message "ERROR" "配置 $ip_type IPSet 失败"
            exit 1
        fi
        need_reload=1
    fi
    if [[ $need_log -eq 1 ]]; then
        log_message "INFO" "配置 $ip_type IPSet 于 drop 区域"
    fi
    return $need_reload
}

# 配置所有 IPSet
# 返回：0 表示无需重载，1 表示需要重载
configure_ipset() {
    local need_reload=0
    if configure_single_ipset "$IPSET_NAME_IPV4" "inet" "IPv4"; then
        need_reload=1
    fi
    if configure_single_ipset "$IPSET_NAME_IPV6" "inet6" "IPv6"; then
        need_reload=1
    fi
    return $need_reload
}

validate_zone() {
    if ! firewall-cmd --get-zones | grep -qw "$ZONE"; then
        log_message "ERROR" "无效 Firewalld 区域：$ZONE"
        exit 1
    fi
}

# 重载防火墙
# 参数：need_reload - 是否需要重载（0/1，默认 0）
# 返回：0 表示成功，1 表示失败
reload_firewalld() {
    local need_reload="${1:-0}"
    if [[ $need_reload -eq 1 ]]; then
        local cmd_output
        if ! cmd_output=$(firewall-cmd --reload 2>&1); then
            log_message "ERROR" "Firewalld 规则重载失败：$cmd_output"
            return 1
        fi
        log_message "SUCCESS" "Firewalld 规则重载成功"
        return 0
    fi
    return 0
}

# 下载威胁列表
# 参数：threat_level - 威胁等级（0-100），temp_gz - 压缩文件路径，temp_txt - 解压文件路径
# 返回：0 表示成功，1 表示失败
download_threat_list() {
    local threat_level="${1:-${THREAT_LEVEL:-$DEFAULT_THREAT_LEVEL}}"
    local temp_gz="${2:-$TEMP_GZ}"
    local temp_txt="${3:-$TEMP_TXT}"
    
    # 验证威胁等级
    if ! [[ "$threat_level" =~ ^[0-9]+$ ]] || [[ "$threat_level" -lt 0 || "$threat_level" -gt 100 ]]; then
        log_message "WARNING" "无效威胁等级：$threat_level，使用默认：$DEFAULT_THREAT_LEVEL"
        threat_level=$DEFAULT_THREAT_LEVEL
    fi
    
    local download_url
    download_url=$(get_threat_list_url "$threat_level")
    log_message "INFO" "下载威胁等级 $threat_level 的 IP 列表"
    log_message "DEBUG" "下载链接：$download_url"
    
    if ! wget -q "$download_url" -O "$temp_gz"; then
        log_message "ERROR" "下载威胁 IP 列表失败（威胁等级：$threat_level，链接：$download_url）"
        return 1
    fi
    if ! gzip -dc "$temp_gz" > "$temp_txt"; then
        log_message "ERROR" "解压威胁 IP 列表失败"
        rm -f "$temp_gz"
        return 1
    fi
    rm -f "$temp_gz"
    TEMP_FILES=("${TEMP_FILES[@]/$temp_gz}")
    log_message "SUCCESS" "威胁 IP 列表下载完成（威胁等级：$threat_level）"
    return 0
}

# ==================== IP 列表处理模块 ====================
# 准备输入文件：过滤空行和注释
# 参数：input_file - 输入文件路径
# 返回：输出临时文件路径，退出码 0 表示成功，1 表示失败
prepare_input_file() {
    local input_file="$1"
    local temp_input
    temp_input=$(mktemp "${TEMP_DIR}/processed_input.XXXXXX.txt")
    TEMP_FILES+=("$temp_input")
    grep -v '^\s*$' "$input_file" | grep -v '^\s*#' > "$temp_input" || {
        log_message "INFO" "IP 列表为空或仅包含注释，无需处理"
        return 1
    }
    echo "$temp_input"
    return 0
}

# 解析 IP 条目：逐行解析并统计
# 参数：temp_input - 临时输入文件，temp_file_ipv4 - IPv4 输出文件，temp_file_ipv6 - IPv6 输出文件
# 返回：0 表示成功，1 表示失败
parse_ip_entries() {
    local temp_input="$1" temp_file_ipv4="$2" temp_file_ipv6="$3"
    local total_count valid_count invalid_count ip
    
    total_count=$(wc -l < "$temp_input")
    if ! [[ "$total_count" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "无法计算输入行数：$total_count"
        return 1
    fi
    
    log_message "INFO" "解析 IP 列表中..."
    
    valid_count=0
    invalid_count=0
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
    
    if [[ $invalid_count -eq $total_count ]]; then
        log_message "INFO" "所有输入 IP ($invalid_count 条) 无效，已跳过"
        return 1
    fi
    
    return 0
}

# 去重并排序 IP 列表
# 参数：temp_file - 临时文件路径，output_file - 输出文件路径
# 返回：0 表示成功，1 表示失败
deduplicate_and_sort_ips() {
    local temp_file="$1" output_file="$2"
    if ! sort -u "$temp_file" > "$output_file" 2>/dev/null; then
        log_message "ERROR" "IP 去重失败：$output_file"
        return 1
    fi
    return 0
}

# 检查并限制 IP 数量
# 参数：ip_file - IP 文件路径，ip_type - 类型标识（IPv4/IPv6）
# 返回：输出 IP 数量，退出码 0 表示成功，1 表示失败
check_and_limit_ip_count() {
    local ip_file="$1" ip_type="$2"
    local count
    count=$(wc -l < "$ip_file")
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "无法计算 $ip_type IP 数量：$count"
        return 1
    fi
    if [[ $count -gt $MAX_IP_LIMIT ]]; then
        log_message "WARNING" "$ip_type IP 数量超出上限 $MAX_IP_LIMIT，截取前 $MAX_IP_LIMIT 条"
        head -n "$MAX_IP_LIMIT" "$ip_file" > "${ip_file}.tmp" && mv "${ip_file}.tmp" "$ip_file"
        count=$MAX_IP_LIMIT
    fi
    echo "$count"
    return 0
}

# 应用 IP 变更到单个 IPSet
# 参数：ip_file - IP 文件路径，ipset_name - IPSet 名称，ip_type - 类型标识，mode - 操作模式（add/remove）
# 返回：输出处理的 IP 数量，退出码 0 表示成功，1 表示失败
apply_ips_to_single_ipset() {
    local ip_file="$1" ipset_name="$2" ip_type="$3" mode="$4"
    local count
    count=$(wc -l < "$ip_file" 2>/dev/null || echo "0")
    if [[ $count -eq 0 ]]; then
        return 0
    fi
    if ! apply_ip_changes "$ip_file" "$ipset_name" "$mode"; then
        log_message "ERROR" "应用 $ip_type IP 变更失败"
        return 1
    fi
    echo "$count"
    return 0
}

# 应用 IP 变更到所有 IPSet
# 参数：output_file_ipv4 - IPv4 输出文件，output_file_ipv6 - IPv6 输出文件，mode - 操作模式（add/remove）
# 返回：0 表示成功，1 表示失败
apply_ips_to_ipsets() {
    local output_file_ipv4="$1" output_file_ipv6="$2" mode="$3"
    local ipv4_count ipv6_count result
    
    ipv4_count=$(apply_ips_to_single_ipset "$output_file_ipv4" "$IPSET_NAME_IPV4" "IPv4" "$mode")
    [[ $? -ne 0 ]] && return 1
    
    ipv6_count=$(apply_ips_to_single_ipset "$output_file_ipv6" "$IPSET_NAME_IPV6" "IPv6" "$mode")
    [[ $? -ne 0 ]] && return 1
    
    if [[ $ipv4_count -eq 0 && $ipv6_count -eq 0 ]]; then
        log_message "INFO" "无 IP 需要处理"
        return 0
    fi
    
    log_message "SUCCESS" "已处理 IPv4: $ipv4_count 条 IPv6: $ipv6_count 条"
    return 0
}

# 处理 IP 列表：解析、去重、排序、限制数量并应用到 IPSet
# 参数：input_file - 输入文件路径，output_file_ipv4 - IPv4 输出文件，output_file_ipv6 - IPv6 输出文件，mode - 操作模式（add/remove）
# 返回：0 表示成功，1 表示失败
process_ip_list() {
    local input_file="$1" output_file_ipv4="$2" output_file_ipv6="$3" mode="$4"
    local temp_file_ipv4 temp_file_ipv6 temp_input
    local ipv4_count ipv6_count
    
    temp_file_ipv4=$(mktemp "${TEMP_DIR}/expanded_ips_ipv4.XXXXXX.txt")
    TEMP_FILES+=("$temp_file_ipv4")
    temp_file_ipv6=$(mktemp "${TEMP_DIR}/expanded_ips_ipv6.XXXXXX.txt")
    TEMP_FILES+=("$temp_file_ipv6")
    : > "$temp_file_ipv4"
    : > "$temp_file_ipv6"
    
    temp_input=$(prepare_input_file "$input_file")
    [[ $? -ne 0 ]] && {
        cleanup_temp_files
        return 0
    }
    
    if ! parse_ip_entries "$temp_input" "$temp_file_ipv4" "$temp_file_ipv6"; then
        cleanup_temp_files
        return 0
    fi
    
    if [[ ! -s "$temp_file_ipv4" && ! -s "$temp_file_ipv6" ]]; then
        log_message "ERROR" "无有效 IP（请检查输入格式）"
        cleanup_temp_files
        return 1
    fi
    
    process_single_ip_file() {
        local temp_file="$1" output_file="$2" ip_type="$3"
        if ! deduplicate_and_sort_ips "$temp_file" "$output_file"; then
            return 1
        fi
        check_and_limit_ip_count "$output_file" "$ip_type" >/dev/null || return 1
        return 0
    }
    
    if ! process_single_ip_file "$temp_file_ipv4" "$output_file_ipv4" "IPv4"; then
        cleanup_temp_files
        return 1
    fi
    if ! process_single_ip_file "$temp_file_ipv6" "$output_file_ipv6" "IPv6"; then
        cleanup_temp_files
        return 1
    fi
    
    ipv4_count=$(check_and_limit_ip_count "$output_file_ipv4" "IPv4")
    [[ $? -ne 0 ]] && {
        cleanup_temp_files
        return 1
    }
    ipv6_count=$(check_and_limit_ip_count "$output_file_ipv6" "IPv6")
    [[ $? -ne 0 ]] && {
        cleanup_temp_files
        return 1
    }
    
    if ! apply_ips_to_ipsets "$output_file_ipv4" "$output_file_ipv6" "$mode"; then
        cleanup_temp_files
        return 1
    fi
    
    cleanup_temp_files
    return 0
}

apply_ip_changes() {
    local ip_file="$1" ipset_name="$2" mode="$3"
    local ip_count_before
    local ipset_entries_before

    if ! check_ipset_exists "$ipset_name"; then
        log_message "ERROR" "IPSet 不存在：$ipset_name"
        return 1
    fi

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
            log_message "WARNING" "输入条目数超过 IPSet 上限：$ipset_name（$ip_count_before > $MAX_IP_LIMIT）"
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

# ==================== IP 移除模块 ====================
# 从单个 IPSet 移除所有 IP
# 参数：ipset_name - IPSet 名称，temp_file - 临时文件路径，ip_type - 类型标识
# 返回：0 表示成功
remove_ips_from_single_ipset() {
    local ipset_name="$1" temp_file="$2" ip_type="$3"
    local sources
    sources=$(firewall-cmd --permanent --ipset="$ipset_name" --get-entries 2>/dev/null)
    if [[ -z "$sources" ]]; then
        return 0
    fi
    echo "$sources" | tr ' ' '\n' > "$temp_file"
    apply_ip_changes "$temp_file" "$ipset_name" "remove" || {
        log_message "WARNING" "移除 $ip_type IP 失败，继续执行清理"
    }
    return 0
}

# 从所有 IPSet 移除所有 IP
# 返回：0 表示成功
remove_ips_from_ipsets() {
    local has_ips=0
    remove_ips_from_single_ipset "$IPSET_NAME_IPV4" "$TEMP_IP_LIST_IPV4" "IPv4" && has_ips=1
    remove_ips_from_single_ipset "$IPSET_NAME_IPV6" "$TEMP_IP_LIST_IPV6" "IPv6" && has_ips=1
    if [[ $has_ips -eq 0 ]]; then
        log_message "INFO" "无封禁 IP"
    fi
    return 0
}

# 从区域解绑单个 IPSet
# 参数：ipset_name - IPSet 名称，ip_type - 类型标识
# 返回：0 表示无需重载，1 表示需要重载
unbind_single_ipset_from_zone() {
    local ipset_name="$1" ip_type="$2"
    local ipset_bound need_reload=0
    ipset_bound=$(firewall-cmd --permanent --zone=drop --list-sources | grep -w "ipset:$ipset_name" || true)
    if [[ -z "$ipset_bound" ]]; then
        return 0
    fi
    log_message "INFO" "从 drop 区域解绑 $ip_type IPSet"
    if firewall-cmd --permanent --zone=drop --remove-source="ipset:$ipset_name" &>/dev/null; then
        need_reload=1
    else
        log_message "WARNING" "解绑 $ip_type IPSet 失败，继续执行清理"
    fi
    return $need_reload
}

# 从区域解绑所有 IPSet
# 返回：0 表示无需重载，1 表示需要重载
unbind_ipsets_from_zone() {
    local need_reload=0
    if unbind_single_ipset_from_zone "$IPSET_NAME_IPV4" "IPv4"; then
        need_reload=1
    fi
    if unbind_single_ipset_from_zone "$IPSET_NAME_IPV6" "IPv6"; then
        need_reload=1
    fi
    return $need_reload
}

# 删除单个 IPSet
# 参数：ipset_name - IPSet 名称，ip_type - 类型标识
# 返回：0 表示无需重载，1 表示需要重载
delete_single_ipset() {
    local ipset_name="$1" ip_type="$2" need_reload=0
    if ! check_ipset_exists "$ipset_name"; then
        return 0
    fi
    log_message "INFO" "删除 $ip_type IPSet：$ipset_name"
    if firewall-cmd --permanent --delete-ipset="$ipset_name" &>/dev/null; then
        need_reload=1
    else
        log_message "WARNING" "删除 $ip_type IPSet 失败，继续执行清理"
    fi
    return $need_reload
}

# 删除所有 IPSet
# 返回：0 表示无需重载，1 表示需要重载
delete_ipsets() {
    local need_reload=0
    if delete_single_ipset "$IPSET_NAME_IPV4" "IPv4"; then
        need_reload=1
    fi
    if delete_single_ipset "$IPSET_NAME_IPV6" "IPv6"; then
        need_reload=1
    fi
    return $need_reload
}

# 清理 drop 区域配置：仅在区域完全清空时删除自定义配置文件
# 返回：0 表示无需重载，1 表示需要重载
cleanup_drop_zone_config() {
    local drop_xml_file="/etc/firewalld/zones/drop.xml"
    local remaining_sources drop_zone_info need_reload=0
    local has_services has_ports has_protocols has_rich_rules
    
    remaining_sources=$(firewall-cmd --permanent --zone=drop --list-sources 2>/dev/null | grep -v "^$" || true)
    drop_zone_info=$(firewall-cmd --permanent --zone=drop --list-all 2>/dev/null || true)
    
    has_services=$(echo "$drop_zone_info" | grep -E "^  services:" | grep -v "services: $" || true)
    has_ports=$(echo "$drop_zone_info" | grep -E "^  ports:" | grep -v "ports: $" || true)
    has_protocols=$(echo "$drop_zone_info" | grep -E "^  protocols:" | grep -v "protocols: $" || true)
    has_rich_rules=$(echo "$drop_zone_info" | grep -E "^  rich rules:" | grep -v "rich rules: $" || true)
    
    if [[ -z "$remaining_sources" ]] && [[ -z "$has_services" ]] && [[ -z "$has_ports" ]] && [[ -z "$has_protocols" ]] && [[ -z "$has_rich_rules" ]]; then
        if [[ -f "$drop_xml_file" ]]; then
            log_message "INFO" "drop 区域已清空，删除自定义配置文件：$drop_xml_file"
            if rm -f "$drop_xml_file"; then
                need_reload=1
            else
                log_message "WARNING" "删除 drop 区域配置文件失败：$drop_xml_file，继续执行清理"
            fi
        fi
    elif [[ -n "$remaining_sources" ]]; then
        log_message "INFO" "drop 区域仍有其他 sources，保留配置文件"
    fi
    return $need_reload
}

# 移除所有 IP：从 IPSet 移除、解绑、删除并清理区域配置
# 参数：temp_file_ipv4 - IPv4 临时文件路径，temp_file_ipv6 - IPv6 临时文件路径
# 返回：0 表示成功
remove_all_ips() {
    local temp_file_ipv4="${1:-$TEMP_IP_LIST_IPV4}"
    local temp_file_ipv6="${2:-$TEMP_IP_LIST_IPV6}"
    local need_reload=0
    
    if ! check_ipset_exists "$IPSET_NAME_IPV4" && ! check_ipset_exists "$IPSET_NAME_IPV6"; then
        log_message "INFO" "未配置 IPSet"
        return 0
    fi
    
    remove_ips_from_single_ipset "$IPSET_NAME_IPV4" "$temp_file_ipv4" "IPv4"
    remove_ips_from_single_ipset "$IPSET_NAME_IPV6" "$temp_file_ipv6" "IPv6"
    
    if unbind_ipsets_from_zone; then
        need_reload=1
    fi
    if delete_ipsets; then
        need_reload=1
    fi
    if cleanup_drop_zone_config; then
        need_reload=1
    fi
    
    reload_firewalld $need_reload || {
        log_message "WARNING" "Firewalld 重载失败，但继续执行清理"
    }
    log_message "SUCCESS" "已移除所有封禁 IP"
}

# 启用自动更新：配置定时任务并执行首次更新
# 返回：0 表示成功，1 表示失败
enable_auto_update() {
    local cron_schedule threat_level

    local read_result read_success
    read_result=$(safe_read "请输入威胁等级（0-100，留空使用默认：$DEFAULT_THREAT_LEVEL）： " "$DEFAULT_THREAT_LEVEL")
    read_success=$?
    
    if [[ $read_success -ne 0 ]]; then
        log_message "WARNING" "读取输入失败，使用默认威胁等级：$DEFAULT_THREAT_LEVEL"
        threat_level=$DEFAULT_THREAT_LEVEL
    else
        threat_level="$read_result"
        if [[ -z "$threat_level" ]]; then
            log_message "INFO" "用户留空，使用默认威胁等级：$DEFAULT_THREAT_LEVEL"
            threat_level=$DEFAULT_THREAT_LEVEL
        elif ! [[ "$threat_level" =~ ^[0-9]+$ ]] || [[ "$threat_level" -lt 0 ]] || [[ "$threat_level" -gt 100 ]]; then
            log_message "WARNING" "无效威胁等级：$threat_level，使用默认：$DEFAULT_THREAT_LEVEL"
            threat_level=$DEFAULT_THREAT_LEVEL
        fi
    fi
    THREAT_LEVEL=$threat_level
    export THREAT_LEVEL

    echo -e "请输入 Cron 规则（留空使用默认：$DEFAULT_UPDATE_CRON）："
    local read_result read_success
    read_result=$(safe_read "" "$DEFAULT_UPDATE_CRON")
    read_success=$?
    
    if [[ $read_success -ne 0 ]]; then
        log_message "WARNING" "读取输入失败，使用默认 Cron 规则：$DEFAULT_UPDATE_CRON"
        cron_schedule=$DEFAULT_UPDATE_CRON
    else
        cron_schedule="$read_result"
        if [[ -z "$cron_schedule" ]]; then
            log_message "INFO" "用户留空，使用默认 Cron 规则：$DEFAULT_UPDATE_CRON"
            cron_schedule=$DEFAULT_UPDATE_CRON
        fi
    fi
    if ! echo "$cron_schedule" | grep -qE '^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+$'; then
        log_message "WARNING" "无效 Cron 规则：$cron_schedule，使用默认：$DEFAULT_UPDATE_CRON"
        cron_schedule=$DEFAULT_UPDATE_CRON
    fi

    init_data_dir
    if [[ ! -d "$LOG_DIR" ]]; then
        log_message "INFO" "创建日志目录：$LOG_DIR"
        if ! mkdir -p "$LOG_DIR"; then
            log_message "ERROR" "创建日志目录失败：$LOG_DIR"
            return 1
        fi
        chmod 755 "$LOG_DIR"
    fi
    if [[ ! -f "$LOG_FILE" ]]; then
        log_message "INFO" "创建日志文件：$LOG_FILE"
        if ! touch "$LOG_FILE"; then
            log_message "ERROR" "创日志文件失败：$LOG_FILE"
            return 1
        fi
        chmod 644 "$LOG_FILE"
    fi
    if [[ ! -w "$LOG_FILE" ]]; then
        log_message "ERROR" "日志文件不可写：$LOG_FILE（请检查权限）"
        return 1
    fi

    if ! echo "THREAT_LEVEL=$threat_level" > "$CONFIG_FILE"; then
        log_message "ERROR" "写入配置文件失败：$CONFIG_FILE（请检查权限）"
        return 1
    fi
    if ! echo "UPDATE_CRON=\"$cron_schedule\"" >> "$CONFIG_FILE"; then
        log_message "ERROR" "写入配置文件失败：$CONFIG_FILE（请检查权限）"
        return 1
    fi
    chmod 644 "$CONFIG_FILE" 2>/dev/null || {
        log_message "ERROR" "设置配置文件权限失败：$CONFIG_FILE"
        return 1
    }

    if ! cp -f "$0" "$CRON_SCRIPT_PATH"; then
        log_message "ERROR" "复制脚本失败：$CRON_SCRIPT_PATH（请检查权限）"
        return 1
    fi
    chmod +x "$CRON_SCRIPT_PATH" 2>/dev/null || {
        log_message "ERROR" "设置脚本执行权限失败：$CRON_SCRIPT_PATH"
        return 1
    }

    local temp_cron
    temp_cron=$(mktemp "${TEMP_DIR}/cron.XXXXXX")
    TEMP_FILES+=("$temp_cron")
    crontab -l > "$temp_cron" 2>/dev/null || true
    sed -i '/# IPThreat Firewalld Update/d' "$temp_cron"
    echo "$cron_schedule /bin/bash $CRON_SCRIPT_PATH --cron # IPThreat Firewalld Update" >> "$temp_cron"
    if ! crontab "$temp_cron"; then
        log_message "ERROR" "设置 crontab 失败（请检查 cron 服务）"
        cleanup_temp_files
        return 1
    fi
    cleanup_temp_files
    log_message "SUCCESS" "启用自动更新：威胁等级 $threat_level，定时 $cron_schedule"

    if ! update_threat_ips "$threat_level"; then
        log_message "WARNING" "首次更新失败，但自动更新已启用（将在下次定时任务时重试）"
    fi
}

# 禁用自动更新：移除定时任务、清理防火墙配置和相关文件
# 返回：无返回值（失败时退出）
disable_auto_update() {
    local temp_cron
    temp_cron=$(mktemp "${TEMP_DIR}/cron.XXXXXX")
    TEMP_FILES+=("$temp_cron")
    crontab -l > "$temp_cron" 2>/dev/null || true
    sed -i '/# IPThreat Firewalld Update/d' "$temp_cron"
    if ! crontab "$temp_cron"; then
        log_message "ERROR" "移除 crontab 失败（请检查 cron 服务）"
        cleanup_temp_files
        exit 1
    fi
    cleanup_temp_files

    remove_all_ips || {
        log_message "WARNING" "清理防火墙配置时出现警告，继续执行清理"
    }

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
    if [[ -d "$DATA_DIR" ]]; then
        if [[ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
            log_message "INFO" "删除数据目录：$DATA_DIR"
            rmdir "$DATA_DIR" 2>/dev/null || true
        else
            log_message "WARNING" "数据目录 $DATA_DIR 非空，保留目录"
        fi
    fi

    log_message "SUCCESS" "已禁用自动更新并清理所有相关配置"
}

# 查看定时任务
view_cron_jobs() {
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

# 更新威胁 IP 列表：下载、解析并应用到 IPSet
# 参数：threat_level - 威胁等级（0-100，可选）
# 返回：0 表示成功，1 表示失败
update_threat_ips() {
    local threat_level="${1:-${THREAT_LEVEL:-$DEFAULT_THREAT_LEVEL}}"
    local temp_gz temp_txt temp_file_ipv4 temp_file_ipv6 need_reload=0
    
    if ! [[ "$threat_level" =~ ^[0-9]+$ ]] || [[ "$threat_level" -lt 0 || "$threat_level" -gt 100 ]]; then
        log_message "WARNING" "无效威胁等级：$threat_level，使用默认：$DEFAULT_THREAT_LEVEL"
        threat_level=$DEFAULT_THREAT_LEVEL
    fi
    
    temp_gz=$(create_temp_file "threat" ".gz")
    temp_txt=$(create_temp_file "threat" ".txt")
    temp_file_ipv4=$(create_temp_file "valid_ips_ipv4" ".txt")
    temp_file_ipv6=$(create_temp_file "valid_ips_ipv6" ".txt")
    
    if ! check_ipset_exists "$IPSET_NAME_IPV4" && ! check_ipset_exists "$IPSET_NAME_IPV6"; then
        if configure_ipset; then
            need_reload=1
        fi
    fi
    
    if ! download_threat_list "$threat_level" "$temp_gz" "$temp_txt"; then
        log_message "ERROR" "下载威胁 IP 列表失败，终止更新"
        cleanup_temp_files
        return 1
    fi
    
    if ! filter_and_add_ips "$temp_txt" "$temp_file_ipv4" "$temp_file_ipv6"; then
        log_message "ERROR" "处理 IP 列表失败，终止更新"
        cleanup_temp_files
        return 1
    fi
    
    cleanup_temp_files
    return 0
}

# ==================== IP 过滤和添加模块 ====================
# 清空单个 IPSet 中的现有 IP
# 参数：ipset_name - IPSet 名称，temp_file - 临时文件路径，ip_type - 类型标识
# 返回：0 表示成功
clear_single_ipset_entries() {
    local ipset_name="$1" temp_file="$2" ip_type="$3"
    local existing_entries
    if ! check_ipset_exists "$ipset_name"; then
        return 0
    fi
    existing_entries=$(firewall-cmd --permanent --ipset="$ipset_name" --get-entries 2>/dev/null || echo "")
    if [[ -z "$existing_entries" ]]; then
        return 0
    fi
    echo "$existing_entries" | tr ' ' '\n' > "$temp_file" 2>/dev/null || true
    if [[ -s "$temp_file" ]]; then
        apply_ip_changes "$temp_file" "$ipset_name" "remove" || {
            log_message "WARNING" "清空 $ip_type IPSet 时出现警告，继续执行"
        }
    fi
    return 0
}

# 清空所有 IPSet 的现有 IP（清空重写模式）
clear_all_ipsets() {
    clear_single_ipset_entries "$IPSET_NAME_IPV4" "$TEMP_IP_LIST_IPV4" "IPv4"
    clear_single_ipset_entries "$IPSET_NAME_IPV6" "$TEMP_IP_LIST_IPV6" "IPv6"
}

# 过滤并添加 IP：配置 IPSet、清空现有条目、处理新 IP 列表并重载防火墙
# 参数：temp_txt - 文本文件路径，temp_file_ipv4 - IPv4 输出文件，temp_file_ipv6 - IPv6 输出文件
# 返回：0 表示成功，1 表示失败
filter_and_add_ips() {
    local temp_txt="${1:-$TEMP_TXT}"
    local temp_file_ipv4="${2:-$TEMP_IP_LIST_IPV4}"
    local temp_file_ipv6="${3:-$TEMP_IP_LIST_IPV6}"
    local need_reload=0
    
    [[ ! -f "$temp_txt" ]] && {
        log_message "ERROR" "IP 列表文件不存在：$temp_txt"
        cleanup_temp_files
        return 1
    }
    
    if configure_ipset; then
        need_reload=1
    fi
    clear_all_ipsets
    
    if ! process_ip_list "$temp_txt" "$temp_file_ipv4" "$temp_file_ipv6" "add"; then
        log_message "ERROR" "处理 IP 列表失败"
        cleanup_temp_files
        return 1
    fi
    
    if ! reload_firewalld $need_reload; then
        log_message "ERROR" "Firewalld 重载失败"
        return 1
    fi
    return 0
}

# ==================== 初始化函数 =================
# 初始化数据目录
# 返回：无返回值（失败时退出）
init_data_dir() {
    if [[ ! -d "$DATA_DIR" ]]; then
        log_message "INFO" "创建数据目录：$DATA_DIR"
        if ! mkdir -p "$DATA_DIR"; then
            log_message "ERROR" "创建数据目录失败：$DATA_DIR"
            exit 1
        fi
        chmod 755 "$DATA_DIR"
    fi
}

# 初始化交互模式：创建日志文件并设置默认威胁等级
# 返回：无返回值（失败时退出）
init_manual() {
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

    THREAT_LEVEL=$DEFAULT_THREAT_LEVEL
}

# 初始化定时任务模式：检查日志文件、初始化数据目录并加载配置文件
# 返回：无返回值（失败时退出）
init_cron() {
    if [[ ! -f "$LOG_FILE" ]]; then
        log_message "ERROR" "日志文件不存在：$LOG_FILE"
        exit 1
    fi
    if [[ ! -w "$LOG_FILE" ]]; then
        log_message "ERROR" "日志文件不可写：$LOG_FILE（请检查权限）"
        exit 1
    fi

    init_data_dir

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_message "ERROR" "配置文件不存在：$CONFIG_FILE"
        exit 1
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            THREAT_LEVEL)
                if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 0 ]] && [[ "$value" -le 100 ]]; then
                    THREAT_LEVEL="$value"
                else
                    log_message "WARNING" "配置文件中的威胁等级无效：$value，使用默认值"
                    THREAT_LEVEL=$DEFAULT_THREAT_LEVEL
                fi
                ;;
            UPDATE_CRON)
                UPDATE_CRON="$value"
                export UPDATE_CRON
                ;;
        esac
    done < <(grep -E '^(THREAT_LEVEL|UPDATE_CRON)=' "$CONFIG_FILE" 2>/dev/null || true)
    if ! [[ "$THREAT_LEVEL" =~ ^[0-9]+$ ]] || [[ "$THREAT_LEVEL" -lt 0 || "$THREAT_LEVEL" -gt 100 ]]; then
        THREAT_LEVEL=$DEFAULT_THREAT_LEVEL
        log_message "WARNING" "配置文件中的威胁等级无效，使用默认值：$THREAT_LEVEL"
    fi
    export THREAT_LEVEL
}

# ==================== 菜单函数 =================
# 显示主菜单并处理用户选择
# 返回：无返回值（退出时调用 exit）
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
        local config_threat_level
        config_threat_level=$(grep -E '^THREAT_LEVEL=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
        if [[ -n "$config_threat_level" ]] && [[ "$config_threat_level" =~ ^[0-9]+$ ]] && [[ "$config_threat_level" -ge 0 ]] && [[ "$config_threat_level" -le 100 ]]; then
            threat_level=$config_threat_level
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
    local read_result read_success
    read_result=$(safe_read "请选择操作: " "")
    read_success=$?
    
    choice=$(echo "$read_result" | tr -d '[:space:]' || echo "")
    
    if [[ $read_success -ne 0 ]] || [[ -z "$choice" ]]; then
        if [[ $read_success -ne 0 ]]; then
            log_message "INFO" "输入流结束，退出脚本"
            NORMAL_EXIT=1
            cleanup_temp_files
            exit 0
        fi
        log_message "ERROR" "读取用户输入失败，请确保在交互式终端中运行"
        return 1
    fi
    case "$choice" in
        1)
            if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
                log_message "INFO" "检测到部分依赖未安装，尝试自动安装..."
                if ! install_missing_dependencies "${REQUIRED_CMDS[@]}"; then
                    log_message "ERROR" "依赖安装失败，请手动安装缺失的依赖"
                    list_missing_dependencies "${REQUIRED_CMDS[@]}"
                    return 1
                fi
                if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
                    log_message "ERROR" "依赖安装后仍有缺失，请手动安装"
                    list_missing_dependencies "${REQUIRED_CMDS[@]}"
                    return 1
                fi
            fi
            if ! check_services; then
                log_message "ERROR" "服务检查失败，请启动相关服务"
                return 1
            fi
            if ! validate_zone; then
                log_message "ERROR" "区域验证失败"
                return 1
            fi
            init_temp_dir
            create_temp_files
            trap 'cleanup_on_exit; exit 1' INT TERM
            trap 'cleanup_temp_files' EXIT
            echo ""
            if ! enable_auto_update; then
                log_message "ERROR" "启用自动更新失败"
                cleanup_temp_files
                trap - EXIT
                return 1
            fi
            cleanup_temp_files
            trap - EXIT INT TERM
            ;;
        2)
            init_temp_dir
            create_temp_files
            trap 'cleanup_on_exit; exit 1' INT TERM
            trap 'cleanup_temp_files' EXIT
            disable_auto_update
            cleanup_temp_files
            trap - EXIT INT TERM
            ;;
        3)
            view_cron_jobs
            ;;
        0)
            NORMAL_EXIT=1
            cleanup_temp_files
            exit 0
            ;;
        *)
            log_message "WARNING" "无效选项：$choice"
            ;;
    esac
}

# ==================== 主函数 ===================
# 主函数：根据运行模式执行相应流程
# 参数：--cron 表示定时任务模式，否则为交互模式
main() {
    init_temp_dir
    create_temp_files
    trap 'cleanup_on_exit; exit 1' INT TERM
    trap 'cleanup_temp_files' EXIT

    if ! [[ "$MAX_IP_LIMIT" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "无效 MAX_IP_LIMIT：$MAX_IP_LIMIT"
        cleanup_temp_files
        exit 1
    fi

    if [[ "$RUN_MODE" == "manual" ]]; then
        while true; do
            show_menu
        done
    else
        init_cron
        validate_zone
        update_threat_ips
        NORMAL_EXIT=1
        cleanup_temp_files
        trap - EXIT INT TERM
    fi
}

main "$@"
