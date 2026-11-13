#!/usr/bin/env bats
# 测试: modules/docker-ce.sh — Docker CE 模块（单元层补充）
# 注：已有 tests/integration/test-docker-ce.bats (26 tests) 覆盖元数据/结构/安全/deps
# 此文件聚焦差异化覆盖：函数定义完整性 + 逻辑 grep + 安全红线补充

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/docker-ce.sh"

# ==================== 语法验证 ====================

@test "docker-ce-unit: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 补充安全红线 ====================

@test "docker-ce-unit: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

@test "docker-ce-unit: 使用 write_file_if_changed 安全写入" {
  grep -q 'write_file_if_changed' "$MODULE_FILE"
}

# 输出某个函数的完整函数体（从 "名称() {" 到首个行首 "}"），代替行数窗口固定的 grep -A
fn_body() {
  sed -n "/^$1() {/,/^}/p" "$MODULE_FILE"
}

# ==================== 函数定义完整性 ====================

@test "docker-ce-unit: 镜像探测直接使用公共 probe_url（不再有单行包装）" {
  ! grep -q '^probe_mirror()' "$MODULE_FILE" || false
  fn_body get_docker_mirror | grep -q 'probe_url "${docker_mirror}/dists/"'
}

@test "docker-ce-unit: install_docker_prerequisites 函数已定义" {
  grep -q '^install_docker_prerequisites()' "$MODULE_FILE"
}

@test "docker-ce-unit: write_docker_apt_source 函数已定义" {
  grep -q '^write_docker_apt_source()' "$MODULE_FILE"
}

@test "docker-ce-unit: install_docker_packages 函数已定义" {
  grep -q '^install_docker_packages()' "$MODULE_FILE"
}

