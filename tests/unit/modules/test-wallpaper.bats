#!/usr/bin/env bats
# 测试: modules/wallpaper/module.sh — 登录壁纸目录模块 (F-20~F-21)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/wallpaper"
MODULE_FILE="${MODULE_DIR}/module.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "wallpaper: @module 为 wallpaper" {
  result=$(parse_meta "module")
  [[ "$result" == "wallpaper" ]]
}

@test "wallpaper: @name 为 登录页壁纸" {
  result=$(parse_meta "name")
  [[ "$result" == "登录页壁纸" ]]
}

@test "wallpaper: @category 为 管理面板" {
  result=$(parse_meta "category")
  [[ "$result" == "管理面板" ]]
}

@test "wallpaper: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "wallpaper: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "wallpaper: @depends 声明依赖 curl（下载实际使用 curl，不再声明 wget）" {
  result=$(parse_meta "depends")
  [[ "$result" == *"curl"* ]]
  [[ "$result" != *"wget"* ]]
}

@test "wallpaper: @depend_modules 声明依赖 cockpit" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"cockpit"* ]]
}

@test "wallpaper: @interactive 为 true（依赖延迟到动作时检查）" {
  result=$(parse_meta "interactive")
  [[ "$result" == "true" ]]
}

@test "wallpaper: @cron 为 true" {
  result=$(parse_meta "cron")
  [[ "$result" == "true" ]]
}

@test "wallpaper: @cron_schedule 为 0 0 * * *" {
  result=$(parse_meta "cron_schedule")
  [[ "$result" == "0 0 * * *" ]]
}

# ==================== 语法验证 ====================

@test "wallpaper: module.sh bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "wallpaper: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "wallpaper: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "wallpaper: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "wallpaper: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "wallpaper: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "wallpaper: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 常量验证 ====================

@test "wallpaper: BRANDING_DIR 指向 /etc/cockpit/branding" {
  grep -q 'BRANDING_DIR="/etc/cockpit/branding"' "$MODULE_FILE"
}

@test "wallpaper: BRANDING_CSS 指向 branding.css" {
  grep -q 'BRANDING_CSS=.*branding.css' "$MODULE_FILE"
}

@test "wallpaper: WALLPAPER_FILE 指向 login-bg.png" {
  grep -q 'WALLPAPER_FILE=.*login-bg.png' "$MODULE_FILE"
}

@test "wallpaper: STATE_FILE 指向 .initialized" {
  grep -q 'STATE_FILE=.*\.initialized' "$MODULE_FILE"
}

@test "wallpaper: DEFAULT_WALLPAPER_API_URL 引用 Bing API" {
  grep -q 'bing.com/HPImageArchive' "$MODULE_FILE"
}

# ==================== 函数定义验证 ====================

@test "wallpaper: get_wallpaper_api_url 函数已定义" {
  grep -q '^get_wallpaper_api_url()' "$MODULE_FILE"
}

@test "wallpaper: mark_initialized 函数已定义" {
  grep -q '^mark_initialized()' "$MODULE_FILE"
}

@test "wallpaper: check_cockpit_version 函数已定义" {
  grep -q '^check_cockpit_version()' "$MODULE_FILE"
}

@test "wallpaper: prepare_env 函数已定义" {
  grep -q '^prepare_env()' "$MODULE_FILE"
}

@test "wallpaper: update_wallpaper 函数已定义" {
  grep -q '^update_wallpaper()' "$MODULE_FILE"
}

@test "wallpaper: generate_css 函数已定义" {
  grep -q '^generate_css()' "$MODULE_FILE"
}

@test "wallpaper: restart_cockpit 函数已定义" {
  grep -q '^restart_cockpit()' "$MODULE_FILE"
}

@test "wallpaper: enable_bing_wallpaper 函数已定义" {
  grep -q '^enable_bing_wallpaper()' "$MODULE_FILE"
}

@test "wallpaper: disable_bing_wallpaper 函数已定义" {
  grep -q '^disable_bing_wallpaper()' "$MODULE_FILE"
}

@test "wallpaper: auto_update_mode 函数已定义" {
  grep -q '^auto_update_mode()' "$MODULE_FILE"
}

