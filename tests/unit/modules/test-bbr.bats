#!/usr/bin/env bats
# 测试: modules/bbr.sh — 配置 BBR 加速模块 (F-85)
# Mock 策略：PATH Injection (sysctl/modprobe/lsmod/modinfo) + TEMP-SYSCTL-DIR
# BBR 支持 cron_mode 早期退出 + 参数模式，可安全 source 并测试函数

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/bbr.sh"
export NO_COLOR=1

setup() {
  # 注意：不要在此 source 任何 lib 文件
  # 模块会通过自己的 bootstrap.sh 加载全部依赖
  # 提前 source 会导致 readonly 变量冲突（DEP_LEVEL_SYSTEM 等）

  # 创建 Mock 命令目录
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"

  # Mock sysctl: 默认返回 cubic 算法
  cat > "$MOCK_BIN/sysctl" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  case "$2" in
    net.ipv4.tcp_congestion_control) echo "cubic" ;;
    net.ipv4.tcp_available_congestion_control) echo "cubic bbr reno" ;;
    net.core.default_qdisc) echo "fq_codel" ;;
    *) echo "0" ;;
  esac
else
  exit 0
fi
INNEREOF
  chmod +x "$MOCK_BIN/sysctl"

  # Mock modprobe: 成功加载模块
  cat > "$MOCK_BIN/modprobe" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/modprobe"

  # Mock modinfo: 模块可用
  cat > "$MOCK_BIN/modinfo" << 'INNEREOF'
#!/usr/bin/env bash
echo "filename: /lib/modules/6.1.0/kernel/net/ipv4/tcp_bbr.ko.xz"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/modinfo"

  # Mock lsmod: 默认不包含 BBR（模块未加载）
  cat > "$MOCK_BIN/lsmod" << 'INNEREOF'
#!/usr/bin/env bash
cat << 'LSMODEOF'
Module                  Size  Used by
ext4                  942080  1
mbcache               16384  1 ext4
LSMODEOF
INNEREOF
  chmod +x "$MOCK_BIN/lsmod"

  # Mock service_ensure systemd-sysctl: 成功
  cat > "$MOCK_BIN/systemctl" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/systemctl"

  # Mock sed: 通过真实 sed（需要保留注释功能）
  # 使用真实 sed，但隔离 sysctl 配置目录
  TEST_SYSCONF_DIR="$BATS_TMPDIR/sysctl.d"
  mkdir -p "$TEST_SYSCONF_DIR"
  # 创建临时 sysctl.conf
  echo "" > "$BATS_TMPDIR/sysctl.conf"

  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$MOCK_BIN" "$TEST_SYSCONF_DIR" "$BATS_TMPDIR/sysctl.conf"
}

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# 辅助：在隔离环境中 source 模块
# 设置 CRON_MODE=1 使 main 在 source 时立即返回 0（不执行菜单）
source_bbr_module() {
  export DEBNAS_CRON_MODE=1
  source "$MODULE_FILE"
  # main() 检测到 CRON_MODE 后立即 return 0，不会进入菜单循环
}

# ==================== 元数据验证 ====================

@test "bbr: @module 为 bbr" {
  result=$(parse_meta "module")
  [[ "$result" == "bbr" ]]
}

@test "bbr: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "bbr: @category 已声明" {
  result=$(parse_meta "category")
  [[ -n "$result" ]]
}

@test "bbr: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "bbr: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "bbr: @interactive 为 true" {
  result=$(parse_meta "interactive")
  [[ "$result" == "true" ]]
}

# ==================== 语法验证 ====================

@test "bbr: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "bbr: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "bbr: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "bbr: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "bbr: 定义 BBR_MODULE='tcp_bbr'" {
  grep -q "BBR_MODULE=\"tcp_bbr\"" "$MODULE_FILE"
}

@test "bbr: 定义 BBR_ALGO='bbr' 和 DEFAULT_ALGO='cubic'" {
  grep -q 'BBR_ALGO="bbr"' "$MODULE_FILE"
  grep -q 'DEFAULT_ALGO="cubic"' "$MODULE_FILE"
}

