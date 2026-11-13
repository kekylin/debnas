#!/usr/bin/env bats
# 测试: 2026-11-10 跟进修复（安装/更新入口）
#   - install.sh 兼容旧版安装命令 -s github@main / -s gitee@main
#   - 全局命令包装脚本单一来源（DEBNAS-DEPLOY 区块 deploy_install_wrapper）：install.sh 与 debnas update 共用，
#     旧版包装脚本 / 软链接被正确替换
#   - 仓库打包规则：tests/、docs/ 入库（CI 需要），发布包经 .gitattributes export-ignore 排除，keys/ 留在包里
#   - ci.yml 每个 job 在 checkout 之前先装 git
# 技术: 临时目录隔离，不触碰 /opt/debnas、/usr/local/bin；不联网

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  WORK="$(mktemp -d "${BATS_TMPDIR}/compat.XXXXXX")"
  export DEBNAS_UPDATE_LOCK="${WORK}/update.lock"
}

teardown() {
  [[ -n "${WORK:-}" ]] && rm -rf -- "$WORK"
}

# 在独立 bash 进程中 source install.sh 后调用其函数
_inst() {
  bash -c 'source "$1"; shift; "$@"' _ "${DEBNAS_ROOT}/install.sh" "$@"
}

# ==================== 旧版安装命令 -s 平台@分支 ====================

@test "install.sh: -s github@main 按 --region global 处理并提示（旧版安装命令兼容）" {
  run bash -c 'source "$1"; parse_args -s github@main; echo "REGION=$REGION UNSIGNED=$UNSIGNED_MODE BRANCH=$INSTALL_BRANCH TAG=$INSTALL_TAG"' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"REGION=global UNSIGNED=0 BRANCH= TAG="* ]]
  [[ "$output" == *"-s 为旧版参数，已按 --region global 处理；新写法见 --help"* ]]
  [[ "$output" != *"未知参数"* ]]
}

@test "install.sh: -s gitee@main 按 --region cn 处理；分支部分被忽略（仍安装签名版本）" {
  run bash -c 'source "$1"; parse_args -s gitee@main; echo "REGION=$REGION UNSIGNED=$UNSIGNED_MODE BRANCH=$INSTALL_BRANCH"' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -eq 0 && "$output" == *"REGION=cn UNSIGNED=0 BRANCH="* ]]
  [[ "$output" == *"已按 --region cn 处理"* ]]
  run bash -c 'source "$1"; parse_args -s gitee@dev --yes; echo "REGION=$REGION UNSIGNED=$UNSIGNED_MODE BRANCH=$INSTALL_BRANCH YES=$FORCE_YES"' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -eq 0 && "$output" == *"REGION=cn UNSIGNED=0 BRANCH= YES=1"* ]]
}

@test "install.sh: -s 格式非法 → 报错并给出新用法" {
  local bad
  for bad in "main" "gitlab@main" "github@" "@main" "github@ma in" 'github@$(id)' ""; do
    run bash -c 'source "$1"; parse_args -s "$2"; echo REACHED' _ "${DEBNAS_ROOT}/install.sh" "$bad"
    [[ "$status" -ne 0 ]]
    [[ "$output" != *REACHED* ]]
    [[ "$output" == *"-s 参数无效"* && "$output" == *"--region cn"* && "$output" == *"--region global"* ]]
  done
  # 缺少参数值
  run bash -c 'source "$1"; parse_args -s; echo REACHED' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -ne 0 && "$output" != *REACHED* && "$output" == *"-s 参数无效"* ]]
}

@test "install.sh: --help 列出 -s 兼容参数" {
  run _inst print_help
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"-s github@main"* && "$output" == *"-s gitee@main"* && "$output" == *"--region cn"* ]]
}

# ==================== 全局命令包装脚本 ====================

# 在独立进程里加载 lib 版 installer.sh 并调用函数
_lib() {
  bash -c 'source "$1/lib/core/constants.sh"; source "$1/lib/core/colors.sh"; source "$1/lib/core/logging.sh"
    source "$1/lib/system/installer.sh"; shift; "$@"' _ "${DEBNAS_ROOT}" "$@"
}

