#!/usr/bin/env bats
# 测试: modules/cockpit-net.sh — 网络管理器模块
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/cockpit-net.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "cockpit-net: @module 为 cockpit-net" {
  result=$(parse_meta "module")
  [[ "$result" == "cockpit-net" ]]
}

@test "cockpit-net: @name 为 网络管理器" {
  result=$(parse_meta "name")
  [[ "$result" == "网络管理器" ]]
}

@test "cockpit-net: @category 为 管理面板" {
  result=$(parse_meta "category")
  [[ "$result" == "管理面板" ]]
}

@test "cockpit-net: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "cockpit-net: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "cockpit-net: @depend_modules 声明依赖 cockpit" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"cockpit"* ]]
}

# ==================== 语法验证 ====================

@test "cockpit-net: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "cockpit-net: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "cockpit-net: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "cockpit-net: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "cockpit-net: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "cockpit-net: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "cockpit-net: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "cockpit-net: 使用 write_file_if_changed 安全写入" {
  grep -q 'write_file_if_changed' "$MODULE_FILE"
}

@test "cockpit-net: 操作 /etc/network/interfaces 文件" {
  grep -q '/etc/network/interfaces' "$MODULE_FILE"
}

@test "cockpit-net: 操作 /etc/NetworkManager/NetworkManager.conf 文件" {
  grep -q '/etc/NetworkManager/NetworkManager.conf' "$MODULE_FILE"
}

@test "cockpit-net: 设置 managed=true 开启网络管理" {
  grep -q 'managed=true' "$MODULE_FILE"
}

@test "cockpit-net: 检测 nmcli 或 NetworkManager 服务存在性" {
  grep -q 'nmcli' "$MODULE_FILE"
  grep -q 'NetworkManager' "$MODULE_FILE"
}

@test "cockpit-net: config_changed 变量跟踪配置变更" {
  grep -q 'config_changed=0' "$MODULE_FILE"
}

@test "cockpit-net: 使用 service_ensure 管理 NetworkManager 服务" {
  grep -q 'service_ensure.*NetworkManager' "$MODULE_FILE"
}

@test "cockpit-net: 使用 service_ensure 管理 cockpit 服务" {
  grep -q 'service_ensure.*cockpit' "$MODULE_FILE"
}

@test "cockpit-net: 调用 check_dependencies 检查必备命令" {
  grep -q 'check_dependencies' "$MODULE_FILE"
}

# ==================== 回归：静态 IP 保护 ====================

@test "cockpit-net: 检测到 ifupdown 静态配置时中止，且检测位于注释 interfaces 之前" {
  local detect_line comment_line
  detect_line=$(grep -n 'static_ifaces=\$(_cnet_static_ifaces)' "$MODULE_FILE" | head -1 | cut -d: -f1)
  comment_line=$(grep -n "commented_interfaces=" "$MODULE_FILE" | head -1 | cut -d: -f1)
  [[ -n "$detect_line" && -n "$comment_line" ]]
  [[ "$detect_line" -lt "$comment_line" ]]
}

