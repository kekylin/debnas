#!/bin/bash
# 功能：Cron 定时任务统一管理模块
# 说明：提供模块定时任务的注册、注销和查询功能
# 设计：所有模块的 cron 任务通过本模块统一管理，不再由模块自行操作 crontab

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap.sh 加载）

# ==================== 常量定义 ====================

# cron 标识前缀（用于在 crontab 中标记 DebNAS 管理的条目）
readonly CRON_MARKER="# DEBNAS-CRON:"

# DebNAS 可执行文件路径
readonly DEBNAS_BIN="${DEBNAS_BIN:-/usr/local/bin/debnas}"

# ==================== 内部函数 ====================

# 构建 cron 条目标识
# 参数：$1 - 模块名
# 输出：cron 条目的标记字符串
_cron_entry_marker() {
  local module_name="$1"
  echo "${CRON_MARKER} ${module_name}"
}

# 获取当前用户的 crontab 内容
# 参数：无
# 输出：crontab 内容
_get_current_crontab() {
  crontab -l 2>/dev/null || true
}

# 写入 crontab
# 参数：$1 - crontab 内容（通过 stdin 传入）
# 返回：0 成功，1 失败
_set_crontab() {
  if crontab - 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ==================== 公共接口 ====================

# 注册模块的 cron 定时任务
# 参数：$1 - 模块名
#       $2 - cron 表达式（如 "0 */6 * * *"）
# 返回：0 成功，1 失败
# 说明：如果已存在相同模块的条目，则先移除再添加（幂等）
cron_register() {
  local module_name="${1:?cron_register: 缺少模块名}"
  local schedule="${2:?cron_register: 缺少 cron 表达式}"
  local marker
  marker=$(_cron_entry_marker "$module_name")

  # 验证 cron 表达式格式（基本校验：5 个字段）
  local field_count
  field_count=$(echo "$schedule" | awk '{print NF}')
  if [[ "$field_count" -ne 5 ]]; then
    log_error "Cron 表达式无效: '${schedule}'"
    return 1
  fi

  # 构建 cron 命令（传递 DEBNAS_CRON_MODE=1 告知模块以非交互模式运行）
  local cron_cmd="${schedule} DEBNAS_CRON_MODE=1 ${DEBNAS_BIN} run ${module_name} ${marker}"

  # 获取当前 crontab，移除该模块的旧条目
  local current_crontab
  current_crontab=$(_get_current_crontab)

  # 移除旧条目并添加新条目
  local new_crontab
  new_crontab=$(echo "$current_crontab" | grep -v "${marker}" || true)

  # 追加新条目（确保末尾有换行）
  if [[ -n "$new_crontab" ]]; then
    new_crontab="${new_crontab}
${cron_cmd}"
  else
    new_crontab="${cron_cmd}"
  fi

  # 写入 crontab
  if echo "$new_crontab" | _set_crontab; then
    log_success "${module_name}（${schedule}）"
    return 0
  else
    log_error "定时注册失败${module_name}"
    return 1
  fi
}

# 注销模块的 cron 定时任务
# 参数：$1 - 模块名
# 返回：0 成功（包括原本不存在的情况），1 操作失败
cron_unregister() {
  local module_name="${1:?cron_unregister: 缺少模块名}"
  local marker
  marker=$(_cron_entry_marker "$module_name")

  # 获取当前 crontab
  local current_crontab
  current_crontab=$(_get_current_crontab)

  # 检查是否存在该模块的条目
  if ! echo "$current_crontab" | grep -q "${marker}" 2>/dev/null; then
    log_debug "未找到 cron 条目：${module_name}，跳过注销"
    return 0
  fi

  # 移除该模块的条目
  local new_crontab
  new_crontab=$(echo "$current_crontab" | grep -v "${marker}" || true)

  # 写入 crontab（如果为空则移除整个 crontab）
  if [[ -z "$new_crontab" ]]; then
    crontab -r 2>/dev/null || true
  else
    if ! echo "$new_crontab" | _set_crontab; then
      log_error "定时取消失败${module_name}"
      return 1
    fi
  fi

  log_success "定时已取消${module_name}"
  return 0
}

# 列出所有 DebNAS 管理的 cron 定时任务
# 参数：无
# 输出：格式化的任务列表（每行：模块名 | cron 表达式 | 命令）
# 返回：始终 0
cron_list() {
  local current_crontab
  current_crontab=$(_get_current_crontab)

  if [[ -z "$current_crontab" ]]; then
    log_info "无定时任务"
    return 0
  fi

  local debnas_entries
  debnas_entries=$(echo "$current_crontab" | grep "${CRON_MARKER}" || true)

  if [[ -z "$debnas_entries" ]]; then
    log_info "无定时任务"
    return 0
  fi

  echo "定时任务"
  echo "─────────────────────────────────────────────────"

  while IFS= read -r line; do
    # 提取模块名（从标记中）
    local module_name
    module_name=$(echo "$line" | sed "s/.*${CRON_MARKER} *//")

    # 提取 cron 表达式（前 5 个字段）
    local schedule
    schedule=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')

    printf "  %-30s %s\n" "$module_name" "$schedule"
  done <<< "$debnas_entries"

  echo "─────────────────────────────────────────────────"
  return 0
}

# 检查模块是否已注册 cron 任务
# 参数：$1 - 模块名
# 返回：0 已注册，1 未注册
cron_is_registered() {
  local module_name="${1:?cron_is_registered: 缺少模块名}"
  local marker
  marker=$(_cron_entry_marker "$module_name")
  local current_crontab
  current_crontab=$(_get_current_crontab)

  echo "$current_crontab" | grep -q "${marker}" 2>/dev/null
}
