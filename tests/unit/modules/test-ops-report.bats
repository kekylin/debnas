#!/usr/bin/env bats
# 单元测试: ops-report 模块结构与常量声明

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/ops-report"

@test "ops-report: 声明全部代码常量" {
  grep -q 'readonly OPS_DEFAULT_PERIOD=7' "$MODULE_DIR/module.sh"
  grep -q 'readonly OPS_EMAIL_ENABLED=1' "$MODULE_DIR/module.sh"
  grep -q 'readonly OPS_REPORT_DIR="/var/lib/debnas/ops-report"' "$MODULE_DIR/module.sh"
  grep -q 'readonly OPS_SYSSTAT_HISTORY=400' "$MODULE_DIR/module.sh"
  grep -q 'readonly OPS_INCLUDE_DOCKER=1' "$MODULE_DIR/module.sh"
  grep -q 'readonly OPS_INCLUDE_VM=1' "$MODULE_DIR/module.sh"
}

@test "ops-report: 子模块职责函数存在" {
  grep -q 'ops_setup_enable()' "$MODULE_DIR/setup.sh"
  grep -q 'ops_collect_health()' "$MODULE_DIR/health.sh"
  grep -q 'ops_collect_security()' "$MODULE_DIR/security.sh"
  grep -q 'ops_collect_services()' "$MODULE_DIR/services.sh"
  grep -q 'ops_generate_report()' "$MODULE_DIR/report.sh"
  grep -q 'ops_send_report_email()' "$MODULE_DIR/notify.sh"
  grep -q 'ops_login_data_start()' "$MODULE_DIR/security.sh"
}

@test "ops-report: 菜单生命周期状态函数存在" {
  grep -q 'ops_data_readiness()' "$MODULE_DIR/module.sh"
  grep -q 'ops_pause_schedule()' "$MODULE_DIR/module.sh"
  grep -q 'ops_resume_schedule()' "$MODULE_DIR/module.sh"
  grep -q 'ops_disable_module()' "$MODULE_DIR/module.sh"
  grep -q 'ops_cron_generate_from_args()' "$MODULE_DIR/module.sh"
}

@test "ops-report: 报告目录权限按安全要求创建" {
  grep -q 'install -d -m 700' "$MODULE_DIR/setup.sh"
  grep -q 'chmod 700' "$MODULE_DIR/setup.sh"
}

@test "ops-report: 配置写入使用 write_file_if_changed" {
  grep -q 'write_file_if_changed' "$MODULE_DIR/setup.sh"
}

# ==================== 审查修复回归（2026-11-09） ====================

@test "ops-report: ops_html_escape 转义 & < > 双引号 单引号" {
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"; ops_html_escape "a&<b>\"'"'"'<!--"' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == 'a&amp;&lt;b&gt;&quot;&#39;&lt;!--' ]]
}

@test "ops-report: 研判表/页眉/失败来源等系统数据经 HTML 转义后输出" {
  grep -q 'ops_html_escape "\$login_note"' "$MODULE_DIR/report.sh"
  grep -q 'ops_html_escape "\$proc_note"' "$MODULE_DIR/report.sh"
  grep -q 'ops_html_escape "\$fail_source_summary"' "$MODULE_DIR/report.sh"
  grep -q 'ops_html_escape "\$(hostname' "$MODULE_DIR/report.sh"
  grep -q 'ops_html_escape "\$OPS_HEALTH_SMART_SUMMARY"' "$MODULE_DIR/report.sh"
}

@test "ops-report: 监听端口只减少时不因 pipefail 终止" {
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/security.sh"
    OPS_SNAPSHOT_DIR="$2"
    OPS_LISTEN_PORTS="tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:*"
    ops_collect_security_drift >/dev/null
    OPS_LISTEN_PORTS="tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"
    ops_collect_security_drift >/dev/null
    echo "${OPS_NEW_LISTEN_PORT_COUNT}|${OPS_LISTEN_PORT_BASELINE_STATE}"' _ "$MODULE_DIR" "$BATS_TEST_TMPDIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"0|未发现"* ]]
}

@test "ops-report: 可用性解析兼容 systemd 252 em dash 格式且不按 CST 缩写换算时区" {
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"
    journalctl() { printf "%s\n" " -1 c3f1aaaaaaaaaaaaaaaaaaaaaaaaaaaa Mon 2026-11-02 10:00:00 CST—Wed 2026-11-04 10:00:00 CST" \
      "  0 d4f1bbbbbbbbbbbbbbbbbbbbbbbbbbbb Wed 2026-11-04 10:05:00 CST—Mon 2026-11-09 12:00:00 CST"; }
    OPS_REPORT_DAYS=7; OPS_REPORT_SINCE="2026-11-02 00:00:00"; OPS_REPORT_UNTIL="2026-11-09 12:00:00"
    ops_collect_availability; echo "${OPS_REBOOT_COUNT}|${OPS_AVAILABILITY_PCT}"' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2|94.40%" ]]
}

