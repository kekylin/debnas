#!/usr/bin/env bats
# 测试: modules/acl-manager.sh — ACL 权限管理模块 (F-81~F-82)
# Mock 策略：纯函数测试 + 结构验证 + grep 断言菜单/函数完整性

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/acl-manager.sh"
export NO_COLOR=1

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "acl-manager: @module 为 acl-manager" {
  result=$(parse_meta "module")
  [[ "$result" == "acl-manager" ]]
}

@test "acl-manager: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "acl-manager: @category 已声明" {
  result=$(parse_meta "category")
  [[ -n "$result" ]]
}

@test "acl-manager: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "acl-manager: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "acl-manager: @depends 为 getfacl,setfacl" {
  result=$(parse_meta "depends")
  [[ "$result" == *"getfacl"* ]]
  [[ "$result" == *"setfacl"* ]]
}

# ==================== 语法验证 ====================

@test "acl-manager: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "acl-manager: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "acl-manager: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "acl-manager: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "acl-manager: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 函数完整性验证 ====================

@test "acl-manager: 定义 8 个核心函数" {
  grep -q '^view_acl()' "$MODULE_FILE"
  grep -q '^set_user_acl()' "$MODULE_FILE"
  grep -q '^set_group_acl()' "$MODULE_FILE"
  grep -q '^set_default_acl()' "$MODULE_FILE"
  grep -q '^remove_default_acl()' "$MODULE_FILE"
  grep -q '^remove_acl()' "$MODULE_FILE"
  grep -q '^batch_set_acl()' "$MODULE_FILE"
  grep -q '^main()' "$MODULE_FILE"
}

@test "acl-manager: 菜单输出包含 7 个选项（main 渲染）" {
  # 菜单选项 0-7 应全部出现
  local menu_func
  menu_func=$(grep -A25 '^main()' "$MODULE_FILE")
  [[ "$menu_func" == *"查看 ACL 权限"* ]]
  [[ "$menu_func" == *"设置用户 ACL"* ]]
  [[ "$menu_func" == *"设置组 ACL"* ]]
  [[ "$menu_func" == *"设置默认 ACL"* ]]
  [[ "$menu_func" == *"取消默认 ACL"* ]]
  [[ "$menu_func" == *"删除 ACL"* ]]
  [[ "$menu_func" == *"批量设置 ACL"* ]]
  [[ "$menu_func" == *"返回"* ]]
}

@test "acl-manager: 操作前延迟调用 ensure_module_deps" {
  grep -q 'ensure_module_deps acl-manager' "$MODULE_FILE"
}

@test "acl-manager: 使用 register_temp_cleanup 注册临时清理" {
  grep -q 'register_temp_cleanup' "$MODULE_FILE"
}

@test "acl-manager: 定义 log_acl_action 审计日志函数" {
  grep -q '^log_acl_action()' "$MODULE_FILE"
}

@test "acl-manager: 审计日志写入 LOG_FILE" {
  grep -A5 '^log_acl_action()' "$MODULE_FILE" | grep -q 'LOG_FILE'
}

# ==================== 纯函数测试 ====================

@test "acl-manager: validate_permissions — 接受 rwx 格式" {
  # 在子 shell 中 source 相关部分并测试纯函数
  # 注意：validate_permissions 函数有 8 行，需要足够的 grep -A 行数
  run bash -c "
    source '${DEBNAS_ROOT}/lib/core/constants.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/colors.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/logging.sh' 2>/dev/null
    # 提取 validate_permissions 函数定义（函数 8 行）
    eval \"\$(grep -A8 '^validate_permissions()' '${MODULE_FILE}')\"
    validate_permissions 'rwx'
  "
  [[ "$status" -eq 0 ]]
}

@test "acl-manager: validate_permissions — 拒绝非法格式（超过 3 字符）" {
  run bash -c "
    source '${DEBNAS_ROOT}/lib/core/constants.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/colors.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/logging.sh' 2>/dev/null
    eval \"\$(grep -A8 '^validate_permissions()' '${MODULE_FILE}')\"
    validate_permissions 'rwxr'
  "
  [[ "$status" -ne 0 ]]
}

