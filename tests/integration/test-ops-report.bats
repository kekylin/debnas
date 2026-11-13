#!/usr/bin/env bats
# 集成测试: ops-report 运维报告模块结构与定时任务

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/ops-report"
export NO_COLOR=1

@test "ops-report: 元数据完整" {
  grep -q '^# @module: ops-report' "$MODULE_DIR/module.sh"
  grep -q '^# @name: 运维报告' "$MODULE_DIR/module.sh"
  grep -q '^# @category: 系统维护' "$MODULE_DIR/module.sh"
  grep -q '^# @interactive: true' "$MODULE_DIR/module.sh"
  grep -q '^# @cron: true' "$MODULE_DIR/module.sh"
}

@test "ops-report: 固定周报调度为 0 1 * * 1" {
  local schedule
  schedule=$(grep -m1 '^# @cron_schedule:' "$MODULE_DIR/module.sh" | sed 's/^# @cron_schedule: *//')
  [[ "$schedule" == "0 1 * * 1" ]]
}

@test "ops-report: 八个模块文件存在且语法有效" {
  local f
  for f in module.sh setup.sh health.sh report.sh report-render.sh security.sh services.sh notify.sh; do
    [[ -f "$MODULE_DIR/$f" ]]
    run bash -n "$MODULE_DIR/$f"
    [[ "$status" -eq 0 ]]
  done
}

@test "ops-report: 不重复写入系统 logrotate 配置" {
  if grep -q '/var/log/wtmp {' "$MODULE_DIR/setup.sh"; then false; fi
  if grep -q '/var/log/btmp {' "$MODULE_DIR/setup.sh"; then false; fi
  if grep -q '/var/lib/wtmpdb/wtmp.db {' "$MODULE_DIR/setup.sh"; then false; fi
  grep -q 'duplicate log entry' "$MODULE_DIR/setup.sh"
}

@test "ops-report: module.sh 使用 main 入口" {
  grep -q '^main()' "$MODULE_DIR/module.sh"
  grep -q 'main "\$@"' "$MODULE_DIR/module.sh"
}

@test "ops-report: 支持三个周期和 CLI 参数" {
  grep -q 'ops_period_to_days' "$MODULE_DIR/module.sh"
  grep -q -- '--period' "$MODULE_DIR/module.sh"
  grep -q -- '--email' "$MODULE_DIR/module.sh"
  grep -q -- '--no-email' "$MODULE_DIR/module.sh"
}

@test "ops-report: 默认发送邮件且不再询问" {
  grep -q 'email="\${OPS_EMAIL_ENABLED:-1}"' "$MODULE_DIR/module.sh"
  grep -q 'ops_generate_report "$days" 1' "$MODULE_DIR/module.sh"
  ! grep -q 'ui_confirm "是否同时发送邮件' "$MODULE_DIR/module.sh"
}

@test "ops-report: 二级菜单固定五个入口" {
  grep -q '"启用定时报告"' "$MODULE_DIR/module.sh"
  grep -q '"禁用定时报告"' "$MODULE_DIR/module.sh"
  grep -q '"生成最近 7 天报告"' "$MODULE_DIR/module.sh"
  grep -q '"生成最近 30 天报告"' "$MODULE_DIR/module.sh"
  grep -q '"生成最近 365 天报告"' "$MODULE_DIR/module.sh"
  if grep -q '"生成最近 180 天报告"' "$MODULE_DIR/module.sh"; then false; fi
  if grep -q '"启用数据采集"' "$MODULE_DIR/module.sh"; then false; fi
  ! grep -q '"查看数据覆盖状态"' "$MODULE_DIR/module.sh"
}

@test "ops-report: 邮件支持 HTML 附件与降级" {
  grep -q 'OPS_EMAIL_ATTACH_HTML=1' "$MODULE_DIR/module.sh"
  grep -q 'OPS_EMAIL_MAX_ATTACH_BYTES=2097152' "$MODULE_DIR/module.sh"
  grep -q 'multipart/mixed' "$MODULE_DIR/notify.sh"
  grep -q '降级为仅发送正文' "$MODULE_DIR/notify.sh"
}