@test "bbr: 定义 SYSCONF_FILE 常量（排序在 50-default.conf 之后）" {
  grep -q 'SYSCONF_FILE="/etc/sysctl.d/99-debnas-bbr.conf"' "$MODULE_FILE"
  grep -q 'LEGACY_SYSCONF_FILE="/etc/sysctl.d/11-debnas-bbr.conf"' "$MODULE_FILE"
}

@test "bbr: 定义 handle_choice 支持 1-5 选项" {
  grep -A10 '^handle_choice()' "$MODULE_FILE" | grep -q 'temp_enable_bbr'
  grep -A10 '^handle_choice()' "$MODULE_FILE" | grep -q 'perm_enable_bbr'
  grep -A10 '^handle_choice()' "$MODULE_FILE" | grep -q 'temp_disable_bbr'
  grep -A10 '^handle_choice()' "$MODULE_FILE" | grep -q 'perm_disable_bbr'
  grep -A10 '^handle_choice()' "$MODULE_FILE" | grep -q 'check_current_algo'
}

@test "bbr: 非交互模式（参数/管道）直接调用 handle_choice" {
  # main() 中有 [[ ! -t 0 ]] || [[ -n "${1:-}" ]] 分支
  grep -q 'handle_choice' "$MODULE_FILE"
}

# ==================== Mock 功能测试 ====================

@test "bbr: handle_choice 5 调用 check_current_algo（Mock sysctl 返回 cubic）" {
  source_bbr_module
  run handle_choice 5
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"cubic"* || "$output" == *"当前"* ]]
}

@test "bbr: check_current_algo 输出包含当前算法和可用算法" {
  source_bbr_module
  run check_current_algo
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"cubic"* ]]
  [[ "$output" == *"bbr"* ]]
}

@test "bbr: handle_choice 1 (临时启用) 调用 temp_enable_bbr" {
  source_bbr_module
  run handle_choice 1
  # Mock modprobe + sysctl -w 均成功 → 应返回 0
  [[ "$status" -eq 0 ]]
}

@test "bbr: handle_choice 3 (临时禁用) 调用 temp_disable_bbr" {
  source_bbr_module
  run handle_choice 3
  [[ "$status" -eq 0 ]]
}

@test "bbr: cron_mode 下 main 返回 0 不执行菜单" {
  # 在子 shell 中 source 模块，CRON_MODE=1 使 main 直接返回
  run bash -c "
    export NO_COLOR=1
    export DEBNAS_CRON_MODE=1
    source \"${DEBNAS_ROOT}/lib/core/constants.sh\"
    source \"${DEBNAS_ROOT}/lib/core/colors.sh\"
    source \"${DEBNAS_ROOT}/lib/core/logging.sh\"
    export PATH=\"${MOCK_BIN}:\$PATH\"
    source \"${MODULE_FILE}\"
  "
  [[ "$status" -eq 0 ]]
}

@test "bbr: COMMENT_OUT_SYSCONF — comment_out_sysctl_conf_key 函数存在" {
  grep -q '^comment_out_sysctl_conf_key()' "$MODULE_FILE"
}

@test "bbr: perm_enable_bbr 使用 sysctl_persist 持久化配置" {
  grep -q 'sysctl_persist' "$MODULE_FILE"
  grep -q '99-debnas-bbr.conf' "$MODULE_FILE"
}

# ==================== 回归：comment_out_sysctl_conf_key 按参数 key 生效 ====================

