#!/bin/bash
# 功能：进度步骤组件 — 多步骤操作的状态反馈
# 说明：在模式 B 下输出，跟随日志流自然排列
# 依赖：lib/core/logging.sh（由 bootstrap 已加载）
#
# 用法：ui_progress_step 1 3 "Docker Engine"
# 输出：[INFO]  [=>                  ] 33% Docker Engine
#       ui_progress_step 3 3 "Docker Engine 安装完成" "done"
# 输出：[DONE] [====================] 100% Docker Engine 安装完成

set -euo pipefail
IFS=$'\n\t'

# 进度步骤输出（含 ASCII 进度条）
# 参数：$1 — 当前步骤号
#       $2 — 总步骤数
#       $3 — 描述文字
#       $4 — 状态（可选，"done"=绿色 [DONE] 标签，其余=蓝色 INFO 标签）
ui_progress_step() {
  local current="$1" total="$2" description="$3" status="${4:-}"
  local pct=$((current * 100 / total))
  local bar_width=20
  local filled=$((pct * bar_width / 100))
  local empty=$((bar_width - filled))

  local bar
  bar=$(printf '%*s' "$filled" '' | tr ' ' '=')
  bar+=$(printf '%*s' "$empty" '' | tr ' ' ' ')

  if [[ "$status" == "done" ]]; then
    log_success "[${bar}] ${pct}% ${description}"
  else
    log_info "[${bar}] ${pct}% ${description}"
  fi
}