@test "ops-report: 定时任务数据不足自动跳过" {
  grep -q 'ops_cron_generate_from_args' "$MODULE_DIR/module.sh"
  grep -q 'OPS_SYSSTAT_DATA_DAYS.*-lt "\$days"' "$MODULE_DIR/module.sh"
  grep -q 'schedule_skip' "$MODULE_DIR/module.sh"
}

@test "ops-report: 按模拟报告样式输出核心结构" {
  grep -q '安全体检结论' "$MODULE_DIR/report-render.sh"
  grep -q '登录与身份审计' "$MODULE_DIR/report-render.sh"
  grep -q 'badge-medium' "$MODULE_DIR/report-render.sh"
  grep -q 'week-overview' "$MODULE_DIR/report-render.sh"
  grep -q 'event-pulse' "$MODULE_DIR/report-render.sh"
  grep -q '主机与进程安全' "$MODULE_DIR/report-render.sh"
  grep -q 'Swap 使用' "$MODULE_DIR/report-render.sh"
  grep -q '时段异常登录' "$MODULE_DIR/report-render.sh"
  grep -q '资源使用情况' "$MODULE_DIR/report-render.sh"
  grep -q '安全更新已装' "$MODULE_DIR/report-render.sh"
  grep -q '物理网卡合计' "$MODULE_DIR/report-render.sh"
  grep -q '系统版本更新' "$MODULE_DIR/report-render.sh"
  grep -q '维护与更新' "$MODULE_DIR/report-render.sh"
  grep -q 'OPS_LOGIN_USER_STATS' "$MODULE_DIR/security.sh"
  grep -q 'ops_render_trend_chart' "$MODULE_DIR/report-render.sh"
  grep -q 'ops_render_network_chart' "$MODULE_DIR/report-render.sh"
  grep -q 'ops_render_login_hours_chart' "$MODULE_DIR/report-render.sh"
  grep -q 'ops_render_anomaly_table' "$MODULE_DIR/report-render.sh"
  ! grep -q 'report-template.html' "$MODULE_DIR/report.sh"
}

@test "ops-report: 图表与安全研判按模拟报告修正" {
  grep -q '%memused' "$MODULE_DIR/report.sh"
  grep -q 'OPS_NET_DAILY_RX_LIST' "$MODULE_DIR/report.sh"
  grep -qF '$5 ~ /^[0-9]+$/' "$MODULE_DIR/security.sh"
}

@test "ops-report: 图表函数生成合法 SVG" {
  source "$MODULE_DIR/report.sh"
  OPS_REPORT_UNTIL="2026-08-06 10:00:00"
  OPS_REPORT_DAYS=7

  run ops_render_trend_chart "10,20,30" "#22D3EE" "%" 480 190 "08-01,08-02,08-03" "Cpu"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"<svg"* ]]
  [[ "$output" != *"division by zero"* ]]

  run ops_render_network_chart "1,2,3" "4,5,6" 480 200 "08-01,08-02,08-03"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'fill="#86868B"'* ]]
  [[ "$output" != *"division by zero"* ]]

  printf '0 1\n1 0\n2 0\n3 0\n4 0\n5 0\n6 0\n7 0\n8 0\n9 0\n10 0\n11 0\n12 0\n13 0\n14 0\n15 0\n16 0\n17 0\n18 0\n19 0\n20 0\n21 0\n22 0\n23 0\n' \
    | ops_render_login_hours_chart 480 200 > /tmp/ops-login-chart-test.svg
  run cat /tmp/ops-login-chart-test.svg
  [[ "$output" == *"次数"* ]]
  [[ "$output" != *"%"* ]]
}

