#!/usr/bin/env bats
# 测试: modules/hosts-sync/ — 同步 Hosts 模块 (F-77~F-79a, TC-P1-MOD-007)
# Mock 策略：结构验证 + 元数据 + DNS 解析逻辑（纯函数部分）
# 网络相关的 update_hosts 通过 grep 结构断言

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/hosts-sync"
MODULE_FILE="${MODULE_DIR}/module.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "hosts-sync: @module 为 hosts-sync" {
  result=$(parse_meta "module")
  [[ "$result" == "hosts-sync" ]]
}

@test "hosts-sync: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "hosts-sync: @category 已声明" {
  result=$(parse_meta "category")
  [[ -n "$result" ]]
}

@test "hosts-sync: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "hosts-sync: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "hosts-sync: @cron 为 true" {
  result=$(parse_meta "cron")
  [[ "$result" == "true" ]]
}

@test "hosts-sync: @interactive 为 true" {
  result=$(parse_meta "interactive")
  [[ "$result" == "true" ]]
}

# ==================== 语法验证 ====================

@test "hosts-sync: module.sh bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "hosts-sync: dns-resolve.sh bash -n 语法通过" {
  run bash -n "${MODULE_DIR}/dns-resolve.sh"
  [[ "$status" -eq 0 ]]
}

@test "hosts-sync: connectivity.sh bash -n 语法通过" {
  run bash -n "${MODULE_DIR}/connectivity.sh"
  [[ "$status" -eq 0 ]]
}

@test "hosts-sync: hosts-manager.sh bash -n 语法通过" {
  run bash -n "${MODULE_DIR}/hosts-manager.sh"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "hosts-sync: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "hosts-sync: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "hosts-sync: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "hosts-sync: DNS_NAME_ORDER 定义 DNS 服务器顺序" {
  grep -q 'DNS_NAME_ORDER=' "$MODULE_FILE"
}

@test "hosts-sync: DNS_IP_BY_NAME 定义 DNS IP 地址映射" {
  grep -q 'DNS_IP_BY_NAME=' "$MODULE_FILE"
}

@test "hosts-sync: DNS_NAME_ORDER 包含 AliDNS" {
  grep -q 'AliDNS' "$MODULE_FILE"
}

@test "hosts-sync: DNS_IP_BY_NAME 包含四个 DNS 提供商" {
  grep -q 'AliDNS' "$MODULE_FILE"
  grep -q 'TencentDNS' "$MODULE_FILE"
  grep -q 'BaiduDNS' "$MODULE_FILE"
  grep -q 'DNS114' "$MODULE_FILE"
}

@test "hosts-sync: 定义 START_MARK / END_MARK hosts 标记" {
  grep -q 'START_MARK=' "$MODULE_FILE"
  grep -q 'END_MARK=' "$MODULE_FILE"
}

@test "hosts-sync: 定义 HOSTS_FILE 指向 /etc/hosts" {
  grep -q 'HOSTS_FILE="/etc/hosts"' "$MODULE_FILE"
}

@test "hosts-sync: 加载三个子模块" {
  grep -q 'dns-resolve.sh' "$MODULE_FILE"
  grep -q 'connectivity.sh' "$MODULE_FILE"
  grep -q 'hosts-manager.sh' "$MODULE_FILE"
}

@test "hosts-sync: export -f 导出并行子 shell 函数" {
  grep -q 'export -f' "$MODULE_FILE"
}

@test "hosts-sync: module_enable_feature 调用 update_hosts" {
  grep -A8 'module_enable_feature()' "$MODULE_FILE" | grep -q 'update_hosts'
}

@test "hosts-sync: --yes 模式下跳过菜单直接执行 update_hosts" {
  grep -A5 'DEBNAS_FORCE_YES' "$MODULE_FILE" | grep -q 'update_hosts'
}

# ==================== dns-resolve.sh ====================

@test "hosts-sync: dns-resolve.sh 包含 resolve_domain 函数" {
  grep -q 'resolve_domain()' "${MODULE_DIR}/dns-resolve.sh"
}

@test "hosts-sync: dns-resolve.sh 包含 get_ip_type 函数（IPv4/IPv6 检测）" {
  grep -q 'get_ip_type()' "${MODULE_DIR}/dns-resolve.sh"
}

# ==================== connectivity.sh ====================

@test "hosts-sync: connectivity.sh 包含三级连通性测试函数" {
  grep -q 'test_https_connectivity()' "${MODULE_DIR}/connectivity.sh"
  grep -q 'test_tcp_connectivity()' "${MODULE_DIR}/connectivity.sh"
  grep -q 'test_ping_connectivity()' "${MODULE_DIR}/connectivity.sh"
}