@test "包装脚本: install.sh 与 lib 生成的内容逐字一致（单一来源）" {
  run _inst deploy_install_wrapper "${WORK}/w-inst" /opt/debnas
  [[ "$status" -eq 0 ]]
  run _lib deploy_install_wrapper "${WORK}/w-lib" /opt/debnas
  [[ "$status" -eq 0 ]]
  cmp -s "${WORK}/w-inst" "${WORK}/w-lib"
  [[ -x "${WORK}/w-inst" && "$(stat -c %a "${WORK}/w-inst")" == "755" ]]
  bash -n "${WORK}/w-inst"
  grep -q '^exec bash /opt/debnas/bin/debnas "\$@"$' "${WORK}/w-inst"
  grep -q '/opt/.debnas.old' "${WORK}/w-inst"
  # install.sh 与 update 都走这一个函数，不再各自内联 heredoc
  sed -n '/^install_debnas_bin()/,/^}/p' "${DEBNAS_ROOT}/install.sh" | grep -q 'deploy_install_wrapper "$DEBNAS_BIN" "$DEBNAS_INSTALL_DIR"'
  run grep -c '<<WRAPPER' "${DEBNAS_ROOT}/install.sh"
  [[ "$output" == "0" ]]
}

@test "包装脚本: 目标是旧版软链接 → 替换链接本身，不改写 bin/debnas" {
  mkdir -p "${WORK}/opt/debnas/bin" "${WORK}/ulb"
  printf '#!/bin/bash\necho "REAL $*"\n' > "${WORK}/opt/debnas/bin/debnas"
  chmod +x "${WORK}/opt/debnas/bin/debnas"
  ln -s "${WORK}/opt/debnas/bin/debnas" "${WORK}/ulb/debnas"
  run _lib deploy_install_wrapper "${WORK}/ulb/debnas" "${WORK}/opt/debnas"
  [[ "$status" -eq 0 ]]
  [[ ! -L "${WORK}/ulb/debnas" && -f "${WORK}/ulb/debnas" && -x "${WORK}/ulb/debnas" ]]
  # 真正的入口没有被写成包装脚本（否则 exec 自己，死循环）
  [[ "$(sed -n 2p "${WORK}/opt/debnas/bin/debnas")" == 'echo "REAL $*"' ]]
  run "${WORK}/ulb/debnas" hi
  [[ "$status" -eq 0 && "$output" == "REAL hi" ]]
  # 目录里不留临时文件
  [[ "$(ls -A "${WORK}/ulb")" == "debnas" ]]
}

@test "包装脚本: 旧版内容被替换；内容已最新时不重写（inode 不变）" {
  mkdir -p "${WORK}/ulb"
  printf '#!/bin/bash\nexec bash /opt/debnas/bin/debnas "$@"\n' > "${WORK}/ulb/debnas"
  chmod +x "${WORK}/ulb/debnas"
  run _lib deploy_install_wrapper "${WORK}/ulb/debnas" /opt/debnas
  [[ "$status" -eq 0 ]]
  grep -q '被中断的更新' "${WORK}/ulb/debnas"
  local ino
  ino=$(stat -c %i "${WORK}/ulb/debnas")
  run _lib deploy_install_wrapper "${WORK}/ulb/debnas" /opt/debnas
  [[ "$status" -eq 0 && "$(stat -c %i "${WORK}/ulb/debnas")" == "$ino" ]]
  # 丢了可执行位也会重写
  chmod 644 "${WORK}/ulb/debnas"
  run _lib deploy_install_wrapper "${WORK}/ulb/debnas" /opt/debnas
  [[ "$status" -eq 0 && -x "${WORK}/ulb/debnas" ]]
}

@test "包装脚本: 目录不可写 / 参数缺失 → 返回 1 且不留临时文件" {
  run _lib deploy_install_wrapper "${WORK}/nosuch/debnas" /opt/debnas
  [[ "$status" -ne 0 && "$output" == *"无法写入全局命令"* ]]
  run _lib deploy_install_wrapper "" /opt/debnas
  [[ "$status" -ne 0 ]]
  run _inst deploy_install_wrapper "${WORK}/nosuch/debnas" /opt/debnas
  [[ "$status" -ne 0 && "$output" == "[FAIL] 无法写入全局命令"* ]]
}

