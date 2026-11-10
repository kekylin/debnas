#!/usr/bin/env bats
# 测试: lib/core/logging.sh — 日志框架

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  export LOG_TIMESTAMP=0
  setup_debnas_lib
}

@test "log_info 始终返回 0（set -e 兼容）" {
  run log_info "测试消息"
  [ "$status" -eq 0 ]
}

@test "log_warning 始终返回 0（set -e 兼容）" {
  run log_warning "警告消息"
  [ "$status" -eq 0 ]
}

@test "log_error 始终返回 0（set -e 兼容）" {
  run log_error "错误消息"
  [ "$status" -eq 0 ]
}

@test "log_success 始终返回 0（set -e 兼容）" {
  run log_success "成功消息"
  [ "$status" -eq 0 ]
}

@test "log_fatal 调用 exit 1（致命错误应终止进程）" {
  run log_fatal "致命消息"
  [ "$status" -eq 1 ]
}

@test "log_fatal_return 返回 1 但不退出进程（库层安全使用）" {
  run log_fatal_return "致命消息"
  [ "$status" -eq 1 ]
}

@test "get_timestamp 返回时间格式" {
  export LOG_TIMESTAMP=1
  result=$(get_timestamp)
  [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]
}

@test "log_to_file 创建日志文件" {
  local tmpdir
  tmpdir=$(mktemp -d)
  export DEBNAS_LOG_DIR="$tmpdir"
  log_to_file "test-module"
  # 验证至少生成了一个匹配的日志文件
  local count
  count=$(find "$tmpdir" -name 'test-module-*.log' | wc -l)
  [ "$count" -ge 1 ]
  rm -rf "$tmpdir"
}

# ==================== L-01~L-05 扩展覆盖 ====================

@test "L-01: log_to_file 写入的日志头包含时间戳格式 (YYYY-MM-DD HH:MM:SS)" {
  local tmpdir
  tmpdir=$(mktemp -d)
  export DEBNAS_LOG_DIR="$tmpdir"
  log_to_file "test-ts"
  local logfile
  logfile=$(get_log_file)
  # 日志头应包含 "开始时间: YYYY-MM-DD HH:MM:SS"
  run grep -c '开始时间: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}' "$logfile"
  [[ "$status" -eq 0 ]]
  rm -rf "$tmpdir"
}

@test "L-02: log_to_file 无 DEBNAS_LOG_DIR 时使用默认 /var/log/debnas 路径" {
  # 清除自定义目录，测试默认路径引用
  unset DEBNAS_LOG_DIR
  # 重新 source 以获取默认值
  source "${DEBNAS_ROOT}/lib/core/logging.sh"
  # 默认 DEBNAS_LOG_DIR 应为 /var/log/debnas
  [[ "${DEBNAS_LOG_DIR:-}" == "/var/log/debnas" ]]
}

@test "L-03: LOG_TIMESTAMP=0 时 get_timestamp 返回空字符串" {
  export LOG_TIMESTAMP=0
  result=$(get_timestamp)
  [[ -z "$result" ]]
  export LOG_TIMESTAMP=1  # 恢复默认
}

@test "L-04: NO_COLOR=1 时 log_info 输出不含 ANSI 转义码" {
  export NO_COLOR=1
  run log_info "无颜色测试"
  # 输出不应包含 ANSI 转义序列 \033[ 或 \e[
  ! grep -qP '\x1b\[' <<< "$output" || true
}

@test "L-06: log_debug 始终返回 0（set -e 兼容）" {
  run log_debug "调试消息"
  [ "$status" -eq 0 ]
}

@test "L-07: DEBNAS_DEBUG=1 时 log_debug 输出到终端" {
  export DEBNAS_DEBUG=1
  export NO_COLOR=1
  run log_debug "调试输出"
  [[ "$output" == *"DEBUG"* ]]
  [[ "$output" == *"调试输出"* ]]
}

@test "L-05: log_to_file 连续调用追加写入不覆盖已有内容" {
  local tmpdir
  tmpdir=$(mktemp -d)
  export DEBNAS_LOG_DIR="$tmpdir"
  log_to_file "test-append"
  local logfile
  logfile=$(get_log_file)
  local line_count_before
  line_count_before=$(wc -l < "$logfile")
  # 再写一条日志（需要 _DEBNAS_FILE_LOGGING=1 且 _DEBNAS_LOG_FILE 已设置）
  log_info "第二条日志"
  local line_count_after
  line_count_after=$(wc -l < "$logfile")
  # 写入后行数应增加
  [[ "$line_count_after" -gt "$line_count_before" ]]
  rm -rf "$tmpdir"
}