# ==================== hosts-manager.sh ====================

@test "hosts-sync: hosts-manager.sh 包含 START_MARK/END_MARK 标记" {
  grep -q 'START_MARK' "${MODULE_DIR}/hosts-manager.sh"
  grep -q 'END_MARK' "${MODULE_DIR}/hosts-manager.sh"
}

@test "hosts-sync: hosts-manager.sh 包含 update_hosts 函数" {
  grep -q 'update_hosts()' "${MODULE_DIR}/hosts-manager.sh"
}

@test "hosts-sync: hosts-manager.sh 包含 init_domains_config 函数" {
  grep -q 'init_domains_config()' "${MODULE_DIR}/hosts-manager.sh"
}

# ==================== 回归：/etc/hosts 写回方式与内容 ====================

@test "hosts-sync: 不再用 mv 覆盖 /etc/hosts（避免变成 0600）" {
  ! grep -qE 'mv .*HOSTS_FILE' "${MODULE_DIR}/hosts-manager.sh"
}

@test "hosts-sync: 移除 DebNAS 区块时保留用户空行与文件权限" {
  local tmp
  tmp=$(mktemp -d)
  printf '127.0.0.1 localhost\n\n::1 ip6\n\n# DebNAS Hosts Start\n1.1.1.1 a\n# DebNAS Hosts End\n\n' > "$tmp/hosts"
  chmod 644 "$tmp/hosts"
  run bash -c '
    set -euo pipefail
    START_MARK="# DebNAS Hosts Start"; END_MARK="# DebNAS Hosts End"; HOSTS_FILE="$2/hosts"
    create_temp_file() { mktemp; }
    log_info() { :; }; log_error() { echo "$*" >&2; }; log_warning() { :; }
    eval "$(sed -n "/^write_file_if_changed()/,/^}/p" "$3")"
    eval "$(sed -n "/^lock_acquire()/,/^}/p;/^lock_release()/,/^}/p" "$4")"
    eval "$(sed -n "/^render_hosts_without_block()/,/^}/p;/^hosts_block_state()/,/^}/p;/^_hosts_lock()/,/^}/p;/^_hosts_unlock()/,/^}/p;/^write_hosts_file()/,/^}/p;/^remove_hosts_block()/,/^}/p" "$1")"
    TMP_DIR="$2"; export DEBNAS_TMP_BASE="$2"
    remove_hosts_block
    stat -c "MODE=%a" "$HOSTS_FILE"
    cat "$HOSTS_FILE"
  ' _ "${MODULE_DIR}/hosts-manager.sh" "$tmp" "${DEBNAS_ROOT}/lib/system/utils.sh" "${DEBNAS_ROOT}/lib/system/tempfile.sh"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"MODE=644"* ]]
  [[ "$output" != *"DebNAS Hosts"* ]]
  [[ "$output" == "MODE=644"$'\n'"127.0.0.1 localhost"$'\n\n'"::1 ip6" ]]
}

@test "hosts-sync: 禁用时清除 hosts 中的 DebNAS 区块" {
  grep -A10 'module_disable_feature()' "$MODULE_FILE" | grep -q 'remove_hosts_block'
}

@test "hosts-sync: 无任何成功解析时不改动 hosts" {
  grep -A25 '^update_hosts()' "${MODULE_DIR}/hosts-manager.sh" | grep -q 'SUCCESS_DOMAINS -eq 0'
}

@test "hosts-sync: is_usable_public_ip 过滤 0.0.0.0/回环/私网/保留地址" {
  run bash -c '
    eval "$(sed -n "/^is_usable_public_ip()/,/^}/p" "$1")"
    for ip in 0.0.0.0 127.0.0.1 10.1.2.3 172.16.0.1 192.168.1.1 100.64.0.1 198.18.0.1 ::1 fd00::1; do
      is_usable_public_ip "$ip" && echo "LEAK:$ip"
    done
    is_usable_public_ip 140.82.112.3 && echo "PUBLIC_OK"
  ' _ "${MODULE_DIR}/dns-resolve.sh"
  [[ "$output" != *"LEAK:"* ]]
  [[ "$output" == *"PUBLIC_OK"* ]]
}

