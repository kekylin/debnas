#!/usr/bin/env bats
# 测试: modules/firewall.sh — 配置防火墙模块 (TC-P1-SVC-001)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）
# 注：此模块已有集成测试 (tests/integration/test-firewall.bats)，此为补充单元覆盖

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/firewall.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "firewall-unit: @module 为 firewall" {
  result=$(parse_meta "module")
  [[ "$result" == "firewall" ]]
}

@test "firewall-unit: @name 为 配置防火墙" {
  result=$(parse_meta "name")
  [[ "$result" == "配置防火墙" ]]
}

@test "firewall-unit: @category 为 安全防护" {
  result=$(parse_meta "category")
  [[ "$result" == "安全防护" ]]
}

@test "firewall-unit: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "firewall-unit: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 语法验证 ====================

@test "firewall-unit: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "firewall-unit: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "firewall-unit: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "firewall-unit: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "firewall-unit: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "firewall-unit: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "firewall-unit: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "firewall-unit: CONFIG_FILE 指向实际默认区的区文件（不再写死 public.xml）" {
  grep -q 'CONFIG_FILE="${_FW_ZONES_DIR}/${zone}.xml"' "$MODULE_FILE"
  ! grep -q 'CONFIG_FILE="/etc/firewalld/zones/public.xml"' "$MODULE_FILE" || false
}

@test "firewall-unit: 检测并禁用 UFW 避免冲突" {
  grep -q 'ufw' "$MODULE_FILE"
}

@test "firewall-unit: 使用 apt_install_packages 安装 firewalld" {
  grep -q 'apt_install_packages firewalld' "$MODULE_FILE"
}

@test "firewall-unit: XML 配置包含 ssh 服务" {
  grep -q '<service name="ssh"/>' "$MODULE_FILE"
}

@test "firewall-unit: XML 配置包含 dhcpv6-client 服务" {
  grep -q '<service name="dhcpv6-client"/>' "$MODULE_FILE"
}

@test "firewall-unit: XML 配置包含 cockpit 服务" {
  grep -q '<service name="cockpit"/>' "$MODULE_FILE"
}

@test "firewall-unit: 使用 write_file_if_changed 安全写入" {
  grep -q 'write_file_if_changed' "$MODULE_FILE"
}

@test "firewall-unit: 补充已有区文件不用 sed -i（内存中插入后经 write_file_if_changed 写回）" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -qE 'sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i' || false
  grep -q '_fw_zone_insert "$current"' "$MODULE_FILE"
  grep -q 'write_file_if_changed "$CONFIG_FILE" "$new_content"' "$MODULE_FILE"
}

# TC-P1-SVC-001: service_ensure firewalld 调用链
@test "firewall-unit: service_ensure firewalld started 调用 (TC-P1-SVC-001)" {
  grep -q 'service_ensure firewalld started' "$MODULE_FILE"
}

@test "firewall-unit: service_ensure firewalld enabled 调用 (TC-P1-SVC-001)" {
  grep -q 'service_ensure firewalld enabled' "$MODULE_FILE"
}

# ==================== 回归：自定义 SSH 端口 / NAS 共享服务 ====================

@test "firewall-unit: 用 sshd_listen_ports 取端口并放行非 22 端口（不自写 sshd -T 解析）" {
  grep -q 'sshd_listen_ports' "$MODULE_FILE"
  ! grep -q 'sshd -T' "$MODULE_FILE" || false
  grep -q '<port protocol=\\"tcp\\" port=' "$MODULE_FILE"
}

@test "firewall-unit: sshd_listen_ports 默认包含当前 SSH 会话的服务端端口" {
  run bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    DEBNAS_SSHD_CONFIG=/nonexistent
    source "$1/lib/system/service.sh"
    sshd() { return 1; }
    SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 2222" sshd_listen_ports
  ' _ "$DEBNAS_ROOT"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"2222"* ]]
}

@test "firewall-unit: module_status/plan 用 pkg_is_installed 查包" {
  grep -q 'pkg_is_installed firewalld' "$MODULE_FILE"
  ! grep -q '_fw_pkg_installed' "$MODULE_FILE"
}