@test "ops-report: sysstat 只读周期内二进制文件并解压历史压缩文件" {
  grep -q "name 'sa\[0-9\]\*'" "$MODULE_DIR/report.sh"
  grep -q -- '-newermt' "$MODULE_DIR/report.sh"
  grep -q 'xz -dc' "$MODULE_DIR/report.sh"
}

@test "ops-report: 报告生成加 flock 并以 600 预创建报告文件" {
  grep -q 'flock -n' "$MODULE_DIR/report.sh"
  grep -q 'install -m 600 /dev/null' "$MODULE_DIR/report.sh"
}

@test "ops-report: 失败登录按 auth/authpriv facility 读取 journal，fail2ban 多 jail 正确拆分" {
  grep -q 'SYSLOG_FACILITY=4 SYSLOG_FACILITY=10' "$MODULE_DIR/security.sh"
  grep -q "IFS=', ' read -r -a jail_list" "$MODULE_DIR/security.sh"
}

@test "ops-report: 邮件使用 exim4 -oi 且主题去控制字符并 RFC 2047 编码" {
  grep -q 'exim4 -oi -t' "$MODULE_DIR/notify.sh"
  grep -q '=?UTF-8?B?' "$MODULE_DIR/notify.sh"
}

@test "ops-report: ops_update_epochs 一次换算更新时间，无法解析的行回退逐行且保持行号对齐" {
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"
    OPS_UPDATE_LIST="2026-11-05 10:00:01 upgrade a:amd64 1 2
bad-date xx upgrade b:amd64 1 2
2026-11-06 11:00:00 install c:amd64 <none> 3"
    ops_update_epochs
    echo "${#OPS_UPDATE_EPOCHS[@]}|${OPS_UPDATE_EPOCHS[0]}|${OPS_UPDATE_EPOCHS[1]}|${OPS_UPDATE_EPOCHS[2]}"
    echo "$(date -d "2026-11-05 10:00:01" +%s)|$(date -d "2026-11-06 11:00:00" +%s)"' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  local want0 want2
  IFS='|' read -r want0 want2 <<< "${lines[1]}"
  [[ "${lines[0]}" == "3|${want0}||${want2}" ]]
}

@test "ops-report: fail2ban 封禁数解析兼容 Currently banned 后的制表符" {
  local mock="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$mock"
  cat > "$mock/fail2ban-client" <<'M'
#!/bin/bash
case "$*" in
  status) printf 'Status\n|- Number of jail:\t2\n`- Jail list:\tsshd, recidive\n' ;;
  "status sshd") printf '   |- Currently banned:\t3\n' ;;
  "status recidive") printf '   |- Currently banned:\t1\n' ;;
esac
M
  chmod +x "$mock/fail2ban-client"
  run env PATH="$mock:$PATH" bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/security.sh"
    OPS_REPORT_SINCE="2026-11-01 00:00:00"
    ops_collect_security >/dev/null 2>&1
    echo "ban=${OPS_FAIL_BAN_COUNT}"' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ban=4"* ]]
}

@test "ops-report: 转义纯 bash 实现（无 sed 子进程）且漂移表只转 & < >" {
  ! sed -n '/^ops_html_escape()/,/^}/p' "$MODULE_DIR/report.sh" | grep -q 'sed'
  run bash -c 'set -euo pipefail; source "$1/security.sh"; ops_drift_escape "a&<b>\"x"' _ "$MODULE_DIR"
  [[ "$output" == 'a&amp;&lt;b&gt;"x' ]]
}

@test "ops-report: 定时任务状态走 cron_state，sysstat 原始输出不再拼进 shell 变量" {
  ! grep -q '_ops_cron_state' "$MODULE_DIR/module.sh"
  grep -q 'cron_state "ops-report"' "$MODULE_DIR/module.sh"
  ! grep -q 'OPS_SAR_NET_LINES' "$MODULE_DIR/report.sh"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/ops-report/module.sh"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="${BATS_TMPDIR}/ops-report-probe-state" \
    DEBNAS_FEATURE_DIR="${BATS_TMPDIR}/ops-report-probe-state" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "ops-report-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "ops-report-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "ops-report-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "ops-report-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TMPDIR}/ops-report-probe-state" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "ops-report-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "ops-report-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "ops-report-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="${BATS_TMPDIR}/ops-report-probe-state" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status ops-report
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

# ==================== 审计修复回归（2026-11-10） ====================

@test "ops-report: [D2] 无 security 源索引时 ops_security_package_names 在 set -e 下返回 0 且无输出" {
  local d="${BATS_TEST_TMPDIR}/lists-empty"
  mkdir -p "$d"
  : > "$d/deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages"
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"
    pkgs=$(ops_security_package_names "$2")
    echo "rc=0 n=${#pkgs}"' _ "$MODULE_DIR" "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "rc=0 n=0" ]]
}

@test "ops-report: [D2] security 索引被压缩存放（.gz）时仍能读出包名" {
  [[ -x /usr/lib/apt/apt-helper ]] || skip "无 apt-helper"
  local d="${BATS_TEST_TMPDIR}/lists-gz"
  mkdir -p "$d"
  printf 'Package: openssl\nVersion: 1\n\nPackage: libc6\nVersion: 2\n\nPackage: openssl\n' \
    | gzip -c > "$d/deb.debian.org_debian-security_dists_bookworm-security_main_binary-amd64_Packages.gz"
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"; ops_security_package_names "$2"' _ "$MODULE_DIR" "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == $'libc6\nopenssl' ]]
}

