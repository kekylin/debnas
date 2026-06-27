#!/bin/bash
# docker-backup: 完整性校验模块
set -euo pipefail
IFS=$'\n\t'
get_rsync_exclude_pattern() {
  local source_dir="$1"
  local exclude_dir="$2"
  local normalized_source="${source_dir%/}"
  local normalized_exclude="${exclude_dir%/}"

  # M1 fix: 排除目录与源目录相同是配置错误
  if [[ "$normalized_exclude" == "$normalized_source" ]]; then
    log_error "排除目录与源目录相同，跳过此排除规则: $exclude_dir"
    return 1
  fi

  if [[ "$normalized_exclude" == "$normalized_source"/* ]]; then
    local relative_path="${normalized_exclude#"$normalized_source"/}"
    echo "/$relative_path"
    return 0
  fi

  return 1
}

# 工具函数，统计目录大小和文件数
get_dir_stats() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    find "$dir" \( -type f -o -type d -o -type l \) -printf '%y %k\n' 2>/dev/null |
      awk '
        {
          size_kb += $2
          if ($1 == "f") {
            file_count += 1
          }
        }
        END {
          printf "%d %d\n", size_kb, file_count
        }
      '
  else
    echo "0 0"
  fi
}

# L4 fix: 使用 awk -v 变量传递，避免注入风险
format_file_size() {
  local size_kb="$1"
  if [[ $size_kb -lt 1024 ]]; then
    echo "${size_kb}KB"
  elif [[ $size_kb -lt $((1024 * 1024)) ]]; then
    echo "$(awk -v s="$size_kb" 'BEGIN {printf "%.2f", s / 1024}')MB"
  else
    echo "$(awk -v s="$size_kb" 'BEGIN {printf "%.2f", s / 1024 / 1024}')GB"
  fi
}

# 工具函数，计算总文件数
get_total_files() {
  local total=0
  for dir in "$@"; do
    if [[ -d "$dir" ]]; then
      total=$((total + $(find "$dir" -type f 2>/dev/null | wc -l)))
    fi
  done
  echo "$total"
}

# L5 fix: 使用 printf 字符串重复替代 50 次循环
show_progress() {
  local current="$1"
  local total="$2"
  local width=50
  if ((total <= 0)); then
    total=1
  fi
  local progress=$((current * width / total))
  local percent=$((current * 100 / total))
  local filled
  filled=$(printf '#%.0s' $(seq 1 "$progress" 2>/dev/null) 2>/dev/null) || filled=""
  local empty
  empty=$(printf ' %.0s' $(seq 1 $((width - progress)) 2>/dev/null) 2>/dev/null) || empty=""
  printf "\r进度: [%s%s] %d%%" "$filled" "$empty" "$percent" >&2
  if [[ $current -eq $total ]]; then
    printf "\n" >&2
  fi
}

# M3 fix: 进度标签改为字节百分比（不再伪装为文件数）
process_rsync_progress() {
  local total_files="$1"
  local last_update=0
  local current_time
  local last_progress=0

  while IFS= read -r line; do
    if [[ $line =~ ([0-9]+)% ]]; then
      local percent="${BASH_REMATCH[1]}"
      current_time=$(date +%s)
      if ((current_time - last_update >= 1)); then
        if ((percent > last_progress)); then
          # 显示字节传输百分比，不再映射为文件数
          printf "\r传输进度: %d%%" "$percent" >&2
          last_progress=$percent
        fi
        last_update=$current_time
      fi
    fi
  done < <(stdbuf -oL tr '\r' '\n')
}

# 运行 rsync 并仅以 rsync 退出码作为结果判定标准
run_rsync_with_progress() {
  local total_files="$1"
  shift

  local rsync_status=0
  set +e
  "$@" 2>&1 | process_rsync_progress "$total_files"
  rsync_status=${PIPESTATUS[0]}
  set -e
  return "$rsync_status"
}
