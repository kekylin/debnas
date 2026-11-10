#!/usr/bin/env bash
# DebNAS 统一质量检查入口
# 用法: bash tests/check.sh
# 执行: 语法检查 + ShellCheck + BATS 单元测试 + 模块元数据冒烟 + 集成测试
#
# 这是开发机上的完整质量门禁（第 1-5 层），合并 PR 前必须通过。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

_PASSED=0
_FAILED=0

echo "╔══════════════════════════════════════════╗"
echo "║     DebNAS 质量门禁（第 1-5 层）         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ==================== 第 1 层：语法检查 ====================

echo ">>> 第 1 层：语法检查 (bash -n)"
echo ""
if bash "${SCRIPT_DIR}/run.sh" syntax; then
  echo "[PASS] 第 1 层语法检查通过"
  ((_PASSED++)) || true
else
  echo "[FAIL] 第 1 层语法检查失败"
  ((_FAILED++)) || true
fi

# ==================== 第 2 层：ShellCheck 静态分析 ====================

echo ""
echo ">>> 第 2 层：ShellCheck 静态分析"
echo ""
if bash "${SCRIPT_DIR}/run.sh" static; then
  echo "[PASS] 第 2 层 ShellCheck 通过"
  ((_PASSED++)) || true
else
  echo "[FAIL] 第 2 层 ShellCheck 失败"
  ((_FAILED++)) || true
fi

# ==================== 第 3 层：BATS 单元测试 ====================

echo ""
echo ">>> 第 3 层：BATS 单元测试"
echo ""
if bash "${SCRIPT_DIR}/run.sh" unit; then
  echo "[PASS] 第 3 层单元测试通过"
  ((_PASSED++)) || true
else
  echo "[FAIL] 第 3 层单元测试失败"
  ((_FAILED++)) || true
fi

# ==================== 第 4 层：模块元数据冒烟测试 ====================

echo ""
echo "=== 第 4 层：模块元数据冒烟测试 ==="

_module_errors=0

# 检查模块元数据标签完整性
for f in "${DEBNAS_ROOT}"/modules/*.sh "${DEBNAS_ROOT}"/modules/*/module.sh; do
  for tag in @module @name @version @order; do
    if ! grep -q "^# ${tag}:" "$f" 2>/dev/null; then
      echo "[WARN] $f 缺少 $tag"
      ((_module_errors++)) || true
    fi
  done
done

# 检查 @depend_modules 引用有效性（用 process substitution 避免 subshell 计数器丢失）
while read -r dep; do
  # find -print -quit 取代 find | grep -q：pipefail 下 grep 提前退出会让 find 收到 SIGPIPE，管道返回非零
  if [[ -n "$dep" && -z "$(find "${DEBNAS_ROOT}"/modules/ \( -name "${dep}.sh" -o -name "${dep}" -type d \) -print -quit 2>/dev/null)" ]]; then
    echo "[WARN] @depend_modules 引用了不存在的模块: $dep"
    ((_module_errors++)) || true
  fi
done < <(grep -h -oP '@depend_modules:\s*\K.*' "${DEBNAS_ROOT}"/modules/*.sh "${DEBNAS_ROOT}"/modules/*/module.sh 2>/dev/null | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u)

if (( _module_errors > 0 )); then
  echo "[FAIL] 模块元数据冒烟测试: ${_module_errors} 个警告"
  _FAILED=$((_FAILED + 1))
else
  echo "[PASS] 模块元数据冒烟测试通过"
  _PASSED=$((_PASSED + 1))
fi

# ==================== 第 5 层：集成测试 ====================

echo ""
echo ">>> 第 5 层：集成测试（模块注册/依赖解析/执行流程/Cron Mock）"
echo ""
if bash "${SCRIPT_DIR}/run.sh" integration; then
  echo ""
  ((_PASSED++)) || true
else
  echo ""
  echo "[FAIL] 第 5 层集成测试失败"
  ((_FAILED++)) || true
fi

# ==================== 结果汇总 ====================

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║            测试结果汇总                  ║"
echo "╚══════════════════════════════════════════╝"
echo "  [PASS] ${_PASSED} 层通过"
echo "  [FAIL] ${_FAILED} 层失败"

if (( _FAILED > 0 )); then
  echo ""
  echo "❌ 质量门禁未通过，请修复后重试。"
  exit 1
else
  echo ""
  echo "✅ 质量门禁全部通过！"
  exit 0
fi
