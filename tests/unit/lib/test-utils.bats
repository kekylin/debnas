#!/usr/bin/env bats
# 测试: lib/system/utils.sh — 系统版本检查工具库

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # 创建 mock 命令目录
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"

  # 默认: lsb_release 不可用（大部分 Debian 最小安装没有此命令）
  # 各测试可按需创建 mock lsb_release
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  export PATH="$MOCK_BIN:$PATH"

  # 假 os-release：只含 VERSION_ID（ID / VERSION_CODENAME 缺失时回退 lsb_release mock，
  # 使下方沿用 lsb_release mock 的用例与本机发行版无关）
  FAKE_OS_RELEASE="$MOCK_BIN/os-release"
  echo 'VERSION_ID="12"' > "$FAKE_OS_RELEASE"
  export DEBNAS_OS_RELEASE="$FAKE_OS_RELEASE"
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
}

teardown() {
  rm -rf "$MOCK_BIN"
  [[ -n "${TMP_PASSWD:-}" ]] && rm -rf "$TMP_PASSWD" || true
}

# ==================== _get_os_id 测试 ====================

@test "_get_os_id: 通过 lsb_release 获取（小写化）" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-is" ]] && echo "Debian"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  result=$(_get_os_id)
  [[ "$result" == "debian" ]]
}

@test "_get_os_id: Ubuntu 返回 ubuntu" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-is" ]] && echo "Ubuntu"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  result=$(_get_os_id)
  [[ "$result" == "ubuntu" ]]
}

# ==================== os-release 优先（lsb_release 仅作回退） ====================

@test "_get_os_id: 优先读 os-release 的 ID，不调用 lsb_release" {
  printf 'ID=debian\nVERSION_ID="13"\n' > "$FAKE_OS_RELEASE"
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
echo "Ubuntu"
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"
  result=$(_get_os_id)
  [[ "$result" == "debian" ]]
}

@test "get_system_codename: 优先读 VERSION_CODENAME（带引号也能解析）" {
  printf 'ID=debian\nVERSION_CODENAME="trixie"\n' > "$FAKE_OS_RELEASE"
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
echo "bookworm"
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"
  result=$(get_system_codename)
  [[ "$result" == "trixie" ]]
}

@test "get_system_codename: os-release 无代号时回退 lsb_release -cs" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-cs" ]] && echo "bookworm"
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"
  result=$(get_system_codename)
  [[ "$result" == "bookworm" ]]
}

@test "_os_release_field: 读取不污染调用方变量" {
  printf 'ID=debian\nNAME="Debian GNU/Linux"\nVERSION_CODENAME=trixie\n' > "$FAKE_OS_RELEASE"
  unset ID NAME VERSION_CODENAME
  result=$(_os_release_field NAME)
  [[ "$result" == "Debian GNU/Linux" ]]
  _os_release_field ID >/dev/null
  [[ -z "${ID:-}" && -z "${NAME:-}" && -z "${VERSION_CODENAME:-}" ]]
}

@test "_os_release_field: 文件不可读返回 1" {
  DEBNAS_OS_RELEASE="$MOCK_BIN/none"
  run _os_release_field ID
  [[ "$status" -eq 1 ]]
}

# ==================== _get_os_codename 测试 ====================

@test "_get_os_codename: 通过 lsb_release -cs 获取" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-cs" ]] && echo "bookworm"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  result=$(_get_os_codename)
  [[ "$result" == "bookworm" ]]
}


# ==================== _get_os_version_id 测试 ====================

@test "_get_os_version_id: 从 /etc/os-release 读取版本号" {
  result=$(_get_os_version_id)
  # 本机有 /etc/os-release，VERSION_ID 非空
  [[ -n "$result" ]]
  # 版本号应以数字开头
  [[ "$result" =~ ^[0-9] ]]
}

# ==================== _verify_os_is_debian 测试 ====================

@test "_verify_os_is_debian: Debian 系统返回 0" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-is" ]] && echo "Debian"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  _verify_os_is_debian
}

@test "_verify_os_is_debian: 非 Debian 系统返回非 0" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-is" ]] && echo "Ubuntu"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  run _verify_os_is_debian
  [[ "$status" -ne 0 ]]
}

# ==================== _is_development_codename 测试 ====================

@test "_is_development_codename: sid 是开发版本" {
  _is_development_codename "sid"
}

@test "_is_development_codename: testing 是开发版本" {
  _is_development_codename "testing"
}

@test "_is_development_codename: bookworm 不是开发版本" {
  run _is_development_codename "bookworm"
  [[ "$status" -ne 0 ]]
}

@test "_is_development_codename: forky 不是开发版本" {
  run _is_development_codename "forky"
  [[ "$status" -ne 0 ]]
}

@test "_is_development_codename: Sid 大写不识别" {
  run _is_development_codename "Sid"
  [[ "$status" -ne 0 ]]
}

# ==================== _verify_debian_min_codename 测试 ====================

@test "_verify_debian_min_codename: bookworm >= bookworm 通过" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-cs" ]] && echo "bookworm"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  _verify_debian_min_codename "bookworm"
}

