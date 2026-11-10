#!/usr/bin/env bats
# 测试: modules/cockpit.sh — 安装 Cockpit 面板模块 (TC-P1-MOD-001)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/cockpit.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "cockpit: @module 为 cockpit" {
  result=$(parse_meta "module")
  [[ "$result" == "cockpit" ]]
}

@test "cockpit: @name 为 安装 Cockpit 面板" {
  result=$(parse_meta "name")
  [[ "$result" == "安装 Cockpit 面板" ]]
}

@test "cockpit: @category 为 管理面板" {
  result=$(parse_meta "category")
  [[ "$result" == "管理面板" ]]
}

@test "cockpit: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "cockpit: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "cockpit: @depends 声明 curl 依赖" {
  result=$(parse_meta "depends")
  [[ "$result" == *"curl"* ]]
}

# ==================== 语法验证 ====================

@test "cockpit: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "cockpit: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "cockpit: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "cockpit: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "cockpit: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "cockpit: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "cockpit: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 函数定义验证 ====================

@test "cockpit: install_core_cockpit_packages 函数已定义" {
  grep -q '^install_core_cockpit_packages()' "$MODULE_FILE"
}

@test "cockpit: configure_cockpit_runtime_files 函数已定义" {
  grep -q '^configure_cockpit_runtime_files()' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "cockpit: main 验证系统代号为 bookworm 或 trixie" {
  grep -A20 '^main()' "$MODULE_FILE" | grep -q 'bookworm.*trixie'
}

@test "cockpit: 不支持的版本使用 ERROR_UNSUPPORTED_OS 退出" {
  grep -A25 '^main()' "$MODULE_FILE" | grep -q 'ERROR_UNSUPPORTED_OS'
}

@test "cockpit: 调用 configure_cockpit_pinning 配置 APT Pinning" {
  grep -q 'configure_cockpit_pinning' "$MODULE_FILE"
}

@test "cockpit: 调用 apply_pinning_config 应用 Pinning 配置" {
  grep -q 'apply_pinning_config' "$MODULE_FILE"
}

@test "cockpit: 调用 apt_install_packages 安装 Cockpit 组件" {
  grep -q 'apt_install_packages' "$MODULE_FILE"
}

@test "cockpit: 安装包列表包含 cockpit 核心包" {
  grep -A5 'install_core_cockpit_packages()' "$MODULE_FILE" | grep -q 'cockpit'
}

@test "cockpit: 使用 write_file_if_changed 写入 cockpit.conf" {
  grep -q 'conf_path="/etc/cockpit/cockpit.conf"' "$MODULE_FILE"
  grep -qF 'write_file_if_changed "$conf_path"' "$MODULE_FILE"
}

@test "cockpit: X-Forwarded 头仅在 cockpit_behind_proxy=1 时写入" {
  grep -q 'cockpit_behind_proxy' "$MODULE_FILE"
}

@test "cockpit: 用户自定义的 cockpit.conf 不被覆盖（DebNAS 管理标记）" {
  grep -q 'local marker=' "$MODULE_FILE"
  grep -qF 'grep -qxF "$marker"' "$MODULE_FILE"
}

@test "cockpit: 使用 write_file_if_changed 写入 motd" {
  grep -q 'write_file_if_changed.*motd' "$MODULE_FILE"
}

@test "cockpit: 调用 service_ensure 管理 cockpit 服务" {
  grep -q 'service_ensure.*cockpit' "$MODULE_FILE"
}

@test "cockpit: 调用 get_system_name 获取系统名称" {
  grep -q 'get_system_name' "$MODULE_FILE"
}

@test "cockpit: 调用 get_system_codename 获取系统代号" {
  grep -q 'get_system_codename' "$MODULE_FILE"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/cockpit.sh"
PROBE_STATE="${BATS_TMPDIR}/cockpit-probe-state"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="$PROBE_STATE" DEBNAS_FEATURE_DIR="$PROBE_STATE" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "cockpit-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "cockpit-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "cockpit-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "cockpit-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="$PROBE_STATE" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "cockpit-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "cockpit-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "cockpit-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="$PROBE_STATE" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status cockpit
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

# ==================== cockpit-files 候选版本（Debian 12 主仓/backports 均无该包） ====================

# 以 plan 动作加载模块，按参数模拟 apt-cache 候选版本后执行一段代码
# 参数：$1 cockpit-files 的 Candidate 值（如 "(none)" / "337-1"）；$2 要执行的 bash 代码
_cand_call() {
  DEBNAS_MODULE_ACTION=plan DEBNAS_STATE_DIR="$PROBE_STATE" DEBNAS_FEATURE_DIR="$PROBE_STATE" CAND="$1" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3
      pkg_is_installed() { return 1; }
      apt-cache() { local c="1.0"; [[ "$2" == "cockpit-files" ]] && c="$CAND"; printf "%s:\n  Installed: (none)\n  Candidate: %s\n" "$2" "$c"; }
      get_system_codename() { echo bookworm; }
      log_warning() { echo "WARN:$*"; }
      log_info() { :; }
      log_success() { :; }
      apt_install_packages() { echo "INSTALL:$*"; }
      eval "$2"' _ "$PROBE_FILE" "$2" 2>/dev/null </dev/null
}

@test "cockpit: _cockpit_pkg_has_candidate 按 Candidate 行判断" {
  run _cand_call "(none)" '_cockpit_pkg_has_candidate cockpit-files && echo Y || echo N; _cockpit_pkg_has_candidate cockpit && echo Y || echo N'
  [[ "$output" == $'N\nY' ]]
}

@test "cockpit: 无 cockpit-files 候选版本时安装跳过该包并告警，模块继续" {
  run _cand_call "(none)" 'install_core_cockpit_packages; echo RC=$?'
  [[ "$output" == *"WARN:当前软件源无 cockpit-files"* ]]
  [[ "$output" == *"INSTALL:cockpit pcp python3-pcp tuned"* ]]
  [[ "$output" == *"RC=0"* ]]
}

@test "cockpit: 有 cockpit-files 候选版本时照常安装" {
  run _cand_call "1.0-1" 'install_core_cockpit_packages'
  [[ "$output" == *"INSTALL:cockpit cockpit-files pcp python3-pcp tuned"* ]]
  [[ "$output" != *"WARN:"* ]]
}

@test "cockpit: 无 cockpit-files 候选版本时 plan 写 info 不写 pkg" {
  run _cand_call "(none)" 'module_plan'
  [[ "$output" == *"info|cockpit-files|当前软件源无候选版本"* ]]
  local pkg_line
  pkg_line=$(grep '^pkg|' <<< "$output")
  [[ "$pkg_line" == "pkg|cockpit pcp python3-pcp tuned|"* ]]
}

@test "cockpit: 无 cockpit-files 候选版本时运行中状态不算 partial" {
  run _cand_call "(none)" 'systemctl() { return 0; }; _cockpit_conf_owner() { echo debnas; }; pkg_is_installed() { [[ "$1" != cockpit-files ]]; }; module_status'
  [[ "$output" == "running|"*"软件源无 cockpit-files"* ]]
}

# ==================== 跟进修复回归（2026-11-10）：NetworkManager 不接管 systemd-networkd 的网卡 ====================

# 在沙箱里加载 cockpit 模块并执行片段。可用环境变量：
#   NETWORKD_LIST  networkctl list 的输出（空 = networkd 未管理任何网卡）
#   NM_STATE_FILE  文件内容为 nmcli device status 的 eth0 状态（connected / unmanaged）；service_ensure 重启 NM 后改写为 NM_AFTER
# 记录：$tmp/calls（ip addr del / nmcli connection delete / service_ensure）
_nm_guard_run() {
  local tmp="$1" snippet="$2"
  env DEBNAS_BACKUP_ROOT="$tmp/backups" DEBNAS_MANIFEST_FILE="$tmp/manifest" DEBNAS_GLOBAL_CONF="$tmp/none" \
    DEBNAS_MODULE_ACTION=status T="$tmp" NETWORKD_LIST="${NETWORKD_LIST:-}" NM_AFTER="${NM_AFTER:-unmanaged}" \
    IP_ADDR_FLAGS="${IP_ADDR_FLAGS:-secondary dynamic noprefixroute}" SS_OUT="${SS_OUT:-}" \
    SNIPPET="$snippet" bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    unset SSH_CONNECTION
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    source "$2" </dev/null
    COCKPIT_NM_GUARD_CONF="$T/conf.d/10-debnas-unmanaged.conf"
    networkctl() { printf "%s\n" "$NETWORKD_LIST"; }
    systemctl() { local IFS=" "; [[ "$*" == *"is-active"*"systemd-networkd"* ]] && [[ -n "$NETWORKD_LIST" ]]; }
    timeout() { shift; "$@"; }
    nmcli() {
      local IFS=" "
      case "$*" in
        *"DEVICE,STATE device status"*) printf "eth0:%s\ndocker0:connected (externally)\n" "$(cat "$T/nm-state")" ;;
        *"UUID,DEVICE,FILENAME connection show --active"*)
          printf "%s\n" "uuid-auto:eth0:/run/NetworkManager/system-connections/Wired connection 1.nmconnection" \
            "uuid-user:eth0:/etc/NetworkManager/system-connections/mine.nmconnection" \
            "uuid-docker:docker0:/run/NetworkManager/system-connections/docker0.nmconnection" ;;
        *"DHCP4.OPTION device show eth0"*) printf "DHCP4.OPTION[1]:dhcp_lease_time = 7200\nDHCP4.OPTION[2]:ip_address = 10.9.9.19\n" ;;
        *"-f UUID connection show"*) printf "uuid-auto\nuuid-user\nuuid-docker\n" ;;
        *"connection delete uuid"*) echo "nmcli $*" >> "$T/calls" ;;
      esac
    }
    nm-online() { return 0; }
    ss() { printf "%s" "$SS_OUT"; }
    ip() {
      local IFS=" "
      case "$*" in
        *"addr show dev eth0"*)
          printf "%s\n" "2: eth0    inet 10.9.9.17/24 metric 100 brd 10.9.9.255 scope global dynamic eth0\\       valid_lft 4073sec" \
            "2: eth0    inet 10.9.9.19/24 brd 10.9.9.255 scope global ${IP_ADDR_FLAGS} eth0\\       valid_lft 4286sec" ;;
        *"addr del"*) echo "ip $*" >> "$T/calls" ;;
      esac
    }
    service_ensure() { local IFS=" "; echo "service_ensure $*" >> "$T/calls"; [[ "$1" == "NetworkManager" ]] && echo "$NM_AFTER" > "$T/nm-state"; return 0; }
    source /dev/stdin <<< "$SNIPPET"
  ' _ "$DEBNAS_ROOT" "${DEBNAS_ROOT}/modules/cockpit.sh" 2>&1
}

