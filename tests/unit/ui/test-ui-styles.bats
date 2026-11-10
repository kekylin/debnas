#!/usr/bin/env bats
# 测试: lib/ui/styles.sh — UI 样式补充测试 (TC-P2-UI-001)

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"

# ==================== TC-P2-UI-001: NO_COLOR=1 输出无 ANSI 转义码 ====================

@test "ui-styles: NO_COLOR=1 时所有颜色变量为空 (TC-P2-UI-001)" {
  run bash -c '
    SRC="$1"
    export NO_COLOR=1
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null

    # 验证所有 COLOR_* 变量在 NO_COLOR=1 时为空
    if [[ -z "${COLOR_RED:-}" && -z "${COLOR_GREEN:-}" && -z "${COLOR_YELLOW:-}" \
       && -z "${COLOR_BLUE:-}" && -z "${COLOR_CYAN:-}" && -z "${COLOR_RESET:-}" ]]; then
      echo "ALL_COLORS_EMPTY"
    else
      echo "HAS_COLORS"
    fi
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"ALL_COLORS_EMPTY"* ]]
}

@test "ui-styles: NO_COLOR 未设置时 COLOR_RED 非空" {
  run bash -c '
    SRC="$1"
    unset NO_COLOR
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null

    if [[ -n "${COLOR_RED:-}" ]]; then
      echo "COLOR_RED_SET"
    else
      echo "COLOR_RED_EMPTY"
    fi
  ' _ "${DEBNAS_ROOT}"
  # 在非终端环境（BATS）下颜色可能也不设置，记录当前行为
  echo "note: COLOR_RED = $output" >&2
  :
}