@test "ops-report: [D2] ops_collect_updates 不再直接 grep security 索引 glob" {
  ! sed -n '/^ops_collect_updates()/,/^}/p' "$MODULE_DIR/report.sh" | grep -q 'grep .*\*security\*Packages\*'
  sed -n '/^ops_collect_updates()/,/^}/p' "$MODULE_DIR/report.sh" | grep -q 'security_pkgs=$(ops_security_package_names /var/lib/apt/lists || true)'
}

@test "ops-report: [D4] 失败登录来源 IP 只取最后一个 <IP> port N，用户名伪造的 from 不计入" {
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/security.sh"
    printf "%s\n" \
      "Nov 10 10:00:00 nas sshd[1]: Failed password for invalid user x from 9.9.9.9 from 1.2.3.4 port 51234 ssh2" \
      "Nov 10 10:00:01 nas sshd[1]: Invalid user a 8.8.8.8 port 1 from 5.6.7.8 port 2222" \
      "Nov 10 10:00:02 nas sshd[1]: Connection closed by authenticating user root 10.0.0.9 port 4444 [preauth]" \
      "Nov 10 10:00:03 nas sshd[1]: pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=192.168.1.5  user=x 7.7.7.7 port 1" \
      "Nov 10 10:00:04 nas sshd[1]: Invalid user rhost=6.6.6.6 from ::ffff:2.2.2.2 port 22" \
      "Nov 10 10:00:05 nas sshd[1]: Failed password for root from 2001:db8::1 port 22 ssh2" \
      | ops_fail_source_ips | paste -sd " " -' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "1.2.3.4 5.6.7.8 10.0.0.9 192.168.1.5 2.2.2.2 2001:db8::1" ]]
}

@test "ops-report: [D5] 可疑进程的 exe 路径含换行时不会伪造出额外记录" {
  local base d
  base=$(mktemp -d /tmp/opsd5.XXXXXX)
  d="${base}/a"$'\n'"FAKE 1 伪造：注入"
  mkdir -p "$d"
  cp /bin/sleep "$d/sleep"
  "$d/sleep" 30 &
  local spid=$!
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/security.sh"
    ops_collect_suspicious_processes
    printf "%s\n" "$OPS_SUSPICIOUS_PROGRAMS"' _ "$MODULE_DIR"
  kill "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  rm -rf -- "$base"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"opsd5"* ]]
  ! grep -q '^FAKE' <<< "$output"
}

@test "ops-report: [D6] 用户登录统计按第 2 列（次数）数值降序" {
  local mock="${BATS_TEST_TMPDIR}/bin-d6"
  mkdir -p "$mock"
  cat > "$mock/last" <<'M'
#!/bin/bash
printf '%s\n' \
  "bob      pts/0        10.0.0.2         Mon Nov  9 09:00:00 2026 - Mon Nov  9 10:00:00 2026  (01:00)" \
  "alice    pts/1        10.0.0.1         Mon Nov  9 10:00:00 2026 - Mon Nov  9 11:00:00 2026  (01:00)" \
  "alice    pts/1        10.0.0.1         Mon Nov  9 12:00:00 2026 - Mon Nov  9 13:00:00 2026  (01:00)" \
  "alice    pts/1        10.0.0.1         Mon Nov  9 14:00:00 2026 - Mon Nov  9 15:00:00 2026  (01:00)"
M
  chmod +x "$mock/last"
  cp "$mock/last" "$mock/wtmpdb"
  printf '#!/bin/sh\nexit 0\n' > "$mock/journalctl"; chmod +x "$mock/journalctl"
  run env PATH="$mock:$PATH" bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/security.sh"
    OPS_REPORT_SINCE="2026-11-01 00:00:00"
    ops_collect_security >/dev/null 2>&1
    printf "%s\n" "$OPS_LOGIN_USER_STATS" | cut -d"|" -f1,2 | paste -sd " " -' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "alice|3 bob|1" ]]
}

# ==================== 跟进修复（2026-11-10）：容量预测 / 服务说明列 / 登录解析 / 内核版本 ====================