_nm_guard_init() {
  NM_TMP=$(mktemp -d)
  : > "$NM_TMP/calls"
  echo "${1:-connected}" > "$NM_TMP/nm-state"
}

_NETWORKD_ETH0='  1 lo      loopback carrier    unmanaged
  2 eth0    ether    routable   configured
  3 docker0 bridge   no-carrier unmanaged'

@test "cockpit: _cockpit_networkd_ifaces 只取 SETUP=configured/configuring 的网卡（不含 lo 与 unmanaged）" {
  _nm_guard_init
  NETWORKD_LIST="$_NETWORKD_ETH0"$'\n''  4 eth1    ether    degraded   configuring'$'\n''  5 eth2    ether    off        pending' \
    run _nm_guard_run "$NM_TMP" '_cockpit_networkd_ifaces'
  [[ "$output" == "eth0"$'\n'"eth1" ]]
  rm -rf "$NM_TMP"
}

@test "cockpit: 没有 networkd 管理的网卡（ifupdown 常规安装）时不写片段、不重启 NM" {
  _nm_guard_init
  NETWORKD_LIST="" run _nm_guard_run "$NM_TMP" 'configure_nm_networkd_guard; _cockpit_nm_guard_state; _cockpit_nm_guard_plan'
  [[ "$status" -eq 0 ]]
  [[ ! -e "$NM_TMP/conf.d" ]]
  [[ ! -s "$NM_TMP/calls" ]]
  [[ "$output" == "none|" ]]
  rm -rf "$NM_TMP"
}