@test "hosts-sync: HTTPS 检测校验证书（无 -k，使用 --resolve 带 SNI）" {
  if grep -A12 '^test_https_connectivity()' "${MODULE_DIR}/connectivity.sh" | grep -qE 'curl[^#]* -k'; then false; fi
  grep -A12 '^test_https_connectivity()' "${MODULE_DIR}/connectivity.sh" | grep -q -- '--resolve'
}

@test "hosts-sync: resolve_domain 的 set +e 不泄漏到调用方（local -）" {
  grep -A4 '^resolve_domain()' "${MODULE_DIR}/dns-resolve.sh" | grep -q 'local -'
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

@test "hosts-sync: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "hosts-sync: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "hosts-sync: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-hosts-sync-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "hosts-sync: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-hosts-sync-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "hosts-sync: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-hosts-sync-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "hosts-sync: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status hosts-sync
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan hosts-sync
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

@test "hosts-sync: status 判据读取 /etc/hosts 中 DebNAS 区块" {
  grep -A4 '^_hosts_sync_block_info()' "$MODULE_FILE" | grep -q 'START_MARK'
}

@test "hosts-sync: 已启用但无区块时 status=warn" {
  run _contract_probe eval /dev/null '
    _hosts_sync_block_info() { echo "none 0 -"; }
    feature_enabled() { return 0; }
    module_status'
  [[ "$output" == warn\|* ]]
}

@test "hosts-sync: 有区块且定时开启时 status=applied 并给出条目数" {
  run _contract_probe eval /dev/null '
    _hosts_sync_block_info() { echo "ok 12 2026年11月09日_10:00:00"; }
    feature_enabled() { return 0; }
    cron_state() { echo on; }
    module_status'
  [[ "$output" == applied\|*"12 条"*"定时更新已开启"* ]]
}

@test "hosts-sync: plan 说明 /etc/hosts 原子替换并备份" {
  run _contract_probe plan /dev/null
  [[ "$output" == *"write|/etc/hosts|"*"原子替换"*"/var/backups/debnas/"* ]]
}

# ==================== 审计修复回归（2026-11-10） ====================

# 加载 hosts-manager.sh（解析步骤打桩），在 $2/hosts 上执行 $3 片段
# 输出片段的 stdout/stderr，末行 RC=<返回码>
_hm_run() {
  local snippet="$1" dir="$2"
  bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    D="$2"
    START_MARK="# DebNAS Hosts Start"; END_MARK="# DebNAS Hosts End"; HOSTS_FILE="$D/hosts"
    CRON_MODE=1; TMP_DIR="$D"; export DEBNAS_TMP_BASE="$D"
    create_temp_file() { mktemp "$D/t.XXXXXX"; }
    log_info() { :; }; log_success() { :; }; log_warning() { echo "W:$*"; }; log_error() { echo "E:$*"; }
    debnas_backup_file() { cp -- "$1" "$D/backup"; }
    eval "$(sed -n "/^write_file_if_changed()/,/^}/p" "$3/lib/system/utils.sh")"
    source "$3/lib/system/tempfile.sh"
    source "$3/modules/hosts-sync/hosts-manager.sh"
    process_all_domains() { echo "140.82.112.3 github.com" >> "$1"; SUCCESS_DOMAINS=1; TOTAL_DOMAINS=1; }
    rc=0
    eval "$4" 2>&1 || rc=$?
    echo "RC=$rc"
  ' _ "$snippet" "$dir" "$DEBNAS_ROOT" "$snippet"
}

@test "hosts-sync: 区块缺 END 时 update_hosts 拒绝写入，用户条目不被删除 (B1)" {
  local tmp before
  tmp=$(mktemp -d)
  printf '127.0.0.1 localhost\n# DebNAS Hosts Start\n1.1.1.1 old\n10.0.0.5 nas.user\n' > "$tmp/hosts"
  before=$(cat "$tmp/hosts")
  run _hm_run 'update_hosts' "$tmp"
  [[ "$output" == *"RC=1"* ]]
  [[ "$output" == *"缺少结束标记"* ]]
  [[ "$(cat "$tmp/hosts")" == "$before" ]]
  rm -rf "$tmp"
}

@test "hosts-sync: 区块缺 END 时 remove_hosts_block 报错且不改文件 (B1)" {
  local tmp before
  tmp=$(mktemp -d)
  printf '127.0.0.1 localhost\n# DebNAS Hosts Start\n10.0.0.5 nas.user\n' > "$tmp/hosts"
  before=$(cat "$tmp/hosts")
  run _hm_run 'remove_hosts_block' "$tmp"
  [[ "$output" == *"RC=1"* ]]
  [[ "$(cat "$tmp/hosts")" == "$before" ]]
  rm -rf "$tmp"
}

