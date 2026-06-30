#!/bin/bash
# 功能：依赖检测与分级安装模块
# 说明：按 Tier 0/1/2 三级处理依赖——
#   Tier 0（系统命令）：仅检查存在性，缺失报致命错误（系统已损坏）
#   Tier 1（工具依赖）：检查 + 自动安装（轻量级软件包）
#   Tier 2（服务依赖）：检查 + 提示用户（安装后产生 daemon/服务）

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap-core.sh 加载）

# ==================== 依赖分级常量 ====================

# 依赖级别
readonly DEP_LEVEL_SYSTEM="system"   # Tier 0：系统命令，缺失 → 致命
readonly DEP_LEVEL_TOOL="tool"       # Tier 1：工具依赖，缺失 → 自动安装
readonly DEP_LEVEL_SERVICE="service" # Tier 2：服务依赖，缺失 → 提示用户

# ==================== 命令→包名映射表 ====================

# 空字符串表示系统自带命令，无需安装
declare -gA cmd_to_pkg=(
  ["grep"]=""
  ["awk"]="gawk"
  ["sed"]=""
  ["curl"]="curl"
  ["wget"]="wget"
  ["apt"]="apt"
  ["bash"]=""
  ["systemctl"]=""
  ["hostname"]=""
  ["dpkg"]=""
  ["cp"]=""
  ["mv"]=""
  ["mkdir"]=""
  ["chmod"]=""
  ["cat"]=""
  ["cut"]=""
  ["head"]=""
  ["tail"]=""
  ["sort"]=""
  ["tr"]=""
  ["wc"]=""
  ["date"]=""
  ["docker"]="docker.io"
  ["tar"]=""
  ["rsync"]="rsync"
  ["msmtp"]="msmtp"
  ["mail"]="mailutils"
  ["firewall-cmd"]="firewalld"
  ["exim4"]="exim4-daemon-light"
  ["update-exim4.conf"]="exim4-config"
  ["sysctl"]=""
  ["dig"]="dnsutils"
  ["ping"]="iputils-ping"
  ["sipcalc"]="sipcalc"
  ["getfacl"]="acl"
  ["setfacl"]="acl"
  ["nmcli"]="network-manager"
  ["ipset"]="ipset"
)

# ==================== 命令→依赖级别映射表 ====================

declare -gA cmd_to_level=(
  # ── Tier 0：系统命令（任何 Debian 最小化安装都有的命令）──
  ["grep"]="$DEP_LEVEL_SYSTEM"
  ["awk"]="$DEP_LEVEL_SYSTEM"
  ["sed"]="$DEP_LEVEL_SYSTEM"
  ["bash"]="$DEP_LEVEL_SYSTEM"
  ["systemctl"]="$DEP_LEVEL_SYSTEM"
  ["hostname"]="$DEP_LEVEL_SYSTEM"
  ["dpkg"]="$DEP_LEVEL_SYSTEM"
  ["cp"]="$DEP_LEVEL_SYSTEM"
  ["mv"]="$DEP_LEVEL_SYSTEM"
  ["mkdir"]="$DEP_LEVEL_SYSTEM"
  ["chmod"]="$DEP_LEVEL_SYSTEM"
  ["cat"]="$DEP_LEVEL_SYSTEM"
  ["cut"]="$DEP_LEVEL_SYSTEM"
  ["head"]="$DEP_LEVEL_SYSTEM"
  ["tail"]="$DEP_LEVEL_SYSTEM"
  ["sort"]="$DEP_LEVEL_SYSTEM"
  ["tr"]="$DEP_LEVEL_SYSTEM"
  ["wc"]="$DEP_LEVEL_SYSTEM"
  ["date"]="$DEP_LEVEL_SYSTEM"
  ["tar"]="$DEP_LEVEL_SYSTEM"
  ["sysctl"]="$DEP_LEVEL_SYSTEM"
  ["apt"]="$DEP_LEVEL_SYSTEM"

  # ── Tier 1：工具依赖（轻量级软件包，可安全自动安装）──
  ["curl"]="$DEP_LEVEL_TOOL"
  ["wget"]="$DEP_LEVEL_TOOL"
  ["rsync"]="$DEP_LEVEL_TOOL"
  ["dig"]="$DEP_LEVEL_TOOL"
  ["ping"]="$DEP_LEVEL_TOOL"
  ["sipcalc"]="$DEP_LEVEL_TOOL"
  ["getfacl"]="$DEP_LEVEL_TOOL"
  ["setfacl"]="$DEP_LEVEL_TOOL"
  ["ipset"]="$DEP_LEVEL_TOOL"

  # ── Tier 2：服务依赖（安装后产生 daemon/服务，需用户确认）──
  ["docker"]="$DEP_LEVEL_SERVICE"
  ["firewall-cmd"]="$DEP_LEVEL_SERVICE"
  ["msmtp"]="$DEP_LEVEL_SERVICE"
  ["mail"]="$DEP_LEVEL_SERVICE"
  ["exim4"]="$DEP_LEVEL_SERVICE"
  ["update-exim4.conf"]="$DEP_LEVEL_SERVICE"
  ["nmcli"]="$DEP_LEVEL_SERVICE"
)

