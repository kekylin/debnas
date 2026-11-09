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
  ["sar"]="sysstat"
  ["sadc"]="sysstat"
  ["smartctl"]="smartmontools"
  ["sensors"]="lm-sensors"
  ["wtmpdb"]="wtmpdb"
  ["virsh"]="libvirt-clients"
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
  ["sar"]="$DEP_LEVEL_TOOL"
  ["sadc"]="$DEP_LEVEL_TOOL"
  ["smartctl"]="$DEP_LEVEL_TOOL"
  ["sensors"]="$DEP_LEVEL_TOOL"
  ["wtmpdb"]="$DEP_LEVEL_TOOL"

  # ── Tier 2：服务依赖（安装后产生 daemon/服务，需用户确认）──
  ["docker"]="$DEP_LEVEL_SERVICE"
  ["firewall-cmd"]="$DEP_LEVEL_SERVICE"
  ["msmtp"]="$DEP_LEVEL_SERVICE"
  ["mail"]="$DEP_LEVEL_SERVICE"
  ["exim4"]="$DEP_LEVEL_SERVICE"
  ["update-exim4.conf"]="$DEP_LEVEL_SERVICE"
  ["nmcli"]="$DEP_LEVEL_SERVICE"
  ["virsh"]="$DEP_LEVEL_SERVICE"
)

# ==================== 内部函数 ====================

# 内部函数的输出（避免命令替换产生子 shell）
declare -g _DEP_LEVEL=""
declare -g -a _DEP_MISSING=() _DEP_FAILED=()

# 计算命令的依赖级别，写入全局 _DEP_LEVEL（不经命令替换，循环中不 fork 子 shell）
# 参数：$1 - 命令名
_dep_level_of() {
  local cmd="$1"
  if [[ -v "cmd_to_level[$cmd]" ]]; then
    _DEP_LEVEL="${cmd_to_level[$cmd]}"
  elif [[ -v "cmd_to_pkg[$cmd]" && -z "${cmd_to_pkg[$cmd]}" ]]; then
    # 映射表中包名为空 = 系统自带命令
    _DEP_LEVEL="$DEP_LEVEL_SYSTEM"
  else
    # 保守默认：未知命令视为工具依赖
    _DEP_LEVEL="$DEP_LEVEL_TOOL"
  fi
}

# 筛出不存在的命令，写入全局数组 _DEP_MISSING
# 参数：命令列表
_dep_filter_missing() {
  local cmd
  _DEP_MISSING=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || _DEP_MISSING+=("$cmd")
  done
}

# 逐行列出缺失命令及其软件包（"  - cmd （软件包: pkg）"）
# 参数：命令列表
_dep_print_missing() {
  local cmd pkg_name
  for cmd in "$@"; do
    pkg_name="${cmd_to_pkg[$cmd]:-}"
    printf "  - %s" "$cmd"
    if [[ -n "$pkg_name" ]]; then
      printf " （软件包: %s）" "$pkg_name"
    fi
    printf "\n"
  done
}

# 逐个 apt install 命令对应的软件包（调用方已完成 apt update），失败的命令写入全局数组 _DEP_FAILED
# 参数：命令列表（无包映射的命令告警后跳过）
_dep_install_cmds() {
  local cmd pkg_name
  _DEP_FAILED=()
  for cmd in "$@"; do
    pkg_name="${cmd_to_pkg[$cmd]:-}"
    if [[ -z "$pkg_name" ]]; then
      log_warning "无法确定 ${cmd} 的软件包名"
      continue
    fi
    if DEBIAN_FRONTEND=noninteractive apt install -y -qq "$pkg_name" 2>/dev/null; then
      log_success "${cmd} 就绪"
    else
      log_error "${cmd} 安装失败"
      _DEP_FAILED+=("$cmd")
    fi
  done
}

# ==================== 公共接口 ====================