@test "cockpit: 片段用 [keyfile] unmanaged-devices+= 写法并说明何时移除" {
  _nm_guard_init
  run _nm_guard_run "$NM_TMP" '_cockpit_nm_guard_render eth0 enp3s0'
  [[ "$output" == *$'\n'"[keyfile]"$'\n'"unmanaged-devices+=interface-name:eth0,interface-name:enp3s0" ]]
  [[ "$output" == *"renderer 改为 NetworkManager"* ]]
  [[ "$output" == *"删除本文件"*"systemctl reload NetworkManager"* ]]
  # [device] managed=0 会被 NM 运行时状态盖过（实测无效），不得使用
  [[ "$output" != *"managed=0"* ]]
  rm -rf "$NM_TMP"
}

@test "cockpit: NM 已接管 networkd 的网卡时写片段、重启 NM、只删 NM 自动建的连接和它 DHCP 到的地址" {
  _nm_guard_init connected
  NETWORKD_LIST="$_NETWORKD_ETH0" run _nm_guard_run "$NM_TMP" '_cockpit_nm_guard_state; configure_nm_networkd_guard; _cockpit_nm_guard_state'
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "unwritten-conflict|eth0" ]]
  [[ "${lines[-1]}" == "ok|eth0" ]]
  grep -qx 'unmanaged-devices+=interface-name:eth0' "$NM_TMP/conf.d/10-debnas-unmanaged.conf"
  grep -qF "$NM_TMP/conf.d/10-debnas-unmanaged.conf" "$NM_TMP/manifest"
  grep -qx 'service_ensure NetworkManager restarted' "$NM_TMP/calls"
  # 只删 /run 下自动生成的连接，用户落盘的连接与其他网卡的连接不动
  grep -q 'connection delete uuid uuid-auto' "$NM_TMP/calls"
  ! grep -q 'uuid-user\|uuid-docker' "$NM_TMP/calls" || false
  # 只删 NM 的地址，networkd 的 10.9.9.17 不动
  grep -qx 'ip -4 addr del 10.9.9.19/24 dev eth0' "$NM_TMP/calls"
  ! grep -q '10.9.9.17' "$NM_TMP/calls" || false
  # 不用 reload（运行中改 unmanaged 会把网卡 down 掉）
  ! grep -q 'reload' "$NM_TMP/calls" || false
  rm -rf "$NM_TMP"
}