@test "firewall-unit: 已安装 samba/nfs 时放行对应服务" {
  grep -q 'service_is_installed smbd' "$MODULE_FILE"
  grep -q 'service_is_installed nfs-server' "$MODULE_FILE"
}

@test "firewall-unit: 规则变更不使用 --reload（避免清掉 fail2ban 运行时规则）" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q 'firewall-cmd --reload'
}

# ==================== 跟进修复回归（2026-11-10）：按实际默认区操作 / 不再 sed -i ====================

# 在临时目录模拟 /etc/firewalld 与 /usr/lib/firewalld/zones，执行 main 或契约函数
# 参数：$1 - 临时根目录；$2 - main|status|plan；环境变量 FW_ACTIVE=1 表示 firewalld 运行中（firewall-cmd 调用记到 $1/fwcmd.log）
_fw_sandbox() {
  local tmp="$1" what="$2"
  env DEBNAS_BACKUP_ROOT="$tmp/backups" DEBNAS_MANIFEST_FILE="$tmp/manifest" DEBNAS_GLOBAL_CONF="$tmp/none" \
    DEBNAS_BACKUP_ENABLED=1 DEBNAS_MODULE_ACTION=status FW_ACTIVE="${FW_ACTIVE:-0}" bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    unset SSH_CONNECTION
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    source "$2" </dev/null
    FW_T="$3"
    _FW_CONF="$3/etc/firewalld.conf"
    _FW_ZONES_DIR="$3/etc/zones"
    _FW_SYS_ZONES_DIR="$3/lib/zones"
    pkg_is_installed() { return 0; }
    sshd_listen_ports() { echo 22; echo 2222; }
    service_is_installed() { [[ "$1" == "smbd" ]]; }
    service_is_active() { [[ "$1" == "firewalld" && "$FW_ACTIVE" == "1" ]]; }
    apt_install_packages() { return 0; }
    service_ensure() { return 0; }
    firewall-cmd() {
      local IFS=" "
      echo "$*" >> "$FW_T/fwcmd.log"
      case "$*" in
        --get-default-zone) sed -n "s/^DefaultZone=//p" "$_FW_CONF" ;;
        *--query-*) return 1 ;;
      esac
    }
    case "$4" in
      main) main ;;
      *) "module_$4" ;;
    esac
  ' _ "$DEBNAS_ROOT" "$MODULE_FILE" "$tmp" "$what" 2>&1
}

# 准备沙箱：$1 默认区名（空 = 不建 firewalld.conf）
_fw_sandbox_init() {
  FW_TMP=$(mktemp -d)
  mkdir -p "$FW_TMP/etc/zones" "$FW_TMP/lib/zones"
  [[ -z "${1:-}" ]] || printf '# c\nDefaultZone=%s\nCleanupOnExit=yes\n' "$1" > "$FW_TMP/etc/firewalld.conf"
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<zone>' '  <short>Home</short>' \
    '  <service name="ssh"/>' '  <service name="mdns"/>' '  <service name="dhcpv6-client"/>' '  <forward/>' '</zone>' \
    > "$FW_TMP/lib/zones/home.xml"
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<zone target="DROP">' '  <short>Drop</short>' '  <forward/>' '</zone>' \
    > "$FW_TMP/lib/zones/drop.xml"
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<zone target="ACCEPT">' '  <short>Trusted</short>' '  <forward/>' '</zone>' \
    > "$FW_TMP/lib/zones/trusted.xml"
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<zone>' '  <short>Public</short>' \
    '  <service name="ssh"/>' '  <service name="dhcpv6-client"/>' '  <forward/>' '</zone>' \
    > "$FW_TMP/lib/zones/public.xml"
}

