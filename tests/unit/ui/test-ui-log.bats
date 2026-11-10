#!/usr/bin/env bats
# 测试: lib/ui/log.sh — 统一日志行输出组件
# 覆盖: ui_log 各级别分发（INFO/OK/WARN/ERROR/DEBUG/未知）

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  source "${DEBNAS_ROOT}/lib/ui/log.sh"
}

# ═══════════════════════════════════════════════════════════════
# ui_log 各级别分发
# ═══════════════════════════════════════════════════════════════

@test "ui_log: INFO 级别 — 调用 log_info" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/log.sh 2>/dev/null
    ui_log "INFO" "测试消息" >&2
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  # log_info 输出到 stderr，标签为 [INFO]
  [[ "$output" == *"[INFO]"* ]]
  [[ "$output" == *"测试消息"* ]]
}

@test "ui_log: OK 级别 — 调用 log_success（[DONE] 标签）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/log.sh 2>/dev/null
    ui_log "OK" "安装完成" >&2
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[DONE]"* ]]
  [[ "$output" == *"安装完成"* ]]
}

@test "ui_log: WARN 级别 — 调用 log_warning" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/log.sh 2>/dev/null
    ui_log "WARN" "磁盘空间不足" >&2
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"磁盘空间不足"* ]]
}

@test "ui_log: ERROR 级别 — 调用 log_error" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/log.sh 2>/dev/null
    ui_log "ERROR" "连接超时" >&2
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[ERROR]"* ]]
  [[ "$output" == *"连接超时"* ]]
}

@test "ui_log: DEBUG 级别 — 调用 log_debug（DEBNAS_DEBUG=1）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/log.sh 2>/dev/null
    export DEBNAS_DEBUG=1
    ui_log "DEBUG" "调试信息" >&2
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[DEBUG]"* ]]
  [[ "$output" == *"调试信息"* ]]
}

@test "ui_log: 未知级别 — 回退到 log_info" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/log.sh 2>/dev/null
    ui_log "UNKNOWN" "未知级别消息" >&2
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  # 回退到 INFO 标签
  [[ "$output" == *"[INFO]"* ]]
  [[ "$output" == *"未知级别消息"* ]]
}