@test "ops-report: [F1] 磁盘容量预测按基线快照外推，同日重复生成不冲掉基线" {
  local dir="${BATS_TEST_TMPDIR}/snap-f1"
  mkdir -p "$dir"
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"
    OPS_SNAPSHOT_DIR="$2"; OPS_REPORT_DAYS=7
    now=$(date +%s)
    printf "sda|30|%s\nsda|36|%s\nsdc|10|%s\n" "$((now - 7 * 86400))" "$((now - 3600))" "$((now - 40 * 86400))" > "$2/disk-usage.snapshot"
    OPS_DISK_USAGE_LINES=$(printf "sda|100.0 GB|37.0 GB|37|/|QEMU|SSD\nsdb|50.0 GB|25.0 GB|50|/data|QEMU|HDD\nsdc|50.0 GB|5.0 GB|10|/x|QEMU|HDD\nsdd|9 GB|8 GB|95|/y|Q|HDD")
    ops_collect_disk_trend
    echo "A:${OPS_DISK_FORECAST//$'"'"'\n'"'"'/ }"
    # 立刻再生成一次：基线仍是 7 天前那条
    ops_collect_disk_trend
    echo "B:${OPS_DISK_FORECAST//$'"'"'\n'"'"'/ }"
    echo "N:$(grep -c "^sda|" "$2/disk-usage.snapshot")"
    grep -c "^sda|30|" "$2/disk-usage.snapshot"' _ "$MODULE_DIR" "$dir"
  [[ "$status" -eq 0 ]]
  # sda：7 天 +7 个百分点 → 1.00%/天，(90-37)/1 = 53 天；sdb 无基线；sdc 基线超出周期（40 天前）按无基线；sdd 已超 90%
  [[ "${lines[0]}" == "A:sda|37|7|1.00|53 sdb|50||| sdc|10||| sdd|95|||" ]]
  [[ "${lines[1]}" == "B:sda|37|7|1.00|53 sdb|50||| sdc|10||| sdd|95|||" ]]
  # 快照：7 天前的基线 + 今天一条（今天较早的那条被本次替换）
  [[ "${lines[2]}" == "N:2" ]]
  [[ "${lines[3]}" == "1" ]]
}

@test "ops-report: [F1] 容量预测表渲染各种状态并转义，且已接入报告的磁盘一节" {
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"
    OPS_DISK_FORECAST=$(printf "sda|37|7|1.00|53\nsdb|50|||\nsdc|40|7|0.00|\nsdd|95|7|0.50|\nsde|85|7|1.00|5\nsdf|89|2|9.00|0\n<b>x|1|||")
    ops_render_disk_forecast_table
    echo
    OPS_DISK_FORECAST=""
    ops_render_disk_forecast_table' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"<td>sda</td><td>37%</td><td>按近 7 天增速（+1.00%/天），约 53 天后达到 90%</td>"* ]]
  [[ "$output" == *"<td>sdb</td><td>50%</td><td class=\"muted\">数据不足"* ]]
  [[ "$output" == *"<td>sdc</td><td>40%</td><td>近 7 天无增长</td>"* ]]
  [[ "$output" == *"<td>sdd</td><td>95%</td><td class=\"warn\">已达 90% 告警线</td>"* ]]
  [[ "$output" == *"<td>sde</td><td>85%</td><td class=\"warn\">按近 7 天增速（+1.00%/天），约 5 天后达到 90%</td>"* ]]
  [[ "$output" == *"不足 1 天后达到 90%"* ]]
  [[ "$output" == *"&lt;b&gt;x"* && "$output" != *"<b>x"* ]]
  [[ "$output" == *'<td colspan="3" class="muted">数据不足</td>'* ]]
  grep -q '\$(ops_render_disk_forecast_table)' "$MODULE_DIR/report.sh"
  grep -q '<h3>磁盘容量预测</h3>' "$MODULE_DIR/report.sh"
}

@test "ops-report: [F2] 服务清单说明列同时保留周期错误与周期重启" {
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"
    OPS_SERVICE_STABILITY=$(printf "ssh|3|2|-|正常\ncron|0|4|-|正常\nnginx|5|0|-|failed\nsmbd|0|0|-|正常")
    ops_render_service_list_table' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"<td>周期错误 3 次；周期重启 2 次</td>"* ]]
  [[ "$output" == *"<td>周期重启 4 次</td>"* ]]
  [[ "$output" == *"<td>周期错误 5 次</td>"* ]]
  [[ "$output" != *"- 周期重启"* ]]
  # 两项都为 0 时仍显示 "-"
  [[ "$(grep -c '<td>-</td><td>-</td></tr>' <<< "$output")" -eq 1 ]]
}

