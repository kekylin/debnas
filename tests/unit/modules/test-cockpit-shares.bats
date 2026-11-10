#!/usr/bin/env bats
# 测试: modules/cockpit-shares/module.sh — 安装共享管理面板（DebNAS 自研插件 / 45Drives 二选一）
# Mock 策略：元数据/结构 grep 断言 + sed 提取函数在临时目录中执行（不 source 整个模块，避免触发 main）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/cockpit-shares/module.sh"
PLUGIN_DIR="${DEBNAS_ROOT}/modules/cockpit-shares/plugin"
FD45_FILE="${DEBNAS_ROOT}/modules/cockpit-45drives.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# 从文件中提取若干函数定义到 $WORK/fn.sh 并 source
load_functions() {
  local file="$1"; shift
  local fn
  : > "$WORK/fn.sh"
  for fn in "$@"; do
    sed -n "/^${fn}()/,/^}/p" "$file" >> "$WORK/fn.sh"
  done
  # shellcheck disable=SC1091
  source "$WORK/fn.sh"
}

setup() {
  WORK=$(mktemp -d)
  log_info() { :; }
  log_success() { :; }
  log_warning() { :; }
  log_error() { echo "E: $*" >&2; }
  CONF_VAL=""
  config_read() { if [[ -n "$CONF_VAL" ]]; then echo "$CONF_VAL"; else echo "${3:-}"; fi; }
  PKGS_INSTALLED=""
  pkg_is_installed() { [[ " ${PKGS_INSTALLED} " == *" $1 "* ]]; }
  SHARES_45DRIVES_PKG="cockpit-file-sharing"
}

teardown() {
  [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"
}

# ==================== 元数据 ====================

@test "cockpit-shares: 元数据完整（模块名/分类/依赖 cockpit）" {
  [[ "$(parse_meta module)" == "cockpit-shares" ]]
  [[ "$(parse_meta category)" == "管理面板" ]]
  [[ -n "$(parse_meta name)" && -n "$(parse_meta version)" && -n "$(parse_meta order)" ]]
  [[ "$(parse_meta depend_modules)" == *"cockpit"* ]]
}

@test "cockpit-shares: bash -n 语法通过 / 文件头与入口与其他模块一致" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
  grep -q 'set -euo pipefail' "$MODULE_FILE"
  grep -q 'source "${SCRIPT_DIR}/lib/bootstrap.sh"' "$MODULE_FILE"
  grep -q '^main()' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "cockpit-shares: 无 eval、无 rm -rf、不直调 systemctl enable" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>' || false
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q 'rm -rf' || false
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q 'systemctl enable' || false
  grep -q 'service_ensure "smbd"' "$MODULE_FILE"
}

@test "cockpit-shares: smb.conf 通过 write_file_if_changed 写入" {
  grep -q 'write_file_if_changed "\$conf" "\$new"' "$MODULE_FILE"
}

@test "cockpit-shares: 插件安装目录为固定常量，与 cockpit-45drives 一致" {
  grep -q '^SHARES_PLUGIN_DIR="/usr/share/cockpit/debnas-shares"$' "$MODULE_FILE"
  grep -q '^DEBNAS_SHARES_PLUGIN_DIR="/usr/share/cockpit/debnas-shares"$' "$FD45_FILE"
}

@test "cockpit-shares: 插件文件齐全且不引用外部资源" {
  for f in manifest.json index.html shares.js shares.css; do
    [[ -f "${PLUGIN_DIR}/${f}" ]]
  done
  ! grep -qE 'https?://' "${PLUGIN_DIR}/index.html" || false
  ! grep -qE '(src|href)="https?://' "${PLUGIN_DIR}/index.html" "${PLUGIN_DIR}/shares.js" || false
  grep -q '"label": "共享管理"' "${PLUGIN_DIR}/manifest.json"
  grep -q '../base1/cockpit.js' "${PLUGIN_DIR}/index.html"
}