@test "acl-manager: validate_permissions — 拒绝包含非法字符的格式" {
  run bash -c "
    source '${DEBNAS_ROOT}/lib/core/constants.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/colors.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/logging.sh' 2>/dev/null
    eval \"\$(grep -A8 '^validate_permissions()' '${MODULE_FILE}')\"
    validate_permissions 'abc'
  "
  [[ "$status" -ne 0 ]]
}

@test "acl-manager: validate_permissions — 接受空权限（0 字符）" {
  run bash -c "
    source '${DEBNAS_ROOT}/lib/core/constants.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/colors.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/logging.sh' 2>/dev/null
    eval \"\$(grep -A8 '^validate_permissions()' '${MODULE_FILE}')\"
    validate_permissions ''
  "
  # 空字符串匹配 {0,3}，应该返回 0
  [[ "$status" -eq 0 ]]
}

# ==================== CRON 模式验证 ====================

@test "acl-manager: cron_mode 下 main 返回 0 提前退出（不进入菜单循环）" {
  grep -A4 '^main()' "$MODULE_FILE" | grep -q 'DEBNAS_CRON_MODE'
  grep -A4 '^main()' "$MODULE_FILE" | grep -q 'cron 模式下不支持交互操作'
}

# ==================== 安全验证 ====================

@test "acl-manager: set_user_acl 操作前有确认提示" {
  grep -A30 '^set_user_acl()' "$MODULE_FILE" | grep -q 'ui_confirm.*为用户设置ACL权限'
}

@test "acl-manager: batch_set_acl 使用 shopt -s nullglob 安全处理通配符" {
  # shopt -s nullglob 在 batch_set_acl 函数体中（~第 243 行），直接 grep 全文
  grep -q 'shopt -s nullglob' "$MODULE_FILE"
}

# ==================== 回归：系统目录与条目注入 ====================

@test "acl-manager: validate_acl_path 拒绝根目录与系统目录" {
  run bash -c '
    log_error() { :; }
    eval "$(grep "^readonly -a ACL_PROTECTED_" "$1")"
    eval "$(sed -n "/^validate_acl_path()/,/^}/p" "$1")"
    for p in / /etc /etc/ssh /usr/lib /var/lib /boot; do
      validate_acl_path "$p" && echo "ALLOWED:$p"
    done
    validate_acl_path /srv/share && echo "SRV_OK"
  ' _ "$MODULE_FILE"
  [[ "$output" != *"ALLOWED:"* ]]
  [[ "$output" == *"SRV_OK"* ]]
}

@test "acl-manager: validate_acl_entry 拒绝逗号/冒号注入额外条目" {
  run bash -c '
    log_error() { :; }
    eval "$(sed -n "/^validate_acl_principal()/,/^}/p;/^validate_acl_entry()/,/^}/p" "$1")"
    validate_acl_entry "u:root:rwx,u:nobody" && echo "INJECTED"
    validate_acl_entry "g:root,o" && echo "INJECTED"
    validate_acl_entry "m::rwx" && echo "INJECTED"
    validate_acl_entry "u:root" && echo "ROOT_OK"
  ' _ "$MODULE_FILE"
  [[ "$output" != *"INJECTED"* ]]
  [[ "$output" == *"ROOT_OK"* ]]
}

# ==================== 审计修复回归（2026-11-10） ====================

@test "acl-manager: 保护列表含 /home/*/.ssh、/root 与 /opt 下可执行文件目录 (B10)" {
  run bash -c '
    log_error() { :; }
    eval "$(grep "^readonly -a ACL_PROTECTED_" "$1")"
    eval "$(sed -n "/^validate_acl_path()/,/^}/p" "$1")"
    for p in /home/alice/.ssh /home/alice/.ssh/authorized_keys /root /root/x /opt/debnas /opt/debnas/lib /opt/foo/bin /opt/foo/sbin/tool; do
      validate_acl_path "$p" && echo "ALLOWED:$p"
    done
    validate_acl_path /home/alice/data && echo "DATA_OK"
    validate_acl_path /opt/foo/share && echo "OPT_SHARE_OK"
  ' _ "$MODULE_FILE"
  [[ "$output" != *"ALLOWED:"* ]]
  [[ "$output" == *"DATA_OK"* ]]
  [[ "$output" == *"OPT_SHARE_OK"* ]]
}

