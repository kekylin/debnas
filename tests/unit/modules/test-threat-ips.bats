#!/usr/bin/env bats
# 测试: modules/threat-ips/ — 威胁 IP 封禁目录模块 (TC-P1-MOD-004 + TC-P2-MOD-008)
# Mock 策略：
#   - 结构验证：grep 断言（module.sh 及子脚本）
#   - 纯函数测试：source download.sh 后对 parse_ip_entries 喂样例列表（awk 批量解析，不依赖 sipcalc）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/threat-ips"
MODULE_FILE="${MODULE_DIR}/module.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "threat-ips: @module 为 threat-ips" {
  result=$(parse_meta "module")
  [[ "$result" == "threat-ips" ]]
}

@test "threat-ips: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "threat-ips: @category 为 安全防护" {
  result=$(parse_meta "category")
  [[ "$result" == "安全防护" ]]
}

@test "threat-ips: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "threat-ips: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "threat-ips: @interactive 为 true" {
  result=$(parse_meta "interactive")
  [[ "$result" == "true" ]]
}

@test "threat-ips: @cron 为 true" {
  result=$(parse_meta "cron")
  [[ "$result" == "true" ]]
}

@test "threat-ips: @cron_schedule 已声明" {
  result=$(parse_meta "cron_schedule")
  [[ -n "$result" ]]
}

@test "threat-ips: @depend_modules 声明依赖 firewall" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"firewall"* ]]
}

@test "threat-ips: 菜单提供定时设置入口" {
  grep -q '定时设置' "$MODULE_FILE"
}

# ==================== 语法验证 ====================

@test "threat-ips: module.sh bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "threat-ips: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "threat-ips: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "threat-ips: 加载子模块 ipset.sh" {
  grep -q 'source.*ipset.sh' "$MODULE_FILE"
}

@test "threat-ips: 加载子模块 firewall.sh" {
  grep -q 'source.*firewall.sh' "$MODULE_FILE"
}

@test "threat-ips: 加载子模块 cron.sh" {
  grep -q 'source.*cron.sh' "$MODULE_FILE"
}

@test "threat-ips: 加载子模块 download.sh" {
  grep -q 'source.*download.sh' "$MODULE_FILE"
}

