#!/usr/bin/env bats
# 测试: lib/system/apt.sh — APT 操作封装

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # 创建 mock 命令目录
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"

  # 默认 mock apt-get: 成功
  cat > "$MOCK_BIN/apt-get" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/apt-get"

  # 兼容 apt 命令
  cat > "$MOCK_BIN/apt" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/apt"

  # 默认 dpkg: 包已安装（exit 0）
  cat > "$MOCK_BIN/dpkg" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/dpkg"

  # 默认 dpkg-query: 包已安装（pkg_is_installed 使用）
  cat > "$MOCK_BIN/dpkg-query" << 'INNEREOF'
#!/usr/bin/env bash
echo "installed"
INNEREOF
  chmod +x "$MOCK_BIN/dpkg-query"

  # 默认 fuser: 锁文件无占用（exit 1 = 无进程）
  cat > "$MOCK_BIN/fuser" << 'INNEREOF'
#!/usr/bin/env bash
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/fuser"

  # 默认 sleep: 无操作
  cat > "$MOCK_BIN/sleep" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/sleep"

  export PATH="$MOCK_BIN:$PATH"
  source "${DEBNAS_ROOT}/lib/system/apt.sh"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# ==================== 参数校验测试（参数化） ====================

@test "apt_install_safe / apt_remove_safe: 无参数报错 — 参数化" {
  local funcs=("apt_install_safe" "apt_remove_safe")
  for func in "${funcs[@]}"; do
    run "$func"
    [[ "$status" -ne 0 ]]
  done
}

# ==================== _apt_lock_available 测试 ====================

@test "_apt_lock_available: fuser 无占用时返回 0" {
  # fuser 对所有锁文件返回 exit 1（无进程占用）
  _apt_lock_available
}

@test "_apt_lock_available: fuser 占用时返回 1" {
  cat > "$MOCK_BIN/fuser" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/fuser"

  run _apt_lock_available
  [[ "$status" -ne 0 ]]
}

# ==================== apt_wait_for_lock 测试 ====================

@test "apt_wait_for_lock: 锁立即可用时返回 0" {
  apt_wait_for_lock 10
}

@test "apt_wait_for_lock: 锁超时时返回 1" {
  cat > "$MOCK_BIN/fuser" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/fuser"

  run apt_wait_for_lock 2
  [[ "$status" -ne 0 ]]
}

@test "apt_wait_for_lock: 自定义超时时间生效" {
  cat > "$MOCK_BIN/fuser" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/fuser"

  run apt_wait_for_lock 1
  [[ "$status" -ne 0 ]]
}

# ==================== apt_install_safe 测试 ====================

@test "apt_install_safe: 正常安装成功返回 0" {
  apt_install_safe "curl"
}

@test "apt_install_safe / apt_update_safe: 锁等待失败时返回非 0 — 参数化" {
  local funcs=("apt_install_safe:curl" "apt_update_safe")
  for entry in "${funcs[@]}"; do
    local func="${entry%%:*}" arg="${entry#*:}"
    [[ "$func" == "$arg" ]] && arg=""

    cat > "$MOCK_BIN/fuser" << 'INNEREOF'
#!/usr/bin/env bash
exit 0
INNEREOF
    chmod +x "$MOCK_BIN/fuser"

    if [[ -n "$arg" ]]; then
      run "$func" "$arg"
    else
      run "$func"
    fi
    [[ "$status" -ne 0 ]]
  done
}

@test "apt_install_safe: apt 失败时返回非 0" {
  cat > "$MOCK_BIN/apt" << 'INNEREOF'
#!/usr/bin/env bash
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/apt"

  run apt_install_safe "badpkg"
  [[ "$status" -ne 0 ]]
}

# ==================== apt_remove_safe 测试 ====================

@test "apt_remove_safe: 默认 purge 模式成功" {
  run apt_remove_safe "curl"
  [[ "$status" -eq 0 ]]
}

@test "apt_remove_safe: APT_REMOVE_PURGE=0 使用 remove 模式" {
  export APT_REMOVE_PURGE=0
  # remove 模式不应以 purge 调用（退出码应为 0：成功）
  run apt_remove_safe "curl"
  [[ "$status" -eq 0 ]]
}

# ==================== apt_update_safe 测试 ====================

@test "apt_update_safe: 更新成功" {
  apt_update_safe
}

