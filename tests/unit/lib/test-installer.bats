#!/usr/bin/env bats
# 测试: lib/system/installer.sh — 下载、解压、部署函数
# 覆盖 TC-ID: TC-P0-MOCK-001~003 + TC-P1-INST-001~005
# 技术: PATH Injection (wget/tar Mock) + 临时目录隔离

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"

  WORK_DIR="$BATS_TMPDIR/installer-work"
  mkdir -p "$WORK_DIR"
  # 非 root 测试环境：更新锁放到临时目录，避免 /run 不可写导致 deploy_lock 失败
  export DEBNAS_UPDATE_LOCK="$WORK_DIR/update.lock"

  source "${DEBNAS_ROOT}/lib/system/installer.sh"
}

teardown() {
  rm -rf "$MOCK_BIN" "$WORK_DIR"
}

# ==================== TC-P1-INST-001~002: installer_get_url ====================

@test "installer_get_url: region=cn 返回 Gitee URL（TC-P1-INST-001）" {
  run installer_get_url "cn"
  [[ "$output" == *"gitee.com"* ]]
  [[ "$output" == *"debnas"* ]]
}

@test "installer_get_url: region=global 返回 GitHub URL（TC-P1-INST-002）" {
  run installer_get_url "global"
  [[ "$output" == *"github.com"* ]]
  [[ "$output" == *"debnas"* ]]
}

@test "installer_get_url: 默认 region 返回 GitHub URL" {
  run installer_get_url
  [[ "$output" == *"github.com"* ]]
}

# ==================== TC-P0-MOCK-001: installer_download_branch 成功 ====================

@test "installer_download_branch: wget Mock 成功 → tarball 存在（TC-P0-MOCK-001）" {
  local tarball="$WORK_DIR/test.tar.gz"
  # 创建 wget mock：模拟下载"成功"（创建目标文件）
  cat > "$MOCK_BIN/wget" << 'INNEREOF'
#!/bin/bash
# 模拟 wget 成功：创建目标文件（最后两个参数之一）
for arg in "$@"; do
  if [[ "$arg" == "$1" ]]; then continue; fi  # skip if first arg
done
# -O <file> 模式：解析参数找到输出文件
while [[ $# -gt 0 ]]; do
  case "$1" in
    -O) shift; touch "$1"; shift ;;
    *) shift ;;
  esac
done
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/wget"

  PATH="$MOCK_BIN:/bin" run installer_download_branch "cn" "main" "$tarball"
  [[ "$status" -eq 0 ]]
  [[ -f "$tarball" ]]
}

# ==================== TC-P0-MOCK-002: 主源失败 + 回退成功 ====================

@test "installer_download_branch: 主源失败 + 备用源成功 → 返回 0（TC-P0-MOCK-002）" {
  local tarball="$WORK_DIR/test.tar.gz"
  # wget mock：第 1 次调用失败(exit 1)，第 2 次调用成功
  local counter_file="$BATS_TMPDIR/wget-counter"
  echo "0" > "$counter_file"
  cat > "$MOCK_BIN/wget" << 'INNEREOF'
#!/bin/bash
counter_file="$BATS_TMPDIR/wget-counter"
count=$(cat "$counter_file")
count=$((count + 1))
echo "$count" > "$counter_file"
if [[ "$count" -eq 1 ]]; then
  exit 1
fi
# 第 2 次成功：创建目标文件
while [[ $# -gt 0 ]]; do
  case "$1" in
    -O) shift; touch "$1"; shift ;;
    *) shift ;;
  esac
done
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/wget"
  export BATS_TMPDIR  # 让子进程的 mock 脚本可访问

  PATH="$MOCK_BIN:/bin" run installer_download_branch "cn" "main" "$tarball"
  [[ "$status" -eq 0 ]]
  [[ -f "$tarball" ]]
}

# ==================== TC-P0-MOCK-003: 双源均失败 ====================

