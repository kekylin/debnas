#!/bin/bash
# sys-patches: 更新检查逻辑
set -euo pipefail
IFS=$'\n\t'
# 解析 Inst 行并格式化为"包名  旧版 → 新版"
# 行格式：Inst <pkg> [<旧版>] (<新版> <来源> [<架构>])
# 注：只用 POSIX awk 语法（Debian 默认 mawk 不支持 gawk 的三参数 match 函数）
format_inst_lines() {
  awk '
  /^Inst / {
    if ($3 ~ /^\[[^]]+\]$/ && $4 ~ /^\(/) {
      n++; pkg[n]=$2
      oldv[n]=substr($3, 2, length($3) - 2)
      newv[n]=substr($4, 2)
    }
    next
  }
  END {
    for (i=1;i<=n;i++) {
      printf "%s\n   ↳ %s → %s\n\n", pkg[i], oldv[i], newv[i];
    }
  }'
}

# 生成报告内容
build_report_content() {
  local security_update_list="$1" security_update_count="$2" regular_update_list="$3" regular_update_count="$4"
  local total=$((security_update_count + regular_update_count))
  printf "🧩 摘要\n"
  printf "总更新：%s\t|\t🔒 安全：%s\t|\t⚙️ 常规：%s\n\n" "${total}" "${security_update_count}" "${regular_update_count}"

  printf "🔒 安全更新 (%s)\n" "${security_update_count}"
  if [[ "${apt_index_stale:-0}" -eq 1 ]]; then
    printf "⚠️ 软件包索引刷新失败（apt update），以下结果可能已过期\n\n"
  fi
  if [[ ${security_update_count} -gt 0 ]]; then
    printf '%b\n' "${security_update_list}" | format_inst_lines
  fi
  printf "\n⚙️ 常规更新 (%s)\n" "${regular_update_count}"
  if [[ ${regular_update_count} -gt 0 ]]; then
    printf '%b\n' "${regular_update_list}" | format_inst_lines
  fi
  printf "\n🕒 检测时间\n"
  printf "%s\n\n" "$(date +'%Y-%m-%d %H:%M:%S')"
  printf "🌐 DebNAS 项目主页\n"
  printf "https://github.com/kekylin/debnas\n\n"
  printf "此邮件由系统自动生成，请勿直接回复。\n"
}

# 执行更新检测并生成报告
run_update_check() {
  log_info "检测系统更新..."
  # 刷新索引（使用跨进程去重）；失败时不中止，但明确标记结果可能过期并写入报告
  declare -g apt_index_stale=0
  if ! apt_update_safe; then
    apt_index_stale=1
    log_warning "apt update 失败，检测结果基于旧索引，可能已过期"
  fi
  local full_update_list
  full_update_list=$(apt-get upgrade -s)
  declare -g security_update_list regular_update_list security_update_count regular_update_count report_content
  # 无匹配时 grep 返回 1，结果按空列表 / 0 处理
  security_update_list=$(grep -E '^Inst' <<<"$full_update_list" | grep -i 'Debian-Security\|security') || true
  security_update_count=$(grep -c "^Inst" <<<"$security_update_list") || true
  regular_update_list=$(grep -E '^Inst' <<<"$full_update_list" | grep -vi 'Debian-Security\|security') || true
  regular_update_count=$(grep -c "^Inst" <<<"$regular_update_list") || true
  report_content=$(build_report_content "$security_update_list" "$security_update_count" "$regular_update_list" "$regular_update_count")
}

# 执行检测并在屏幕输出结果，有更新时尝试发送邮件
execute_update_check() {
  run_update_check

  local total=$((security_update_count + regular_update_count))
  if [[ $total -gt 0 ]]; then
    # 始终在屏幕输出检测结果
    echo ""
    printf '%b\n' "$report_content"
    echo ""
    log_info "检测完成：共 ${total} 个可用更新（安全 ${security_update_count} / 常规 ${regular_update_count}）"
    # 邮件通知（可选，失败不阻断）
    send_email_notification || true
  else
    log_info "系统已是最新状态，无可用更新"
  fi
  sleep 2
}
