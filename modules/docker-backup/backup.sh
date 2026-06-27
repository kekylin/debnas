#!/bin/bash
# docker-backup: 备份逻辑模块
set -euo pipefail
IFS=$'\n\t'
prepare_backup_target() {
  if [[ ! -d "$BACKUP_DEST" ]]; then
    if ! mkdir -p "$BACKUP_DEST"; then
      log_error "无法创建备份目标目录: $BACKUP_DEST（请检查权限）"
      return 1
    fi
  fi
  if [[ ! -w "$BACKUP_DEST" ]]; then
    log_error "备份目标目录不可写: $BACKUP_DEST（请检查权限）"
    return 1
  fi

  local backup_name
  backup_name=$(build_backup_dir_name)
  local backup_path="$BACKUP_DEST/$backup_name"
  if ! mkdir -p "$backup_path/source"; then
    log_error "无法创建备份目录: $backup_path（请检查权限）"
    return 1
  fi

  _BACKUP_RESULT_PATH="$backup_path"
}

# 备份单个源目录
backup_single_source_dir() {
  local source_dir="$1"
  local backup_path="$2"
  local total_source_files="$3"
  # shellcheck disable=SC2034
  local -n excluded_dirs_ref="$4"

  if [[ ! -d "$source_dir" ]]; then
    log_warning "目录不存在，已跳过: $source_dir"
    return 2
  fi

  # M4: 检查源目录是否为空（防止 --delete 清空备份）
  if [[ -z "$(ls -A "$source_dir" 2>/dev/null)" ]]; then
    log_warning "源目录为空，已跳过: $source_dir"
    return 2
  fi

  log_action "备份目录: $source_dir"
  local exclude_args=()
  local exclude_dir
  for exclude_dir in "${excluded_dirs_ref[@]}"; do
    if [[ -n "$exclude_dir" ]]; then
      local exclude_pattern
      if exclude_pattern=$(get_rsync_exclude_pattern "$source_dir" "$exclude_dir"); then
        exclude_args+=(--exclude="$exclude_pattern")
      fi
    fi
  done

  local backup_source_dir
  backup_source_dir=$(get_backup_source_dir "$backup_path" "$source_dir")
  mkdir -p "$backup_source_dir"

  # C1 fix: 移除 --delete，改用不删除备份中已有文件的模式
  if run_rsync_with_progress "$total_source_files" \
    env LC_ALL=C rsync -ah --info=progress2 --no-i-r --stats "${exclude_args[@]}" \
    "$source_dir/" "$backup_source_dir/"; then
    show_progress "$total_source_files" "$total_source_files"
    local dir_stats
    dir_stats=$(get_dir_stats "$backup_source_dir")
    local dir_size
    dir_size=$(echo "$dir_stats" | cut -d' ' -f1)
    local dir_files
    dir_files=$(echo "$dir_stats" | cut -d' ' -f2)
    _BACKUP_RESULT_STATS="$dir_size $dir_files"
    return 0
  fi

  return 1
}


perform_backup() {
  log_action "开始执行 Docker 备份..."
  local start_time
  start_time=$(date +%s)

  # C3 fix: 使用全局变量而非 stdout 捕获路径
  prepare_backup_target || return 1
  local backup_path="$_BACKUP_RESULT_PATH"

  prepare_docker_service_for_data_operation

  local total_files=0
  local total_size=0
  local successful_dirs=0
  local skipped_dirs=0

  log_info "正在统计文件数量..."
  local total_source_files
  total_source_files=$(calculate_total_files_for_sources SOURCE_DIRS)
  log_info "共发现 $total_source_files 个文件需要备份"

  local source_dir
  for source_dir in "${SOURCE_DIRS[@]}"; do
    if backup_single_source_dir "$source_dir" "$backup_path" "$total_source_files" EXCLUDED_DIRS; then
      local dir_size="${_BACKUP_RESULT_STATS%% *}"
      local dir_files="${_BACKUP_RESULT_STATS##* }"
      total_size=$((total_size + dir_size))
      total_files=$((total_files + dir_files))
      successful_dirs=$((successful_dirs + 1))
      printf "\r%s\n" "$(log_success "目录 $source_dir 备份完成 (${dir_files} 文件, $(format_file_size "$dir_size"))。")"
    else
      local backup_status=$?
      if [[ $backup_status -eq 1 ]]; then
        printf "\r%s\n" "$(log_fail "目录 $source_dir 备份失败。")"
      elif [[ $backup_status -eq 2 ]]; then
        skipped_dirs=$((skipped_dirs + 1))
      fi
    fi
  done

  # H5 fix: 报告跳过的目录
  if [[ $skipped_dirs -gt 0 ]]; then
    log_warning "共跳过 $skipped_dirs 个目录（不存在或为空）"
  fi

  if [[ $successful_dirs -eq 0 ]]; then
    log_error "没有找到任何有效的源目录，备份操作已取消。"
    rm -rf "$backup_path"
    return 1
  fi

  local end_time
  end_time=$(date +%s)
  local backup_log_file
  backup_log_file="$backup_path/$(build_operation_log_name "backup")"
  generate_operation_log "$backup_log_file" "$start_time" "$end_time" "backup" \
    "$backup_path"
  log_success "Docker 备份完成: $backup_path"
  log_info "备份统计: ${total_files} 文件, $(format_file_size "$total_size")（成功 ${successful_dirs}/${#SOURCE_DIRS[@]} 目录）"
}