@test "threat-ips: 加载配置文件 ipthreat.conf.default" {
  grep -q 'source.*ipthreat.conf.default' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "threat-ips: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "threat-ips: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 目录模块子脚本存在性 ====================

@test "threat-ips: ipset.sh 子脚本存在且可读" {
  [[ -f "${MODULE_DIR}/ipset.sh" ]]
  [[ -r "${MODULE_DIR}/ipset.sh" ]]
}

@test "threat-ips: firewall.sh 子脚本存在且可读" {
  [[ -f "${MODULE_DIR}/firewall.sh" ]]
  [[ -r "${MODULE_DIR}/firewall.sh" ]]
}

@test "threat-ips: cron.sh 子脚本存在且可读" {
  [[ -f "${MODULE_DIR}/cron.sh" ]]
  [[ -r "${MODULE_DIR}/cron.sh" ]]
}

@test "threat-ips: download.sh 子脚本存在且可读" {
  [[ -f "${MODULE_DIR}/download.sh" ]]
  [[ -r "${MODULE_DIR}/download.sh" ]]
}

@test "threat-ips: 配置文件存在且可读" {
  [[ -f "${MODULE_DIR}/config/ipthreat.conf.default" ]]
  [[ -r "${MODULE_DIR}/config/ipthreat.conf.default" ]]
}

# ==================== 子脚本语法验证 ====================

@test "threat-ips: ipset.sh bash -n 语法通过" {
  run bash -n "${MODULE_DIR}/ipset.sh"
  [[ "$status" -eq 0 ]]
}

@test "threat-ips: firewall.sh bash -n 语法通过" {
  run bash -n "${MODULE_DIR}/firewall.sh"
  [[ "$status" -eq 0 ]]
}

@test "threat-ips: cron.sh bash -n 语法通过" {
  run bash -n "${MODULE_DIR}/cron.sh"
  [[ "$status" -eq 0 ]]
}

@test "threat-ips: download.sh bash -n 语法通过" {
  run bash -n "${MODULE_DIR}/download.sh"
  [[ "$status" -eq 0 ]]
}

# ==================== 逻辑验证 ====================

@test "threat-ips: parse_ip_entries 函数已定义（download.sh）且不再依赖 sipcalc" {
  grep -q '^parse_ip_entries()' "${MODULE_DIR}/download.sh"
  ! grep -rqE 'sipcalc[[:space:]]+"' "${MODULE_DIR}" || false
  [[ "$(parse_meta depends)" != *sipcalc* ]]
}

@test "threat-ips: 引用 IPSET_NAME_IPV4/IPV6 变量" {
  grep -q 'IPSET_NAME_IPV4' "$MODULE_FILE"
  grep -q 'IPSET_NAME_IPV6' "$MODULE_FILE"
}

@test "threat-ips: configure_ipset 函数已定义（在 ipset.sh）" {
  grep -q '^configure_ipset()' "${MODULE_DIR}/ipset.sh"
}

# ==================== TC-P2-MOD-008: 纯函数测试（parse_ip_entries） ====================

# 参数：$1 - 列表内容（printf %b 解释转义）；输出：V4:/V6:/LOG: 前缀的结果行，末行 RC=<返回码>
_parse_list() {
  local tmp
  tmp=$(mktemp -d)
  printf '%b' "$1" > "$tmp/in.txt"
  bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    D="$2"
    source "$1/config/ipthreat.conf.default"
    create_temp_file() { mktemp "$D/t.XXXXXX"; }
    log_info() { echo "LOG:I:$*"; }
    log_warning() { echo "LOG:W:$*"; }
    log_error() { echo "LOG:E:$*"; }
    source "$1/download.sh"
    : > "$D/v4"; : > "$D/v6"
    rc=0
    parse_ip_entries "$D/in.txt" "$D/v4" "$D/v6" || rc=$?
    sed "s/^/V4:/" "$D/v4"
    sed "s/^/V6:/" "$D/v6"
    echo "RC=$rc"
  ' _ "${MODULE_DIR}" "$tmp"
  rm -rf "$tmp"
}

@test "threat-ips: 单个 IPv4 / IPv4 CIDR / IPv6 / IPv6 CIDR 原样输出 (TC-P2-MOD-008)" {
  run _parse_list '1.2.3.4\n10.0.0.0/8\n2001:db8::1\n2001:db8::/32\n'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"V4:1.2.3.4"* ]]
  [[ "$output" == *"V4:10.0.0.0/8"* ]]
  [[ "$output" == *"V6:2001:db8::1"* ]]
  [[ "$output" == *"V6:2001:db8::/32"* ]]
  [[ "$output" == *"解析 IP 列表：4 条有效，0 条无效"* ]]
  [[ "$output" == *"RC=0"* ]]
}

@test "threat-ips: 行尾注释与首尾空白被去掉，引号按 xargs 规则处理 (TC-P2-MOD-008)" {
  run _parse_list '  5.6.7.8   # seen 3\n"9.9.9.9"\n\t8.8.4.4\n'
  [[ "$output" == *"V4:5.6.7.8"* ]]
  [[ "$output" == *"V4:9.9.9.9"* ]]
  [[ "$output" == *"V4:8.8.4.4"* ]]
  [[ "$output" == *"3 条有效，0 条无效"* ]]
}

@test "threat-ips: IPv4 范围展开，前导 0 按十进制处理 (TC-P2-MOD-008)" {
  run _parse_list '10.0.0.08-10.0.0.010\n'
  [[ "$output" == *"V4:10.0.0.8"* ]]
  [[ "$output" == *"V4:10.0.0.9"* ]]
  [[ "$output" == *"V4:10.0.0.10"* ]]
  [[ "$output" != *"V4:10.0.0.11"* ]]
}

@test "threat-ips: 起始大于结束、超过 MAX_RANGE_SIZE 的范围被拒绝并告警 (TC-P2-MOD-008)" {
  run _parse_list '1.1.1.9-1.1.1.1\n1.1.0.0-1.1.2.0\n2.2.2.2\n'
  [[ "$output" == *"LOG:W:无效 IPv4 范围：1.1.1.9-1.1.1.1（起始地址大于结束地址）"* ]]
  [[ "$output" == *"LOG:W:IPv4 范围过大：1.1.0.0-1.1.2.0（513 条，建议使用 CIDR 格式）"* ]]
  [[ "$output" == *"LOG:W:无效输入：1.1.1.9-1.1.1.1"* ]]
  [[ "$output" != *"V4:1.1.1."* ]]
  [[ "$output" == *"1 条有效，2 条无效"* ]]
}