@test "bbr: comment_out_sysctl_conf_key 注释传入的 key（不再写死拥塞算法键）" {
  local tmp
  tmp=$(mktemp -d)
  printf '# net.core.default_qdisc = x\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$tmp/sysctl.conf"
  run bash -c '
    set -euo pipefail
    log_success() { :; }
    log_warning() { :; }
    write_file_if_changed() { printf "%s\n" "$2" > "$1"; }
    eval "$(sed -n "/^comment_out_sysctl_conf_key()/,/^}/p" "$1" | sed "s#/etc/sysctl.conf#$2/sysctl.conf#")"
    comment_out_sysctl_conf_key net.core.default_qdisc
    cat "$2/sysctl.conf"
  ' _ "$MODULE_FILE" "$tmp"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"# net.core.default_qdisc=fq"* ]]
  [[ "$output" == *$'\n'"net.ipv4.tcp_congestion_control = bbr"* ]]
}

@test "bbr: 菜单内单项失败不会让 set -e 退出整个工具" {
  grep -q 'handle_choice "$((choice + 1))" || true' "$MODULE_FILE"
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

@test "bbr: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "bbr: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "bbr: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-bbr-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "bbr: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-bbr-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "bbr: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-bbr-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "bbr: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status bbr
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan bbr
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

@test "bbr: 当前 bbr 且已持久化时 status=applied" {
  run _contract_probe eval /dev/null '
    _bbr_read_proc() { case "$1" in *available*) echo "cubic bbr" ;; *congestion_control) echo bbr ;; *qdisc) echo fq ;; esac; }
    _bbr_persisted() { return 0; }
    module_status'
  [[ "$output" == applied\|* ]]
}

@test "bbr: 当前 bbr 但未持久化时 status=partial" {
  run _contract_probe eval /dev/null '
    _bbr_read_proc() { case "$1" in *available*) echo "cubic bbr" ;; *congestion_control) echo bbr ;; *qdisc) echo fq ;; esac; }
    _bbr_persisted() { return 1; }
    module_status'
  [[ "$output" == partial\|* ]]
}

@test "bbr: 已持久化但当前非 bbr 时 status=warn" {
  run _contract_probe eval /dev/null '
    _bbr_read_proc() { case "$1" in *available*) echo "cubic" ;; *congestion_control) echo cubic ;; *qdisc) echo fq_codel ;; esac; }
    _bbr_persisted() { return 0; }
    module_status'
  [[ "$output" == warn\|* ]]
}

@test "bbr: 内核无 BBR 时 plan 给出 risk" {
  run _contract_probe eval /dev/null '
    _bbr_available() { return 1; }
    DEBNAS_MODULE_ACTION=plan module_plan'
  [[ "$output" == *"risk|tcp_bbr|"* ]]
}

# ==================== 审计修复回归（2026-11-10） ====================

# 在临时目录模拟 /etc/sysctl.d，执行 $1（perm_enable_bbr / perm_disable_bbr）后列出目录
_bbr_persist_run() {
  local tmp="$2"
  bash -c '
    set -euo pipefail
    log_info() { :; }; log_success() { :; }; log_warning() { :; }; log_error() { :; }
    load_bbr_module() { return 0; }
    sysctl() { return 0; }
    comment_out_sysctl_conf_key() { return 0; }
    service_ensure() { return 0; }
    sysctl_persist() { echo "$1 = $2" >> "$D/$3"; }
    D="$3"
    eval "$(grep -E "^readonly (SYSCONF|LEGACY_SYSCONF|BBR_|DEFAULT_|QDISC)" "$1" | sed "s#/etc/sysctl.d#$3#")"
    eval "$(sed -n "/^perm_enable_bbr()/,/^}/p;/^perm_disable_bbr()/,/^}/p" "$1")"
    "$2"
    ls -1 "$D"
  ' _ "$MODULE_FILE" "$1" "$tmp"
}

