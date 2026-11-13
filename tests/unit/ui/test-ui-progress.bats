#!/usr/bin/env bats
# 测试: lib/ui/progress.sh — 进度步骤输出

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
  source "${DEBNAS_ROOT}/lib/core/logging.sh"
  source "${DEBNAS_ROOT}/lib/ui/progress.sh"

  log_info() { printf 'INFO[%s]\n' "$*"; }
  log_success() { printf 'DONE[%s]\n' "$*"; }
}

@test "ui_progress_step: 输出步骤数、百分比与进度条" {
  run ui_progress_step 1 3 "Docker Engine"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"INFO["*"33% Docker Engine"* ]]
  [[ "$output" == *"[======              ]"* ]]
}

@test "ui_progress_step: done 使用成功标签且 100%" {
  run ui_progress_step 3 3 "安装完成" done
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"DONE["*"100% 安装完成"* ]]
  [[ "$output" == *"[====================]"* ]]
}

@test "ui_progress_step: total=0 不除零，按 1 处理" {
  run ui_progress_step 0 0 "空步骤"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"0% 空步骤"* ]]
}