@test "threat-ips: 非法地址判无效（octet>255、/33、多段 ::、主机名、- 开头）(TC-P2-MOD-008)" {
  run _parse_list '256.1.1.1\n1.2.3.4/33\n1::2::3\nexample.com\n-\n-41.2.3.4\n'
  [[ "$output" != *"V4:"* ]]
  [[ "$output" != *"V6:"* ]]
  [[ "$output" == *"LOG:W:无效输入：256.1.1.1"* ]]
  [[ "$output" == *"LOG:W:无效输入：example.com"* ]]
  [[ "$output" == *"所有输入 IP (6 条) 无效"* ]]
  [[ "$output" == *"RC=1"* ]]
}

@test "threat-ips: IPv6 CIDR 掩码 >128 先告警，再按 sipcalc 规则作为单个地址接受 (TC-P2-MOD-008)" {
  run _parse_list '2001:db8::/129\n'
  [[ "$output" == *"LOG:W:无效 IPv6 CIDR 掩码：2001:db8::/129"* ]]
  [[ "$output" == *"V6:2001:db8::/129"* ]]
}

@test "threat-ips: IPv6 范围只取两端；内嵌 IPv4 的 IPv6 地址可识别 (TC-P2-MOD-008)" {
  run _parse_list '2001:db8::1-2001:db8::5\n::ffff:1.2.3.4\n'
  [[ "$output" == *"V6:2001:db8::1"* ]]
  [[ "$output" == *"V6:2001:db8::5"* ]]
  [[ "$output" != *"V6:2001:db8::3"* ]]
  [[ "$output" == *"V6:::ffff:1.2.3.4"* ]]
}

# ==================== 回归：白名单 / 先解析后替换 / 并发 ====================

@test "threat-ips: filter_protected_entries 剔除私网/本机/会话来源/过宽网段并规范化前导 0" {
  local tmp
  tmp=$(mktemp -d)
  printf '1.2.3.4\n010.020.030.040\n8.8.8.9/24\n0.0.0.0/0\n44.0.0.0/8\n203.0.113.0/24\n192.168.1.1\n08.08.04.04\n' > "$tmp/v4.txt"
  run bash -c '
    set -euo pipefail
    source "$1/config/ipthreat.conf.default"
    WHITELIST_FILE=/nonexistent
    create_temp_file() { mktemp; }
    log_warning() { :; }
    source "$1/download.sh"
    SSH_CLIENT="203.0.113.77 5555 22"
    filter_protected_entries "$2/v4.txt" IPv4
    cat "$2/v4.txt"
  ' _ "${MODULE_DIR}" "$tmp"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"1.2.3.4"* ]]
  [[ "$output" == *"8.8.8.0/24"* ]]
  [[ "$output" == *"8.8.4.4"* ]]
  [[ "$output" != *"10.20.30.40"* ]]
  [[ "$output" != *"0.0.0.0/0"* ]]
  [[ "$output" != *"44.0.0.0/8"* ]]
  [[ "$output" != *"203.0.113."* ]]
  [[ "$output" != *"192.168."* ]]
}


@test "threat-ips: 更新流程不再先清空 IPSet（解析成功后才增量同步）" {
  ! grep -q 'clear_all_ipsets' "${MODULE_DIR}/firewall.sh"
  grep -A40 '^filter_and_add_ips()' "${MODULE_DIR}/firewall.sh" | grep -q 'sync_ipset_entries'
}

@test "threat-ips: 空列表/全部无效时 process_ip_list 返回失败（保留现有封禁）" {
  grep -A15 '^process_ip_list()' "${MODULE_DIR}/firewall.sh" | grep -q 'prepare_input_file.*|| return 1'
}

@test "threat-ips: reload 后重启 fail2ban 恢复其运行时规则" {
  grep -A20 '^reload_firewalld()' "${MODULE_DIR}/firewall.sh" | grep -q 'service_ensure fail2ban restarted'
}