@test "hosts-sync: 完整区块时 update_hosts 正常替换区块并备份原文件 (B1/B7)" {
  local tmp
  tmp=$(mktemp -d)
  printf '127.0.0.1 localhost\n\n# DebNAS Hosts Start\n1.1.1.1 old\n# DebNAS Hosts End\n10.0.0.5 nas.user\n' > "$tmp/hosts"
  run _hm_run 'update_hosts' "$tmp"
  [[ "$output" == *"RC=0"* ]]
  run cat "$tmp/hosts"
  [[ "$output" == *"10.0.0.5 nas.user"* ]]
  [[ "$output" == *"140.82.112.3 github.com"* ]]
  [[ "$output" != *"1.1.1.1 old"* ]]
  [[ "$(grep -c '^# DebNAS Hosts Start$' "$tmp/hosts")" -eq 1 ]]
  [[ "$(grep -c '^# DebNAS Hosts End$' "$tmp/hosts")" -eq 1 ]]
  grep -q '1.1.1.1 old' "$tmp/backup"
  rm -rf "$tmp"
}

@test "hosts-sync: hosts 写入走 write_file_if_changed 并加锁 (B7)" {
  grep -A10 '^write_hosts_file()' "${MODULE_DIR}/hosts-manager.sh" | grep -q 'write_file_if_changed'
  grep -A5 '^_hosts_lock()' "${MODULE_DIR}/hosts-manager.sh" | grep -q 'lock_acquire'
  grep -A30 '^lock_acquire()' "${DEBNAS_ROOT}/lib/system/tempfile.sh" | grep -q 'flock'
  grep -A40 '^update_hosts()' "${MODULE_DIR}/hosts-manager.sh" | grep -q '_hosts_lock'
  grep -A12 '^remove_hosts_block()' "${MODULE_DIR}/hosts-manager.sh" | grep -q '_hosts_lock'
}

@test "hosts-sync: dig 报错行中的 DNS 服务器地址不会被当成解析结果 (B4)" {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/dig" <<'DIG'
#!/bin/sh
echo ";; communications error to 223.5.5.5#53: timed out"
echo ";; no servers could be reached 119.29.29.29"
echo "github.map.fastly.net."
echo "223.5.5.5"
echo "garbage 8.8.8.8 trailing"
echo "140.82.112.4"
DIG
  chmod +x "$tmp/bin/dig"
  run env PATH="$tmp/bin:$PATH" bash -c '
    set -euo pipefail
    IP_MODE=IPv4
    eval "$(sed -n "/^is_usable_public_ip()/,/^}/p;/^filter_dig_answers()/,/^}/p;/^resolve_from_dns()/,/^}/p" "$1")"
    resolve_from_dns github.com 223.5.5.5
  ' _ "${MODULE_DIR}/dns-resolve.sh"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "140.82.112.4" ]]
}

@test "hosts-sync: 非严格组只通 TCP/ping、HTTPS 证书校验失败时不采用 (B4)" {
  run bash -c '
    set -euo pipefail
    eval "$(sed -n "/^is_strict_domain()/,/^}/p;/^test_ip_connectivity()/,/^}/p" "$1")"
    test_https_connectivity() { return 1; }
    test_tcp_connectivity() { return 0; }
    test_ping_connectivity() { echo 20; }
    r=$(test_ip_connectivity 1.2.3.4 api.themoviedb.org TMDB) || true
    echo "R=[$r]"
    test_https_connectivity() { return 0; }
    r=$(test_ip_connectivity 1.2.3.4 api.themoviedb.org TMDB) || true
    echo "R2=[$r]"
  ' _ "${MODULE_DIR}/connectivity.sh"
  [[ "$output" == *"R=[]"* ]]
  [[ "$output" == *"R2=[1|1|1|20]"* ]]
}

# ==================== 边界行为补充（2026-11-13） ====================