@test "firewall-unit: _fw_default_zone 读 firewalld.conf 的 DefaultZone，缺省/无效回落 public" {
  _fw_sandbox_init home
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" status
  [[ "$output" == *"home 区"* ]]
  rm -f "$FW_TMP/etc/firewalld.conf"
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" status
  [[ "$output" == *"public 区"* ]]
  printf 'DefaultZone=nosuchzone\n' > "$FW_TMP/etc/firewalld.conf"
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" status
  [[ "$output" == *"public 区"* ]]
  rm -rf "$FW_TMP"
}

@test "firewall-unit: 默认区为 home 时放行规则写入 home 区（以系统区定义为基础追加），不动 public" {
  _fw_sandbox_init home
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  [[ -f "$FW_TMP/etc/zones/home.xml" ]]
  [[ ! -e "$FW_TMP/etc/zones/public.xml" ]]
  grep -qF '<service name="cockpit"/>' "$FW_TMP/etc/zones/home.xml"
  grep -qF '<service name="samba"/>' "$FW_TMP/etc/zones/home.xml"
  grep -qF '<port protocol="tcp" port="2222"/>' "$FW_TMP/etc/zones/home.xml"
  # 系统定义原有内容保留，ssh 不重复
  grep -qF '<service name="mdns"/>' "$FW_TMP/etc/zones/home.xml"
  [[ "$(grep -cF '<service name="ssh"/>' "$FW_TMP/etc/zones/home.xml")" -eq 1 ]]
  [[ "$(tail -n 1 "$FW_TMP/etc/zones/home.xml")" == "</zone>" ]]
  grep -qF "$FW_TMP/etc/zones/home.xml" "$FW_TMP/manifest"
  rm -rf "$FW_TMP"
}

@test "firewall-unit: firewalld 运行中时运行时规则也加到实际默认区（--zone=home）" {
  _fw_sandbox_init home
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  grep -qF -- '--zone=home --add-service=cockpit' "$FW_TMP/fwcmd.log"
  grep -qF -- '--zone=home --add-port=2222/tcp' "$FW_TMP/fwcmd.log"
  ! grep -qF -- '--zone=public' "$FW_TMP/fwcmd.log" || false
  ! grep -qF -- '--reload' "$FW_TMP/fwcmd.log" || false
  rm -rf "$FW_TMP"
}

@test "firewall-unit: 默认区为 drop 时照常追加服务（保留 target=DROP）" {
  _fw_sandbox_init drop
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  grep -qF '<zone target="DROP">' "$FW_TMP/etc/zones/drop.xml"
  grep -qF '<service name="ssh"/>' "$FW_TMP/etc/zones/drop.xml"
  grep -qF '<service name="cockpit"/>' "$FW_TMP/etc/zones/drop.xml"
  # dhcpv6-client 该区本不含，不强行补
  ! grep -qF 'dhcpv6-client' "$FW_TMP/etc/zones/drop.xml" || false
  rm -rf "$FW_TMP"
}

@test "firewall-unit: 默认区为 trusted 时不写放行规则，只提示" {
  _fw_sandbox_init trusted
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"trusted"*"放行全部入站"* ]]
  [[ -z "$(ls -A "$FW_TMP/etc/zones")" ]]
  run _fw_sandbox "$FW_TMP" plan
  [[ "$output" == *"risk|trusted 区|"* ]]
  [[ "$output" != *"write|"* ]]
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" status
  [[ "$output" == "warn|"*"trusted"* ]]
  rm -rf "$FW_TMP"
}

@test "firewall-unit: 已有区文件补缺经 write_file_if_changed（原件进备份、登记清单、用户自定义条目保留）" {
  _fw_sandbox_init ""
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<zone>' '  <short>Public</short>' \
    '  <service name="ssh"/>' '  <port protocol="tcp" port="8080"/>' '</zone>' > "$FW_TMP/etc/zones/public.xml"
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  grep -qF '<service name="cockpit"/>' "$FW_TMP/etc/zones/public.xml"
  grep -qF '<service name="samba"/>' "$FW_TMP/etc/zones/public.xml"
  grep -qF '<port protocol="tcp" port="8080"/>' "$FW_TMP/etc/zones/public.xml"
  # 用户删掉的 dhcpv6-client 不强行补回
  ! grep -qF 'dhcpv6-client' "$FW_TMP/etc/zones/public.xml" || false
  # 备份是修改前的原件
  ! grep -qF 'cockpit' "$FW_TMP/backups/original$FW_TMP/etc/zones/public.xml" || false
  grep -qF '8080' "$FW_TMP/backups/original$FW_TMP/etc/zones/public.xml"
  grep -qF "$FW_TMP/etc/zones/public.xml" "$FW_TMP/manifest"
  # 幂等：再跑一次内容不变
  local before
  before=$(cat "$FW_TMP/etc/zones/public.xml")
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$FW_TMP/etc/zones/public.xml")" == "$before" ]]
  rm -rf "$FW_TMP"
}

