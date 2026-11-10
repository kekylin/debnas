#!/bin/bash
# 功能：模块功能启用状态统一管理
# 说明：记录模块功能开关状态，供模块菜单和定时任务管理共同判断

set -euo pipefail
IFS=$'\n\t'

# 功能状态目录（复用状态目录，不设 readonly 以便测试 Mock）
DEBNAS_FEATURE_DIR="${DEBNAS_FEATURE_DIR:-${DEBNAS_STATE_DIR:-/var/lib/debnas/state}}"

# 获取模块功能状态文件路径
# 参数：$1 - 模块名
# 输出：状态文件绝对路径
_feature_file() {
  local module_name="${1:?_feature_file: 缺少模块名}"
  echo "${DEBNAS_FEATURE_DIR}/${module_name}.enabled"
}

# 检查模块功能是否已启用
# 参数：$1 - 模块名
# 返回：0 已启用，1 未启用
feature_enabled() {
  local module_name="${1:?feature_enabled: 缺少模块名}"
  [[ "$(cat "$(_feature_file "$module_name")" 2>/dev/null || true)" == "1" ]]
}

# 启用模块功能状态
# 参数：$1 - 模块名
# 返回：0 成功，1 失败
feature_enable() {
  local module_name="${1:?feature_enable: 缺少模块名}"
  mkdir -p "${DEBNAS_FEATURE_DIR}" 2>/dev/null || return 1
  echo "1" > "$(_feature_file "$module_name")" || return 1
  return 0
}

# 禁用模块功能状态
# 参数：$1 - 模块名
# 返回：0 成功，1 失败
feature_disable() {
  local module_name="${1:?feature_disable: 缺少模块名}"
  mkdir -p "${DEBNAS_FEATURE_DIR}" 2>/dev/null || return 1
  echo "0" > "$(_feature_file "$module_name")" || return 1
  return 0
}
