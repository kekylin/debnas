#!/usr/bin/env bats
# 测试: modules/fail2ban.sh — 配置 Fail2ban 模块 (TC-P1-MOD-003)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/fail2ban.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "fail2ban: @module 为 fail2ban" {
  result=$(parse_meta "module")
  [[ "$result" == "fail2ban" ]]
}

@test "fail2ban: @name 为 配置 Fail2ban" {
  result=$(parse_meta "name")
  [[ "$result" == "配置 Fail2ban" ]]
}

@test "fail2ban: @category 为 安全防护" {
  result=$(parse_meta "category")
  [[ "$result" == "安全防护" ]]
}

@test "fail2ban: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "fail2ban: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "fail2ban: @depend_modules 声明依赖 firewall" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"firewall"* ]]
}

# ==================== 语法验证 ====================

@test "fail2ban: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "fail2ban: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "fail2ban: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "fail2ban: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "fail2ban: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "fail2ban: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "fail2ban: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 函数定义验证 ====================

@test "fail2ban: install_fail2ban 函数已定义" {
  grep -q '^install_fail2ban()' "$MODULE_FILE"
}

@test "fail2ban: configure_email 函数已定义" {
  grep -q '^configure_email()' "$MODULE_FILE"
}

@test "fail2ban: configure_jail_local 函数已定义" {
  grep -q '^configure_jail_local()' "$MODULE_FILE"
}

@test "fail2ban: configure_mail_whois 函数已定义" {
  grep -q '^configure_mail_whois()' "$MODULE_FILE"
}

@test "fail2ban: configure_pam_generic 函数已定义" {
  grep -q '^configure_pam_generic()' "$MODULE_FILE"
}