# ==================== 公共接口 ====================

# 获取命令的依赖级别
# 参数：$1 - 命令名
# 输出：system / tool / service / unknown
get_dependency_level() {
  local cmd="${1:?get_dependency_level: 缺少命令名}"
  if [[ -v "cmd_to_level[$cmd]" ]]; then
    echo "${cmd_to_level[$cmd]}"
  else
    # 未显式分级的命令：检查映射表
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      local pkg="${cmd_to_pkg[$cmd]}"
      if [[ -z "$pkg" ]]; then
        echo "$DEP_LEVEL_SYSTEM"
      else
        # 保守默认：未知命令视为工具依赖
        echo "$DEP_LEVEL_TOOL"
      fi
    else
      echo "$DEP_LEVEL_TOOL"
    fi
  fi
}

# 检查依赖命令是否存在（兼容旧接口，不区分级别）
# 参数：命令列表
# 返回：0 全部存在，1 有缺失
check_dependencies() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || return 1
  done
  return 0
}

# ── Tier 0 检查：系统命令 ──
# 仅检查存在性，缺失时报致命错误（系统已损坏，不是本脚本该解决的问题）
# 参数：命令列表
# 返回：0 全部存在，1 有缺失（已记录 fatal 日志）
check_system_deps() {
  local -a missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_fatal "系统基础命令缺失：${missing[*]}"
    log_fatal "这些命令应由 Debian 最小化安装提供，系统可能已损坏"
    return 1
  fi
  return 0
}