# last -F（Debian 12 util-linux 2.38，10.9.9.7 实测输出）
LAST_D12_SAMPLE='guiuser  :0           :0               Tue Nov 10 00:50:02 2026   gone - no logout
alonguse tty2                          Tue Nov 10 00:33:22 2026   gone - no logout
dnadmin  web console  ::ffff:10.9.9.66 Tue Nov 10 00:16:42 2026 - Tue Nov 10 00:18:22 2026  (00:01)
debnas   pts/0        10.9.9.66        Tue Nov 10 00:00:02 2026 - Tue Nov 10 00:08:22 2026  (00:08)
root     tty1                          Mon Nov  9 23:26:42 2026 - Mon Nov  9 23:43:22 2026  (00:16)
reboot   system boot  6.1.0-18-amd64   Mon Nov  9 20:23:22 2026   still running

wtmp begins Mon Nov  9 20:23:22 2026'

# wtmpdb last -F（Debian 13 wtmpdb 0.73，10.9.9.16 实测输出；-f 指定库文件时末行以文件路径开头）
LAST_D13_SAMPLE='debnas   pts/0        10.9.9.66        Tue Nov 10 01:56:22 2026 - Tue Nov 10 01:56:23 2026  (00:00)
root     tty1                          Tue Nov 10 00:56:32 2026 - Tue Nov 10 00:58:12 2026  (00:01)
debnas   tty2                          Mon Nov  9 23:56:32 2026 - still logged in          
dnadmin  web console  ::ffff:10.9.9.66 Mon Nov  9 23:26:32 2026 - Mon Nov  9 23:43:12 2026  (00:16)
alonguse ssh          2001:db8:85a3::8 Mon Nov  9 23:18:12 2026 - Mon Nov  9 23:19:52 2026  (00:01)
root     seat0        :0               Mon Nov  9 23:11:32 2026 - Mon Nov  9 23:13:12 2026  (00:01)
svc                   10.9.9.9         Mon Nov  9 22:00:00 2026 - Mon Nov  9 22:00:05 2026  (00:00)
reboot   system boot  6.12.115+deb13.1 Mon Nov  9 20:00:00 2026 - still running

/tmp/w.db begins Mon Nov  9 20:00:00 2026'

login_parse() {
  bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/security.sh"; printf "%s\n" "$2" | ops_login_parse | tr "\t" "|"' _ "$MODULE_DIR" "$1"
}

@test "ops-report: [F3] last -F（Debian 12）本地 tty / web console / 远程登录的来源与时间不错位" {
  run login_parse "$LAST_D12_SAMPLE"
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 5 ]]
  [[ "${lines[0]}" == "guiuser|:0|local|Tue Nov 10 00:50:02 2026|00|2026-11-10" ]]
  [[ "${lines[1]}" == "alonguse|tty2|local|Tue Nov 10 00:33:22 2026|00|2026-11-10" ]]
  [[ "${lines[2]}" == "dnadmin|web console|10.9.9.66|Tue Nov 10 00:16:42 2026|00|2026-11-10" ]]
  [[ "${lines[3]}" == "debnas|pts/0|10.9.9.66|Tue Nov 10 00:00:02 2026|00|2026-11-10" ]]
  [[ "${lines[4]}" == "root|tty1|local|Mon Nov 9 23:26:42 2026|23|2026-11-09" ]]
}

@test "ops-report: [F3] wtmpdb last -F（Debian 13）同样按列解析，终端为空时来源不串列，末行 begins 不算登录" {
  run login_parse "$LAST_D13_SAMPLE"
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 7 ]]
  [[ "${lines[1]}" == "root|tty1|local|Tue Nov 10 00:56:32 2026|00|2026-11-10" ]]
  [[ "${lines[2]}" == "debnas|tty2|local|Mon Nov 9 23:56:32 2026|23|2026-11-09" ]]
  [[ "${lines[3]}" == "dnadmin|web console|10.9.9.66|Mon Nov 9 23:26:32 2026|23|2026-11-09" ]]
  [[ "${lines[4]}" == "alonguse|ssh|2001:db8:85a3::8|Mon Nov 9 23:18:12 2026|23|2026-11-09" ]]
  [[ "${lines[5]}" == "root|seat0|local|Mon Nov 9 23:11:32 2026|23|2026-11-09" ]]
  [[ "${lines[6]}" == "svc||10.9.9.9|Mon Nov 9 22:00:00 2026|22|2026-11-09" ]]
  [[ "$output" != *"begins"* && "$output" != *"reboot"* ]]
}