@test "installer_download_branch: 双源均失败 → 返回 1（TC-P0-MOCK-003）" {
  local tarball="$WORK_DIR/test.tar.gz"
  # wget mock：始终失败
  cat > "$MOCK_BIN/wget" << 'INNEREOF'
#!/bin/bash
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/wget"

  PATH="$MOCK_BIN:/bin" run installer_download_branch "cn" "main" "$tarball"
  [[ "$status" -ne 0 ]]
  [[ ! -f "$tarball" ]]
}

# ==================== TC-P1-INST-003: installer_extract ====================

@test "installer_extract: 正常 tar.gz → strip-components=1 解压（TC-P1-INST-003）" {
  # 创建测试 tarball：debnas-main/bin/debnas（带一层目录前缀）
  local src_dir="$WORK_DIR/src"
  mkdir -p "$src_dir/bin" "$src_dir/lib"
  echo "#!/bin/bash" > "$src_dir/bin/debnas"
  echo "# lib file" > "$src_dir/lib/test.sh"

  # 打包（带 strip-components=1 会被去掉的前缀目录）
  local tarball="$WORK_DIR/test.tar.gz"
  cd "$WORK_DIR" && tar -czf "$tarball" -C "$src_dir" .

  # 解压
  local extract_dir="$WORK_DIR/extracted"
  run installer_extract "$tarball" "$extract_dir"
  [[ "$status" -eq 0 ]]
  [[ -d "$extract_dir" ]]
  [[ -f "$extract_dir/bin/debnas" ]]
  [[ -f "$extract_dir/lib/test.sh" ]]
}

@test "installer_extract: 无效 tarball → 返回 1" {
  local tarball="$WORK_DIR/invalid.tar.gz"
  echo "not a valid tar" > "$tarball"
  local extract_dir="$WORK_DIR/extracted"
  run installer_extract "$tarball" "$extract_dir"
  [[ "$status" -ne 0 ]]
}

# ==================== TC-P1-INST-004: installer_deploy 关键文件缺失 ====================

@test "installer_deploy: bin/debnas 缺失 → 返回 1（TC-P1-INST-004）" {
  # 创建源目录（缺少 bin/debnas）
  local src_dir="$WORK_DIR/src"
  mkdir -p "$src_dir/lib"
  echo "# lib" > "$src_dir/lib/test.sh"

  local install_dir="$WORK_DIR/install"
  run installer_deploy "$src_dir" "$install_dir"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"关键文件缺失"* ]]
}

# ==================== TC-P1-INST-005: installer_deploy 完整 E2E ====================

@test "installer_deploy: 完整部署成功 + bin/debnas 可执行（TC-P1-INST-005）" {
  # 创建完整的源目录结构
  local src_dir="$WORK_DIR/src"
  mkdir -p "$src_dir/bin" "$src_dir/lib" "$src_dir/modules"
  echo "#!/bin/bash" > "$src_dir/bin/debnas"
  echo "#!/bin/bash" > "$src_dir/bin/other-tool"
  echo "# lib" > "$src_dir/lib/core.sh"
  echo "# module" > "$src_dir/modules/test.sh"

  local install_dir="$WORK_DIR/install"
  run installer_deploy "$src_dir" "$install_dir"
  [[ "$status" -eq 0 ]]
  # 验证文件已复制
  [[ -f "$install_dir/bin/debnas" ]]
  [[ -f "$install_dir/lib/core.sh" ]]
  [[ -f "$install_dir/modules/test.sh" ]]
  # 验证可执行权限
  [[ -x "$install_dir/bin/debnas" ]]
}

# ==================== 补充: installer_download_branch global region ====================

@test "installer_download_branch: global region 主源 GitHub + 回退 Gitee" {
  local tarball="$WORK_DIR/test.tar.gz"
  # wget mock：第 1 次失败（GitHub），第 2 次成功（Gitee 回退）
  local counter_file="$BATS_TMPDIR/wget-counter2"
  echo "0" > "$counter_file"
  cat > "$MOCK_BIN/wget" << 'INNEREOF'
#!/bin/bash
counter_file="$BATS_TMPDIR/wget-counter2"
count=$(cat "$counter_file")
count=$((count + 1))
echo "$count" > "$counter_file"
if [[ "$count" -eq 1 ]]; then exit 1; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -O) shift; touch "$1"; shift ;;
    *) shift ;;
  esac