@test "fail2ban: start_fail2ban 函数已定义" {
  grep -q '^start_fail2ban()' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "fail2ban: install_fail2ban 使用 apt_install_packages 安装" {
  grep -A5 'install_fail2ban()' "$MODULE_FILE" | grep -q 'apt_install_packages fail2ban'
}

@test "fail2ban: install_fail2ban 验证 fail2ban-server 存在" {
  grep -A10 'install_fail2ban()' "$MODULE_FILE" | grep -q 'fail2ban-server'
}

@test "fail2ban: configure_email 通过 notify_email_get 读取通知邮箱（/etc/debnas/notify_email，旧路径回退）" {
  grep -A20 'configure_email()' "$MODULE_FILE" | grep -q 'notify_email_get'
  ! grep -q 'notify_file="/etc/exim4/notify_email"' "$MODULE_FILE"
}

@test "fail2ban: configure_email 读取 /etc/email-addresses" {
  grep -A20 'configure_email()' "$MODULE_FILE" | grep -q '/etc/email-addresses'
}

@test "fail2ban: configure_jail_local 设置 firewallcmd-ipset 封禁后端" {
  grep -A80 'configure_jail_local()' "$MODULE_FILE" | grep -q 'firewallcmd-ipset'
}

@test "fail2ban: configure_jail_local 使用 write_file_if_changed 安全写入" {
  grep -A80 'configure_jail_local()' "$MODULE_FILE" | grep -q 'write_file_if_changed'
}

@test "fail2ban: configure_pam_generic 使用 grep 检查幂等性" {
  grep -A5 'configure_pam_generic()' "$MODULE_FILE" | grep -q 'grep.*pam-generic'
}

@test "fail2ban: start_fail2ban 确保 firewalld 启动 (TC-P1-SVC-001 关联)" {
  grep -A5 'start_fail2ban()' "$MODULE_FILE" | grep -q 'service_ensure firewalld'
}

@test "fail2ban: start_fail2ban 使用 service_ensure 管理 fail2ban" {
  grep -A10 'start_fail2ban()' "$MODULE_FILE" | grep -q 'service_ensure fail2ban'
}

@test "fail2ban: _config_changed 全局变量跟踪配置变更" {
  grep -q '_config_changed=0' "$MODULE_FILE"
}

@test "fail2ban: main 串联调用所有子函数" {
  grep -A45 '^main()' "$MODULE_FILE" | grep -q 'install_fail2ban'
  grep -A45 '^main()' "$MODULE_FILE" | grep -q 'configure_email'
  grep -A45 '^main()' "$MODULE_FILE" | grep -q 'configure_jail_local'
  grep -A45 '^main()' "$MODULE_FILE" | grep -q 'configure_mail_whois'
  grep -A45 '^main()' "$MODULE_FILE" | grep -q 'configure_pam_generic'
  grep -A45 '^main()' "$MODULE_FILE" | grep -q 'start_fail2ban'
}

# ==================== 回归：SSH 端口 / ignoreip / 不覆盖用户 jail.local ====================

@test "fail2ban: sshd jail 端口按实际 SSH 端口生成（不写死 ssh）" {
  ! grep -qE '^port[[:space:]]*=[[:space:]]*ssh$' "$MODULE_FILE" || false
  grep -q 'port     = ${ssh_ports}' "$MODULE_FILE"
  grep -q 'ssh_ports=$(sshd_listen_ports_csv --no-session)' "$MODULE_FILE"
  ! grep -q 'sshd -T' "$MODULE_FILE" || false
}

@test "fail2ban: ignoreip 模板为回环 + 可选局域网段" {
  grep -q 'ignoreip = 127.0.0.1/8 ::1${lan_subnets:+ ${lan_subnets}}' "$MODULE_FILE"
}

# 用假 ip 命令输出路由表，按 fail2ban_ignore_lan 取值生成 jail.local，输出其 ignoreip 行
# 参数：$1 - fail2ban_ignore_lan 的值（空串表示未设置）
_f2b_lan() {
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/ip" <<'IP'
#!/bin/sh
cat <<'R'
10.9.9.0/24 dev eth0 proto kernel scope link src 10.9.9.12
192.168.50.0/24 dev eth1 proto kernel scope link src 192.168.50.2
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
172.18.0.0/16 dev br-1a2b3c proto kernel scope link src 172.18.0.1
192.168.122.0/24 dev virbr0 proto kernel scope link src 192.168.122.1
10.0.3.0/24 dev lxcbr0 proto kernel scope link src 10.0.3.1
10.88.0.0/16 dev podman0 proto kernel scope link src 10.88.0.1
10.66.0.0/24 dev wg0 proto kernel scope link src 10.66.0.1
R
IP
  chmod +x "$tmp/ip"
  PATH="$tmp:$PATH" F2B_LAN="$1" bash -c '
    set -euo pipefail
    config_get_bool() {
      case "${F2B_LAN:-$2}" in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac
    }
    log_info() { :; }
    sshd_listen_ports_csv() { echo 22; }
    write_file_if_changed() { grep "^ignoreip" <<< "$2"; return 1; }
    eval "$(grep "^readonly JAIL_LOCAL_MARKER=" "$1")"
    eval "$(sed -n "/^get_local_private_subnets()/,/^}/p;/^fail2ban_ignore_lan_subnets()/,/^}/p;/^configure_jail_local()/,/^}/p" "$1")"
    jail_local_is_managed() { return 0; }
    configure_jail_local
  ' _ "$MODULE_FILE"
  rm -rf "$tmp"
}

@test "fail2ban: 默认 ignoreip 不含局域网段（只回环）(B5)" {
  run _f2b_lan ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == "ignoreip = 127.0.0.1/8 ::1" ]]
  run _f2b_lan 0
  [[ "$output" == "ignoreip = 127.0.0.1/8 ::1" ]]
}

@test "fail2ban: fail2ban_ignore_lan=1 时加入直连私网段并排除虚拟/VPN 接口 (B5)" {
  run _f2b_lan 1
  [[ "$status" -eq 0 ]]
  [[ "$output" == "ignoreip = 127.0.0.1/8 ::1 10.9.9.0/24 192.168.50.0/24" ]]
}

@test "fail2ban: debnas.conf.default 注释说明 fail2ban_ignore_lan (B5)" {
  grep -q '^#fail2ban_ignore_lan=0$' "${DEBNAS_ROOT}/config/debnas.conf.default"
}

@test "fail2ban: jail_local_is_managed — 用户自定义 jail.local 不被覆盖" {
  local tmp
  tmp=$(mktemp -d)
  printf '[DEFAULT]\nbantime = 1d\n' > "$tmp/user.local"
  run bash -c '
    eval "$(grep "^readonly JAIL_LOCAL_MARKER=" "$1")"
    eval "$(sed -n "/^jail_local_is_managed()/,/^}/p" "$1")"
    jail_local_is_managed "$2/missing.local" && echo "MISSING=managed"
    jail_local_is_managed "$2/user.local" || echo "USER=kept"
    printf "%s\n[DEFAULT]\n" "$JAIL_LOCAL_MARKER" > "$2/ours.local"
    jail_local_is_managed "$2/ours.local" && echo "OURS=managed"
  ' _ "$MODULE_FILE" "$tmp"
  rm -rf "$tmp"
  [[ "$output" == *"MISSING=managed"* ]]
  [[ "$output" == *"USER=kept"* ]]
  [[ "$output" == *"OURS=managed"* ]]
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