@test "ops-report: 设备 I/O 图横轴刻度均匀" {
  source "$MODULE_DIR/report.sh"
  OPS_SYSSTAT_SAMPLE_DAYS=7
  OPS_DISK_IO_SUMMARY="sda|0.001|0.0002|12|08-05 10:00|1"

  run ops_render_disk_io_chart
  [[ "$status" -eq 0 ]]
  # 图表高度随磁盘数动态计算：单块盘时 grid_bottom=40，横轴标签 y=63
  [[ "$output" == *'text x="112.0" y="63">0.0'* ]]
  [[ "$output" == *'text x="310.0" y="63">0.3'* ]]
  [[ "$output" == *'text x="442.0" y="63">0.5'* ]]
}

@test "ops-report: 网络图按数据量自动缩放" {
  source "$MODULE_DIR/report.sh"

  run ops_render_network_chart "0.1,0.2" "0.05,0.1" 480 200 "08-08,08-09"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'y="18">0.20'* ]]
  [[ "$output" != *'y="18">4'* ]]

  run ops_render_network_chart "10,20,42" "5,15,30" 480 200 "08-08,08-09,08-10"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'y="18">50'* ]]
}

@test "ops-report: 网络图柱顶标注流量且不显示纵轴单位" {
  source "$MODULE_DIR/report.sh"

  run ops_render_network_chart "1.23,2.5" "0.5,1.8" 480 200 "08-08,08-09"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *'text x="16" y="18"'* ]]
  [[ "$output" == *'">1.23</text>'* ]]
  [[ "$output" == *'">0.50</text>'* ]]
}

@test "ops-report: 数据覆盖与维护数据补齐" {
  grep -q 'OPS_SYSSTAT_SAMPLE_DAYS' "$MODULE_DIR/report.sh"
  grep -q 'OPS_SERVICE_STABILITY' "$MODULE_DIR/services.sh"
  grep -q 'OPS_DISK_IO_SUMMARY' "$MODULE_DIR/report.sh"
  grep -q 'ops_render_system_version_table' "$MODULE_DIR/report-render.sh"
  grep -q 'OPS_JOURNAL_ERROR_COUNT' "$MODULE_DIR/services.sh"
}

@test "ops-report: 数据采集在采样天数相同时正常返回" {
  source "$MODULE_DIR/report.sh"
  OPS_REPORT_DAYS=7
  OPS_REPORT_SINCE=$(date -d "7 days ago" '+%Y-%m-%d %H:%M:%S')
  OPS_REPORT_UNTIL=$(date '+%Y-%m-%d %H:%M:%S')
  run ops_collect_resources
  [[ "$status" -eq 0 ]]
}

@test "ops-report: 周期/估算/当前状态口径明确" {
  grep -q '待周期数据' "$MODULE_DIR/report.sh"
  grep -q '待基线' "$MODULE_DIR/report-render.sh"
  grep -q '当前状态' "$MODULE_DIR/report-render.sh"
  grep -q 'OPS_LAST_UPDATE_CHECK' "$MODULE_DIR/report.sh"
  grep -q 'OPS_REBOOT_REQUIRED' "$MODULE_DIR/report.sh"
}

@test "ops-report: 按新版结构与样式输出" {
  grep -q 'report-style.css' "$MODULE_DIR/report-render.sh"
  grep -q 'ops_render_html_report' "$MODULE_DIR/report-render.sh"
  grep -q '服务器\$(ops_period_label_cn' "$MODULE_DIR/report-render.sh"
  grep -q 'footer-grid' "$MODULE_DIR/report-render.sh"
}

@test "ops-report: 报告文件名包含周期标识" {
  grep -q 'period_tag=' "$MODULE_DIR/report.sh"
  grep -q 'ops-report-\${period_tag}' "$MODULE_DIR/report.sh"
}