done
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/wget"
  export BATS_TMPDIR

  PATH="$MOCK_BIN:/bin" run installer_download_branch "global" "main" "$tarball"
  [[ "$status" -eq 0 ]]
  [[ -f "$tarball" ]]
}

# ==================== installer_deploy / deploy_tree：整树替换、可回滚、加锁 ====================

# 构造新版本源目录与旧安装目录
_mk_src_and_install() {
  SRC="$WORK_DIR/src"; INST="$WORK_DIR/opt/debnas"
  rm -rf "$SRC" "$WORK_DIR/opt"
  mkdir -p "$SRC/bin" "$SRC/lib" "$SRC/modules" "$INST/bin" "$INST/lib" "$INST/modules"
  echo "new" > "$SRC/bin/debnas"; echo "new" > "$SRC/lib/a.sh"; echo "new" > "$SRC/modules/keep.sh"
  echo "new" > "$SRC/install.sh"
  echo "old" > "$INST/bin/debnas"; echo "old" > "$INST/lib/a.sh"; echo "old" > "$INST/modules/keep.sh"
  echo "old" > "$INST/modules/removed.sh"
  printf 'tag=v1\n' > "$INST/RELEASE"
  mkdir -p "$INST/extra"; echo "x" > "$INST/extra/f"
  export DEBNAS_UPDATE_LOCK="$WORK_DIR/update.lock"
}

@test "installer_deploy: 整树替换——新版已删除的旧模块不残留，RELEASE 等非代码条目保留" {
  _mk_src_and_install
  run installer_deploy "$SRC" "$INST"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$INST/bin/debnas")" == "new" && "$(cat "$INST/lib/a.sh")" == "new" ]]
  [[ ! -e "$INST/modules/removed.sh" ]]
  [[ "$(cat "$INST/RELEASE")" == "tag=v1" && -f "$INST/extra/f" && -f "$INST/install.sh" ]]
  [[ -x "$INST/bin/debnas" ]]
  [[ ! -e "$WORK_DIR/opt/.debnas.old" && ! -e "$WORK_DIR/opt/.debnas.new" ]]
}

@test "installer_deploy: 组装新树失败 → 旧安装原封不动、暂存目录被清理" {
  _mk_src_and_install
  run bash -c 'source "$1/lib/system/installer.sh"
    cp() { [[ "$*" == *modules* ]] && return 1; command cp "$@"; }
    installer_deploy "$2" "$3"' _ "$DEBNAS_ROOT" "$SRC" "$INST"
  [[ "$status" -ne 0 ]]
  [[ "$(cat "$INST/bin/debnas")" == "old" && -f "$INST/modules/removed.sh" ]]
  [[ ! -e "$WORK_DIR/opt/.debnas.new" && ! -e "$WORK_DIR/opt/.debnas.old" ]]
}

@test "installer_deploy: 两次 rename 之间进程被 SIGKILL → deploy_recover 回滚到旧版本" {
  _mk_src_and_install
  # 第二次 rename（.new → 安装目录）前直接 SIGKILL 整个进程，模拟断电/kill -9
  run bash -c 'source "$1/lib/system/installer.sh"; target="$3"
    mv() { if [[ "${*: -1}" == "$target" ]]; then kill -KILL "$$" "$BASHPID"; sleep 5; fi; command mv "$@"; }
    installer_deploy "$2" "$3"' _ "$DEBNAS_ROOT" "$SRC" "$INST"
  [[ "$status" -eq 137 ]]
  # 中断现场：安装目录缺失，旧版本在 .debnas.old，新树在 .debnas.new
  [[ ! -e "$INST" && -d "$WORK_DIR/opt/.debnas.old" && -d "$WORK_DIR/opt/.debnas.new" ]]
  run deploy_recover "$INST"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$INST/bin/debnas")" == "old" && -f "$INST/modules/removed.sh" && -f "$INST/RELEASE" ]]
  [[ ! -e "$WORK_DIR/opt/.debnas.old" && ! -e "$WORK_DIR/opt/.debnas.new" ]]
  # 回滚后可再次正常部署
  run installer_deploy "$SRC" "$INST"
  [[ "$status" -eq 0 && "$(cat "$INST/bin/debnas")" == "new" ]]
}