@test "cockpit-net: NetworkManager 未安装时先退出，不改动 interfaces" {
  local nm_line comment_line
  nm_line=$(grep -n 'NetworkManager 未安装' "$MODULE_FILE" | head -1 | cut -d: -f1)
  comment_line=$(grep -n "commented_interfaces=" "$MODULE_FILE" | head -1 | cut -d: -f1)
  [[ "$nm_line" -lt "$comment_line" ]]
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 探测方式与 lib/system/module-probe.sh 一致：预加载库 + _DEBNAS_BOOTSTRAPPED=1 + DEBNAS_MODULE_ACTION=status|plan 后 source。
# source 期间把常见"执行动作"类函数替换为写标记文件，用于断言探测时 main 未执行。

# 参数：$1 — status|plan|eval，$2 — 标记文件，$3 — eval 时在 source 后执行的脚本片段
_contract_probe() {
  local action="$1" marker="$2" snippet="${3:-}"
  local probe_action="$action"
  [[ "$action" == "eval" ]] && probe_action="status"
  DEBNAS_MODULE_ACTION="$probe_action" _CT_MARKER="$marker" _CT_SNIPPET="$snippet" \
    bash -c '
      set -euo pipefail
      source "$1/lib/bootstrap.sh" >/dev/null 2>&1 || exit 90
      _DEBNAS_BOOTSTRAPPED=1
      _CT_SOURCING=1
      _ct_mark() { [[ -n "${_CT_SOURCING:-}" ]] && echo "$1" >> "$_CT_MARKER"; return 0; }
      log_info() { _ct_mark log_info; }
      log_success() { _ct_mark log_success; }
      log_warning() { _ct_mark log_warning; }
      log_error() { _ct_mark log_error; }
      ui_progress_step() { _ct_mark ui_progress_step; }
      ui_menu() { _ct_mark ui_menu; return 255; }
      register_temp_cleanup() { _ct_mark register_temp_cleanup; }
      create_temp_file() { _ct_mark create_temp_file; echo /dev/null; }
      check_dependencies() { _ct_mark check_dependencies; return 0; }
      apt_install_packages() { _ct_mark apt_install_packages; return 0; }
      service_ensure() { _ct_mark service_ensure; return 0; }
      write_file_if_changed() { _ct_mark write_file_if_changed; return 1; }
      source "$2" </dev/null >/dev/null 2>&1 || exit 91
      unset _CT_SOURCING
      case "$DEBNAS_MODULE_ACTION" in
        status) if [[ -n "$_CT_SNIPPET" ]]; then source /dev/stdin <<< "$_CT_SNIPPET"; else module_status; fi ;;
        plan) module_plan ;;
      esac
    ' _ "$DEBNAS_ROOT" "$MODULE_FILE" </dev/null 2>/dev/null
}

_contract_status_ok() {
  [[ "$(printf '%s\n' "$1" | grep -c .)" -eq 1 ]] || return 1
  [[ "$1" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+$ ]]
}

_contract_plan_ok() {
  local line n=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.*$ ]] || return 1
    n=$((n + 1))
  done <<< "$1"
  [[ $n -gt 0 ]]
}

@test "cockpit-net: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "cockpit-net: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "cockpit-net: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-cockpit-net-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "cockpit-net: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-cockpit-net-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "cockpit-net: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-cockpit-net-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "cockpit-net: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status cockpit-net
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan cockpit-net
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

@test "cockpit-net: 存在 ifupdown 静态配置时 status=warn、plan 给出跳过风险提示" {
  run _contract_probe eval /dev/null '
    _cnet_nm_installed() { return 0; }
    _cnet_static_ifaces() { echo "/etc/network/interfaces: iface eth0 inet static"; }
    module_status
    module_plan'
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == warn\|* ]]
  [[ "$output" == *"risk|/etc/network/interfaces|"*"跳过"* ]]
  [[ "$output" != *"write|"* ]]
}

@test "cockpit-net: 未安装 NetworkManager 时 status=absent，plan 不列写入" {
  run _contract_probe eval /dev/null '
    _cnet_nm_installed() { return 1; }
    module_status
    module_plan'
  [[ "${lines[0]}" == "absent|未安装 NetworkManager" ]]
  [[ "$output" != *"write|"* ]]
}

@test "cockpit-net: 网卡仍由 ifupdown 管理时 status=absent" {
  run _contract_probe eval /dev/null '
    _cnet_nm_installed() { return 0; }
    _cnet_static_ifaces() { :; }
    _cnet_other_managers() { :; }
    _cnet_ifupdown_ifaces() { printf "eth0"; }
    _cnet_ifupdown_active_lines() { echo 4; }
    _cnet_nm_managed() { return 1; }
    systemctl() { return 0; }
    module_status'
  [[ "$output" == "absent|网卡 eth0 仍由 ifupdown 管理" ]]
}

# ==================== 审计修复回归（2026-11-10） ====================

