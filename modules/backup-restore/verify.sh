#!/bin/bash
# backup-restore: 完整性校验模块
set -euo pipefail
IFS=$'\n\t'
get_rsync_exclude_pattern() {
  local source_dir="$1"
  local exclude_dir="$2"
  local normalized_source="${source_dir%/}"
  local normalized_exclude="${exclude_dir%/}"

  if [[ "$normalized_exclude" == "$normalized_source" ]]; then
    echo "/"
    return 0
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

format_file_size() {
  local size_kb="$1"
  if [[ $size_kb -lt 1024 ]]; then
    echo "${size_kb}KB"
  elif [[ $size_kb -lt $((1024 * 1024)) ]]; then
    echo "$(awk "BEGIN {printf \"%.2f\", $size_kb / 1024}")MB"
  else
    echo "$(awk "BEGIN {printf \"%.2f\", $size_kb / 1024 / 1024}")GB"
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

# 工具函数，显示进度条
show_progress() {
  local current="$1"
  local total="$2"
  local width=50
  if ((total <= 0)); then
    total=1
  fi
  local progress=$((current * width / total))
  local percent=$((current * 100 / total))
  printf "\r进度: [" >&2
  for ((i = 0; i < width; i++)); do
    if [[ $i -lt $progress ]]; then
      printf "#" >&2
    else
      printf " " >&2
    fi
  done
  printf "] %d%%" "$percent" >&2
  if [[ $current -eq $total ]]; then
    printf "\n" >&2
  fi
}

# 工具函数，处理 rsync 进度输出
process_rsync_progress() {
  local total_files="$1"
  local processed_files=0
  local last_update=0
  local current_time
  local last_progress=0

  while IFS= read -r line; do
    # 提取已传输的字节数和百分比
    if [[ $line =~ ([0-9]+)% ]]; then
      local percent="${BASH_REMATCH[1]}"
      current_time=$(date +%s)
      # 每秒最多更新一次进度条
      if ((current_time - last_update >= 1)); then
        # 只有当进度发生变化时才显示
        if ((percent > last_progress)); then
          processed_files=$((total_files * percent / 100))
          show_progress "$processed_files" "$total_files"
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