@test "fail2ban: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "fail2ban: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "fail2ban: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-fail2ban-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "fail2ban: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-fail2ban-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "fail2ban: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-fail2ban-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "fail2ban: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status fail2ban
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan fail2ban
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

@test "fail2ban: 未安装时 status=absent，plan 列出 pkg fail2ban" {
  run _contract_probe eval /dev/null 'pkg_is_installed() { return 1; }; module_status; module_plan'
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "absent|未安装 fail2ban" ]]
  [[ "$output" == *"pkg|fail2ban|"* ]]
}

@test "fail2ban: 服务与 sshd/pam-generic jail 在跑时 status=running" {
  run _contract_probe eval /dev/null '
    pkg_is_installed() { return 0; }
    systemctl() { return 0; }
    _f2b_running_jails() { printf "pam-generic,sshd"; }
    module_status'
  [[ "$status" -eq 0 ]]
  [[ "$output" == "running|运行中 · jail：pam-generic,sshd" ]]
}

@test "fail2ban: sshd jail 未启用时 status=warn" {
  run _contract_probe eval /dev/null '
    pkg_is_installed() { return 0; }
    systemctl() { return 0; }
    _f2b_running_jails() { printf "pam-generic"; }
    module_status'
  [[ "$output" == warn\|* ]]
}

@test "fail2ban: 读不到控制套接字（非 root）时不报错" {
  run _contract_probe eval /dev/null '
    pkg_is_installed() { return 0; }
    systemctl() { return 0; }
    _f2b_running_jails() { return 1; }
    module_status'
  [[ "$status" -eq 0 ]]
  [[ "$output" == running\|*"需 root 查看"* ]]
}

# ==================== jail.local 管理与局域网段（行为） ====================

@test "fail2ban: jail_local_is_managed 识别 DebNAS 生成/旧版/用户自定义" {
  local d
  d=$(mktemp -d)
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/fail2ban.sh" >/dev/null 2>&1
    printf "%s\n" "$JAIL_LOCAL_MARKER" > "$2/managed.local"
    {
      echo "# some header"
      echo "# 忽略本机流量，防止自身被封禁"
      echo "# 使用 firewallcmd-ipset 作为封禁后端（适配 firewalld）"
    } > "$2/legacy.local"
    echo "[sshd]" > "$2/user.local"
    for f in managed legacy user; do
      if jail_local_is_managed "$2/$f.local"; then echo "$f=YES"; else echo "$f=NO"; fi
    done
    if jail_local_is_managed "$2/nonexistent.local"; then echo "missing=YES"; else echo "missing=NO"; fi
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"managed=YES"* ]]
  [[ "$output" == *"legacy=YES"* ]]
  [[ "$output" == *"user=NO"* ]]
  [[ "$output" == *"missing=YES"* ]]
}

@test "fail2ban: get_local_private_subnets 排除虚拟网桥、公网与非 RFC1918" {
  local mock="${BATS_TEST_TMPDIR}/mockbin"
  mkdir -p "$mock"
  cat > "${mock}/ip" <<'INNEREOF'
#!/bin/sh
cat <<'ROUTES'
10.1.2.0/24 dev eth0 proto kernel scope link src 10.1.2.5
172.16.5.0/24 dev eth1 proto kernel scope link src 172.16.5.5
192.168.1.0/24 dev br-lan proto kernel scope link src 192.168.1.1
10.9.0.0/24 dev docker0 proto kernel scope link src 10.9.0.1
100.64.0.0/10 dev tun0 scope link
8.8.8.0/24 dev eth2 scope link
ROUTES
INNEREOF
  chmod +x "${mock}/ip"
  run env PATH="${mock}:$PATH" bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/fail2ban.sh" >/dev/null 2>&1
    get_local_private_subnets
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "10.1.2.0/24 172.16.5.0/24" ]]
}