@test "ops-report: 报告按周期分目录存放" {
  grep -q 'ops_period_reports_dir' "$MODULE_DIR/report.sh"
  grep -q '"${OPS_REPORTS_DIR}/weekly"' "$MODULE_DIR/setup.sh"
  grep -q '"${OPS_REPORTS_DIR}/monthly"' "$MODULE_DIR/setup.sh"
  grep -q '"${OPS_REPORTS_DIR}/annual"' "$MODULE_DIR/setup.sh"
}

@test "ops-report: 事件脉冲复刻与健康结论细分" {
  grep -q 'pulse-legend' "$MODULE_DIR/report-render.sh"
  grep -q 'OPS_HEALTH_FS_ERRORS' "$MODULE_DIR/health.sh"
  grep -q 'OPS_HEALTH_KERNEL_ERRORS' "$MODULE_DIR/health.sh"
  grep -q '检测到文件系统错误' "$MODULE_DIR/report-render.sh"
  grep -q '检测到内核错误' "$MODULE_DIR/report-render.sh"
}

@test "ops-report: 同日多事件使用独立标注位不重叠" {
  source "$MODULE_DIR/report.sh"
  OPS_REPORT_UNTIL="2026-08-06 10:00:00"
  OPS_EVENTS="2026-08-06 02:18|存在 2 个失败服务|中风险 · 服务状态异常|待处理
2026-08-06 03:00|CPU 平均使用率 85%|中风险 · 长期高占用|待处理"

  run ops_render_event_pulse
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'cx="896" cy="148"'* ]]
  [[ "$output" == *'cx="896" cy="184"'* ]]
  [[ "$output" == *'pulse-node service'* ]]
  [[ "$output" == *'pulse-node system'* ]]
}

@test "ops-report: 维护更新事件按低风险展示" {
  source "$MODULE_DIR/report.sh"
  OPS_REPORT_UNTIL="2026-08-15 10:00:00"
  OPS_EVENTS="2026-08-15 10:00:00|系统更新（3 个软件包）|低风险 · 维护完成|已完成"

  run ops_render_event_pulse
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'pulse-node update'* ]]
  [[ "$output" != *'pulse-node maintenance'* ]]
}

@test "ops-report: 登录风险说明明确区分异常与失败并定位用户" {
  source "$MODULE_DIR/report.sh"
  OPS_SECURITY_EVENTS="非工作时间登录：alice local Wed Aug 5 00:21:46 2026"
  OPS_LOGIN_FAIL_COUNT=1
  OPS_FAIL_IP_STATS="203.0.113.5 1"
  OPS_LOGIN_SUCCESS_COUNT=10
  OPS_LOGIN_USERS="alice"

  ops_build_login_risk_note
  [[ "$OPS_LOGIN_RISK_NOTE" == *"异常登录：alice"* ]]
  [[ "$OPS_LOGIN_RISK_NOTE" == *"失败登录：1 次"* ]]
  [[ "$OPS_LOGIN_RISK_NOTE" == *"203.0.113.5"* ]]
  [[ "$OPS_LOGIN_RISK_LABEL" == "登录安全" ]]
}

