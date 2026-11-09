#!/bin/bash
# 功能：仪表盘系统概况采集（只读、快速）
# 说明：数据全部来自 /proc、/etc 与 bash 内置变量，单次采样 < 50ms；
#       根分区占用调用一次 df；IP 只在启动时取一次。
#       待更新包数只读 apt 本地缓存（apt-get -s upgrade，后台异步执行），
#       **绝不执行 apt update**，不联网。
# 输出：全局变量 _SI_*（避免子 shell）

set -euo pipefail
IFS=$'\n\t'

# 可覆盖路径（测试注入）
DEBNAS_PROC_DIR="${DEBNAS_PROC_DIR:-/proc}"
DEBNAS_OS_RELEASE="${DEBNAS_OS_RELEASE:-/etc/os-release}"

declare -g _SI_OS="" _SI_ARCH="" _SI_HOST="" _SI_IP=""
declare -g _SI_CPU=-1 _SI_MEM=-1 _SI_DISK=-1 _SI_UPTIME="" _SI_UPDATES="…"
declare -g _SI_CPU_PREV_TOTAL=0 _SI_CPU_PREV_IDLE=0
declare -g _SI_UPDATES_FILE="" _SI_UPDATES_PID=""

# 静态信息：系统版本 / 架构 / 主机名 / 主 IP（启动时调用一次）
ui_sysinfo_static() {
  local line id="" ver="" code="" name=""
  if [[ -r "$DEBNAS_OS_RELEASE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        ID=*)               id="${line#ID=}" ;;
        NAME=*)             name="${line#NAME=}" ;;
        VERSION_ID=*)       ver="${line#VERSION_ID=}" ;;
        VERSION_CODENAME=*) code="${line#VERSION_CODENAME=}" ;;
      esac
    done < "$DEBNAS_OS_RELEASE"
  fi
  id="${id//\"/}" ver="${ver//\"/}" code="${code//\"/}" name="${name//\"/}"
  if [[ "$id" == "debian" ]]; then
    _SI_OS="Debian${ver:+ $ver}${code:+ $code}"
  else
    _SI_OS="${name:-Linux}${ver:+ $ver}"
  fi

  case "${HOSTTYPE:-}" in
    x86_64)  _SI_ARCH="amd64" ;;
    aarch64) _SI_ARCH="arm64" ;;
    i?86)    _SI_ARCH="i386" ;;
    arm*)    _SI_ARCH="armhf" ;;
    *)       _SI_ARCH="${HOSTTYPE:-unknown}" ;;
  esac
  _SI_HOST="${HOSTNAME:-$(uname -n 2>/dev/null || echo localhost)}"

  # 主 IP：默认路由所在网卡的 IPv4 地址
  _SI_IP=""
  local iface="" dest rest
  if [[ -r "${DEBNAS_PROC_DIR}/net/route" ]]; then
    while IFS=$' \t' read -r rest dest _; do
      if [[ "$dest" == "00000000" ]]; then iface="$rest"; break; fi
    done < "${DEBNAS_PROC_DIR}/net/route"
  fi
  if [[ -n "$iface" ]] && command -v ip &>/dev/null; then
    local out
    out=$(ip -4 -o addr show dev "$iface" 2>/dev/null) || out=""
    if [[ "$out" =~ inet[[:space:]]([0-9.]+)/ ]]; then
      _SI_IP="${BASH_REMATCH[1]}"
    fi
  fi
  if [[ -z "$_SI_IP" ]] && command -v hostname &>/dev/null; then
    local all
    all=$(hostname -I 2>/dev/null) || all=""
    _SI_IP="${all%% *}"
    _SI_IP="${_SI_IP%%$'\n'*}"
  fi
  [[ -n "$_SI_IP" ]] || _SI_IP="无网络"
  return 0
}

# 把秒数格式化为中文运行时长（3天4小时 / 4小时12分 / 12分）
# 参数：$1 — 秒数（整数）
# 输出：全局 _SI_UPTIME
_ui_sysinfo_fmt_uptime() {
  local s=$1 d h m
  d=$(( s / 86400 )); h=$(( s % 86400 / 3600 )); m=$(( s % 3600 / 60 ))
  if (( d > 0 )); then
    _SI_UPTIME="${d}天${h}小时"
  elif (( h > 0 )); then
    _SI_UPTIME="${h}小时${m}分"
  else
    _SI_UPTIME="${m}分"
  fi
}