@test "包装脚本: 安装目录缺失且有 .old 时回滚后启动" {
  local root="${WORK}/w"
  mkdir -p "$root/opt/.debnas.old/bin"
  printf '#!/bin/bash\necho "RAN $*"\n' > "$root/opt/.debnas.old/bin/debnas"
  run _inst deploy_install_wrapper "$root/debnas-wrapper" "$root/opt/debnas"
  [[ "$status" -eq 0 ]]
  run env DEBNAS_UPDATE_LOCK="$root/lock" bash "$root/debnas-wrapper" hello
  [[ "$status" -eq 0 && "$output" == *"RAN hello"* && "$output" == *"回滚"* ]]
  [[ -f "$root/opt/debnas/bin/debnas" && ! -e "$root/opt/.debnas.old" ]]
}

# 生成"新版本"的最小代码树并打成 tar 包：bin/debnas、lib/bootstrap.sh（桩：只提供 migration_run 并加载真实 installer.sh）
_mk_new_release_tarball() {
  local src="${WORK}/newsrc/debnas"
  mkdir -p "$src/bin" "$src/lib/system" "$src/modules"
  printf '#!/bin/bash\necho "NEW $*"\n' > "$src/bin/debnas"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "$src/lib/system/installer.sh"
  cat > "$src/lib/bootstrap.sh" <<'EOF'
migration_run() { echo migrated > "$(dirname "${BASH_SOURCE[0]}")/../MIGRATED"; }
source "$(dirname "${BASH_SOURCE[0]}")/system/installer.sh"
EOF
  tar -czf "${WORK}/new.tar.gz" -C "${WORK}/newsrc" debnas
}

# 运行真实的 cmd_update（路径改写到临时目录；下载/验签用桩，解压/部署/包装脚本刷新走真实代码）
# 参数：$1 - bin/debnas 文件
_run_cmd_update() {
  run bash -c '
    set -euo pipefail
    SRC="$1"; BIN="$2"; R="$3"
    log_info() { :; }; log_success() { :; }
    log_warning() { echo "WARN: $*" >&2; }; log_error() { echo "ERROR: $*" >&2; }
    config_read() { echo "cn"; }
    create_temp_dir() { mktemp -d "$R/tmp.XXXXXX"; }
    DEBNAS_VERSION="v0.0.1"
    DEBNAS_OPT_DIR="$R/opt/debnas"
    DEBNAS_BIN="$R/ulb/debnas"
    source "$SRC/lib/system/installer.sh"
    installer_load_release_key() { echo "0000000000000000000000000000000000000000"; }
    installer_download_release() { cp "$R/new.tar.gz" "$3/debnas-$2.tar.gz"; }
    installer_verify_release() { return 0; }
    eval "$(sed -n "/^cmd_update()/,/^}/p" "$BIN")"
    cmd_update --tag v9.9.9
  ' _ "${DEBNAS_ROOT}" "$1" "$WORK"
}

@test "debnas update: 成功后刷新包装脚本（旧版软链接 → 新版包装脚本，内容由新代码生成）" {
  _mk_new_release_tarball
  mkdir -p "${WORK}/opt/debnas/bin" "${WORK}/opt/debnas/lib" "${WORK}/opt/debnas/modules" "${WORK}/ulb"
  printf '#!/bin/bash\necho "OLD $*"\n' > "${WORK}/opt/debnas/bin/debnas"
  ln -s "${WORK}/opt/debnas/bin/debnas" "${WORK}/ulb/debnas"

  _run_cmd_update "${DEBNAS_ROOT}/bin/debnas"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"未能刷新"* ]]
  [[ -f "${WORK}/opt/debnas/MIGRATED" ]]
  # 包装脚本：不再是软链接，内容与 deploy_install_wrapper 生成的一致
  [[ ! -L "${WORK}/ulb/debnas" && -x "${WORK}/ulb/debnas" ]]
  _lib deploy_install_wrapper "${WORK}/expected" "${WORK}/opt/debnas"
  cmp -s "${WORK}/ulb/debnas" "${WORK}/expected"
  # 新版入口没有被包装脚本覆盖，经包装脚本可启动
  run "${WORK}/ulb/debnas" x
  [[ "$status" -eq 0 && "$output" == "NEW x" ]]
}