@test "ops-report: 事件脉冲与第二章风险研判保持一致" {
  source "$MODULE_DIR/report.sh"
  OPS_REPORT_UNTIL="2026-08-06 10:00:00"
  OPS_EVENTS="2026-08-06 02:18|CPU 平均使用率 85%|中风险 · 长期高占用|待处理
2026-08-06 02:18|内存平均使用率 90%|中风险 · 长期高占用|待处理
2026-08-06 02:18|检测到SMART异常|高风险 · 服务风险升高|待处理
2026-08-06 02:18|存在 2 个失败服务|中风险 · 服务状态异常|待处理
2026-08-06 02:18|发现 8 个安全更新待装|风险升高|待处理
2026-08-06 02:18|登录审计发现异常|安全事件，待确认|处理中"

  run ops_render_event_pulse
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"pulse-node system"* ]]
  [[ "$output" == *"pulse-node service"* ]]
  [[ "$output" == *"pulse-node update"* ]]
  [[ "$output" == *"pulse-node security"* ]]

  OPS_CPU_AVG=85
  OPS_CPU_MAX=90
  OPS_MEM_AVG=90
  OPS_MEM_MAX=95
  OPS_DISK_IO_SUMMARY=""
  OPS_DISK_USAGE_LINES=""
  OPS_HEALTH_ISSUE_SUMMARY="SMART 异常"
  OPS_SYSTEMD_FAILED_COUNT=2
  OPS_SECURITY_ISSUE=1
  OPS_LOGIN_SUCCESS_COUNT=1
  OPS_LOGIN_USERS="alice"
  OPS_PENDING_SECURITY_COUNT=8
  OPS_REPORT_DAYS=7
  OPS_NET_DAILY_TX_LIST=""
  OPS_NET_TOTAL_TX_BYTES=0

  run ops_render_anomaly_table
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"CPU 持续高占用"* ]]
  [[ "$output" == *"内存持续高占用"* ]]
  [[ "$output" == *"磁盘 / 存储"* ]]
  [[ "$output" == *"服务状态"* ]]
  [[ "$output" == *"安全更新"* ]]
  [[ "$output" == *"异常登录"* ]]
}

@test "ops-report: 曲线/磁盘标注/服务清单/登录时段/来源IP修正" {
  grep -q 'path_points = sprintf("M%.1f %.1f"' "$MODULE_DIR/report-render.sh"
  grep -q 'OPS_DOCKER_RUNNING_COUNT' "$MODULE_DIR/services.sh"
  grep -q 'period = sprintf("%02d:00-%02d:00"' "$MODULE_DIR/security.sh"
  grep -q 'last_label' "$MODULE_DIR/report-render.sh"
}

@test "ops-report: 日期格式与动态图表坐标" {
  grep -q 'ops_normalize_date' "$MODULE_DIR/report-render.sh"
  grep -q 'nice = max' "$MODULE_DIR/report-render.sh"
  grep -q 'axis_grid' "$MODULE_DIR/report-render.sh"
}

@test "ops-report: 已登记到 timer-manager 定时概览" {
  grep -q 'ops-report' "${DEBNAS_ROOT}/modules/timer-manager.sh"
}

@test "ops-report: 年报 cron 变体注册在同一模块名下" {
  source "${DEBNAS_ROOT}/tests/helpers/common-setup.bash" 2>/dev/null || true
  setup_crontab_mock
  source "${DEBNAS_ROOT}/lib/system/cron.sh"

  run cron_register "ops-report" "0 1 * * 1"
  [[ "$status" -eq 0 ]]
  run cron_register_variant "ops-report" "0 2 1 1 *" "--period 1y --email"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$CRON_STATE")" == *"0 2 1 1 *"* ]]
  [[ "$(cat "$CRON_STATE")" == *"--period 1y --email"* ]]

  teardown_crontab_mock
}

@test "ops-report: 磁盘一节展示容量预测，服务说明列不丢信息，内核版本走专用查询函数" {
  source "$MODULE_DIR/report.sh"
  grep -A6 '\$(ops_render_disk_io_chart)' "$MODULE_DIR/report-render.sh" | grep -q '磁盘容量预测'
  grep -q 'kernel_version=\$(ops_kernel_pkg_version)' "$MODULE_DIR/report.sh"
  if grep -q "linux-image-amd64 2>/dev/null" "$MODULE_DIR/report.sh"; then false; fi
  if grep -q 'note="\${note:+- }' "$MODULE_DIR/report-render.sh"; then false; fi
  OPS_DISK_FORECAST="sda|37|7|1.00|53"
  run ops_render_disk_forecast_table
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"约 53 天后达到 90%"* ]]
  run ops_kernel_pkg_version
  [[ "$status" -eq 0 && -n "$output" ]]
}