@test "installer_deploy: rename 区间收到 TERM/INT 不打断切换（切换完成，残留由 deploy_recover 清理）" {
  _mk_src_and_install
  local sig
  for sig in TERM INT; do
    _mk_src_and_install
    run bash -c 'source "$1/lib/system/installer.sh"
      mv() { command mv "$@"; local rc=$?; [[ "${*: -1}" == *.debnas.old ]] && { kill -'"$sig"' "$$"; kill -'"$sig"' "$BASHPID"; }; return $rc; }
      installer_deploy "$2" "$3"' _ "$DEBNAS_ROOT" "$SRC" "$INST"
    # TERM 的默认动作会立即结束父进程，切换由忽略信号的子 shell 继续完成
    local i
    for (( i = 0; i < 50; i++ )); do [[ -f "$INST/bin/debnas" && ! -e "$WORK_DIR/opt/.debnas.new" ]] && break; sleep 0.1; done
    [[ "$(cat "$INST/bin/debnas")" == "new" ]]
    [[ ! -e "$WORK_DIR/opt/.debnas.new" ]]
    run deploy_recover "$INST"
    [[ "$status" -eq 0 && ! -e "$WORK_DIR/opt/.debnas.old" && "$(cat "$INST/bin/debnas")" == "new" ]]
  done
}

@test "deploy_recover: 无残留不动作；锁被占用时不碰残留；旧版逐目录残留 .lib.old 在 lib 缺失时改回" {
  _mk_src_and_install
  run deploy_recover "$INST"
  [[ "$status" -eq 0 && "$output" == "" ]]
  mkdir -p "$WORK_DIR/opt/.debnas.new"
  # 另一进程持锁（正在部署）：残留是它的暂存目录，不能删
  flock "$DEBNAS_UPDATE_LOCK" sleep 3 &
  local holder=$!
  sleep 0.3
  run deploy_recover "$INST"
  [[ "$status" -eq 0 && -d "$WORK_DIR/opt/.debnas.new" ]]
  run installer_deploy "$SRC" "$INST"
  [[ "$status" -ne 0 && "$output" == *"正在进行"* ]]
  [[ "$(cat "$INST/bin/debnas")" == "old" ]]
  wait "$holder" || true
  run deploy_recover "$INST"
  [[ ! -e "$WORK_DIR/opt/.debnas.new" ]]
  mv "$INST/lib" "$INST/.lib.old"
  run deploy_recover "$INST"
  [[ "$status" -eq 0 && -f "$INST/lib/a.sh" && ! -e "$INST/.lib.old" ]]
}

@test "cmd_update: 下载前加更新锁并处理部署残留；临时目录走 tempfile 自动清理；main 启动时回滚残留" {
  local body
  body=$(sed -n '/^cmd_update()/,/^}/p' "${DEBNAS_ROOT}/bin/debnas")
  [[ "$body" == *"deploy_lock || return 1"* && "$body" == *'deploy_recover "$install_dir" || return 1'* ]]
  [[ "$body" == *'create_temp_dir "update"'* && "$body" != *"mktemp -d /tmp/debnas-update"* ]]
  # 锁在下载之前
  awk '/^cmd_update\(\)/,/^}/' "${DEBNAS_ROOT}/bin/debnas" | awk '/deploy_lock/ { l = NR } /installer_download_/ && !d { d = NR } END { exit !(l && d && l < d) }'
  sed -n '/^main()/,/^}/p' "${DEBNAS_ROOT}/bin/debnas" | grep -q 'deploy_recover "/opt/debnas"'
}

@test "install.sh: 包含下载→解压→部署流程" {
  local install_sh="${DEBNAS_ROOT}/install.sh"
  grep -qE 'wget|curl|download' "$install_sh"
  grep -qE 'tar|extract|解压' "$install_sh"
  grep -qE 'deploy|安装|install_dir|/opt/debnas' "$install_sh"
}