@test "_verify_debian_min_codename: trixie >= bookworm 通过" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-cs" ]] && echo "trixie"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  _verify_debian_min_codename "bookworm"
}

@test "_verify_debian_min_codename: bullseye < bookworm 失败" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-cs" ]] && echo "bullseye"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  run _verify_debian_min_codename "bookworm"
  [[ "$status" -ne 0 ]]
}

@test "_verify_debian_min_codename: sid 始终通过（开发版本豁免）" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-cs" ]] && echo "sid"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  _verify_debian_min_codename "trixie"
}

# ==================== verify_system_support 测试 ====================

@test "verify_system_support: Debian bookworm 通过" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
case "$*" in
  *-is*) echo "Debian" ;;
  *-cs*) echo "bookworm" ;;
esac
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  verify_system_support
}

@test "verify_system_support: Ubuntu 失败并提示" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
case "$*" in
  *-is*) echo "Ubuntu" ;;
  *-cs*) echo "noble" ;;
esac
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  run verify_system_support
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Ubuntu"* || "$output" == *"不支持"* ]]
}

# ==================== verify_debian_12_13_support 测试 ====================

@test "verify_debian_12_13_support: bookworm 通过" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
case "$*" in
  *-is*) echo "Debian" ;;
  *-cs*) echo "bookworm" ;;
esac
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  verify_debian_12_13_support
}

@test "verify_debian_12_13_support: trixie 通过" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
case "$*" in
  *-is*) echo "Debian" ;;
  *-cs*) echo "trixie" ;;
esac
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  verify_debian_12_13_support
}

@test "verify_debian_12_13_support: forky 通过" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
case "$*" in
  *-is*) echo "Debian" ;;
  *-cs*) echo "forky" ;;
esac
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  verify_debian_12_13_support
}

@test "verify_debian_12_13_support: sid (开发版) 通过" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
case "$*" in
  *-is*) echo "Debian" ;;
  *-cs*) echo "sid" ;;
esac
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  verify_debian_12_13_support
}

# ==================== 公共查询函数测试 ====================

@test "get_system_codename: 返回系统代号" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-cs" ]] && echo "trixie"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  result=$(get_system_codename)
  [[ "$result" == "trixie" ]]
}

@test "is_supported_codename: 支持的代号返回 0" {
  is_supported_codename "bookworm"
  is_supported_codename "trixie"
  is_supported_codename "forky"
  is_supported_codename "sid"
  is_supported_codename "testing"
}

@test "is_supported_codename: 不支持的代号返回 1" {
  run is_supported_codename "bullseye"
  [[ "$status" -ne 0 ]]
}

@test "is_supported_codename: 空参数返回 1" {
  run is_supported_codename ""
  [[ "$status" -ne 0 ]]
}

@test "get_system_name: 返回系统名称" {
  cat > "$MOCK_BIN/lsb_release" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-is" ]] && echo "Debian"
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/lsb_release"

  result=$(get_system_name)
  [[ "$result" == "Debian" ]]
}

@test "get_system_version: 返回版本号" {
  result=$(get_system_version)
  # 版本号非空（非"未知"）
  [[ -n "$result" && "$result" != "未知" ]]
}

@test "get_system_architecture: 返回当前架构" {
  result=$(get_system_architecture)
  [[ -n "$result" && "$result" != "未知" ]]
  # 常见架构: x86_64, aarch64
  [[ "$result" =~ ^(x86_64|aarch64|amd64) ]]
}

# ==================== verify_architecture_support 测试 ====================

@test "verify_architecture_support: 支持的架构返回 0" {
  # 本机实际架构
  local arch
  arch=$(get_system_architecture)
  verify_architecture_support "x86_64 amd64 aarch64 $arch"
}

@test "verify_architecture_support: 空列表返回 1" {
  run verify_architecture_support ""
  [[ "$status" -ne 0 ]]
}

@test "verify_architecture_support: 不匹配返回 1" {
  run verify_architecture_support "armhf mips"
  [[ "$status" -ne 0 ]]
}

# ==================== get_first_regular_user 测试 ====================

@test "get_first_regular_user: 返回 UID>=1000 用户" {
  result=$(get_first_regular_user)
  # 如果测试环境有普通用户（UID>=1000），应返回非空
  # 如果测试环境只有 root，结果可能为空
  if id -u kekylin &>/dev/null; then
    [[ -n "$result" ]]
  fi
}

@test "get_first_regular_user: 不包含 nobody" {
  result=$(get_first_regular_user)
  [[ "$result" != "nobody" ]]
}

# ==================== get_primary_user 测试 ====================

@test "get_primary_user: 返回首个 UID>=1000 的用户（跳过系统用户与 nobody）" {
  TMP_PASSWD=$(mktemp -d)
  cat > "${TMP_PASSWD}/passwd" << 'INNEREOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
alice:x:1000:1000::/home/alice:/bin/bash
bob:x:1001:1001::/home/bob:/bin/bash
INNEREOF
  DEBNAS_PASSWD_FILE="${TMP_PASSWD}/passwd"
  [[ "$(get_primary_user)" == "alice" ]]
  [[ "$(get_first_regular_user)" == "alice" ]]
}