@test "threat-ips: 更新与禁用使用 flock 互斥" {
  grep -q 'flock' "${MODULE_DIR}/cron.sh"
  grep -A6 '^update_threat_ips()' "${MODULE_DIR}/cron.sh" >/dev/null
  grep -A20 '^update_threat_ips()' "${MODULE_DIR}/cron.sh" | grep -q 'acquire_update_lock'
}

@test "threat-ips: wget 设置超时与重试上限" {
  grep -q 'wget .*--timeout=[0-9]* --tries=[0-9]*' "${MODULE_DIR}/download.sh"
}

# ==================== 审计修复回归（2026-11-10） ====================

# 在临时目录执行 download.sh 中的函数片段：$1 - 片段，$2 - 临时目录（片段中用 $D 引用）
_ti_run() {
  bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    D="$2"
    source "$1/config/ipthreat.conf.default"
    WHITELIST_FILE="$D/whitelist"
    create_temp_file() { mktemp "$D/t.XXXXXX"; }
    log_info() { echo "LOG:I:$*"; }
    log_warning() { echo "LOG:W:$*"; }
    log_error() { echo "LOG:E:$*"; }
    source "$1/download.sh"
    eval "$3"
  ' _ "${MODULE_DIR}" "$2" "$1"
}

@test "threat-ips: IPv6 白名单/本机地址按前缀重叠剔除，写法不同也能命中 (B2)" {
  local tmp
  tmp=$(mktemp -d)
  printf '2606:4700::/32\n2A01:0:0::1\n' > "$tmp/whitelist"
  printf '%s\n' 2606:4700:10::6816:1/64 2a01::1 2a01:0000::0001/128 2a00:1450:4001::/48 \
    2a00:1450:4001:0:0:0:0:5 FE80::1 2400:cb00:2049::1 > "$tmp/v6"
  run _ti_run 'SSH_CLIENT="2a00:1450:4001::5 51000 22"; filter_protected_entries "$D/v6" IPv6; cat "$D/v6"' "$tmp"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  # 威胁条目落在白名单 /32 内、与白名单单地址写法不同、包含 SSH 来源的 /48 都要剔除
  [[ "$output" != *"2606:4700"* ]]
  [[ "$output" != *"2a01:"* ]]
  [[ "$output" != *"2a00:1450"* ]]
  [[ "$output" != *"fe80"* && "$output" != *"FE80"* ]]
  [[ "$output" == *"2400:cb00:2049::1"* ]]
  [[ "$output" == *"命中保护/白名单 6 条"* ]]
}

@test "threat-ips: IPv6 前缀必须为纯数字 0-128，过宽下限 /32 (B6/B9)" {
  local tmp
  tmp=$(mktemp -d)
  : > "$tmp/whitelist"
  printf '%s\n' 2400:cb00::/129 2400:cb00::/abc 2400:cb00::/1x 2400:cb00::/31 2400:cb00::/32 2400:cb01::1/128 > "$tmp/v6"
  run _ti_run 'filter_protected_entries "$D/v6" IPv6; cat "$D/v6"' "$tmp"
  rm -rf "$tmp"
  [[ "$output" != *"/129"* && "$output" != *"/abc"* && "$output" != *"/1x"* && "$output" != *"/31"* ]]
  [[ "$output" == *"2400:cb00::/32"* ]]
  [[ "$output" == *"2400:cb01::1/128"* ]]
  [[ "$output" == *"过宽网段 1 条"*"格式无效 3 条"* ]]
}

@test "threat-ips: IPv4 封禁下限 /16 (B9)" {
  local tmp
  tmp=$(mktemp -d)
  : > "$tmp/whitelist"
  printf '%s\n' 44.0.0.0/15 44.2.0.0/16 > "$tmp/v4"
  run _ti_run 'filter_protected_entries "$D/v4" IPv4; cat "$D/v4"' "$tmp"
  rm -rf "$tmp"
  [[ "$output" != *"44.0.0.0/15"* ]]
  [[ "$output" == *"44.2.0.0/16"* ]]
}