@test "firewall-unit: 默认区 public 且无区文件时仍按模板新建 public.xml" {
  _fw_sandbox_init public
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  grep -qF '<service name="dhcpv6-client"/>' "$FW_TMP/etc/zones/public.xml"
  grep -qF '<service name="cockpit"/>' "$FW_TMP/etc/zones/public.xml"
  rm -rf "$FW_TMP"
}

@test "firewall-unit: plan/status 显示实际操作的区，备份说明与实际一致" {
  _fw_sandbox_init home
  run _fw_sandbox "$FW_TMP" plan
  [[ "$output" == *"info|默认区|"*"home"* ]]
  [[ "$output" == *"write|$FW_TMP/etc/zones/home.xml|新建：以 $FW_TMP/lib/zones/home.xml 为基础追加"*"cockpit"* ]]
  [[ "$output" == *"|home 区放行服务"* ]]
  [[ "$output" != *"sed -i"* && "$output" != *"不另做备份"* ]]
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" status
  [[ "$output" == "partial|"*"home 区未放行 cockpit"* ]]
  _fw_sandbox "$FW_TMP" main >/dev/null
  run _fw_sandbox "$FW_TMP" plan
  [[ "$output" == *"info|$FW_TMP/etc/zones/home.xml|规则已齐全"* ]]
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" status
  [[ "$output" == "running|"*"home 区已放行"* ]]
  rm -rf "$FW_TMP"
}

@test "firewall-unit: 区文件缺少 </zone> 时不写入（不破坏文件）" {
  _fw_sandbox_init ""
  printf '<zone/>\n' > "$FW_TMP/etc/zones/public.xml"
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$FW_TMP/etc/zones/public.xml")" == "<zone/>" ]]
  [[ "$output" == *"不是可识别的区定义"* ]]
  rm -rf "$FW_TMP"
}

@test "firewall-unit: firewalld 运行中时把新增项同步进它的永久配置（--permanent 逐项追加，不 reload）" {
  _fw_sandbox_init home
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  grep -qF -- '--permanent --zone=home --add-service=cockpit' "$FW_TMP/fwcmd.log"
  grep -qF -- '--permanent --zone=home --add-service=samba' "$FW_TMP/fwcmd.log"
  grep -qF -- '--permanent --zone=home --add-port=2222/tcp' "$FW_TMP/fwcmd.log"
  # 区里已有的 ssh、未强补的 dhcpv6-client 不动
  ! grep -qE -- '--permanent .*--add-service=(ssh|dhcpv6-client)$' "$FW_TMP/fwcmd.log" || false
  ! grep -qF -- '--reload' "$FW_TMP/fwcmd.log" || false
  rm -rf "$FW_TMP"
}

@test "firewall-unit: firewalld 未运行或规则无变化时不调用 firewall-cmd --permanent" {
  _fw_sandbox_init home
  run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  [[ ! -e "$FW_TMP/fwcmd.log" ]] || ! grep -qF -- '--permanent' "$FW_TMP/fwcmd.log"
  : > "$FW_TMP/fwcmd.log"
  FW_ACTIVE=1 run _fw_sandbox "$FW_TMP" main
  [[ "$status" -eq 0 ]]
  ! grep -qF -- '--permanent' "$FW_TMP/fwcmd.log" || false
  rm -rf "$FW_TMP"
}