@test "ops-report: [F3] 不截断用户名的输出（-w）退回分词，web console 仍是一个终端名" {
  run login_parse 'alongusername_x tty2                          Tue Nov 10 00:33:22 2026   gone - no logout
alongusername_x web console  2001:db8:85a3::8a2e:370:7334 Mon Nov  9 23:18:12 2026 - Mon Nov  9 23:19:52 2026  (00:01)
alongusername_x pts/3        10.9.9.66 Mon Nov  9 22:18:12 2026 - Mon Nov  9 22:19:52 2026  (00:01)'
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "alongusername_x|tty2|local|Tue Nov 10 00:33:22 2026|00|2026-11-10" ]]
  [[ "${lines[1]}" == "alongusername_x|web console|2001:db8:85a3::8a2e:370:7334|Mon Nov 9 23:18:12 2026|23|2026-11-09" ]]
  [[ "${lines[2]}" == "alongusername_x|pts/3|10.9.9.66|Mon Nov 9 22:18:12 2026|22|2026-11-09" ]]
}

@test "ops-report: [F3] 登录来源统计与最后活动时间不再出现 console / 错位的时间" {
  local mock="${BATS_TEST_TMPDIR}/bin-f3"
  mkdir -p "$mock"
  { printf '#!/bin/bash\ncat <<"M"\n%s\nM\n' "$LAST_D12_SAMPLE"; } > "$mock/last"
  chmod +x "$mock/last"
  cp "$mock/last" "$mock/wtmpdb"
  printf '#!/bin/sh\nexit 0\n' > "$mock/journalctl"; chmod +x "$mock/journalctl"
  run env PATH="$mock:$PATH" bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/security.sh"
    OPS_REPORT_SINCE="2026-11-01 00:00:00"
    ops_collect_security >/dev/null 2>&1
    echo "N:${OPS_LOGIN_SUCCESS_COUNT}"
    printf "%s\n" "$OPS_LOGIN_IP_STATS" | sort | paste -sd "," -
    printf "%s\n" "$OPS_LOGIN_IP_LAST" | sort | paste -sd "," -' _ "$MODULE_DIR"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "N:5" ]]
  [[ "${lines[1]}" == "10.9.9.66 2,local 3" ]]
  [[ "${lines[2]}" == "10.9.9.66 Tue Nov 10 00:16:42 2026,local Tue Nov 10 00:50:02 2026" ]]
}

# 生成假的 uname / dpkg-query：$1 目录 $2 uname -r $3 uname -v $4 dpkg-query 的行为（shell 片段，$pkg 为被查包名）
mock_kernel() {
  mkdir -p "$1"
  cat > "$1/uname" <<M
#!/bin/sh
case "\$1" in -r) echo '$2' ;; -v) echo '$3' ;; *) echo Linux ;; esac
M
  cat > "$1/dpkg-query" <<M
#!/bin/sh
for pkg in "\$@"; do :; done
$4
M
  chmod +x "$1/uname" "$1/dpkg-query"
}

kernel_ver() {
  env PATH="$1:$PATH" bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"; ops_kernel_pkg_version' _ "$MODULE_DIR"
}

@test "ops-report: [F4] 内核版本按 linux-image-\$(uname -r) 查包（包名带 -amd64），不查元包" {
  local mock="${BATS_TEST_TMPDIR}/bin-f4a"
  mock_kernel "$mock" "6.1.0-18-amd64" "#1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01)" \
    'case "$pkg" in linux-image-6.1.0-18-amd64) echo "installed 6.1.76-1+real" ;; linux-image-amd64) echo "installed 6.1.99-9" ;; *) exit 1 ;; esac'
  run kernel_ver "$mock"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "6.1.76-1+real" ]]
  ! grep -q "sed 's/-amd64\$//'" "$MODULE_DIR/report.sh"
}

@test "ops-report: [F4] 查不到内核包（容器 / PVE 内核 / 包已卸载）时回退 uname -v 的版本串，再回退 uname -r" {
  local mock="${BATS_TEST_TMPDIR}/bin-f4b"
  # 容器：宿主是 PVE 内核，没有对应的包
  mock_kernel "$mock" "6.8.12-11-pve" "#1 SMP PREEMPT_DYNAMIC PMX 6.8.12-11 (2025-05-22T09:39Z)" 'exit 1'
  run kernel_ver "$mock"
  [[ "$status" -eq 0 && "$output" == "6.8.12-11" ]]
  # 包已知但未安装：dpkg-query 返回 0、Version 为空
  mock_kernel "$mock" "6.1.0-18-amd64" "#1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01)" 'echo "not-installed "'
  run kernel_ver "$mock"
  [[ "$status" -eq 0 && "$output" == "6.1.76-1" ]]
  # uname -v 里没有版本串
  mock_kernel "$mock" "5.10.0-custom" "#1 SMP Thu Jan 1 00:00:00 UTC 2026" 'exit 1'
  run kernel_ver "$mock"
  [[ "$status" -eq 0 && "$output" == "5.10.0-custom" ]]
}