@test "threat-ips: 重叠条目合并，被包含的条目丢弃（IPv4/IPv6）(B6)" {
  local tmp
  tmp=$(mktemp -d)
  printf '%s\n' 1.2.3.4 1.2.3.0/24 1.2.3.0/24 5.6.7.8 9.9.9.0/25 9.9.9.128/25 9.9.0.0/17 > "$tmp/v4"
  printf '%s\n' 2400:cb00::1 2400:cb00::/32 2400:cb00:1::/48 2a0b::1 > "$tmp/v6"
  run _ti_run 'merge_overlapping_entries "$D/v4" IPv4; merge_overlapping_entries "$D/v6" IPv6; sort "$D/v4" "$D/v6"' "$tmp"
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
  local body
  body=$(grep -v '^LOG:' <<< "$output")
  [[ "$body" == $'1.2.3.0/24\n2400:cb00::/32\n2a0b::1\n5.6.7.8\n9.9.0.0/17' ]]
}

@test "threat-ips: 解析告警最多显示 20 条，原文去控制字符并截断到 80 字符 (B9)" {
  local tmp
  tmp=$(mktemp -d)
  # 控制字符行与超长行放在前面，确保它们在显示的 20 条以内
  { printf 'evil\033[31mred\n'
    printf '%0100d\n' 0 | tr 0 x
    for i in $(seq 1 30); do echo "bad-entry-$i"; done
    echo 1.2.3.4
  } > "$tmp/in.txt"
  run _ti_run ': > "$D/v4"; : > "$D/v6"; parse_ip_entries "$D/in.txt" "$D/v4" "$D/v6"' "$tmp"
  rm -rf "$tmp"
  [[ "$(grep -c '^LOG:W:无效输入' <<< "$output")" -eq 20 ]]
  [[ "$output" == *"其余 12 条解析告警已省略（共 32 条）"* ]]
  [[ "$output" != *$'\033'* ]]
  [[ "$output" == *"无效输入：evil[31mred"* ]]
  [[ "$output" == *"无效输入：$(printf '%080d' 0 | tr 0 x)..."* ]]
}

# 假 firewall-cmd：状态存在 $FW_STATE/<scope>，操作顺序记入 $FW_STATE/log；
# 与 firewalld 一样，新增后集合内出现重叠网段即整批拒绝；新增文件含 $FW_FAIL_ADD 这一行时失败
_ti_fake_fw() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/state/permanent"; : > "$dir/state/runtime"; : > "$dir/state/log"
  cat > "$dir/bin/firewall-cmd" <<'FW'
#!/bin/bash
set -euo pipefail
scope=runtime; op=""; file=""
for a in "$@"; do
  case "$a" in
    --permanent) scope=permanent ;;
    --get-entries) op=get ;;
    --add-entries-from-file=*) op=add; file="${a#*=}" ;;
    --remove-entries-from-file=*) op=remove; file="${a#*=}" ;;
  esac
done
st="$FW_STATE/$scope"
case "$op" in
  get) tr '\n' ' ' < "$st"; echo ;;
  add)
    echo "$scope add $(tr '\n' ' ' < "$file")" >> "$FW_STATE/log"
    if [[ -n "${FW_FAIL_ADD:-}" ]] && grep -qxF "$FW_FAIL_ADD" "$file"; then exit 13; fi
    source "$FW_LIB"
    if cat "$st" "$file" | awk "${_THREAT_NET_AWK}"'netparse($1) { printf "%s %03d\n", NKEY, NM }' | sort -k1,1 -k2,2n \
      | awk "${_THREAT_NET_AWK}"'{ if (h && netcontains(lk, lm, $1, $2 + 0)) bad = 1; lk = $1; lm = $2 + 0; h = 1 } END { exit bad }'; then
      cat "$file" >> "$st"
    else
      exit 136
    fi ;;
  remove)
    echo "$scope remove $(tr '\n' ' ' < "$file")" >> "$FW_STATE/log"
    grep -vxF -f "$file" "$st" > "$st.new" || true
    mv "$st.new" "$st" ;;
esac
FW
  chmod +x "$dir/bin/firewall-cmd"
  # 供假 firewall-cmd 复用的 awk 库
  { sed -n "/^_THREAT_NET_AWK='/,/^'$/p" "${MODULE_DIR}/download.sh"; } > "$dir/netlib.sh"
}

