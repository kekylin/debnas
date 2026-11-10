#!/usr/bin/env bats
# 集成测试: modules/docker-ce.sh — 安装 Docker CE 模块
# 验证元数据完整性、语法、结构、Mock 功能（extract_mirror_from_sources）、依赖链

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
export NO_COLOR=1
source "${DEBNAS_ROOT}/lib/core/constants.sh"
source "${DEBNAS_ROOT}/lib/core/colors.sh"
source "${DEBNAS_ROOT}/lib/core/logging.sh"

MODULE_FILE="${DEBNAS_ROOT}/modules/docker-ce.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "docker-ce: @module 为 docker-ce" {
  result=$(parse_meta "module")
  [[ "$result" == "docker-ce" ]]
}

@test "docker-ce: @name 为 安装 Docker CE" {
  result=$(parse_meta "name")
  [[ "$result" == "安装 Docker CE" ]]
}

@test "docker-ce: @category 为 容器管理" {
  result=$(parse_meta "category")
  [[ "$result" == "容器管理" ]]
}

@test "docker-ce: @depends 包含 wget,curl" {
  result=$(parse_meta "depends")
  [[ "$result" == *"wget"* ]]
  [[ "$result" == *"curl"* ]]
}

@test "docker-ce: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "docker-ce: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 结构验证 ====================
# 注：bash -n 语法检查已由 L1 门禁全局覆盖，此处不再重复

@test "docker-ce: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "docker-ce: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "docker-ce: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "docker-ce: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

@test "docker-ce: 包含 extract_mirror_from_sources 函数" {
  grep -q '^extract_mirror_from_sources()' "$MODULE_FILE"
}

@test "docker-ce: 包含 get_docker_mirror 函数" {
  grep -q '^get_docker_mirror()' "$MODULE_FILE"
}

@test "docker-ce: GPG 公钥经公共 keyring_install_verified 安装（含重试与指纹校验）" {
  grep -q 'keyring_install_verified "${docker_mirror}/gpg" "$DOCKER_GPG_FINGERPRINT"' "$MODULE_FILE"
}

@test "docker-ce: 使用 service_ensure 管理 docker 服务" {
  grep -q 'service_ensure docker started' "$MODULE_FILE"
  grep -q 'service_ensure docker enabled' "$MODULE_FILE"
}

# ==================== 安全性验证 ====================

@test "docker-ce: 模块内不直接调用 curl（下载经 probe_url / keyring_install_verified，均带超时）" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -qE '(^|[^-[:alnum:]_])curl[[:space:]]' || false
}

@test "docker-ce: 无 eval 使用" {
  ! grep -q '\beval\b' "$MODULE_FILE"
}

@test "docker-ce: 无写操作类 systemctl 调用（使用 service_ensure；只读查询放行）" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" \
    | grep -qE '\bsystemctl[[:space:]]+(--[a-z-]+[[:space:]]+)*(start|stop|restart|reload|try-restart|reload-or-restart|enable|disable|mask|unmask|daemon-reload|kill)\b' || false
}

# ==================== Mock: extract_mirror_from_sources (结构验证) ====================
# 注：原有的内联 awk 逻辑（复制 extract_mirror_from_sources 的实现）已移除
# 改为结构 grep 验证，避免源码变更时测试假阳性

@test "docker-ce: extract_mirror_from_sources — 函数包含 URIs 字段提取逻辑" {
  sed -n '/^extract_mirror_from_sources()/,/^}/p' "$MODULE_FILE" | grep -q 'URIs'
}

@test "docker-ce: extract_mirror_from_sources — awk 过滤注释行（! 模式排除 # 开头行）" {
  # awk 模式: !/^[[:space:]]*#/ 排除以 # 开头的注释行
  sed -n '/^extract_mirror_from_sources()/,/^}/p' "$MODULE_FILE" | grep -q '/\^\[\[:space:\]\]\*#/'
}

@test "docker-ce: extract_mirror_from_sources — 函数包含文件缺失检查（-f test)" {
  sed -n '/^extract_mirror_from_sources()/,/^}/p' "$MODULE_FILE" | grep -q '\-f'
}

@test "docker-ce: extract_mirror_from_sources — awk 使用 sub() 去除 URI 前缀" {
  sed -n '/^extract_mirror_from_sources()/,/^}/p' "$MODULE_FILE" | grep -q 'sub('
}

# ==================== Mock: is_official_debian_source (结构验证) ====================

@test "docker-ce: is_official_debian_source — 函数匹配 deb.debian.org 和 ftp.debian.org" {
  # 函数使用 =~ 正则运算符，域名以转义形式出现（deb\.debian\.org）
  sed -n '/^is_official_debian_source()/,/^}/p' "$MODULE_FILE" | grep -q 'deb.*debian.*org'
  sed -n '/^is_official_debian_source()/,/^}/p' "$MODULE_FILE" | grep -q 'ftp.*debian.*org'
}

@test "docker-ce: @depend_modules 未声明（无上游依赖）" {
  ! grep -q '@depend_modules:' "$MODULE_FILE"
}

@test "docker-ce: docker-mirror 模块依赖 docker-ce" {
  grep -q '@depend_modules:.*docker-ce' "${DEBNAS_ROOT}/modules/docker-mirror.sh"
}

@test "docker-ce: docker-apps 模块依赖 docker-ce" {
  grep -q '@depend_modules:.*docker-ce' "${DEBNAS_ROOT}/modules/docker-apps.sh"
}