# 动态采样：CPU（与上次采样的差值）/ 内存 / 根分区 / 运行时长
# 首次调用 CPU 无差值可用，_SI_CPU=-1（显示为 …），第二次起有效
# 参数：$1 — 1=同时采样根分区（调用 df，默认 1）
ui_sysinfo_sample() {
  local with_disk="${1:-1}"
  local cpu u n s i io irq sirq st total idle
  if [[ -r "${DEBNAS_PROC_DIR}/stat" ]] \
    && IFS=$' \t' read -r cpu u n s i io irq sirq st _ < "${DEBNAS_PROC_DIR}/stat" && [[ "$cpu" == "cpu" ]]; then
    total=$(( u + n + s + i + ${io:-0} + ${irq:-0} + ${sirq:-0} + ${st:-0} ))
    idle=$(( i + ${io:-0} ))
    if (( _SI_CPU_PREV_TOTAL > 0 && total > _SI_CPU_PREV_TOTAL )); then
      local dt=$(( total - _SI_CPU_PREV_TOTAL )) di=$(( idle - _SI_CPU_PREV_IDLE ))
      _SI_CPU=$(( (dt - di) * 100 / dt ))
      (( _SI_CPU < 0 )) && _SI_CPU=0
      (( _SI_CPU > 100 )) && _SI_CPU=100
    fi
    _SI_CPU_PREV_TOTAL=$total
    _SI_CPU_PREV_IDLE=$idle
  fi

  local key val mt=0 ma=-1
  if [[ -r "${DEBNAS_PROC_DIR}/meminfo" ]]; then
    while IFS=$' \t' read -r key val _; do
      case "$key" in
        MemTotal:)     mt=$val ;;
        MemAvailable:) ma=$val; break ;;
      esac
    done < "${DEBNAS_PROC_DIR}/meminfo"
    if (( mt > 0 && ma >= 0 )); then
      _SI_MEM=$(( (mt - ma) * 100 / mt ))
    fi
  fi

  local up
  if [[ -r "${DEBNAS_PROC_DIR}/uptime" ]] && IFS=$' \t' read -r up _ < "${DEBNAS_PROC_DIR}/uptime"; then
    _ui_sysinfo_fmt_uptime "${up%%.*}"
  fi

  if [[ "$with_disk" == "1" ]]; then
    local dfout pct
    dfout=$(df -P / 2>/dev/null) || dfout=""
    if [[ "$dfout" =~ [[:space:]]([0-9]+)%[[:space:]] ]]; then
      pct="${BASH_REMATCH[1]}"
      _SI_DISK=$(( 10#$pct ))
    fi
  fi
  return 0
}

# 后台统计待更新包数（只读 apt 本地缓存，不执行 apt update）
# 参数：$1 — 结果文件路径
ui_sysinfo_updates_start() {
  local out_file="$1"
  _SI_UPDATES="…"
  _SI_UPDATES_FILE="$out_file"
  if ! command -v apt-get &>/dev/null; then
    _SI_UPDATES="?"
    return 0
  fi
  # 跨会话缓存：apt 列表与 dpkg 状态的 mtime 未变时直接复用上次结果
  # （apt-get -s upgrade 在待更新包多时可能要十几秒）
  local cache="${DEBNAS_UPDATES_CACHE:-${DEBNAS_STATE_DIR:-/var/lib/debnas/state}/updates.cache}"
  local key="" ck="" cv=""
  key=$(stat -c '%Y' /var/lib/apt/lists /var/lib/dpkg/status 2>/dev/null | tr '\n' ':') || key=""
  if [[ -n "$key" && -r "$cache" ]] && IFS=' ' read -r ck cv < "$cache" && [[ "$ck" == "$key" && "$cv" =~ ^[0-9]+$ ]]; then
    _SI_UPDATES="$cv"
    return 0
  fi
  (
    n=$(LC_ALL=C apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst ') || true
    printf '%s\n' "${n:-?}" > "${out_file}.tmp" 2>/dev/null && mv -f "${out_file}.tmp" "$out_file" 2>/dev/null
    if [[ -n "$key" && "${n:-}" =~ ^[0-9]+$ && -d "${cache%/*}" && -w "${cache%/*}" ]]; then
      printf '%s %s\n' "$key" "$n" > "${cache}.tmp" 2>/dev/null && mv -f "${cache}.tmp" "$cache" 2>/dev/null
    fi
  ) </dev/null >/dev/null 2>&1 &
  _SI_UPDATES_PID=$!
  return 0
}

# 读取后台统计结果
# 返回：0 已有结果（含失败 ?），1 仍在统计
ui_sysinfo_updates_poll() {
  [[ "$_SI_UPDATES" == "…" ]] || return 0
  [[ -n "$_SI_UPDATES_FILE" ]] || return 0
  if [[ -f "$_SI_UPDATES_FILE" ]]; then
    local v=""
    read -r v < "$_SI_UPDATES_FILE" || true
    [[ "$v" =~ ^[0-9]+$ ]] && _SI_UPDATES="$v" || _SI_UPDATES="?"
    return 0
  fi
  if [[ -n "$_SI_UPDATES_PID" ]] && ! kill -0 "$_SI_UPDATES_PID" 2>/dev/null; then
    _SI_UPDATES="?"
    return 0
  fi
  return 1
}

# 停止后台统计（退出仪表盘时调用）
ui_sysinfo_updates_stop() {
  if [[ -n "$_SI_UPDATES_PID" ]]; then
    kill "$_SI_UPDATES_PID" 2>/dev/null || true
    _SI_UPDATES_PID=""
  fi
  return 0
}