# 参数：$1 - 临时目录（已 _ti_fake_fw），旧条目写在 state/{permanent,runtime}，新列表 $1/new
_ti_sync() {
  local dir="$1"
  PATH="$dir/bin:$PATH" FW_STATE="$dir/state" FW_LIB="$dir/netlib.sh" bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    D="$2"
    source "$1/config/ipthreat.conf.default"
    create_temp_file() { mktemp "$D/t.XXXXXX"; }
    log_info() { echo "LOG:I:$*"; }; log_warning() { echo "LOG:W:$*"; }; log_error() { echo "LOG:E:$*"; }
    source "$1/download.sh"
    source "$1/firewall.sh"
    rc=0; sync_ipset_entries test4 "$D/new" IPv4 || rc=$?
    echo "RC=$rc"
  ' _ "${MODULE_DIR}" "$dir"
}

@test "threat-ips: 同步先 add 后 remove，与新条目重叠的旧条目先删 (B6)" {
  local tmp
  tmp=$(mktemp -d)
  _ti_fake_fw "$tmp"
  printf '1.2.3.4\n7.7.7.7\n' | tee "$tmp/state/permanent" > "$tmp/state/runtime"
  printf '1.2.3.0/24\n8.8.8.8\n' > "$tmp/new"
  run _ti_sync "$tmp"
  [[ "$output" == *"RC=0"* ]]
  run grep '^permanent' "$tmp/state/log"
  [[ "${lines[0]}" == "permanent remove 1.2.3.4 " ]]
  [[ "${lines[1]}" == "permanent add 1.2.3.0/24 8.8.8.8 " ]]
  [[ "${lines[2]}" == "permanent remove 7.7.7.7 " ]]
  [[ "$(sort "$tmp/state/permanent" | tr '\n' ' ')" == "1.2.3.0/24 8.8.8.8 " ]]
  [[ "$(sort "$tmp/state/runtime" | tr '\n' ' ')" == "1.2.3.0/24 8.8.8.8 " ]]
  rm -rf "$tmp"
}