@test "acl-manager: 递归时拒绝包含 .ssh 的上级目录 (B10)" {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/home/alice/.ssh" "$tmp/home/alice/data"
  run bash -c '
    log_error() { echo "E:$*"; }
    eval "$(grep "^readonly -a ACL_PROTECTED_" "$1" | sed "s#/home/#$2/home/#")"
    eval "$(sed -n "/^validate_acl_path()/,/^}/p" "$1")"
    validate_acl_path "$2/home/alice" && echo "NONREC_OK"
    validate_acl_path "$2/home/alice" recursive && echo "REC_ALLOWED"
    validate_acl_path "$2/home" recursive && echo "REC_HOME_ALLOWED"
    validate_acl_path "$2/home/alice/data" recursive && echo "REC_DATA_OK"
  ' _ "$MODULE_FILE" "$tmp"
  rm -rf "$tmp"
  [[ "$output" == *"NONREC_OK"* ]]
  [[ "$output" != *"REC_ALLOWED"* ]]
  [[ "$output" != *"REC_HOME_ALLOWED"* ]]
  [[ "$output" == *"REC_DATA_OK"* ]]
}

# 运行 acl-manager.sh 中的交互函数：ui_input 依次返回 $3 起的参数，ui_confirm 依次返回 $CONFIRMS 中的值，setfacl 只打印参数
_acl_interactive() {
  local fn="$1" dir="$2"
  shift 2
  ( cd "$dir" && CONFIRMS="${CONFIRMS:-0}" bash -c '
    set -uo pipefail
    D=$(mktemp -d)
    printf "%s\n" "${@:3}" > "$D/in"
    # shellcheck disable=SC2086
    printf "%s\n" $CONFIRMS > "$D/cf"
    IFS=$'"'"'\n\t'"'"'
    _next() { local f="$D/$1" v; v=$(head -n 1 "$f"); sed -i 1d "$f"; printf "%s" "$v"; }
    ui_input() { _next in; }
    ui_confirm() { _next cf; }
    setfacl() { local IFS=" "; echo "SETFACL:$*"; }
    log_info() { :; }; log_success() { :; }; log_warning() { :; }; log_error() { echo "E:$*"; }
    module_mark_action() { :; }; log_acl_action() { :; }
    ACL_OUTPUT=/dev/null
    eval "$(grep "^readonly -a ACL_PROTECTED_" "$1")"
    eval "$(sed -n "/^validate_acl_path()/,/^}/p;/^_acl_is_toplevel_dir()/,/^}/p;/^validate_permissions()/,/^}/p;/^validate_acl_principal()/,/^}/p;/^validate_acl_entry()/,/^}/p;/^_acl_run()/,/^}/p;/^acl_error()/,/^}/p;/^${2}()/,/^}/p" "$1")"
    "$2"
    rm -rf "$D"
  ' _ "$MODULE_FILE" "$fn" "$@" )
}

@test "acl-manager: setfacl 路径参数前加 --（以 - 开头的路径不被当成选项）(B10)" {
  local tmp
  tmp=$(mktemp -d)
  mkdir -- "$tmp/-k"
  run _acl_interactive remove_default_acl "$tmp" "-k"
  rm -rf "$tmp"
  [[ "$output" == *"SETFACL:-k -- -k"* ]]
}

