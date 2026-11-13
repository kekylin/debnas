#!/bin/bash
# 功能：进度步骤组件 — 多步骤操作的步骤计数反馈
# 说明：在模式 B 下输出，跟随日志流自然排列
#       离散步骤不可度量，不显示百分比/进度条，避免“开始第 N 步”被误读为完成度
#       可度量任务的进度条应由调用方按字节/条数自行实现
# 依赖：lib/core/logging.sh（由 bootstrap 已加载）
#
# 用法：ui_progress_step 1 3 "Docker Engine"
# 输出：[INFO] [1/3] Docker Engine
#       ui_progress_step 3 3 "Docker Engine 安装完成" "done"
# 输出：[DONE] [3/3] Docker Engine 安装完成

set -euo pipefail
IFS=$'\n\t'

# 进度步骤输出（步骤计数）
# 参数：$1 — 当前步骤号
#       $2 — 总步骤数
#       $3 — 描述文字
#       $4 — 状态（可选，"done"=绿色 [DONE] 标签并显示 total/total，其余=蓝色 INFO 标签）
ui_progress_step() {
  local current="${1:-0}" total="${2:-0}" description="${3:-}" status="${4:-}"
  if [[ ! "$total" =~ ^[0-9]+$ ]] || (( total < 1 )); then
    total=1
  fi
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  if (( current > total )); then
    current="$total"
  fi

  if [[ "$status" == "done" ]]; then
    log_success "[${total}/${total}] ${description}"
  else
    log_info "[${current}/${total}] ${description}"
  fi
}