# 获取命令的依赖级别
# 参数：$1 - 命令名
# 输出：system / tool / service
get_dependency_level() {
  local cmd="${1:?get_dependency_level: 缺少命令名}"
  _dep_level_of "$cmd"
  echo "$_DEP_LEVEL"
}

# 检查依赖命令是否存在（兼容旧接口，不区分级别）
# 参数：命令列表
# 返回：0 全部存在，1 有缺失
check_dependencies() {
  local cmd
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
  local IFS=' '  # 日志中 "${arr[*]}" 以空格连接命令名（全局 IFS 首字符是换行）
  _dep_filter_missing "$@"
  if [[ ${#_DEP_MISSING[@]} -gt 0 ]]; then
    log_fatal_return "系统基础命令缺失：${_DEP_MISSING[*]}" || true
    log_fatal_return "这些命令应由 Debian 最小化安装提供，系统可能已损坏" || true
    return 1
  fi
  return 0
}

# ── Tier 1 检查+自动安装：工具依赖 ──
# 检查缺失的工具命令，自动安装对应软件包
# 参数：命令列表
# 返回：0 全部就绪，1 部分安装失败（不阻断，模块自行处理）
check_and_install_tool_deps() {
  local IFS=' '  # 日志中 "${arr[*]}" 以空格连接命令名（全局 IFS 首字符是换行）
  _dep_filter_missing "$@"
  if [[ ${#_DEP_MISSING[@]} -eq 0 ]]; then
    return 0
  fi
  local -a missing=("${_DEP_MISSING[@]}")

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

  _dep_install_cmds "${missing[@]}"
  if [[ ${#_DEP_FAILED[@]} -gt 0 ]]; then
    log_warning "以下工具安装失败：${_DEP_FAILED[*]}，模块将自行处理"
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
  _dep_filter_missing "$@"
  if [[ ${#_DEP_MISSING[@]} -eq 0 ]]; then
    return 0
  fi

  log_error "以下服务级依赖未安装："
  _dep_print_missing "${_DEP_MISSING[@]}"
  log_error "服务级依赖不会自动安装。请先运行对应的模块（如 firewall、docker-ce 等）"
  return 1
}

# 检查主软件源是否已配置（sources.list 中有 deb 行，或 debian.sources 中有 Types: deb）
has_valid_main_apt_source() {
  grep -qE '^[[:space:]]*deb[[:space:]]+' /etc/apt/sources.list 2>/dev/null && return 0
  if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    grep -qE '^[[:space:]]*Types:[[:space:]]*deb' /etc/apt/sources.list.d/debian.sources 2>/dev/null && return 0
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

  local cmd
  for cmd in "$@"; do
    _dep_level_of "$cmd"
    case "$_DEP_LEVEL" in
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

# 确保模块依赖全部就绪（命令依赖 + 模块依赖的组合入口）
# 供交互式模块在具体操作前调用，实现延迟依赖检查
# 参数：$1 - 模块名
# 返回：0 全部就绪，1 有缺失
ensure_module_deps() {
  local module_name="${1:?ensure_module_deps: 缺少模块名}"

  # ── 命令依赖（@depends）──
  local depends_str
  depends_str=$(get_module_field "$module_name" "depends" "" 2>/dev/null) || depends_str=""
  if [[ -n "$depends_str" ]]; then
    local -a dep_cmds=()
    IFS=' ,' read -ra dep_cmds <<< "$depends_str"
    local -a clean_cmds=()
    local cmd
    for cmd in "${dep_cmds[@]}"; do
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      cmd="${cmd%"${cmd##*[![:space:]]}"}"
      [[ -n "$cmd" ]] || continue
      clean_cmds+=("$cmd")
    done
    if [[ ${#clean_cmds[@]} -gt 0 ]]; then
      log_info "检查依赖命令：${depends_str}"
      check_dependencies_by_level "${clean_cmds[@]}" || return 1
    fi
  fi

  # ── 模块依赖（@depend_modules）──
  local dep_modules
  dep_modules=$(get_module_field "$module_name" "depend_modules" "" 2>/dev/null) || dep_modules=""
  if [[ -n "$dep_modules" ]]; then
    log_info "检查依赖模块：${dep_modules}"
    local -a not_ready=()
    mapfile -t not_ready < <(check_module_deps_ready "$module_name" 2>/dev/null) || not_ready=()
    if [[ ${#not_ready[@]} -gt 0 ]]; then
      log_error "以下依赖模块尚未完成，请先执行："
      local nd
      for nd in "${not_ready[@]}"; do
        local nd_name
        nd_name=$(get_module_field "$nd" "name" "$nd" 2>/dev/null) || nd_name="$nd"
        echo "  debnas run ${nd}   # ${nd_name}"
      done
      return 1
    fi
    log_info "依赖模块已全部就绪：${dep_modules}"
  fi

  return 0
}

# 自动安装缺失依赖（兼容旧接口，仅安装 Tier 1 工具依赖，Tier 2 只检查不安装）
# 参数：命令列表
# 返回：0 全部就绪，1 有缺失
install_missing_dependencies() {
  local IFS=' '  # 日志中 "${arr[*]}" 以空格连接命令名（全局 IFS 首字符是换行）
  _dep_filter_missing "$@"
  if [[ ${#_DEP_MISSING[@]} -eq 0 ]]; then
    return 0
  fi

  # 按级别分流处理
  local -a tool_cmds=()
  local -a service_cmds=()
  local -a system_cmds=()
  local cmd

  for cmd in "${_DEP_MISSING[@]}"; do
    _dep_level_of "$cmd"
    case "$_DEP_LEVEL" in
      "$DEP_LEVEL_SYSTEM")
        system_cmds+=("$cmd")
        ;;
      "$DEP_LEVEL_TOOL")
        # 只处理有包映射的命令
        [[ -n "${cmd_to_pkg[$cmd]:-}" ]] && tool_cmds+=("$cmd")
        ;;
      "$DEP_LEVEL_SERVICE")
        service_cmds+=("$cmd")
        ;;
    esac
  done

  # Tier 0 系统命令缺失 → 致命
  if [[ ${#system_cmds[@]} -gt 0 ]]; then
    log_warning "发现缺失的依赖命令：${system_cmds[*]}"
    log_fatal_return "系统基础命令缺失：${system_cmds[*]}，系统可能已损坏" || true
    return 1
  fi

  # Tier 2 服务依赖 → 提示，不安装
  if [[ ${#service_cmds[@]} -gt 0 ]]; then
    log_warning "发现缺失的依赖命令：${service_cmds[*]}"
    log_error "以下服务级依赖未安装，请先运行对应模块："
    _dep_print_missing "${service_cmds[@]}"
    return 1
  fi

  # Tier 1 工具依赖 → 自动安装
  if [[ ${#tool_cmds[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "自动安装缺失工具依赖：${tool_cmds[*]}"
  if ! has_valid_main_apt_source; then
    log_warning "未检测到有效主软件源，跳过自动安装（模块将自行处理）"
    return 1
  fi

  log_info "更新索引..."
  if ! DEBIAN_FRONTEND=noninteractive apt update -qq 2>/dev/null; then
    log_error "apt update 失败，跳过自动安装"
    return 1
  fi

  # 旧实现返回最后一条 log 的状态（恒为 0），安装失败也报"就绪"
  _dep_install_cmds "${tool_cmds[@]}"
  [[ ${#_DEP_FAILED[@]} -eq 0 ]]
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
  _dep_level_of "$cmd"
  if [[ "$_DEP_LEVEL" == "$DEP_LEVEL_SERVICE" ]]; then
    log_error "${cmd} 是服务级依赖，不会自动安装。请先运行对应模块"
    return 1
  fi

  if [[ -z "$pkg" ]]; then
    return 0
  fi

  apt_update_safe || log_warning "APT 索引更新失败，使用现有缓存继续安装"
  DEBIAN_FRONTEND=noninteractive apt install -y -qq "$pkg" 2>/dev/null
}
