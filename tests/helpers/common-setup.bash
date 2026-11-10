#!/usr/bin/env bash
# BATS 测试共享设置
# 所有测试文件通过 load 'helpers/common-setup' 引入

# 项目根目录（优先使用 run.sh 传入的绝对路径，否则从测试文件位置推断）
# 测试文件位于 tests/unit/lib/，需向上 3 层到项目根
export DEBNAS_ROOT="${DEBNAS_ROOT:-${BATS_TEST_DIRNAME}/../../..}"

# 确保可以 source 库文件
setup_debnas_lib() {
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
  source "${DEBNAS_ROOT}/lib/core/logging.sh"
}

setup_debnas_system() {
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  source "${DEBNAS_ROOT}/lib/system/dependency.sh"
  source "${DEBNAS_ROOT}/lib/system/tempfile.sh"
  source "${DEBNAS_ROOT}/lib/system/urls.sh"
  source "${DEBNAS_ROOT}/lib/system/apt.sh"
  source "${DEBNAS_ROOT}/lib/system/service.sh"
  source "${DEBNAS_ROOT}/lib/system/args.sh"
  source "${DEBNAS_ROOT}/lib/system/state.sh"
  source "${DEBNAS_ROOT}/lib/system/cron.sh"
  source "${DEBNAS_ROOT}/lib/system/config.sh"
}

# ==================== 共享 Mock 工具 ====================

# 创建 crontab Mock（统一实现，避免 test-cron.bats 和 test-cron-mode.bats 重复）
# 用法: setup_crontab_mock
# 之后通过 CRON_STATE 环境变量控制状态文件路径
setup_crontab_mock() {
  MOCK_BIN="${MOCK_BIN:-$BATS_TMPDIR/mockbin}"
  mkdir -p "$MOCK_BIN"
  CRON_STATE="${BATS_TMPDIR}/mock-crontab"
  export CRON_STATE

  cat > "$MOCK_BIN/crontab" << 'INNEREOF'
#!/usr/bin/env bash
state_file="${CRON_STATE:-/tmp/mock-crontab}"
case "$1" in
  -l)
    if [[ -f "$state_file" ]]; then
      cat "$state_file"
    fi
    exit 0
    ;;
  -r)
    rm -f "$state_file"
    exit 0
    ;;
  -)
    cat > "$state_file"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
INNEREOF
  chmod +x "$MOCK_BIN/crontab"
  export PATH="$MOCK_BIN:$PATH"
}

# 清理 crontab Mock
teardown_crontab_mock() {
  rm -rf "${MOCK_BIN:-}" "${CRON_STATE:-}" 2>/dev/null || true
}