@test "cockpit-net: 递归解析 source / source-directory 引入文件中的静态配置 (B3)" {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/interfaces.d" "$tmp/more"
  printf 'auto lo\niface lo inet loopback\nsource interfaces.d/*\nsource-directory %s/more\n' "$tmp" > "$tmp/interfaces"
  printf 'source %s/interfaces\niface eth0 inet static\n  address 10.1.1.5/24\n' "$tmp" > "$tmp/interfaces.d/eth0"
  printf 'iface br0 inet dhcp\n  bridge_ports eth1\n' > "$tmp/more/br0"
  printf 'iface eth9 inet static\n' > "$tmp/more/skip.conf"
  run _contract_probe eval /dev/null "
    _CNET_IFACES_FILE='$tmp/interfaces'
    _cnet_static_ifaces"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"interfaces.d/eth0: iface eth0 inet static"* ]]
  [[ "$output" == *"more/br0: bridge_ports eth1"* ]]
  # source-directory 只取 ^[a-zA-Z0-9_-]+$ 的文件名
  [[ "$output" != *"eth9"* ]]
}

@test "cockpit-net: DHCP 网卡带 bond/vlan/wpa/pre-up/up 等指令也拒绝 (B3)" {
  local tmp
  tmp=$(mktemp -d)
  printf 'iface eth0 inet dhcp\n  pre-up /sbin/ethtool -s eth0 wol g\n  wpa-ssid home\niface bond0 inet dhcp\n  bond-slaves eth1 eth2\niface eth1.10 inet dhcp\n  vlan-raw-device eth1\n  up ip route add 1.2.3.0/24 dev eth1.10\n' > "$tmp/interfaces"
  run _contract_probe eval /dev/null "
    _CNET_IFACES_FILE='$tmp/interfaces'
    _cnet_static_ifaces"
  rm -rf "$tmp"
  [[ "$output" == *": pre-up /sbin/ethtool"* ]]
  [[ "$output" == *": wpa-ssid home"* ]]
  [[ "$output" == *": bond-slaves eth1 eth2"* ]]
  [[ "$output" == *": vlan-raw-device eth1"* ]]
  [[ "$output" == *": up ip route add"* ]]
}