@test "wallpaper: main_menu 函数已定义" {
  grep -q '^main_menu()' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "wallpaper: get_wallpaper_api_url 使用 config_read 读取配置" {
  grep -A5 'get_wallpaper_api_url()' "$MODULE_FILE" | grep -q 'config_read'
}

@test "wallpaper: mark_initialized 使用 touch 创建标记文件" {
  grep -A1 'mark_initialized()' "$MODULE_FILE" | grep -q 'touch'
}

@test "wallpaper: check_cockpit_version 要求最低 347 版本" {
  grep -q 'cockpit_version.*-lt 347' "$MODULE_FILE"
}

@test "wallpaper: check_cockpit_version 多路径检测 (bridge/ws/dpkg)" {
  grep -q 'cockpit-bridge.*version' "$MODULE_FILE"
  grep -q 'cockpit-ws.*version' "$MODULE_FILE"
  grep -q 'dpkg.*cockpit' "$MODULE_FILE"
}

@test "wallpaper: prepare_env 使用 install -d 创建目录" {
  grep -A1 'prepare_env()' "$MODULE_FILE" | grep -q 'install -d'
}

@test "wallpaper: update_wallpaper curl 设置 --max-time 超时" {
  grep -q 'curl.*--max-time' "$MODULE_FILE"
}

@test "wallpaper: update_wallpaper 使用 Bing JSON API 解析" {
  grep -A30 'update_wallpaper()' "$MODULE_FILE" | grep -q 'bing_json'
}

@test "wallpaper: update_wallpaper 提取 url/title/copyright 字段" {
  grep -A30 'update_wallpaper()' "$MODULE_FILE" | grep -q 'bing_url'
  grep -A30 'update_wallpaper()' "$MODULE_FILE" | grep -q 'bing_title'
  grep -A30 'update_wallpaper()' "$MODULE_FILE" | grep -q 'bing_copyright'
}

@test "wallpaper: update_wallpaper 移动临时文件后写入 ISSUE_FILE" {
  grep -A40 'update_wallpaper()' "$MODULE_FILE" | grep -q 'mv.*WALLPAPER_FILE'
  grep -A40 'update_wallpaper()' "$MODULE_FILE" | grep -q 'ISSUE_FILE'
}

@test "wallpaper: generate_css 写入 branding.css" {
  grep -A100 'generate_css()' "$MODULE_FILE" | grep -qF 'write_file_if_changed "$BRANDING_CSS"'
}

@test "wallpaper: cron 自动更新仅在样式变化时重启 cockpit（不每天断开会话）" {
  grep -A10 '^auto_update_mode()' "$MODULE_FILE" | grep -q '_CSS_CHANGED" -eq 1'
}

@test "wallpaper: generate_css 输出 login-bg.png 背景引用" {
  grep -q 'login-bg.png' "$MODULE_FILE"
}

@test "wallpaper: restart_cockpit 使用 systemctl is-active 检测状态" {
  grep -A5 'restart_cockpit()' "$MODULE_FILE" | grep -q 'systemctl is-active'
}

@test "wallpaper: restart_cockpit 使用 service_ensure cockpit restarted" {
  grep -A5 'restart_cockpit()' "$MODULE_FILE" | grep -q 'service_ensure cockpit restarted'
}

@test "wallpaper: restart_cockpit 兼容 cockpit.socket 激活" {
  grep -A8 'restart_cockpit()' "$MODULE_FILE" | grep -q 'cockpit.socket'
}

@test "wallpaper: enable_bing_wallpaper 使用 feature_enable 记录启用状态" {
  grep -A20 'enable_bing_wallpaper()' "$MODULE_FILE" | grep -q 'feature_enable.*wallpaper'
}

@test "wallpaper: enable_bing_wallpaper 先调用 ensure_module_deps" {
  grep -A3 'enable_bing_wallpaper()' "$MODULE_FILE" | grep -q 'ensure_module_deps wallpaper'
}

@test "wallpaper: disable_bing_wallpaper 使用 cron_unregister 取消注册" {
  grep -A5 'disable_bing_wallpaper()' "$MODULE_FILE" | grep -q 'cron_unregister.*wallpaper'
}

@test "wallpaper: disable_bing_wallpaper 删除 BRANDING_DIR 目录（先备份）" {
  grep -A5 'disable_bing_wallpaper()' "$MODULE_FILE" | grep -q '_wp_remove_branding_dir'
  local body
  body=$(sed -n '/^_wp_remove_branding_dir()/,/^}/p' "$MODULE_FILE")
  [[ "$(grep -n 'debnas_backup_file' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'rm -rf' <<<"$body" | cut -d: -f1)" ]]
}

@test "wallpaper: _wp_remove_branding_dir 备份失败保留目录、备份关闭照常删除" {
  local t="${BATS_TEST_TMPDIR}/wp"
  mkdir -p "$t/b/sub"; touch "$t/b/login-bg.png" "$t/b/sub/x"
  run bash -c '
    set -euo pipefail
    BRANDING_DIR="$1"; log_warning() { echo "W:$1"; }
    eval "$(sed -n "/^_wp_remove_branding_dir()/,/^}/p" "$2")"
    debnas_backup_file() { echo "B:$1"; return 1; }
    _wp_remove_branding_dir || echo "KEPT"
    [[ -d "$BRANDING_DIR" ]] && echo "EXISTS"
    debnas_backup_file() { return 2; }
    _wp_remove_branding_dir
    [[ -d "$BRANDING_DIR" ]] || echo "REMOVED"
  ' _ "$t/b" "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"B:$t/b/sub/x"* ]]
  [[ "$output" == *"KEPT"* && "$output" == *"EXISTS"* && "$output" == *"REMOVED"* ]]
}