@test "get_primary_user: 无普通用户 / 文件缺失时输出空并返回 0" {
  TMP_PASSWD=$(mktemp -d)
  printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534::/:/bin/false\n' > "${TMP_PASSWD}/passwd"
  DEBNAS_PASSWD_FILE="${TMP_PASSWD}/passwd"
  run get_primary_user
  [[ "$status" -eq 0 && -z "$output" ]]
  DEBNAS_PASSWD_FILE="${TMP_PASSWD}/missing"
  run get_primary_user
  [[ "$status" -eq 0 && -z "$output" ]]
}

# ==================== write_file_if_changed 测试 ====================

@test "write_file_if_changed: 新建文件成功" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local testfile="${tmpdir}/test.conf"

  write_file_if_changed "$testfile" "hello world" "644"
  [[ -f "$testfile" ]]
  [[ "$(cat "$testfile")" == "hello world" ]]

  local perm
  perm=$(stat -c '%a' "$testfile")
  [[ "$perm" == "644" ]]

  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 内容相同时跳过并返回 1" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local testfile="${tmpdir}/test.conf"

  # 第一次写入
  write_file_if_changed "$testfile" "unchanged" "644"
  # 第二次写入：内容相同，应跳过
  run write_file_if_changed "$testfile" "unchanged" "644"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"跳过"* || "$output" == *"未变更"* ]]

  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 内容不同时更新" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local testfile="${tmpdir}/test.conf"

  echo "old content" > "$testfile"
  write_file_if_changed "$testfile" "new content" "644"
  [[ "$(cat "$testfile")" == "new content" ]]

  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 自动创建父目录" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local testfile="${tmpdir}/subdir/nested/test.conf"

  write_file_if_changed "$testfile" "nested" "644"
  [[ -f "$testfile" ]]
  [[ "$(cat "$testfile")" == "nested" ]]

  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 默认权限 644 生效" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local testfile="${tmpdir}/default-perm.conf"

  write_file_if_changed "$testfile" "default" ""

  local perm
  perm=$(stat -c '%a' "$testfile")
  [[ "$perm" == "644" ]]

  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 未指定权限时保留已存在文件的权限" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local testfile="${tmpdir}/secret.conf"

  echo "old" > "$testfile"
  chmod 600 "$testfile"
  write_file_if_changed "$testfile" "new"
  [[ "$(cat "$testfile")" == "new" ]]
  [[ "$(stat -c '%a' "$testfile")" == "600" ]]

  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 目标为符号链接时写入真实文件且保留链接" {
  local tmpdir
  tmpdir=$(mktemp -d)
  echo "old" > "${tmpdir}/real.conf"
  ln -s real.conf "${tmpdir}/link.conf"

  write_file_if_changed "${tmpdir}/link.conf" "via-link"
  [[ -L "${tmpdir}/link.conf" ]]
  [[ "$(cat "${tmpdir}/real.conf")" == "via-link" ]]

  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 写入后不残留临时文件" {
  local tmpdir
  tmpdir=$(mktemp -d)
  write_file_if_changed "${tmpdir}/a.conf" "content"
  [[ "$(ls -A "$tmpdir")" == "a.conf" ]]
  rm -rf "$tmpdir"
}

@test "write_file_if_changed: 空内容合法——写 0 字节空文件，不终止进程；缺参数返回 2" {
  local testfile="$BATS_TMPDIR/wfic-empty.conf"
  printf 'old\n' > "$testfile"
  run bash -c 'source "$1/lib/core/constants.sh"; source "$1/lib/core/colors.sh"; source "$1/lib/core/logging.sh"; source "$1/lib/system/utils.sh"
    rc=0; write_file_if_changed "$2" "" "644" 1 || rc=$?; echo "RC=$rc"' _ "$DEBNAS_ROOT" "$testfile"
  [[ "$output" == *"RC=0"* ]]
  [[ -f "$testfile" && ! -s "$testfile" ]]
  # 再写一次空内容：未变更
  run bash -c 'source "$1/lib/core/constants.sh"; source "$1/lib/core/colors.sh"; source "$1/lib/core/logging.sh"; source "$1/lib/system/utils.sh"
    rc=0; write_file_if_changed "$2" "" "644" 1 || rc=$?; echo "RC=$rc"' _ "$DEBNAS_ROOT" "$testfile"
  [[ "$output" == *"RC=1"* ]]
  run bash -c 'source "$1/lib/core/constants.sh"; source "$1/lib/core/colors.sh"; source "$1/lib/core/logging.sh"; source "$1/lib/system/utils.sh"
    rc=0; write_file_if_changed "$2" || rc=$?; echo "RC=$rc"' _ "$DEBNAS_ROOT" "$testfile"
  [[ "$output" == *"RC=2"* ]]
  rm -f "$testfile"
}