@test "ops-report: [F4] 内核上一版本取元包升级记录的旧版本列，兼容 cloud 等风味元包" {
  local log="${BATS_TEST_TMPDIR}/dpkg-f4.log"
  cat > "$log" <<'L'
2026-10-01 09:00:00 upgrade linux-image-cloud-amd64:amd64 6.12.110-1 6.12.115-2
2026-11-08 10:00:00 upgrade linux-image-cloud-amd64:amd64 6.12.115-2 6.12.116-1
2026-11-08 10:00:01 install linux-image-6.12.116+deb13-cloud-amd64:amd64 <none> 6.12.116-1
2026-11-08 10:00:02 upgrade linux-libc-dev:amd64 6.12.115-2 6.12.116-1
2026-11-08 10:00:03 status installed linux-image-cloud-amd64:amd64 6.12.116-1
L
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/report.sh"; ops_kernel_prev_upgrade "$2"; ops_kernel_prev_upgrade /nonexistent; echo END' _ "$MODULE_DIR" "$log"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "6.12.115-2|2026-11-08 10:00:00" ]]
  [[ "${lines[1]}" == "END" ]]
  printf '2026-11-08 10:00:00 upgrade linux-image-amd64:amd64 6.1.76-1 6.1.90-1\n' > "$log"
  run bash -c 'source "$1/report.sh"; ops_kernel_prev_upgrade "$2"' _ "$MODULE_DIR" "$log"
  [[ "$output" == "6.1.76-1|2026-11-08 10:00:00" ]]
}

# ==================== 登录数据源（Debian 13 默认没有 last / wtmpdb，2026-11-10） ====================

# 建一个只含系统命令链接、但没有 last / lastb / wtmpdb 的 PATH 目录（模拟干净的 Debian 13）
bare_path() {
  local dir="$1" f
  mkdir -p "$dir"
  for f in /usr/bin/* /usr/sbin/*; do
    case "${f##*/}" in last|lastb|wtmpdb) continue ;; esac
    ln -sf "$f" "$dir/${f##*/}" 2>/dev/null || true
  done
}

# 在指定 PATH 下执行 ops_ensure_login_source；$2 系统版本，$3 apt_install_packages 的行为（shell 片段）
ensure_login_source() {
  env PATH="$1" BARE="$1" VER="$2" bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'
    source "$1/security.sh"; source "$1/setup.sh"
    log_info() { echo "INFO:$*"; }; log_warning() { echo "WARN:$*"; }
    get_system_version() { echo "$VER"; }
    apt_install_packages() { echo "APT:$*"; '"$3"'; }
    ops_ensure_login_source; echo "RC:$?"; echo "SRC:$(ops_login_source || echo none)"' _ "$MODULE_DIR" "$2"
}

@test "ops-report: [L1] 已有 last（Debian 12）时不安装任何包" {
  local p="${BATS_TEST_TMPDIR}/bare-l1"
  bare_path "$p"
  printf '#!/bin/sh\nexit 0\n' > "$p/last"; chmod +x "$p/last"
  run ensure_login_source "$p" 12 'return 0'
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"APT:"* && "$output" != *"WARN:"* ]]
  [[ "$output" == *"RC:0"*"SRC:last"* ]]
}

@test "ops-report: [L1] 已有 wtmpdb 时不安装任何包，且优先于 last" {
  local p="${BATS_TEST_TMPDIR}/bare-l2"
  bare_path "$p"
  printf '#!/bin/sh\nexit 0\n' > "$p/wtmpdb"; chmod +x "$p/wtmpdb"; cp "$p/wtmpdb" "$p/last"
  run ensure_login_source "$p" 13 'return 0'
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"APT:"* ]]
  [[ "$output" == *"SRC:wtmpdb"* ]]
}

@test "ops-report: [L1] Debian 13 两者都没有时安装 wtmpdb libpam-wtmpdb，成功后数据源可用" {
  local p="${BATS_TEST_TMPDIR}/bare-l3"
  bare_path "$p"
  run ensure_login_source "$p" 13 'printf "#!/bin/sh\nexit 0\n" > "$BARE/wtmpdb"; chmod +x "$BARE/wtmpdb"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"APT:wtmpdb"*"libpam-wtmpdb"* ]]
  [[ "$output" != *"WARN:"* ]]
  [[ "$output" == *"RC:0"*"SRC:wtmpdb"* ]]
}