@test "docker-ce-unit: add_user_to_docker_group 函数已定义" {
  grep -q '^add_user_to_docker_group()' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "docker-ce-unit: install_docker_prerequisites 使用 apt_install_packages 安装依赖" {
  fn_body install_docker_prerequisites | grep -q 'apt_install_packages ca-certificates curl'
  fn_body install_docker_prerequisites | grep -q 'apt_install_packages gnupg'
}

@test "docker-ce-unit: 固定 Docker 官方 GPG 指纹，经 keyring_install_verified 下载校验" {
  grep -q 'DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"' "$MODULE_FILE"
  fn_body main | grep -q 'keyring_install_verified "${docker_mirror}/gpg" "$DOCKER_GPG_FINGERPRINT" "${DOCKER_KEYRINGS_DIR}/docker.asc"'
  fn_body main | grep -q -- '--label Docker || exit "${ERROR_DEPENDENCY}"'
}

@test "docker-ce-unit: 不再自写公钥下载/指纹校验，也不直接写 keyring" {
  ! grep -qE '^(download_docker_gpg_key|verify_docker_gpg_fingerprint)\(\)' "$MODULE_FILE" || false
  ! grep -qE 'gpg .*--show-keys|^[[:space:]]*curl ' "$MODULE_FILE" || false
  ! grep -qF -- '-o "${DOCKER_KEYRINGS_DIR}/docker.asc"' "$MODULE_FILE" || false
}

@test "docker-ce-unit: 公钥安装失败时 main 以 ERROR_DEPENDENCY 退出且不写源" {
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    ui_progress_step() { :; }; log_info() { :; }; log_error() { :; }
    get_docker_mirror() { echo https://mirror.example/docker-ce/linux/debian; }
    install_docker_prerequisites() { :; }
    keyring_install_verified() { local IFS=" "; echo "KIV:$*"; return 1; }
    write_docker_apt_source() { echo WROTE; }
    main' _ "$DEBNAS_ROOT" "$MODULE_FILE"
  [[ "$status" -eq 2 ]]  # ERROR_DEPENDENCY
  [[ "$output" == *"KIV:https://mirror.example/docker-ce/linux/debian/gpg 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 /etc/apt/keyrings/docker.asc --label Docker"* ]]
  [[ "$output" != *WROTE* ]]
}

@test "docker-ce-unit: extract_mirror_from_sources 回退解析传统 sources.list" {
  fn_body extract_mirror_from_sources | grep -q '_legacy_list_first_uri'
  fn_body _legacy_list_first_uri | grep -q 'sources.list"'
}

@test "docker-ce-unit: extract_mirror_from_sources 解析 DEB822 与传统格式" {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/sources.list.d"
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    DOCKER_SOURCES_DIR="$3/sources.list.d"
    extract_mirror_from_sources || echo NONE
    printf "deb [arch=amd64] http://legacy.example/debian bookworm main\n" > "$3/sources.list"
    extract_mirror_from_sources
    printf "# URIs: http://x\nTypes: deb\nURIs: https://m.example/debian/ http://y\n" > "$3/sources.list.d/debian.sources"
    extract_mirror_from_sources' _ "$DEBNAS_ROOT" "$MODULE_FILE" "$d"
  rm -rf -- "$d"
  [[ "$output" == $'NONE\nhttp://legacy.example\nhttps://m.example' ]]
}

@test "docker-ce-unit: 加入 docker 组时输出等同 root 警告并支持关闭" {
  fn_body add_user_to_docker_group | grep -q 'config_get_bool add_user_to_docker 1'
  fn_body add_user_to_docker_group | grep -q 'log_warning.*root'
}

@test "docker-ce-unit: add_user_to_docker=0/false 时不加组，默认加组" {
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    log_info() { :; }; log_warning() { :; }; log_success() { :; }
    usermod() { local IFS=" "; echo "USERMOD:$*"; }
    config_read() { echo false; }; add_user_to_docker_group alice
    config_read() { echo "${3:-}"; }; add_user_to_docker_group bob' _ "$DEBNAS_ROOT" "$MODULE_FILE"
  [[ "$output" == "USERMOD:-aG docker bob" ]]
}

@test "docker-ce-unit: write_docker_apt_source 备份旧 docker.list 文件" {
  fn_body write_docker_apt_source | grep -q 'docker.list'
  fn_body write_docker_apt_source | grep -q '\.bak'
}

@test "docker-ce-unit: write_docker_apt_source 使用 DEB822 格式" {
  fn_body write_docker_apt_source | grep -q 'Types: deb'
}

@test "docker-ce-unit: write_docker_apt_source 调用 apt_update_safe 更新索引" {
  fn_body write_docker_apt_source | grep -q 'apt_update_safe'
}

@test "docker-ce-unit: write_docker_apt_source 写入失败时中止（不再 || true 吞掉）" {
  fn_body write_docker_apt_source | grep -q 'write_file_if_changed .*|| rc=\$?'
  ! fn_body write_docker_apt_source | grep -q 'write_file_if_changed .*|| true' || false
}

@test "docker-ce-unit: install_docker_packages 全新安装包含 docker-buildx-plugin" {
  grep -q 'docker-buildx-plugin' "$MODULE_FILE"
}

@test "docker-ce-unit: install_docker_packages 全新安装包含 docker-compose-plugin" {
  grep -q 'docker-compose-plugin' "$MODULE_FILE"
}

@test "docker-ce-unit: install_docker_packages 已安装时使用 apt_install_safe 升级" {
  grep -q 'apt_install_safe docker-ce' "$MODULE_FILE"
}

@test "docker-ce-unit: add_user_to_docker_group 使用 usermod -aG docker" {
  fn_body add_user_to_docker_group | grep -q 'usermod -aG docker'
}

@test "docker-ce-unit: main 调用 get_primary_user 获取普通用户" {
  fn_body main | grep -q 'get_primary_user'
  ! grep -q 'get_first_regular_user' "$MODULE_FILE" || false
}

@test "docker-ce-unit: get_docker_mirror 引用 DOCKER_OFFICIAL_MIRROR 变量" {
  fn_body get_docker_mirror | grep -q 'DOCKER_OFFICIAL_MIRROR'
}

@test "docker-ce-unit: get_docker_mirror 引用 DOCKER_FALLBACK_MIRRORS 数组" {
  fn_body get_docker_mirror | grep -q 'DOCKER_FALLBACK_MIRRORS'
}

@test "docker-ce-unit: main 获取 Docker 版本信息输出" {
  fn_body main | grep -q 'docker --version'
}

# ==================== APT 源 DEB822 格式 ====================

@test "docker-ce-unit: DEB822 源包含 Signed-By 字段指向 keyrings" {
  grep -q 'Signed-By: /etc/apt/keyrings/docker.asc' "$MODULE_FILE"
}

@test "docker-ce-unit: DEB822 源包含 Suites 字段" {
  grep -q 'Suites:' "$MODULE_FILE"
}

@test "docker-ce-unit: DEB822 源包含 Components: stable" {
  grep -q 'Components: stable' "$MODULE_FILE"
}

@test "docker-ce-unit: 使用 get_system_codename 获取系统代号" {
  fn_body write_docker_apt_source | grep -q 'get_system_codename'
}

# ==================== 源地址解析（行为） ====================

@test "docker-ce-unit: is_official_debian_source 只认 Debian 官方域名" {
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/docker-ce.sh" >/dev/null 2>&1
    is_official_debian_source "http://deb.debian.org/debian" && echo OFFICIAL
    is_official_debian_source "https://mirror.example/debian" || echo OTHER
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"OFFICIAL"*"OTHER"* ]]
}

@test "docker-ce-unit: extract_mirror_from_sources 从 DEB822 取主机名" {
  local d
  d=$(mktemp -d)
  printf 'Types: deb\nURIs: https://mirror.example/debian\nSuites: bookworm\n' > "$d/debian.sources"
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    DOCKER_SOURCES_DIR="$2"
    source "$1/modules/docker-ce.sh" >/dev/null 2>&1
    extract_mirror_from_sources
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 0 && "$output" == "https://mirror.example" ]]
}

@test "docker-ce-unit: extract_mirror_from_sources 回退传统 sources.list" {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/sources.list.d"
  printf 'deb http://legacy.example/debian bookworm main\n' > "$d/sources.list"
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    DOCKER_SOURCES_DIR="$2/sources.list.d"
    source "$1/modules/docker-ce.sh" >/dev/null 2>&1
    extract_mirror_from_sources
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 0 && "$output" == "http://legacy.example" ]]
}

@test "docker-ce-unit: 无系统源时 extract_mirror_from_sources 返回 1" {
  local d
  d=$(mktemp -d)
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    DOCKER_SOURCES_DIR="$2"
    source "$1/modules/docker-ce.sh" >/dev/null 2>&1
    extract_mirror_from_sources
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 1 ]]
}