# ── Tier 1 检查+自动安装：工具依赖 ──
# 检查缺失的工具命令，自动安装对应软件包
# 参数：命令列表
# 返回：0 全部就绪，1 部分安装失败（不阻断，模块自行处理）
check_and_install_tool_deps() {
  local -a missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "安装工具依赖：${missing[*]}"

  if ! has_valid_main_apt_source; then
    log_warning "未检测到有效主软件源，跳过自动安装（请先配置 APT 源）"
    return 1
  fi

  # apt update 只执行一次
  log_info "更新软件包索引..."
  if ! DEBIAN_FRONTEND=noninteractive apt update -qq 2>/dev/null; then
    log_error "apt update 失败，跳过自动安装"
    return 1
  fi

  local -a still_missing=()
  for cmd in "${missing[@]}"; do
    local pkg_name=""
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg_name="${cmd_to_pkg[$cmd]}"
    fi
    if [[ -z "$pkg_name" ]]; then
      # 无包映射的系统命令，不应出现在这里
      log_warning "无法确定 ${cmd} 的软件包名"
      continue
    fi
    if DEBIAN_FRONTEND=noninteractive apt install -y -qq "$pkg_name" 2>/dev/null; then
      log_success "${cmd} 就绪"
    else
      log_error "${cmd} 安装失败"
      still_missing+=("$cmd")
    fi
  done

  if [[ ${#still_missing[@]} -gt 0 ]]; then
    log_warning "以下工具安装失败：${still_missing[*]}，模块将自行处理"
    return 1
  fi
  return 0
}

# ── Tier 2 检查：服务依赖 ──
# 仅检查命令是否存在，不自动安装
# 缺失时提示用户先运行对应的模块来安装
# 参数：命令列表
# 返回：0 全部存在，1 有缺失（已记录提示）
check_service_deps() {
  local -a missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  log_error "以下服务级依赖未安装："
  for cmd in "${missing[@]}"; do
    local pkg_name=""
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg_name="${cmd_to_pkg[$cmd]}"
    fi
    printf "  - %s" "$cmd"
    if [[ -n "$pkg_name" ]]; then
      printf " （软件包: %s）" "$pkg_name"
    fi
    printf "\n"
  done
  log_error "服务级依赖不会自动安装。请先运行对应的模块（如 firewall、docker-ce 等）"
  return 1
}

# 检查主软件源是否已配置
has_valid_main_apt_source() {
  if grep -E '^[[:space:]]*deb[[:space:]]+' /etc/apt/sources.list 2>/dev/null | grep -vqE '^[[:space:]]*#'; then
    return 0
  fi
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    if grep -E '^[[:space:]]*Types:[[:space:]]*deb' /etc/apt/sources.list.d/debian.sources 2>/dev/null | grep -vqE '^[[:space:]]*#'; then
      return 0
    fi
  fi
  return 1
}

# ── 按依赖级别分流检查 ──
# 读取命令列表，按 cmd_to_level 分级后分别调用对应的检查函数
# 参数：命令列表
# 返回：0 全部就绪，1 有缺失
check_dependencies_by_level() {
  local -a system_cmds=()
  local -a tool_cmds=()
  local -a service_cmds=()

  for cmd in "$@"; do
    local level
    level=$(get_dependency_level "$cmd")
    case "$level" in
      "$DEP_LEVEL_SYSTEM")  system_cmds+=("$cmd") ;;
      "$DEP_LEVEL_TOOL")    tool_cmds+=("$cmd") ;;
      "$DEP_LEVEL_SERVICE") service_cmds+=("$cmd") ;;
    esac
  done

  # Tier 0：系统命令检查（失败则致命）
  if [[ ${#system_cmds[@]} -gt 0 ]]; then
    check_system_deps "${system_cmds[@]}" || return 1
  fi

  # Tier 1：工具依赖自动安装（失败不阻断）
  if [[ ${#tool_cmds[@]} -gt 0 ]]; then
    check_and_install_tool_deps "${tool_cmds[@]}" || true
  fi

  # Tier 2：服务依赖仅检查（失败阻断，强制用户先运行对应模块）
  if [[ ${#service_cmds[@]} -gt 0 ]]; then
    check_service_deps "${service_cmds[@]}" || return 1
  fi

  return 0
}

# 自动安装缺失依赖（兼容旧接口，仅安装 Tier 1 工具依赖，Tier 2 只检查不安装）
# 参数：命令列表
# 返回：0 全部就绪，1 有缺失
install_missing_dependencies() {
  local missing_cmds=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done
  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    log_info "所有依赖命令均已安装"
    return 0
  fi
  log_warning "发现缺失的依赖命令：${missing_cmds[*]}"

  # 按级别分流处理
  local -a tool_cmds=()
  local -a service_cmds=()
  local -a system_cmds=()

  for cmd in "${missing_cmds[@]}"; do
    local level
    level=$(get_dependency_level "$cmd")
    case "$level" in
      "$DEP_LEVEL_SYSTEM")
        system_cmds+=("$cmd")
        ;;
      "$DEP_LEVEL_TOOL")
        # 只处理有包映射的命令
        local pkg_name=""
        if [[ -v "cmd_to_pkg[$cmd]" ]]; then
          pkg_name="${cmd_to_pkg[$cmd]}"
        fi
        if [[ -n "$pkg_name" ]]; then
          tool_cmds+=("$cmd")
        fi
        ;;
      "$DEP_LEVEL_SERVICE")
        service_cmds+=("$cmd")
        ;;
    esac
  done

  # Tier 0 系统命令缺失 → 致命
  if [[ ${#system_cmds[@]} -gt 0 ]]; then
    log_fatal "系统基础命令缺失：${system_cmds[*]}，系统可能已损坏"
    return 1
  fi

  # Tier 2 服务依赖 → 提示，不安装
  if [[ ${#service_cmds[@]} -gt 0 ]]; then
    log_error "以下服务级依赖未安装，请先运行对应模块："
    for cmd in "${service_cmds[@]}"; do
      local pkg_name=""
      if [[ -v "cmd_to_pkg[$cmd]" ]]; then
        pkg_name="${cmd_to_pkg[$cmd]}"
      fi
      printf "  - %s" "$cmd"
      if [[ -n "$pkg_name" ]]; then
        printf " （软件包: %s）" "$pkg_name"
      fi
      printf "\n"
    done
    return 1
  fi

  # Tier 1 工具依赖 → 自动安装
  if [[ ${#tool_cmds[@]} -eq 0 ]]; then
    return 0
  fi

  if ! has_valid_main_apt_source; then
    log_warning "未检测到有效主软件源，跳过自动安装（模块将自行处理）"
    return 1
  fi

  log_info "更新索引..."
  if ! DEBIAN_FRONTEND=noninteractive apt update -qq 2>/dev/null; then
    log_error "apt update 失败，跳过自动安装"
    return 1
  fi

  for cmd in "${tool_cmds[@]}"; do
    local pkg_name=""
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg_name="${cmd_to_pkg[$cmd]}"
    fi
    if [[ -n "$pkg_name" ]]; then
      if DEBIAN_FRONTEND=noninteractive apt install -y -qq "$pkg_name" 2>/dev/null; then
        log_success "${cmd} 就绪"
      else
        log_error "${cmd} 安装失败"
      fi
    fi
  done
}

# 确保命令可用（检测 + 自动安装一体化，兼容旧接口）
# 参数：$1 - 命令名
#       $2 - 包名（可选，默认从 cmd_to_pkg 映射获取）
# 返回：0 命令可用，1 不可用
ensure_command() {
  local cmd="${1:?ensure_command: 缺少命令名}"
  local pkg="${2:-}"

  if [[ -z "$pkg" ]]; then
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg="${cmd_to_pkg[$cmd]}"
    else
      pkg="$cmd"
    fi
  fi

  if command -v "$cmd" &>/dev/null; then
    return 0
  fi

  # Tier 2 服务依赖不自动安装
  local level
  level=$(get_dependency_level "$cmd")
  if [[ "$level" == "$DEP_LEVEL_SERVICE" ]]; then
    log_error "${cmd} 是服务级依赖，不会自动安装。请先运行对应模块"
    return 1
  fi

  if [[ -z "$pkg" ]]; then
    return 0
  fi

  apt_update_safe
  DEBIAN_FRONTEND=noninteractive apt install -y -qq "$pkg" 2>/dev/null
}

# 列出缺失依赖并给出手动安装建议
# 参数：命令列表
list_missing_dependencies() {
  local missing_cmds=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done
  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    log_info "所有依赖命令均已安装"
    return 0
  fi
  log_warning "以下依赖命令缺失："
  for cmd in "${missing_cmds[@]}"; do
    local level
    level=$(get_dependency_level "$cmd")
    local level_label=""
    case "$level" in
      "$DEP_LEVEL_SYSTEM")  level_label="[系统] 系统可能已损坏" ;;
      "$DEP_LEVEL_SERVICE") level_label="[服务] 请先运行对应模块" ;;
      *)                    level_label="[工具] 可自动安装" ;;
    esac
    echo "  - ${cmd} ${level_label}"
  done

  if ! has_valid_main_apt_source; then
    log_error "未检测到有效主软件源，请先配置软件源后再安装依赖。"
    return 1
  fi

  # 只对工具依赖给出 apt install 建议
  local has_installable=false
  for cmd in "${missing_cmds[@]}"; do
    local pkg_name=""
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg_name="${cmd_to_pkg[$cmd]}"
    fi
    if [[ -n "$pkg_name" ]]; then
      local level
      level=$(get_dependency_level "$cmd")
      if [[ "$level" == "$DEP_LEVEL_TOOL" ]]; then
        echo "apt install $pkg_name  # $cmd"
        has_installable=true
      fi
    fi
  done

  if ! $has_installable; then
    log_info "缺失的依赖无需通过 apt 安装（可能是系统命令或服务级依赖）"
  fi
}