@test "apt_update_safe: apt-get update 失败时返回非 0" {
  cat > "$MOCK_BIN/apt" << 'INNEREOF'
#!/usr/bin/env bash
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/apt"

  run apt_update_safe
  [[ "$status" -ne 0 ]]
}

# ==================== apt_install_packages 测试 ====================

@test "apt_install_packages: 空参数返回 0" {
  apt_install_packages
}

@test "apt_install_packages: 所有包已安装时跳过" {
  # dpkg -s 返回 0 表示包已安装
  run apt_install_packages "curl" "wget"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"已安装"* || "$output" == *"无需"* ]]
}

@test "apt_install_packages: 部分包缺失时安装" {
  # dpkg-query 对 curl 返回 installed，对 wget 失败（未装）
  cat > "$MOCK_BIN/dpkg-query" << 'INNEREOF'
#!/usr/bin/env bash
case "$*" in
  *curl*) echo "installed" ;;
  *) exit 1 ;;
esac
INNEREOF
  chmod +x "$MOCK_BIN/dpkg-query"

  apt_install_packages "curl" "wget"
}

# ==================== 日志中的包名列表以空格连接 ====================
# 全局 IFS=$'\n\t' 下 "${arr[*]}" 会用换行连接，错误日志被拆成多行（真机发现）

@test "apt_install_safe: 失败日志中的多个包名以空格连接、单行输出" {
  cat > "$MOCK_BIN/apt" << 'INNEREOF'
#!/usr/bin/env bash
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/apt"
  [[ "$IFS" == $'\n\t' ]]
  run apt_install_safe cockpit cockpit-files pcp
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"cockpit cockpit-files pcp 安装失败"* ]]
  [[ "$output" == *"apt install cockpit cockpit-files pcp"* ]]
  ! grep -qx 'cockpit-files' <<<"$output"
}

@test "apt_install_packages / apt_remove_safe: 进度日志中的包名以空格连接" {
  cat > "$MOCK_BIN/dpkg-query" << 'INNEREOF'
#!/usr/bin/env bash
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/dpkg-query"
  run apt_install_packages vim curl
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"安装 vim curl..."* ]]
  run apt_remove_safe vim curl
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"卸载 vim curl..."* ]]
  [[ "$output" == *"vim curl 已卸载"* ]]
}

# ==================== TC-P2-REC-005: 锁超时传播链 ====================

@test "apt_update_safe: 锁等待失败时提前退出不调用 apt update（TC-P2-REC-005）" {
  # 使用文件标记检测 apt-get update 是否被调用
  local marker="${BATS_TMPDIR}/apt-update-called"
  rm -f "$marker"

  # apt-get mock：如果被调用则创建标记文件
  cat > "$MOCK_BIN/apt-get" << 'INNEREOF'
#!/usr/bin/env bash
touch "$1"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/apt-get"

  # 同样修改 apt mock
  cat > "$MOCK_BIN/apt" << 'INNEREOF'
#!/usr/bin/env bash
touch "$1"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/apt"

  # 覆盖 apt_wait_for_lock 函数（模拟锁等待超时）
  apt_wait_for_lock() { return 1; }

  run apt_update_safe "$marker"
  [[ "$status" -ne 0 ]]

  # 验证 apt-get update 从未被调用（标记文件不存在）
  [[ ! -f "$marker" ]]
}

# ==================== pkg_is_installed ====================

@test "pkg_is_installed: 只认 installed 状态" {
  local mb="$BATS_TMPDIR/pkgmock"
  mkdir -p "$mb"
  cat > "$mb/dpkg-query" << 'INNEREOF'
#!/usr/bin/env bash
case "${@: -1}" in
  okpkg) printf 'installed' ;;
  cfgpkg) printf 'config-files' ;;
  *) exit 1 ;;
esac
INNEREOF
  chmod +x "$mb/dpkg-query"
  PATH="$mb:$PATH" run pkg_is_installed okpkg
  [[ "$status" -eq 0 && -z "$output" ]]
  PATH="$mb:$PATH" run pkg_is_installed cfgpkg
  [[ "$status" -eq 1 ]]
  PATH="$mb:$PATH" run pkg_is_installed nopkg
  [[ "$status" -eq 1 ]]
  rm -rf "$mb"
}