@test "bbr: 永久启用写入排在 50-default.conf 之后的文件并迁移旧 11- 文件 (B8)" {
  local tmp name
  tmp=$(mktemp -d)
  printf 'net.ipv4.tcp_congestion_control = bbr\nnet.core.default_qdisc = fq\n' > "$tmp/11-debnas-bbr.conf"
  run _bbr_persist_run perm_enable_bbr "$tmp"
  [[ "$status" -eq 0 ]]
  [[ ! -e "$tmp/11-debnas-bbr.conf" ]]
  name=$(ls -1 "$tmp")
  [[ "$name" == *debnas-bbr.conf ]]
  # systemd-sysctl 按文件名排序应用，后者覆盖前者：必须排在 50-default.conf 之后
  [[ "$(printf '%s\n' 50-default.conf "$name" | LC_ALL=C sort | tail -n 1)" == "$name" ]]
  grep -q '^net.core.default_qdisc = fq$' "$tmp/$name"
  rm -rf "$tmp"
}

@test "bbr: 永久停用同时删除新旧两个配置文件 (B8)" {
  local tmp
  tmp=$(mktemp -d)
  touch "$tmp/11-debnas-bbr.conf" "$tmp/99-debnas-bbr.conf"
  run _bbr_persist_run perm_disable_bbr "$tmp"
  [[ "$status" -eq 0 ]]
  [[ ! -e "$tmp/11-debnas-bbr.conf" ]]
  [[ ! -e "$tmp/99-debnas-bbr.conf" ]]
  rm -rf "$tmp"
}

# ==================== 跟进修复回归（2026-11-10）：不再 sed -i 直改 /etc/sysctl.conf ====================

@test "bbr: 模块内无 sed -i 原地修改系统文件" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -qE 'sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i' || false
}

@test "bbr: comment_out_sysctl_conf_key 经 write_file_if_changed 写回（原件进备份、路径进文件清单）" {
  local tmp
  tmp=$(mktemp -d)
  printf '# keep\nnet.core.default_qdisc=fq\nvm.swappiness = 10\n' > "$tmp/sysctl.conf"
  run env DEBNAS_BACKUP_ROOT="$tmp/backups" DEBNAS_MANIFEST_FILE="$tmp/manifest" DEBNAS_GLOBAL_CONF="$tmp/none" \
    DEBNAS_BACKUP_ENABLED=1 bash -c '
    set -euo pipefail
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    eval "$(sed -n "/^comment_out_sysctl_conf_key()/,/^}/p" "$2" | sed "s#/etc/sysctl.conf#$3/sysctl.conf#")"
    comment_out_sysctl_conf_key net.core.default_qdisc >/dev/null
    cat "$3/sysctl.conf"
  ' _ "$DEBNAS_ROOT" "$MODULE_FILE" "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"# net.core.default_qdisc=fq"* ]]
  [[ "$output" == *"vm.swappiness = 10"* ]]
  # 原件备份（未注释的版本）
  grep -rqx 'net.core.default_qdisc=fq' "$tmp/backups/original$tmp/sysctl.conf"
  # 文件清单登记
  grep -qF "$tmp/sysctl.conf" "$tmp/manifest"
  rm -rf "$tmp"
}

@test "bbr: plan 对 /etc/sysctl.conf 的说明与实际一致（有备份，不再写 sed -i 不另做备份）" {
  ! grep -q 'sed -i 原地修改，不另做备份' "$MODULE_FILE" || false
  grep -q '注释掉重复项.*备份到 /var/backups/debnas/' "$MODULE_FILE"
}

# ==================== 持久化判定（行为） ====================

@test "bbr: _bbr_persisted 识别 bbr 配置行并忽略注释" {
  local d
  d=$(mktemp -d)
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$d/good.conf"
  printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$d/bad.conf"
  printf '# net.ipv4.tcp_congestion_control = bbr\n' > "$d/comment.conf"
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/bbr.sh" >/dev/null 2>&1
    _bbr_persisted "$2/good.conf" && echo GOOD=YES || echo GOOD=NO
    _bbr_persisted "$2/bad.conf" && echo BAD=YES || echo BAD=NO
    _bbr_persisted "$2/comment.conf" && echo COMMENT=YES || echo COMMENT=NO
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"GOOD=YES"* ]]
  [[ "$output" == *"BAD=NO"* ]]
  [[ "$output" == *"COMMENT=NO"* ]]
}