@test "cockpit: 片段已就位且 NM 未接管时幂等（不重启、不删任何东西）" {
  _nm_guard_init unmanaged
  NETWORKD_LIST="$_NETWORKD_ETH0" run _nm_guard_run "$NM_TMP" 'configure_nm_networkd_guard; : > "$T/calls"; configure_nm_networkd_guard; _cockpit_nm_guard_state'
  [[ "$status" -eq 0 ]]
  [[ ! -s "$NM_TMP/calls" ]]
  [[ "${lines[-1]}" == "ok|eth0" ]]
  rm -rf "$NM_TMP"
}

@test "cockpit: 重启后 NM 仍接管时不删地址、不删连接，只告警" {
  _nm_guard_init connected
  NETWORKD_LIST="$_NETWORKD_ETH0" NM_AFTER=connected run _nm_guard_run "$NM_TMP" 'configure_nm_networkd_guard'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"仍接管网卡 eth0"* ]]
  ! grep -q 'addr del\|connection delete' "$NM_TMP/calls" || false
  rm -rf "$NM_TMP"
}

@test "cockpit: NM 的地址仍有连接在用时不删（避免断开连在该地址上的 SSH）" {
  _nm_guard_init connected
  NETWORKD_LIST="$_NETWORKD_ETH0" SS_OUT="0 0 10.9.9.19:22 10.9.9.66:5555" run _nm_guard_run "$NM_TMP" 'configure_nm_networkd_guard'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"仍有连接在使用"* ]]
  ! grep -q 'addr del' "$NM_TMP/calls" || false
  rm -rf "$NM_TMP"
}

