#!/bin/bash
# 功能：DebNAS 文件清单（记录被 DebNAS 写入/备份/迁移过的系统文件，供 `debnas files` 展示）
# 说明：清单文件 ${DEBNAS_MANIFEST_FILE}（默认 /var/lib/debnas/manifest），每行一条：
#         <绝对路径>\t<首次登记时间>\t<来源模块>
#       同一路径只登记一次（保留首次时间与来源）；DebNAS 自有目录下的文件不登记。
#       登记失败从不影响调用方（清单是辅助信息，不能阻断配置写入）。
# 依赖: system/layout.sh（目录常量）

set -euo pipefail
IFS=$'\n\t'

# ==================== 内部函数 ====================

# DebNAS 自有目录列表（"路径|说明"）
_manifest_own_dirs() {
  printf '%s\n' \
    "${DEBNAS_ETC_DIR}|配置" \
    "${DEBNAS_VAR_DIR}|状态/数据/报告" \
    "${DEBNAS_LOG_ROOT}|日志" \
    "${DEBNAS_OPT_DIR}|程序" \
    "${DEBNAS_BACKUP_ROOT}|备份" \
    "${DEBNAS_LIBEXEC_DIR}|辅助脚本（供 PAM 等系统程序调用）"
}

# 判断路径是否位于 DebNAS 自有目录内
# 参数：$1 - 绝对路径
# 返回：0 是，1 否
_manifest_is_own_path() {
  local path="$1" entry dir
  while IFS= read -r entry; do
    dir="${entry%%|*}"
    [[ -n "$dir" && "$dir" != "/" ]] || continue
    if [[ "$path" == "$dir" || "$path" == "$dir"/* ]]; then
      return 0
    fi
  done < <(_manifest_own_dirs)
  return 1
}

# 推断来源模块（优先 DEBNAS_MANIFEST_SOURCE，其次入口脚本路径）
# 输出：模块名
_manifest_source() {
  if [[ -n "${DEBNAS_MANIFEST_SOURCE:-}" ]]; then
    printf '%s' "$DEBNAS_MANIFEST_SOURCE"
    return 0
  fi
  # 参数展开取目录名/文件名（不 fork basename/dirname）
  local entry="${0:-unknown}" name
  case "$entry" in
    */modules/*/module.sh)
      name="${entry%/module.sh}"
      while [[ "$name" == */ ]]; do name="${name%/}"; done
      name="${name##*/}"
      ;;
    */modules/*.sh)
      name="${entry##*/}"
      name="${name%.sh}"
      ;;
    *)
      name="${entry%/}"
      name="${name##*/}"
      ;;
  esac
  printf '%s' "${name:-unknown}"
}

# 判断清单中是否已有该路径
# 参数：$1 - 路径
_manifest_has() {
  local path="$1"
  [[ -f "$DEBNAS_MANIFEST_FILE" ]] || return 1
  _DEBNAS_MF_PATH="$path" awk -F'\t' '
    BEGIN { p = ENVIRON["_DEBNAS_MF_PATH"]; found = 0 }
    $1 == p { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$DEBNAS_MANIFEST_FILE" 2>/dev/null
}

# 统计某路径在备份目录中的份数（各次运行目录 + original/）
# 参数：$1 - 绝对路径
# 输出：份数
_manifest_backup_count() {
  local path="$1" root="$DEBNAS_BACKUP_ROOT" d count=0
  if [[ -n "$root" && -d "$root" ]]; then
    for d in "$root"/*/; do
      [[ -d "$d" ]] || continue
      if [[ -e "${d%/}${path}" || -L "${d%/}${path}" ]]; then
        count=$((count + 1))
      fi
    done
  fi
  printf '%s' "$count"
}

# ==================== 公共接口 ====================

# 登记一个被 DebNAS 写入/备份/迁移的系统文件
# 参数：$1 - 绝对路径；$2 - 来源模块（可选，默认自动推断）
# 返回：始终 0
manifest_add() {
  local path="${1:-}" source="${2:-}"
  [[ -n "$path" && "$path" == /* ]] || return 0
  [[ "$path" != *$'\n'* && "$path" != *$'\t'* ]] || return 0
  [[ -n "${DEBNAS_MANIFEST_FILE:-}" ]] || return 0
  if _manifest_is_own_path "$path"; then
    return 0
  fi
  if _manifest_has "$path"; then
    return 0
  fi
  [[ -n "$source" ]] || source=$(_manifest_source)
  source="${source//[$'\t\n']/ }"

  local mf="$DEBNAS_MANIFEST_FILE" created=0
  if [[ ! -e "$mf" ]]; then
    mkdir -p -- "$(dirname -- "$mf")" 2>/dev/null || return 0
    created=1
  fi
  local ts
  printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
  printf '%s\t%s\t%s\n' "$path" "$ts" "$source" >> "$mf" 2>/dev/null || return 0
  if [[ "$created" -eq 1 ]]; then
    chmod 640 -- "$mf" 2>/dev/null || true
  fi
  return 0
}

# 输出分组文件清单
# 分组：DebNAS 自有目录 / 修改过的系统文件 / 定时任务 / 审计目录
# 返回：始终 0
manifest_list() {
  local entry dir desc state

  echo "== DebNAS 自有目录 =="
  while IFS= read -r entry; do
    dir="${entry%%|*}"
    desc="${entry#*|}"
    if [[ -d "$dir" ]]; then state="存在"; else state="不存在"; fi
    printf '  %-32s %-8s %s\n' "$dir" "$state" "$desc"
  done < <(_manifest_own_dirs)
  echo

  echo "== 修改过的系统文件（原地修改，备份见 ${DEBNAS_BACKUP_ROOT}） =="
  if [[ -s "$DEBNAS_MANIFEST_FILE" ]]; then
    local path first source exists backups
    # 读取时再去重一次（并发写入时可能出现重复行）
    while IFS=$'\t' read -r path first source; do
      [[ -n "$path" ]] || continue
      if [[ -e "$path" || -L "$path" ]]; then exists="存在"; else exists="已不存在"; fi
      backups=$(_manifest_backup_count "$path")
      if [[ "$backups" -gt 0 ]]; then
        backups="备份 ${backups} 份"
      else
        backups="无备份"
      fi
      printf '  %-44s %-8s %-10s 首次 %s  来源 %s\n' "$path" "$exists" "$backups" "${first:-?}" "${source:-?}"
    done < <(awk -F'\t' '!seen[$1]++' "$DEBNAS_MANIFEST_FILE" 2>/dev/null | LC_ALL=C sort -t $'\t' -k1,1)
  else
    echo "  （暂无记录：清单只记录 v3 布局收敛之后写入的文件）"
  fi
  echo

  echo "== 定时任务（root crontab 中的 DEBNAS-CRON 条目） =="
  local cron_lines=""
  cron_lines=$(crontab -l 2>/dev/null | grep -F '# DEBNAS-CRON:' || true)
  if [[ -n "$cron_lines" ]]; then
    printf '%s\n' "$cron_lines" | sed 's/^/  /'
  else
    echo "  （无）"
  fi
  echo

  echo "== 审计目录（原地保留） =="
  local hist_dir="${DEBNAS_HISTORY_DIR:-/var/log/history}"
  if [[ -d "$hist_dir" ]]; then state="存在"; else state="不存在"; fi
  printf '  %-32s %-8s %s\n' "$hist_dir" "$state" "命令历史审计（security 模块，/etc/profile 引用）"
  return 0
}