@test "cockpit-shares: 插件 JS 不使用 innerHTML / eval，命令只用参数数组" {
  ! grep -vE '^[[:space:]]*(\*|//)' "${PLUGIN_DIR}/shares.js" | grep -qE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(' || false
  ! grep -q 'cockpit.script' "${PLUGIN_DIR}/shares.js" || false
  ! grep -qE 'spawn\(\["(sh|bash)"' "${PLUGIN_DIR}/shares.js" || false
  grep -q '"smbpasswd", "-s", "-a"' "${PLUGIN_DIR}/shares.js"
}

@test "cockpit-shares: 插件与 45Drives 共用后端文件" {
  grep -q '/etc/exports.d/cockpit-file-sharing.exports\|EXPORTS_DIR + "/cockpit-file-sharing.exports"' "${PLUGIN_DIR}/shares.js"
  grep -q '"net", "conf", "listshares"' "${PLUGIN_DIR}/shares.js"
  ! grep -q '"/etc/exports"' "${PLUGIN_DIR}/shares.js" || false
}

@test "cockpit-shares: 插件 JS 语法正确（有 node 时检查）" {
  command -v node >/dev/null 2>&1 || skip "node 不可用"
  run node --check "${PLUGIN_DIR}/shares.js"
  [[ "$status" -eq 0 ]]
}

@test "cockpit-shares: debnas.conf.default 声明 file_sharing_ui=debnas" {
  grep -q '^file_sharing_ui=debnas$' "${DEBNAS_ROOT}/config/debnas.conf.default"
  grep -q '^file_sharing_nfs=' "${DEBNAS_ROOT}/config/debnas.conf.default"
}

@test "cockpit-shares: 一键方案包含 cockpit-shares 且不直接包含 cockpit-45drives" {
  for f in "${DEBNAS_ROOT}"/config/solutions/*.list; do
    grep -qx 'cockpit-shares' "$f"
    ! grep -qx 'cockpit-45drives' "$f" || false
  done
}

# ==================== shares_ui_choice ====================

@test "shares_ui_choice: 默认 debnas，大小写不敏感，非法值回落 debnas" {
  load_functions "$MODULE_FILE" shares_legacy_45drives shares_ui_choice
  [[ "$(shares_ui_choice)" == "debnas" ]]
  CONF_VAL="45Drives"
  [[ "$(shares_ui_choice)" == "45drives" ]]
  CONF_VAL="bogus"
  [[ "$(shares_ui_choice 2>/dev/null)" == "debnas" ]]
}

@test "main: file_sharing_ui=45drives 时转交 cockpit-45drives 模块" {
  sed -n '/^main()/,/^}/p' "$MODULE_FILE" | grep -q 'exec bash "${SCRIPT_DIR}/modules/cockpit-45drives.sh"'
}

# ==================== shares_confirm_switch（非交互按配置） ====================

@test "shares_confirm_switch: 非交互时仅当配置与目标一致才同意切换" {
  load_functions "$MODULE_FILE" shares_legacy_45drives shares_ui_choice shares_confirm_switch
  CONF_VAL="debnas"
  run shares_confirm_switch debnas "t" "d" < /dev/null
  [[ "$status" -eq 0 ]]
  run shares_confirm_switch 45drives "t" "d" < /dev/null
  [[ "$status" -ne 0 ]]
}

# ==================== shares_want_nfs（config_get_bool 三态） ====================

@test "shares_want_nfs: 1/true 安装，0/off 不装，未设置时按已装/非交互判断" {
  load_functions "${DEBNAS_ROOT}/lib/system/config.sh" config_get_bool
  load_functions "$MODULE_FILE" shares_want_nfs
  NFS_INSTALLED=1
  pkg_is_installed() { [[ "$NFS_INSTALLED" -eq 0 ]]; }
  CONF_VAL=1;    run shares_want_nfs < /dev/null; [[ "$status" -eq 0 ]]
  CONF_VAL=true; run shares_want_nfs < /dev/null; [[ "$status" -eq 0 ]]
  CONF_VAL=0;    run shares_want_nfs < /dev/null; [[ "$status" -eq 1 ]]
  CONF_VAL=OFF;  run shares_want_nfs < /dev/null; [[ "$status" -eq 1 ]]
  CONF_VAL="";   run shares_want_nfs < /dev/null; [[ "$status" -eq 1 ]]
  NFS_INSTALLED=0
  CONF_VAL="";   run shares_want_nfs < /dev/null; [[ "$status" -eq 0 ]]
  CONF_VAL=0;    run shares_want_nfs < /dev/null; [[ "$status" -eq 1 ]]
}

# ==================== smbconf_with_registry ====================

@test "smbconf_with_registry: 插入到 [global] 最后一个参数之后，其余内容不变" {
  load_functions "$MODULE_FILE" smbconf_with_registry
  input=$'#c\n[global]\n   workgroup = W\n   # x\n\n[data]\n path=/d'
  expected=$'#c\n[global]\n   workgroup = W\n   include = registry\n   # x\n\n[data]\n path=/d'
  [[ "$(printf '%s\n' "$input" | smbconf_with_registry)" == "$expected" ]]
}

@test "smbconf_with_registry: 已启用（include / config backend，大小写不敏感）时原样输出" {
  load_functions "$MODULE_FILE" smbconf_with_registry
  a=$'[global]\n   Include = Registry\n[x]\npath=/x'
  [[ "$(printf '%s\n' "$a" | smbconf_with_registry)" == "$a" ]]
  b=$'[Global]\n config backend = registry'
  [[ "$(printf '%s\n' "$b" | smbconf_with_registry)" == "$b" ]]
}

@test "smbconf_with_registry: 没有 [global] 时在开头新建" {
  load_functions "$MODULE_FILE" smbconf_with_registry
  out=$(printf '[a]\npath=/a\n' | smbconf_with_registry)
  [[ "$out" == $'[global]\n   include = registry\n\n[a]\npath=/a' ]]
}

@test "smbconf_with_registry: 其他段里的 include = registry 不算启用" {
  load_functions "$MODULE_FILE" smbconf_with_registry
  out=$(printf '[global]\n workgroup = W\n[x]\n include = registry\n' | smbconf_with_registry)
  [[ "$(grep -c 'include = registry' <<< "$out")" -eq 2 ]]
}

# ==================== shares_deploy_plugin ====================

@test "shares_deploy_plugin: 部署 644 文件、幂等、清理多余文件" {
  load_functions "$MODULE_FILE" _shares_plugin_diff shares_deploy_plugin
  dst="$WORK/dst"
  run shares_deploy_plugin "$PLUGIN_DIR" "$dst" "$(id -un)"
  [[ "$status" -eq 0 ]]
  [[ "$(stat -c %a "$dst")" == "755" ]]
  [[ "$(stat -c %a "$dst/shares.js")" == "644" ]]
  cmp -s "$PLUGIN_DIR/manifest.json" "$dst/manifest.json"
  touch "$dst/stale.js"
  shares_deploy_plugin "$PLUGIN_DIR" "$dst" "$(id -un)"
  [[ ! -e "$dst/stale.js" ]]
  [[ -f "$dst/index.html" ]]
}

@test "shares_deploy_plugin: 源目录不完整时失败且不创建目标" {
  load_functions "$MODULE_FILE" _shares_plugin_diff shares_deploy_plugin
  mkdir "$WORK/src"
  run shares_deploy_plugin "$WORK/src" "$WORK/dst" "$(id -un)"
  [[ "$status" -ne 0 ]]
  [[ ! -e "$WORK/dst" ]]
  run shares_deploy_plugin "$PLUGIN_DIR" "" "$(id -un)"
  [[ "$status" -ne 0 ]]
}

# ==================== cockpit-45drives 侧：移除自研插件 ====================

@test "remove_debnas_shares_plugin_dir: 拒绝空路径与非固定常量路径" {
  load_functions "$FD45_FILE" remove_debnas_shares_plugin_dir
  DEBNAS_SHARES_PLUGIN_DIR="/usr/share/cockpit/debnas-shares"
  run remove_debnas_shares_plugin_dir ""
  [[ "$status" -ne 0 ]]
  run remove_debnas_shares_plugin_dir "/usr/share/cockpit"
  [[ "$status" -ne 0 ]]
  run remove_debnas_shares_plugin_dir "/usr/share/cockpit/debnas-shares/"
  [[ "$status" -ne 0 ]]
  run remove_debnas_shares_plugin_dir "$WORK"
  [[ "$status" -ne 0 ]]
  [[ -d "$WORK" ]]
}

@test "remove_debnas_shares_plugin_dir: 只删除固定常量目录" {
  load_functions "$FD45_FILE" remove_debnas_shares_plugin_dir
  DEBNAS_SHARES_PLUGIN_DIR="$WORK/debnas-shares"
  mkdir -p "$DEBNAS_SHARES_PLUGIN_DIR"
  touch "$DEBNAS_SHARES_PLUGIN_DIR/index.html" "$WORK/keep"
  run remove_debnas_shares_plugin_dir "$WORK/debnas-shares"
  [[ "$status" -eq 0 ]]
  [[ ! -e "$WORK/debnas-shares" && -f "$WORK/keep" ]]
}

@test "ensure_debnas_shares_removed: 非交互且配置不是 45drives 时不删除并返回失败" {
  load_functions "$FD45_FILE" _fd45_ui_choice remove_debnas_shares_plugin_dir ensure_debnas_shares_removed
  DEBNAS_SHARES_PLUGIN_DIR="$WORK/debnas-shares"
  mkdir -p "$DEBNAS_SHARES_PLUGIN_DIR"
  CONF_VAL="debnas"
  run ensure_debnas_shares_removed < /dev/null
  [[ "$status" -ne 0 ]]
  [[ -d "$DEBNAS_SHARES_PLUGIN_DIR" ]]
  CONF_VAL="45drives"
  run ensure_debnas_shares_removed < /dev/null
  [[ "$status" -eq 0 ]]
  [[ ! -e "$DEBNAS_SHARES_PLUGIN_DIR" ]]
}

@test "cockpit-45drives: 安装成功后记录 file_sharing_ui=45drives" {
  grep -A20 '^main()' "$FD45_FILE" | grep -q 'ensure_debnas_shares_removed'
  grep -A20 '^main()' "$FD45_FILE" | grep -q 'config_write "global" "file_sharing_ui" "45drives"'
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/cockpit-shares/module.sh"
PROBE_STATE="${BATS_TMPDIR}/cockpit-shares-probe-state"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="$PROBE_STATE" DEBNAS_FEATURE_DIR="$PROBE_STATE" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "cockpit-shares-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "cockpit-shares-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "cockpit-shares-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "cockpit-shares-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="$PROBE_STATE" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "cockpit-shares-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "cockpit-shares-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "cockpit-shares-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="$PROBE_STATE" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status cockpit-shares
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

@test "cockpit-shares-contract: exec cockpit-45drives 只出现在 main 函数体内" {
  local body
  body=$(sed -n '/^main()/,/^}/p' "$PROBE_FILE")
  [[ "$body" == *'exec bash "${SCRIPT_DIR}/modules/cockpit-45drives.sh"'* ]]
  [[ "$(grep -c '^[[:space:]]*exec ' "$PROBE_FILE")" -eq 1 ]]
}

@test "cockpit-shares-contract: file_sharing_ui=45drives 时探测加载与 status/plan 均不触发 exec" {
  local conf="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/cockpit-shares-probe.conf"
  printf 'file_sharing_ui=45drives\n' > "$conf"
  # 若触发 exec，当前 shell 被替换，SOURCED_OK / DONE 不会输出
  run env DEBNAS_GLOBAL_CONF="$conf" DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="$PROBE_STATE" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK; module_status 2>/dev/null; module_plan 2>/dev/null; echo DONE' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "SOURCED_OK" ]]
  [[ "${lines[1]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|file_sharing_ui=45drives ]]
  [[ "${lines[2]}" == info\|cockpit-45drives\|* ]]
  [[ "${lines[-1]}" == "DONE" ]]
}

# ==================== 回归：老用户升级（未设置 file_sharing_ui + 已装 45Drives） ====================

@test "C3 shares_ui_choice: 未设置 file_sharing_ui 且已装 cockpit-file-sharing 时按 45drives 处理" {
  load_functions "$MODULE_FILE" shares_legacy_45drives shares_ui_choice
  PKGS_INSTALLED="cockpit-file-sharing"
  CONF_VAL=""
  [[ "$(shares_ui_choice --quiet)" == "45drives" ]]
  shares_legacy_45drives
  # 显式配置优先：配置为 debnas 时仍按 debnas（会卸载 45Drives）
  CONF_VAL="debnas"
  [[ "$(shares_ui_choice --quiet)" == "debnas" ]]
  ! shares_legacy_45drives || false
  # 未装 45Drives 时未设置仍为默认 debnas
  PKGS_INSTALLED=""
  CONF_VAL=""
  [[ "$(shares_ui_choice --quiet)" == "debnas" ]]
}

@test "C3 shares_confirm_switch: 老用户升级场景非交互不同意卸载 45Drives" {
  load_functions "$MODULE_FILE" shares_legacy_45drives shares_ui_choice shares_confirm_switch
  PKGS_INSTALLED="cockpit-file-sharing"
  CONF_VAL=""
  run shares_confirm_switch debnas "t" "d" < /dev/null
  [[ "$status" -ne 0 ]]
}

@test "C3 main: 老用户升级时先写入 file_sharing_ui=45drives 并提示切换方法，再转交 cockpit-45drives" {
  local body
  body=$(sed -n '/^main()/,/^}/p' "$MODULE_FILE")
  [[ "$body" == *'if shares_legacy_45drives; then'* ]]
  [[ "$body" == *'config_write "global" "file_sharing_ui" "45drives"'* ]]
  [[ "$body" == *'file_sharing_ui 改为 debnas 后重新运行'* ]]
  # 固化写入在 exec 之前、在 shares_remove_45drives 之前
  local l_legacy l_exec l_remove
  l_legacy=$(grep -n 'if shares_legacy_45drives; then' <<< "$body" | head -1 | cut -d: -f1)
  l_exec=$(grep -n 'exec bash' <<< "$body" | cut -d: -f1)
  l_remove=$(grep -n 'shares_remove_45drives ||' <<< "$body" | cut -d: -f1)
  (( l_legacy < l_exec && l_exec < l_remove ))
}

@test "C3 module_plan: 老用户升级时预演写入 file_sharing_ui=45drives" {
  sed -n '/^module_plan()/,/^}/p' "$MODULE_FILE" | grep -q '老用户升级.*写入 file_sharing_ui=45drives'
}

@test "C3 _fd45_ui_choice: 未设置且已装 cockpit-file-sharing 时为 45drives（与 cockpit-shares 一致）" {
  load_functions "$FD45_FILE" _fd45_ui_choice
  PKGS_INSTALLED="cockpit-file-sharing"
  CONF_VAL=""
  [[ "$(_fd45_ui_choice)" == "45drives" ]]
  CONF_VAL="debnas"
  [[ "$(_fd45_ui_choice)" == "debnas" ]]
  PKGS_INSTALLED=""
  CONF_VAL=""
  [[ "$(_fd45_ui_choice)" == "debnas" ]]
}

# ==================== 回归：插件安全（结构性断言；行为由 node 测试覆盖） ====================

@test "C1 shares.js: spawn 对 argv[0] 之外以 - 开头的参数做选项白名单检查" {
  local js="${PLUGIN_DIR}/shares.js"
  grep -q 'const flags = options.flags || \[\];' "$js"
  grep -q 'delete options.flags;' "$js"
  grep -q 'a.startsWith("-") && !flags.some(' "$js"
}

@test "C1 shares.js: 浏览对话框只接受以 / 开头的目录，find 声明了允许的选项" {
  local js="${PLUGIN_DIR}/shares.js"
  grep -q '!dir.startsWith("/")' "$js"
  grep -q '{ flags: \["-mindepth", "-maxdepth", "-type", "-printf"\] }' "$js"
}

@test "C1 shares.js: net conf showshare/delshare/setparm 前校验共享名" {
  local js="${PLUGIN_DIR}/shares.js"
  grep -q '^    function existingShareNameError(name)' "$js"
  [[ "$(grep -c 'const ne = existingShareNameError(' "$js")" -ge 3 ]]
  ! grep -q 'spawn(\["net", "conf", "delshare", s.name\])' "$js" || false
}

@test "C2 shares.js: Samba/NFS 写入 realpath 结果，并检查上级目录属主与写权限" {
  local js="${PLUGIN_DIR}/shares.js"
  grep -q '^    async function resolveSharePath(p, prevPath)' "$js"
  grep -q 'next.path = await resolveSharePath(next.path, prevPath);' "$js"
  grep -q 'const real = await resolveSharePath(p, isNew ? "" : entry.path);' "$js"
  grep -q 'path: real, clients' "$js"
  grep -q '"%u:%a:%n"' "$js"
}

@test "C6 shares.js: exports 行内注释保真、路径八进制转义、主机不得以 - 开头、空主机项可编辑" {
  local js="${PLUGIN_DIR}/shares.js"
  grep -q '^    function splitExportComment(line)' "$js"
  grep -q 'if (e.src && e.src.length) out.push(...e.src);' "$js"
  grep -q 'toString(8).padStart(3, "0")' "$js"
  grep -q 'const NFS_HOST_RE = /^(?!-)' "$js"
  grep -q 'f.host === "" && f.allowEmptyHost' "$js"
}

@test "C7 shares.js: * + no_root_squash/insecure、anonuid/anongid=0 时确认" {
  local js="${PLUGIN_DIR}/shares.js"
  grep -q '^    function nfsRiskWarnings(clients)' "$js"
  grep -q 'anon(uid|gid)=0+' "$js"
  grep -q 'const risks = nfsRiskWarnings(clients);' "$js"
}

@test "C8 shares.js: 新建失败 delshare 回滚、编辑失败恢复、未知参数名整体不写" {
  local js="${PLUGIN_DIR}/shares.js" body
  body=$(sed -n '/^    async function saveSambaShare(/,/^    }/p' "$js")
  [[ "$body" == *'await smbDelShare(next.name);'* ]]
  [[ "$body" == *'await applyParams(next.name, before);'* ]]
  [[ "$body" == *'smbParamKnown(k)'* ]]
  # 参数名校验在 addshare 之前
  local l_chk l_add
  l_chk=$(grep -n 'smbParamKnown(k)' <<< "$body" | cut -d: -f1)
  l_add=$(grep -n '"net", "conf", "addshare"' <<< "$body" | cut -d: -f1)
  (( l_chk < l_add ))
}

@test "C9 shares.js: 删除导入段时保留下一段上方的注释块" {
  sed -n '/^    function removeSections(/,/^    }/p' "${PLUGIN_DIR}/shares.js" | grep -q 'end < parsed.lines.length'
}