@test "hosts-sync: is_usable_public_ip 保留段边界与公网 IPv6 判定" {
  run bash -c '
    eval "$(sed -n "/^is_usable_public_ip()/,/^}/p" "$1")"
    for ip in 100.64.0.0 100.127.255.255 172.16.0.0 172.31.255.255 \
      198.18.0.1 198.51.100.7 203.0.113.9 192.0.2.2 192.0.0.9 169.254.3.4 \
      224.0.0.0 256.1.1.1; do
      is_usable_public_ip "$ip" && echo "LEAK:$ip"
    done
    for ip in 100.63.255.255 100.128.0.0 172.15.255.255 172.32.0.0 \
      223.255.255.255 2606:4700::6810:84e5 2001:4860:4860::8888; do
      is_usable_public_ip "$ip" || echo "MISS:$ip"
    done
    for ip in 2001:db8::1 fe80::1 fc00::1 ff02::1 64:ff9b::1 ::ffff:1.2.3.4 :: ::1; do
      is_usable_public_ip "$ip" && echo "LEAK:$ip"
    done
    echo DONE
  ' _ "${MODULE_DIR}/dns-resolve.sh"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"LEAK:"* ]]
  [[ "$output" != *"MISS:"* ]]
  [[ "$output" == *"DONE"* ]]
}

@test "hosts-sync: hosts_block_state 区分无区块/完整区块/缺 END/缺文件" {
  local tmp
  tmp=$(mktemp -d)
  run bash -c '
    set -euo pipefail
    START_MARK="# DebNAS Hosts Start"; END_MARK="# DebNAS Hosts End"; HOSTS_FILE="$1/hosts"
    eval "$(sed -n "/^hosts_block_state()/,/^}/p" "$2")"
    printf "127.0.0.1 localhost\n" > "$HOSTS_FILE"
    echo "none=$(hosts_block_state)"
    printf "127.0.0.1 localhost\n# DebNAS Hosts Start\n1.1.1.1 a\n# DebNAS Hosts End\n" > "$HOSTS_FILE"
    echo "ok=$(hosts_block_state)"
    printf "127.0.0.1 localhost\n# DebNAS Hosts Start\n1.1.1.1 a\n" > "$HOSTS_FILE"
    echo "broken=$(hosts_block_state)"
    HOSTS_FILE="$1/hosts.missing"
    echo "missing=$(hosts_block_state)"
  ' _ "$tmp" "${MODULE_DIR}/hosts-manager.sh"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"none=none"* ]]
  [[ "$output" == *"ok=ok"* ]]
  [[ "$output" == *"broken=broken"* ]]
  [[ "$output" == *"missing=none"* ]]
}

@test "hosts-sync: hosts_block_state 兼容 CRLF 与重复完整区块" {
  local tmp
  tmp=$(mktemp -d)
  run bash -c '
    set -euo pipefail
    START_MARK="# DebNAS Hosts Start"; END_MARK="# DebNAS Hosts End"; HOSTS_FILE="$1/hosts"
    eval "$(sed -n "/^hosts_block_state()/,/^}/p" "$2")"
    printf "127.0.0.1 localhost\r\n# DebNAS Hosts Start\r\n1.1.1.1 a\r\n# DebNAS Hosts End\r\n" > "$HOSTS_FILE"
    echo "crlf=$(hosts_block_state)"
    printf "127.0.0.1 localhost\r\n# DebNAS Hosts Start\r\n1.1.1.1 a\r\n" > "$HOSTS_FILE"
    echo "crlf_broken=$(hosts_block_state)"
    printf "127.0.0.1 localhost\n# DebNAS Hosts Start\n1.1.1.1 a\n# DebNAS Hosts End\nkeep\n# DebNAS Hosts Start\n2.2.2.2 b\n# DebNAS Hosts End\n" > "$HOSTS_FILE"
    echo "dup=$(hosts_block_state)"
  ' _ "$tmp" "${MODULE_DIR}/hosts-manager.sh"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"crlf=ok"* ]]
  [[ "$output" == *"crlf_broken=broken"* ]]
  [[ "$output" == *"dup=ok"* ]]
}

@test "hosts-sync: render_hosts_without_block 移除多个区块并保留用户空行" {
  local tmp
  tmp=$(mktemp -d)
  printf '127.0.0.1 localhost\n\n# DebNAS Hosts Start\n1.1.1.1 a\n# DebNAS Hosts End\n\nkeep1\n\nkeep2\n\n# DebNAS Hosts Start\n2.2.2.2 b\n# DebNAS Hosts End\n\n' > "$tmp/hosts"
  run bash -c '
    set -euo pipefail
    START_MARK="# DebNAS Hosts Start"; END_MARK="# DebNAS Hosts End"; HOSTS_FILE="$1/hosts"
    eval "$(sed -n "/^render_hosts_without_block()/,/^}/p" "$2")"
    render_hosts_without_block
  ' _ "$tmp" "${MODULE_DIR}/hosts-manager.sh"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == $'127.0.0.1 localhost\n\n\nkeep1\n\nkeep2' ]]
  [[ "$output" != *"DebNAS Hosts"* ]]
}