@test "threat-ips: add 失败时不做 remove，已先删的重叠旧条目被加回 (B6)" {
  local tmp
  tmp=$(mktemp -d)
  _ti_fake_fw "$tmp"
  printf '1.2.3.4\n7.7.7.7\n' | tee "$tmp/state/permanent" > "$tmp/state/runtime"
  printf '1.2.3.0/24\n8.8.8.8\n' > "$tmp/new"
  FW_FAIL_ADD=8.8.8.8 run _ti_sync "$tmp"
  [[ "$output" == *"RC=1"* ]]
  [[ "$output" == *"添加条目失败"* ]]
  ! grep -q 'remove 7.7.7.7' "$tmp/state/log"
  [[ "$(sort "$tmp/state/permanent" | tr '\n' ' ')" == "1.2.3.4 7.7.7.7 " ]]
  rm -rf "$tmp"
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

@test "threat-ips: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "threat-ips: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "threat-ips: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-threat-ips-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "threat-ips: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-threat-ips-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "threat-ips: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-threat-ips-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "threat-ips: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status threat-ips
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan threat-ips
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

_ct_threat_fw() {
  local dir="$BATS_TMPDIR/ct-threat-fw"
  rm -rf "$dir"
  mkdir -p "$dir/ipsets" "$dir/zones" "$BATS_TMPDIR/ct-threat-bin"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TMPDIR/ct-threat-bin/firewall-cmd"
  chmod +x "$BATS_TMPDIR/ct-threat-bin/firewall-cmd"
  echo "$dir"
}

@test "threat-ips: 无 IPSet 且未启用时 status=absent" {
  local dir
  dir=$(_ct_threat_fw)
  PATH="$BATS_TMPDIR/ct-threat-bin:$PATH" THREAT_FW_DIR="$dir" run _contract_probe eval /dev/null '
    feature_enabled() { return 1; }
    module_status'
  [[ "$status" -eq 0 ]]
  [[ "$output" == "absent|未启用威胁 IP 封禁" ]]
  rm -rf "$dir"
}

@test "threat-ips: IPSet 已建、已绑定 drop 区时报告条目数" {
  local dir
  dir=$(_ct_threat_fw)
  printf '<ipset type="hash:net">\n<entry>1.2.3.0/24</entry>\n<entry>5.6.7.8</entry>\n<entry>9.9.9.9</entry>\n</ipset>\n' > "$dir/ipsets/ipthreat_block_ipv4.xml"
  printf '<zone target="DROP">\n<source ipset="ipthreat_block_ipv4"/>\n</zone>\n' > "$dir/zones/drop.xml"
  PATH="$BATS_TMPDIR/ct-threat-bin:$PATH" THREAT_FW_DIR="$dir" run _contract_probe eval /dev/null '
    feature_enabled() { return 0; }
    systemctl() { return 0; }
    cron_state() { echo on; }
    module_status'
  [[ "$status" -eq 0 ]]
  [[ "$output" == applied\|*"IPv4 3 / IPv6 0"*"定时更新已开启"* ]]
  rm -rf "$dir"
}

@test "threat-ips: IPSet 未绑定 drop 区时 status=partial" {
  local dir
  dir=$(_ct_threat_fw)
  printf '<ipset><entry>5.6.7.8</entry></ipset>\n' > "$dir/ipsets/ipthreat_block_ipv4.xml"
  PATH="$BATS_TMPDIR/ct-threat-bin:$PATH" THREAT_FW_DIR="$dir" run _contract_probe eval /dev/null '
    feature_enabled() { return 0; }
    systemctl() { return 0; }
    module_status'
  [[ "$output" == partial\|*"未绑定"* ]]
  rm -rf "$dir"
}

@test "threat-ips: plan 含交互说明与误封风险" {
  run _contract_probe plan /dev/null
  [[ "$output" == *"info|threat-ips|交互式菜单"* ]]
  [[ "$output" == *"risk|误封|"* ]]
}

# ==================== 跟进修复回归（2026-11-10） ====================

@test "threat-ips: firewalld 永久配置（两个 IPSet 与 drop 区文件）登记到文件清单" {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/fw/ipsets" "$tmp/fw/zones"
  touch "$tmp/fw/ipsets/ipthreat_block_ipv4.xml" "$tmp/fw/ipsets/ipthreat_block_ipv6.xml" "$tmp/fw/zones/drop.xml"
  run env DEBNAS_MANIFEST_FILE="$tmp/manifest" DEBNAS_GLOBAL_CONF="$tmp/none" bash -c '
    set -euo pipefail
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    source "$1/modules/threat-ips/config/ipthreat.conf.default"
    source "$1/modules/threat-ips/firewall.sh"
    _THREAT_FW_DIR="$2/fw"
    register_threat_manifest
    register_threat_manifest
    cat "$DEBNAS_MANIFEST_FILE"
  ' _ "$DEBNAS_ROOT" "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"$tmp/fw/ipsets/ipthreat_block_ipv4.xml"*$'\t'"threat-ips"* ]]
  [[ "$output" == *"$tmp/fw/ipsets/ipthreat_block_ipv6.xml"* ]]
  [[ "$output" == *"$tmp/fw/zones/drop.xml"* ]]
  # 重复登记不产生重复行
  [[ "$(grep -c . "$tmp/manifest")" -eq 3 ]]
  rm -rf "$tmp"
}

@test "threat-ips: 更新成功后调用 register_threat_manifest" {
  grep -A45 '^filter_and_add_ips()' "${MODULE_DIR}/firewall.sh" | grep -q 'register_threat_manifest'
}

@test "threat-ips: check_services 用 pkg_is_installed 判断 cron（dpkg -l 对未安装的 un 状态包也返回 0）" {
  ! grep -v '^[[:space:]]*#' "${MODULE_DIR}/module.sh" | grep -q 'dpkg -l cron' || false
  grep -q 'pkg_is_installed cron' "${MODULE_DIR}/module.sh"
}

@test "threat-ips: 未安装 cron 时 check_services 只告警、不去启动不存在的服务" {
  run env DEBNAS_MODULE_ACTION=status bash -c '
    set -euo pipefail
    source "$1/modules/threat-ips/module.sh" </dev/null >/dev/null 2>&1
    service_is_active() { [[ "$1" == "firewalld" ]]; }
    pkg_is_installed() { return 1; }
    service_ensure() { echo "ENSURE $*"; return 1; }
    # 模拟云镜像：PATH 中没有 cron 可执行文件，但 dpkg 数据库里知道 cron 这个包（dpkg -l 返回 0）
    command() { if [[ "$1" == "-v" && "$2" == "cron" ]]; then return 1; fi; builtin command "$@"; }
    dpkg() { return 0; }
    check_services
  ' _ "$DEBNAS_ROOT"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"ENSURE"* ]]
  [[ "$output" == *"Cron 未安装"* ]]
}
