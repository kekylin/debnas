#!/bin/bash
# 功能：统一日志行输出组件 — 7 字符宽标签 + 2 空格 + 消息
# 说明：对 Phase 1 统一标签后的 log_* 函数的薄封装，增加语义化 LEVEL 参数
# 依赖：lib/core/logging.sh（由 bootstrap 已加载）
#
# 用法：ui_log "INFO"  "正在检查系统环境"
#       ui_log "OK"    "Docker Engine 安装完成"   # 成功级别，终端标签渲染为 [DONE]
#       ui_log "ERROR" "无法连接到服务器 (超时)"

set -euo pipefail
IFS=$'\n\t'

# 统一日志行输出（薄封装）
# 参数：$1 — 级别 (INFO/OK/WARN/ERROR/DEBUG)
#       $2 — 消息内容
ui_log() {
  local level="$1" message="$2"
  case "$level" in
    INFO)  log_info    "$message" ;;
    OK)    log_success "$message" ;;
    WARN)  log_warning "$message" ;;
    ERROR) log_error   "$message" ;;
    DEBUG) log_debug   "$message" ;;
    *)     log_info    "$message" ;;
  esac
}