@test "debnas update: 旧版包装脚本（无回滚逻辑）在更新后被换成新版" {
  _mk_new_release_tarball
  mkdir -p "${WORK}/opt/debnas/bin" "${WORK}/opt/debnas/lib" "${WORK}/opt/debnas/modules" "${WORK}/ulb"
  printf '#!/bin/bash\necho "OLD $*"\n' > "${WORK}/opt/debnas/bin/debnas"
  printf '#!/bin/bash\nexec bash %s/opt/debnas/bin/debnas "$@"\n' "$WORK" > "${WORK}/ulb/debnas"
  chmod +x "${WORK}/ulb/debnas"
  _run_cmd_update "${DEBNAS_ROOT}/bin/debnas"
  [[ "$status" -eq 0 ]]
  grep -q '被中断的更新' "${WORK}/ulb/debnas"
  grep -q 'flock -n' "${WORK}/ulb/debnas"
}

@test "debnas update: 新版本没有 deploy_install_wrapper（降级到旧版）时只告警不失败" {
  _mk_new_release_tarball
  # 把"新版本"换成没有包装脚本函数的旧代码
  printf 'migration_run() { :; }\n' > "${WORK}/newsrc/debnas/lib/bootstrap.sh"
  tar -czf "${WORK}/new.tar.gz" -C "${WORK}/newsrc" debnas
  mkdir -p "${WORK}/opt/debnas/bin" "${WORK}/opt/debnas/lib" "${WORK}/opt/debnas/modules" "${WORK}/ulb"
  printf '#!/bin/bash\n' > "${WORK}/opt/debnas/bin/debnas"
  _run_cmd_update "${DEBNAS_ROOT}/bin/debnas"
  [[ "$status" -eq 0 && "$output" == *"未能刷新"* ]]
}

@test "bin/debnas: 启动时发现包装脚本过期或仍是软链接则换成当前版本（旧版 update 不刷新的补救）" {
  local body
  body=$(sed -n '/^main()/,/^}/p' "${DEBNAS_ROOT}/bin/debnas")
  [[ "$body" == *'deploy_install_wrapper "$DEBNAS_BIN" "$DEBNAS_OPT_DIR"'* ]]
  # 只在包装脚本已存在时动它；且位于 root 检查之后
  [[ "$body" == *'[[ -e "$DEBNAS_BIN" || -L "$DEBNAS_BIN" ]]'* ]]
  awk '/^main\(\)/,/^}/' "${DEBNAS_ROOT}/bin/debnas" | awk '/需要 root 权限/ { r = NR } /deploy_install_wrapper/ { w = NR } END { exit !(r && w && r < w) }'
}

# ==================== 打包规则（.gitignore / .gitattributes / ci.yml） ====================

@test "仓库: tests/ 不被 .gitignore 排除（CI 要跑 tests/run.sh）；docs/ 按项目约定不入库；tests/reports/ 仍忽略" {
  local gi="${DEBNAS_ROOT}/.gitignore"
  [[ -f "$gi" ]] || skip "发布包内没有 .gitignore"
  run grep -cxE '(/)?tests/?' "$gi"
  [[ "$output" == "0" ]]
  grep -qx 'docs/' "$gi"
  grep -qx 'tests/reports/' "$gi"
  grep -qx 'CLAUDE.md' "$gi"
}

@test "仓库: .gitattributes 用 export-ignore 排除开发目录，keys/ 等运行时目录不在其中" {
  local ga="${DEBNAS_ROOT}/.gitattributes"
  [[ -f "$ga" ]] || skip "发布包内没有 .gitattributes"
  local p
  for p in /tests /tools /.github /.gitattributes /.gitignore; do
    grep -qE "^${p//./\\.}[[:space:]]+export-ignore$" "$ga"
  done
  # 部署目录与信任根不得被排除
  for p in keys bin lib modules config compose install.sh README.md LICENSE; do
    run grep -E "^/?${p//./\\.}(/|[[:space:]])" "$ga"
    [[ "$status" -ne 0 ]]
  done
}