@test "wallpaper: disable_bing_wallpaper 恢复默认 ISSUE_FILE" {
  grep -A5 'disable_bing_wallpaper()' "$MODULE_FILE" | grep -q 'DebNAS'
}

@test "wallpaper: main 在 cron 模式下调用 auto_update_mode" {
  grep -q 'auto_update_mode' "$MODULE_FILE"
}

@test "wallpaper: main 在 TTY 交互模式下调用 main_menu" {
  grep -q 'main_menu' "$MODULE_FILE"
}

@test "wallpaper: main 在非 TTY 非 cron 模式调用 enable_bing_wallpaper" {
  grep -A10 '^main()' "$MODULE_FILE" | grep -q 'enable_bing_wallpaper'
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/wallpaper/module.sh"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="${BATS_TMPDIR}/wallpaper-probe-state" \
    DEBNAS_FEATURE_DIR="${BATS_TMPDIR}/wallpaper-probe-state" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "wallpaper-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "wallpaper-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "wallpaper-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "wallpaper-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TMPDIR}/wallpaper-probe-state" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "wallpaper-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "wallpaper-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "wallpaper-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="${BATS_TMPDIR}/wallpaper-probe-state" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status wallpaper
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

# ==================== 审计修复回归（2026-11-10，D8） ====================

# 以探测模式加载模块（只定义函数），再执行给定代码
_wp_eval() {
  DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TEST_TMPDIR}/wp-st" DEBNAS_FEATURE_DIR="${BATS_TEST_TMPDIR}/wp-st" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; set -euo pipefail; eval "$2"' _ "$MODULE_FILE" "$1"
}

@test "wallpaper: [D8] 两次下载都带 --max-filesize，下载后核对大小" {
  [[ "$(sed -n '/^update_wallpaper()/,/^}/p' "$MODULE_FILE" | grep -c -- '--max-filesize "\$WALLPAPER_')" -eq 2 ]]
  sed -n '/^update_wallpaper()/,/^}/p' "$MODULE_FILE" | grep -q 'img_size" -gt "$WALLPAPER_IMAGE_MAX_BYTES"'
}

@test "wallpaper: [D8] _wp_image_magic_ok 只接受 PNG/JPEG 文件头" {
  local d="${BATS_TEST_TMPDIR}/magic"
  mkdir -p "$d"
  printf '\x89PNG\r\n\x1a\nrest' > "$d/a.png"
  printf '\xff\xd8\xff\xe0rest' > "$d/b.jpg"
  printf '<html>error</html>' > "$d/c.html"
  : > "$d/empty"
  run _wp_eval "_wp_image_magic_ok '$d/a.png' && _wp_image_magic_ok '$d/b.jpg' && echo OK1
    _wp_image_magic_ok '$d/c.html' || echo OK2
    _wp_image_magic_ok '$d/empty' || echo OK3"
  [[ "$status" -eq 0 ]]
  [[ "$output" == $'OK1\nOK2\nOK3' ]]
}

@test "wallpaper: [D8] bing_url 不以 / 开头或含 @ 时拒绝，不发起图片下载" {
  local d="${BATS_TEST_TMPDIR}/wp-url" u
  mkdir -p "$d"
  for u in '@evil.example/x.jpg' '/th?id=a@evil.example' 'evil.example/x.jpg'; do
    rm -f "$d/calls"
    run _wp_eval "check_cockpit_version() { return 0; }; prepare_env() { :; }
      curl() { echo call >> '$d/calls'; printf '%s' '{\"url\":\"$u\",\"title\":\"t\"}'; }
      update_wallpaper && echo UPDATED || echo REJECTED"
    [[ "$output" == *REJECTED* ]]
    [[ "$(wc -l < "$d/calls")" -eq 1 ]]
  done
}

@test "wallpaper: [D8] Cockpit 未运行时禁用流程照常完成（不被 set -e 中止）" {
  run _wp_eval "feature_disable() { :; }; cron_unregister() { :; }; _wp_remove_branding_dir() { :; }
    write_file_if_changed() { :; }; module_mark_action() { :; }; systemctl() { return 3; }
    disable_bing_wallpaper; echo DONE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *DONE* ]]
}

# ==================== 图片文件头校验（行为） ====================

@test "wallpaper: _wp_image_magic_ok 接受 PNG/JPEG、拒绝其他格式" {
  local d
  d=$(mktemp -d)
  printf '\x89PNG\r\n\x1a\nrest' > "$d/a.png"
  printf '\xff\xd8\xff\xe0rest' > "$d/a.jpg"
  printf 'GIF89arest' > "$d/a.gif"
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/wallpaper/module.sh" >/dev/null 2>&1
    for f in a.png a.jpg a.gif missing.png; do
      if _wp_image_magic_ok "$2/$f"; then echo "$f=YES"; else echo "$f=NO"; fi
    done
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"a.png=YES"* ]]
  [[ "$output" == *"a.jpg=YES"* ]]
  [[ "$output" == *"a.gif=NO"* ]]
  [[ "$output" == *"missing.png=NO"* ]]
}