@test "cockpit: 地址不带 noprefixroute（不像 NM 加的）时不删" {
  _nm_guard_init connected
  NETWORKD_LIST="$_NETWORKD_ETH0" IP_ADDR_FLAGS="secondary dynamic" run _nm_guard_run "$NM_TMP" 'configure_nm_networkd_guard'
  [[ "$status" -eq 0 ]]
  ! grep -q 'addr del' "$NM_TMP/calls" || false
  rm -rf "$NM_TMP"
}

@test "cockpit: plan/status 反映 NM 与 networkd 的共存状态" {
  _nm_guard_init connected
  NETWORKD_LIST="$_NETWORKD_ETH0" run _nm_guard_run "$NM_TMP" '_cockpit_nm_guard_plan'
  [[ "$output" == *"write|$NM_TMP/conf.d/10-debnas-unmanaged.conf|网卡 eth0 由 systemd-networkd 管理"* ]]
  [[ "$output" == *"service|NetworkManager|"*"eth0"* ]]
  NETWORKD_LIST="$_NETWORKD_ETH0" run _nm_guard_run "$NM_TMP" '
    pkg_is_installed() { return 0; }
    systemctl() { return 0; }
    module_status'
  [[ "$output" == "partial|"*"eth0 被 NetworkManager 与 systemd-networkd 同时管理"* ]]
  NETWORKD_LIST="$_NETWORKD_ETH0" run _nm_guard_run "$NM_TMP" 'configure_nm_networkd_guard &>/dev/null; _cockpit_nm_guard_plan'
  [[ "$output" == "info|$NM_TMP/conf.d/10-debnas-unmanaged.conf|"*"已满足"*"需先删除该文件"* ]]
  # 片段还在但 networkd 已不管任何网卡（如 renderer 改成了 NetworkManager）：提示移除
  NETWORKD_LIST="" run _nm_guard_run "$NM_TMP" '_cockpit_nm_guard_state; _cockpit_nm_guard_plan; configure_nm_networkd_guard'
  [[ "${lines[0]}" == "stale|" ]]
  [[ "$output" == *"不再适用"*"删除该文件"* ]]
  [[ -f "$NM_TMP/conf.d/10-debnas-unmanaged.conf" ]]
  rm -rf "$NM_TMP"
}

@test "cockpit: main 在装包之前先调用 configure_nm_networkd_guard（NM 首次启动即不接管）" {
  local guard_line install_line
  guard_line=$(grep -n '^[[:space:]]*configure_nm_networkd_guard$' "$MODULE_FILE" | head -n 1 | cut -d: -f1)
  install_line=$(grep -n '^[[:space:]]*install_core_cockpit_packages ||' "$MODULE_FILE" | head -n 1 | cut -d: -f1)
  [[ -n "$guard_line" && -n "$install_line" ]]
  (( guard_line < install_line ))
}