@test "仓库: git archive 产物不含 tests/docs/tools/.github，含 keys/；解压后可正常部署" {
  command -v git >/dev/null 2>&1 || skip "需要 git"
  [[ -f "${DEBNAS_ROOT}/.gitattributes" ]] || skip "发布包内没有 .gitattributes"
  local repo="${WORK}/repo" d
  mkdir -p "$repo"
  # 只复制会入库的内容（不依赖工作区本身是不是 git 仓库）
  for d in bin lib modules config compose keys tools docs .github; do
    [[ -e "${DEBNAS_ROOT}/${d}" ]] && cp -R "${DEBNAS_ROOT}/${d}" "$repo/"
  done
  mkdir -p "$repo/tests/unit"
  cp "${DEBNAS_ROOT}/tests/run.sh" "$repo/tests/"
  cp "${DEBNAS_ROOT}/install.sh" "${DEBNAS_ROOT}/README.md" "${DEBNAS_ROOT}/.gitattributes" "${DEBNAS_ROOT}/.gitignore" "$repo/"
  echo v0.0.1 > "$repo/LATEST"; echo sig > "$repo/LATEST.asc"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  git -C "$repo" archive --format=tar.gz --prefix=debnas/ -o "${WORK}/pkg.tar.gz" HEAD
  local list
  list=$(tar -tzf "${WORK}/pkg.tar.gz")
  grep -qx 'debnas/bin/debnas' <<<"$list"
  grep -qx 'debnas/keys/debnas-release.asc' <<<"$list"
  grep -qx 'debnas/keys/debnas-release.fpr' <<<"$list"
  grep -qx 'debnas/install.sh' <<<"$list"
  grep -qx 'debnas/lib/bootstrap.sh' <<<"$list"
  run grep -E '^debnas/(tests|docs|tools|\.github)/|^debnas/(\.gitattributes|\.gitignore|LATEST|LATEST\.asc)$' <<<"$list"
  [[ "$status" -ne 0 ]]

  # 解压 + deploy_tree（install.sh 与 update 共用）不依赖被排除的目录
  mkdir -p "${WORK}/extract"
  tar -xzf "${WORK}/pkg.tar.gz" -C "${WORK}/extract" --strip-components=1 --no-same-owner
  run _inst deploy_tree "${WORK}/extract" "${WORK}/opt/debnas"
  [[ "$status" -eq 0 ]]
  [[ -f "${WORK}/opt/debnas/bin/debnas" && -f "${WORK}/opt/debnas/keys/debnas-release.fpr" && -d "${WORK}/opt/debnas/modules" ]]
  # 部署后的树可独立加载（--version 不需要 root，也不引用 tests/docs/tools）
  run bash "${WORK}/opt/debnas/bin/debnas" --version
  [[ "$status" -eq 0 ]]
}

@test "运行时代码不引用发布包里没有的目录（tests/ docs/ tools/）" {
  # deploy_tree 的部署清单
  local body
  body=$(sed -n '/^deploy_tree()/,/^}/p' "${DEBNAS_ROOT}/lib/system/installer.sh")
  [[ "$body" == *"for d in bin lib modules config compose keys; do"* ]]
  [[ "$body" == *"for e in install.sh README.md LICENSE; do"* ]]
  # bin/ lib/ modules/ 中没有 source / bash 调用仓库内 tests、docs、tools 下文件的语句
  run grep -rnE '(source|bash|\.)[[:space:]]+"?\$\{?[A-Za-z_]*(ROOT|DIR)\}?/(tests|docs|tools)/' \
    "${DEBNAS_ROOT}/bin" "${DEBNAS_ROOT}/lib" "${DEBNAS_ROOT}/modules" "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -ne 0 ]]
}

@test "ci.yml: 每个 job 都在 actions/checkout 之前安装 git（否则 checkout 走归档接口，tests/ 被 export-ignore 排除）" {
  local ci="${DEBNAS_ROOT}/.github/workflows/ci.yml"
  [[ -f "$ci" ]] || skip "发布包内没有 .github/"
  local n_checkout
  n_checkout=$(grep -c 'uses: actions/checkout@' "$ci")
  [[ "$n_checkout" -ge 5 ]]
  # 每个 checkout 之前（同一 job 内）都出现过 apt-get install … git
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { git = 0 }
    /apt-get install .*[[:space:]]git([[:space:]]|$)/ { git = 1 }
    /uses: actions\/checkout@/ { if (!git) bad++ ; n++ }
    END { exit !(n > 0 && bad == 0) }' "$ci"
}