@test "acl-manager: 批量递归命中一级目录时要求二次确认，拒绝则跳过 (B10)" {
  [[ -d /mnt ]] || skip "无 /mnt"
  CONFIRMS="0 1" run _acl_interactive batch_set_acl /tmp "/mnt" "u:root" "rwx" "y"
  [[ "$output" != *"SETFACL:"* ]]
  CONFIRMS="0 0" run _acl_interactive batch_set_acl /tmp "/mnt" "u:root" "rwx" "y"
  [[ "$output" == *"SETFACL:-R -m u:root:rwx -- /mnt"* ]]
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

@test "acl-manager: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "acl-manager: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "acl-manager: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-acl-manager-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "acl-manager: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-acl-manager-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "acl-manager: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-acl-manager-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "acl-manager: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status acl-manager
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan acl-manager
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

@test "acl-manager: 顶层不再注册临时清理/创建临时文件（移入 main）" {
  if grep -q '^register_temp_cleanup' "$MODULE_FILE"; then false; fi
  if grep -q '^ACL_OUTPUT=\$(create_temp_file' "$MODULE_FILE"; then false; fi
  grep -A8 '^main()' "$MODULE_FILE" | grep -q 'register_temp_cleanup'
  grep -A8 '^main()' "$MODULE_FILE" | grep -q 'ACL_OUTPUT=\$(create_temp_file'
}

@test "acl-manager: plan 列出交互动作范围与递归风险，系统目录列表不被拆行" {
  run _contract_probe plan /dev/null
  [[ "$output" == *"info|acl-manager|交互式菜单"* ]]
  [[ "$output" == *"risk|递归操作|"* ]]
  [[ "$output" != *"未识别的预演行"* ]]
  _contract_plan_ok "$output"
}

# ==================== 输入校验（行为） ====================

@test "acl-manager: validate_permissions 接受合法权限并拒绝非法字符" {
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/acl-manager.sh" >/dev/null 2>&1
    log_error() { :; }
    for p in rwx r-x "" rwq rwxr; do
      if validate_permissions "$p"; then echo "[$p]=OK"; else echo "[$p]=NO"; fi
    done
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[rwx]=OK"* ]]
  [[ "$output" == *"[r-x]=OK"* ]]
  [[ "$output" == *"[]=OK"* ]]
  [[ "$output" == *"[rwq]=NO"* ]]
  [[ "$output" == *"[rwxr]=NO"* ]]
}

@test "acl-manager: validate_acl_path 拒绝根/系统目录/受保护目录" {
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/acl-manager.sh" >/dev/null 2>&1
    log_error() { :; }
    for p in / /etc/hosts /opt/debnas/bin /home/u/.ssh /srv/data; do
      if validate_acl_path "$p"; then echo "$p=OK"; else echo "$p=NO"; fi
    done
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"/=NO"* ]]
  [[ "$output" == *"/etc/hosts=NO"* ]]
  [[ "$output" == *"/opt/debnas/bin=NO"* ]]
  [[ "$output" == *"/home/u/.ssh=NO"* ]]
  [[ "$output" == *"/srv/data=OK"* ]]
}

@test "acl-manager: _acl_is_toplevel_dir 只认一级目录" {
  local d
  d=$(mktemp -d)
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/acl-manager.sh" >/dev/null 2>&1
    _acl_is_toplevel_dir /tmp && echo TOP=YES || echo TOP=NO
    _acl_is_toplevel_dir "$2" && echo SUB=YES || echo SUB=NO
    _acl_is_toplevel_dir / && echo ROOT=YES || echo ROOT=NO
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"TOP=YES"* ]]
  [[ "$output" == *"SUB=NO"* ]]
  [[ "$output" == *"ROOT=NO"* ]]
}

@test "acl-manager: validate_acl_entry 拒绝非法格式与非法用户名" {
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/acl-manager.sh" >/dev/null 2>&1
    log_error() { :; }
    getent() { [[ "$2" == "root" ]]; }
    for e in u:root g:root u:bad,name x:root; do
      if validate_acl_entry "$e"; then echo "$e=OK"; else echo "$e=NO"; fi
    done
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"u:root=OK"* ]]
  [[ "$output" == *"g:root=OK"* ]]
  [[ "$output" == *"u:bad,name=NO"* ]]
  [[ "$output" == *"x:root=NO"* ]]
}
