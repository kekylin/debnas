#!/usr/bin/env bats
# 测试: modules/timer-manager.sh — 统一定时任务管理

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/timer-manager.sh"

@test "timer-manager: 元数据完整" {
  grep -q '^# @module: timer-manager' "$MODULE_FILE"
  grep -q '^# @name: 定时任务概览' "$MODULE_FILE"
  grep -q '^# @category: 系统维护' "$MODULE_FILE"
  grep -q '^# @interactive: true' "$MODULE_FILE"
}

@test "timer-manager: 支持四个定时模块" {
  grep -q 'sys-patches' "$MODULE_FILE"
  grep -q 'wallpaper' "$MODULE_FILE"
  grep -q 'hosts-sync' "$MODULE_FILE"
  grep -q 'threat-ips' "$MODULE_FILE"
}

@test "timer-manager: 定义统一列表函数" {
  grep -q '^_timer_list_all()' "$MODULE_FILE"
}

@test "timer-manager: main 直接输出只读概览" {
  grep -A3 '^main()' "$MODULE_FILE" | grep -q '_timer_list_all'
  grep -A3 '^main()' "$MODULE_FILE" | grep -q 'return 0'
}