@test "cockpit-net: 存在 netplan / systemd-networkd 配置时 main 告警跳过（返回 0）且不改任何文件 (B3)" {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/netplan" "$tmp/network"
  printf 'network:\n  version: 2\n' > "$tmp/netplan/50-cloud-init.yaml"
  printf '[main]\nplugins=ifupdown,keyfile\n\n[ifupdown]\nmanaged=false\n' > "$tmp/NetworkManager.conf"
  run _contract_probe eval /dev/null "
    _CNET_IFACES_FILE='$tmp/interfaces'
    _CNET_NM_CONF='$tmp/NetworkManager.conf'
    _CNET_NETPLAN_DIR='$tmp/netplan'
    _CNET_NETWORKD_DIR='$tmp/network'
    _cnet_nm_installed() { return 0; }
    _cnet_cockpit_call() { echo \"GUARD \$1\" >&2; }
    write_file_if_changed() { echo WRITE; return 0; }
    service_ensure() { echo SERVICE; return 0; }
    rc=0; ( main ) || rc=\$?
    echo RC=\$rc
    module_status"
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" != *"WRITE"* ]]
  [[ "$output" != *"SERVICE"* ]]
  [[ "$output" == *"warn|"*"50-cloud-init.yaml"* ]]
  rm -f "$tmp/netplan/50-cloud-init.yaml"
  printf '[Match]\nName=eth0\n' > "$tmp/network/10-eth0.network"
  run _contract_probe eval /dev/null "
    _CNET_NETPLAN_DIR='$tmp/netplan'
    _CNET_NETWORKD_DIR='$tmp/network'
    _cnet_other_managers"
  rm -rf "$tmp"
  [[ "$output" == *"10-eth0.network: systemd-networkd"* ]]
}

@test "cockpit-net: 存在 ifupdown 静态配置时 main 告警跳过（返回 0），不注释 interfaces、不重启 NM" {
  local tmp
  tmp=$(mktemp -d)
  printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet static\n  address 192.168.1.10/24\n' > "$tmp/interfaces"
  printf '[main]\nplugins=ifupdown,keyfile\n' > "$tmp/NetworkManager.conf"
  run _contract_probe eval /dev/null "
    _CNET_IFACES_FILE='$tmp/interfaces'
    _CNET_NM_CONF='$tmp/NetworkManager.conf'
    _CNET_NETPLAN_DIR='$tmp/netplan'
    _CNET_NETWORKD_DIR='$tmp/network'
    _cnet_nm_installed() { return 0; }
    write_file_if_changed() { echo WRITE; return 0; }
    service_ensure() { echo SERVICE; return 0; }
    rc=0; ( main ) || rc=\$?
    echo RC=\$rc"
  local ifaces; ifaces=$(<"$tmp/interfaces")
  rm -rf "$tmp"
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" != *"WRITE"* ]]
  [[ "$output" != *"SERVICE"* ]]
  [[ "$ifaces" == *"iface eth0 inet static"* ]]
}

# ==================== 跟进修复回归（2026-11-10）：netplan/networkd 系统上让 NM 放开网卡 ====================

@test "cockpit-net: netplan/networkd 系统跳过切换时调用 cockpit 模块的 configure_nm_networkd_guard，并提示如何移除片段" {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/netplan" "$tmp/network"
  printf 'network:\n  version: 2\n' > "$tmp/netplan/50-cloud-init.yaml"
  run env _CT_LOG=1 DEBNAS_MODULE_ACTION=status bash -c '
    set -euo pipefail
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    source "$2" </dev/null
    _CNET_IFACES_FILE="$3/interfaces"
    _CNET_NM_CONF="$3/NetworkManager.conf"
    _CNET_NETPLAN_DIR="$3/netplan"
    _CNET_NETWORKD_DIR="$3/network"
    _cnet_nm_installed() { return 0; }
    check_dependencies() { return 0; }
    _cnet_cockpit_call() { echo "GUARD $1"; }
    service_ensure() { echo SERVICE; return 0; }
    rc=0; ( main ) || rc=$?
    echo "RC=$rc"
  ' _ "$DEBNAS_ROOT" "$MODULE_FILE" "$tmp" 2>&1
  rm -rf "$tmp"
  [[ "$output" == *"GUARD configure_nm_networkd_guard"* ]]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" != *"SERVICE"* ]]
  [[ "$output" == *"10-debnas-unmanaged.conf"*"systemctl reload NetworkManager"* ]]
}

@test "cockpit-net: _cnet_cockpit_call 在子 shell 加载 cockpit 模块函数，不执行其 main、不污染本模块函数" {
  run env DEBNAS_MODULE_ACTION=status bash -c '
    set -euo pipefail
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    source "$2" </dev/null
    apt_install_packages() { echo MAIN-RAN; }
    _cnet_cockpit_call _cockpit_nm_guard_render eth0 >/dev/null
    out=$(_cnet_cockpit_call _cockpit_nm_guard_state)
    echo "STATE=${out%%|*}"
    declare -f module_status | grep -q _cnet_blockers && echo OWN-STATUS-KEPT
  ' _ "$DEBNAS_ROOT" "$MODULE_FILE" 2>&1
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"MAIN-RAN"* ]]
  [[ "$output" =~ STATE=(none|ok|missing|conflict|unwritten-conflict|stale) ]]
  [[ "$output" == *"OWN-STATUS-KEPT"* ]]
}

@test "cockpit-net: NM 与 networkd 同管网卡时 status 给出 warn 并说明执行本模块会让 NM 放开" {
  run _contract_probe eval /dev/null '
    _cnet_nm_installed() { return 0; }
    _cnet_static_ifaces() { :; }
    _cnet_other_managers() { echo "/etc/netplan/50-cloud-init.yaml: netplan 配置"; }
    _cnet_cockpit_call() { case "$1" in _cockpit_nm_guard_state) echo "unwritten-conflict|eth0" ;; _cockpit_nm_guard_plan) echo "write|/etc/NetworkManager/conf.d/10-debnas-unmanaged.conf|x" ;; esac; }
    module_status
    module_plan'
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "warn|网卡 eth0 被 NetworkManager 与 systemd-networkd 同时管理"* ]]
  [[ "$output" == *"write|/etc/NetworkManager/conf.d/10-debnas-unmanaged.conf|"* ]]
}