@test "ops-report: [L1] 安装失败只告警、返回 0；Debian 12 缺 last 时不尝试安装" {
  local p="${BATS_TEST_TMPDIR}/bare-l4"
  bare_path "$p"
  run ensure_login_source "$p" 13 'return 1'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"APT:"* && "$output" == *"WARN:wtmpdb 安装失败"* ]]
  [[ "$output" == *"RC:0"*"SRC:none"* ]]
  run ensure_login_source "$p" 12 'return 0'
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"APT:"* && "$output" == *"WARN:未找到 last / wtmpdb"* && "$output" == *"RC:0"* ]]
  # 不手改 PAM：模块里没有写 /etc/pam.d 或直接调用 pam-auth-update 的代码（注释除外）
  ! grep -v '^[[:space:]]*#' "$MODULE_DIR"/*.sh | grep -q '/etc/pam\.d\|pam-auth-update[^ 自（]'
  grep -q 'ops_ensure_login_source$' "$MODULE_DIR/setup.sh"
}

# 在指定 PATH 下采集登录数据并输出说明；$2 系统版本
login_note() {
  env PATH="$1" VER="$2" bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'
    source "$1/security.sh"; source "$1/report.sh"
    get_system_version() { echo "$VER"; }
    OPS_REPORT_SINCE="2026-11-01 00:00:00"
    ops_collect_security >/dev/null 2>&1
    echo "SRC:${OPS_LOGIN_SOURCE:-none}"; echo "NOTE:${OPS_LOGIN_SOURCE_NOTE}"' _ "$MODULE_DIR" "$2"
}

@test "ops-report: [L3] 报告登录一节：数据源缺失 / 刚装上还没有记录 / 有记录 三种情况的说明" {
  local p="${BATS_TEST_TMPDIR}/bare-l5"
  bare_path "$p"
  printf '#!/bin/sh\nexit 0\n' > "$p/journalctl"; chmod +x "$p/journalctl"
  run login_note "$p" 13
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"SRC:none"* && "$output" == *"NOTE:无登录数据源：未安装 wtmpdb"*"apt install wtmpdb libpam-wtmpdb"* ]]
  run login_note "$p" 12
  [[ "$output" == *"NOTE:无登录数据源：系统中没有 last 或 wtmpdb 命令"* ]]
  # 刚装上：有命令但库里没有记录
  printf '#!/bin/sh\necho\necho "wtmpdb begins Tue Nov 10 01:56:22 2026"\n' > "$p/wtmpdb"; chmod +x "$p/wtmpdb"
  run login_note "$p" 13
  [[ "$output" == *"SRC:wtmpdb"* && "$output" == *"NOTE:登录数据源（wtmpdb）可用，周期内没有登录记录。"*"此前的登录不会出现在报告里"* ]]
  # 有记录：不加说明
  printf '#!/bin/sh\necho "debnas   pts/0        10.9.9.66        Tue Nov 10 01:56:22 2026 - Tue Nov 10 01:56:23 2026  (00:00)"\n' > "$p/wtmpdb"
  run login_note "$p" 13
  [[ "$output" == *"SRC:wtmpdb"* && "${lines[1]}" == "NOTE:" ]]
  # 说明经 ops_html_escape 输出到登录一节
  grep -q 'ops_html_escape "\$OPS_LOGIN_SOURCE_NOTE"' "$MODULE_DIR/report.sh"
}

# 在指定 PATH 下探测 module_status / module_plan；$2 status|plan，$3 系统版本
probe_bare() {
  env PATH="$1" BARE_PATH="$1" VER="$3" DEBNAS_MODULE_ACTION="$2" DEBNAS_STATE_DIR="${BATS_TEST_TMPDIR}/probe-state" bash -c '
    source "$1/module.sh" </dev/null >/dev/null 2>&1
    PATH="$BARE_PATH"
    get_system_version() { echo "$VER"; }
    module_$2' _ "$MODULE_DIR" "$2" "$3"
}

@test "ops-report: [L2] module_plan 在 Debian 13 缺数据源时列出 pkg 行与说明，有数据源时不列" {
  local p="${BATS_TEST_TMPDIR}/bare-l6" line
  bare_path "$p"
  run probe_bare "$p" plan 13
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"pkg|wtmpdb libpam-wtmpdb|"*"pam-auth-update"* ]]
  [[ "$output" == *"info|登录记录|安装后才开始记录"*"此前的登录不会出现在报告里"* ]]
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
  run probe_bare "$p" plan 12
  [[ "$output" != *"pkg|wtmpdb"* && "$output" == *"info|登录记录|未找到 last / wtmpdb"* ]]
  printf '#!/bin/sh\nexit 0\n' > "$p/last"; chmod +x "$p/last"
  run probe_bare "$p" plan 13
  [[ "$output" != *"wtmpdb"* && "$output" != *"info|登录记录|"* ]]
}

@test "ops-report: [L2] module_status 在缺数据源时说明里带「无登录数据源」，仍是合法的一行" {
  local p="${BATS_TEST_TMPDIR}/bare-l7"
  bare_path "$p"
  run probe_bare "$p" status 13
  [[ "$status" -eq 0 && "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
  [[ "$output" == *"无登录数据源"* ]]
  printf '#!/bin/sh\nexit 0\n' > "$p/wtmpdb"; chmod +x "$p/wtmpdb"
  run probe_bare "$p" status 13
  [[ "${#lines[@]}" -eq 1 && "$output" != *"无登录数据源"* ]]
}
