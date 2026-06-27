#!/bin/bash
# docker-backup: 恢复逻辑模块
set -euo pipefail
IFS=$'\n\t'
restore_single_source_dir() {
  local source_dir="$1"
  local selected_backup="$2"
  local total_backup_files="$3"
  local restore_mode="$4"

  local backup_dir
  backup_dir=$(get_restore_backup_dir "$selected_backup" "$source_dir")
  if [[ ! -d "$backup_dir" ]]; then
    log_warning "备份中不存在目录: $source_dir"
    return 2
  fi

  mkdir -p "$source_dir"

  log_action "恢复目录: $source_dir"
  local rsync_args=(env LC_ALL=C rsync -ah --info=progress2 --no-i-r --stats)
  if [[ "$restore_mode" == "完全恢复" ]]; then
    rsync_args+=(--delete)
  fi
  rsync_args+=("$backup_dir/" "$source_dir/")

  if run_rsync_with_progress "$total_backup_files" "${rsync_args[@]}"; then
    show_progress "$total_backup_files" "$total_backup_files"
    local dir_stats
    dir_stats=$(get_dir_stats "$source_dir")
    local dir_size
    dir_size=$(echo "$dir_stats" | cut -d' ' -f1)
    local dir_files
    dir_files=$(echo "$dir_stats" | cut -d' ' -f2)
    printf "%s\n" "$dir_size $dir_files"
    return 0
  fi

  return 1
}

# 工具函数，将绝对排除路径转换为相对当前源目录的 rsync 排除规则

perform_restore() {
  log_info "开始执行 Docker 恢复..."
  BACKUP_DEST="$(prompt_absolute_path "请输入备份文件存储路径（例如 /mnt/backup）：")"

  log_info "请选择恢复模式:"
  log_info "  1. 完全恢复（覆盖现有数据）"
  log_info "  2. 增量恢复（保留现有数据）"
  read -r -p "请选择 (1/2): " restore_mode_choice
  local restore_mode=""
  case "$restore_mode_choice" in
    1) restore_mode="完全恢复" ;;
    2) restore_mode="增量恢复" ;;
    *) log_error "无效选择，使用完全恢复模式。"; restore_mode="完全恢复" ;;
  esac
  if [[ "$restore_mode" == "完全恢复" ]]; then
    local restore_confirm
    read -r -p "完全恢复会删除目标目录中的多余文件，确认继续？(y/n): " restore_confirm
    if [[ "$restore_confirm" != "y" ]]; then
      log_warning "已取消完全恢复操作。"
      return 1
    fi
  fi
  local available_backups=()
  local backup_index=1
  set +e
  mapfile -t available_backups < <(get_available_backup_dirs "$BACKUP_DEST")
  echo "可用的备份版本:"
  for backup_dir in "${available_backups[@]}"; do
    if [[ -d "$backup_dir" ]]; then
      local display_name
      display_name=$(format_backup_display_name "$backup_dir")
      local backup_date
      backup_date=$(stat -c %y "$backup_dir" | cut -d'.' -f1)
      echo "$backup_index. $display_name (创建于 $backup_date)"
      ((backup_index++))
    fi
  done
  set -e
  if [[ ${#available_backups[@]} -eq 0 ]]; then
    log_error "未找到可用的备份。"
    return 1
  fi
  read -r -p "请选择要恢复的备份版本 (1-${#available_backups[@]}): " backup_choice
  if [[ ! "$backup_choice" =~ ^[0-9]+$ ]] || [[ "$backup_choice" -lt 1 ]] || [[ "$backup_choice" -gt ${#available_backups[@]} ]]; then
    log_error "无效的备份版本选择。"
    return 1
  fi
  local selected_backup="${available_backups[$((backup_choice - 1))]}"
  log_info "选择恢复备份: $(basename "$selected_backup")"

  local info_file
  if ! info_file=$(get_backup_log_file "$selected_backup"); then
    log_error "备份日志文件不存在: $selected_backup"
    log_error "该备份版本缺少恢复所需信息，请重新执行备份后再尝试恢复。"
    return 1
  fi

  if ! load_backup_sources_from_info "$info_file"; then
    log_error "备份说明文件中未找到源目录信息。"
    return 1
  fi

  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
    log_error "备份目录中未找到任何源目录。"
    return 1
  fi

  log_info "正在统计文件数量..."
  local total_backup_files
  total_backup_files=$(calculate_total_files_for_backup "$selected_backup" SOURCE_DIRS)
  log_info "共发现 $total_backup_files 个文件需要恢复"

  local start_time
  start_time=$(date +%s)
  prepare_docker_service_for_data_operation
  local total_files=0
  local total_size=0

  local source_dir
  for source_dir in "${SOURCE_DIRS[@]}"; do
    local restore_result
    if restore_result=$(restore_single_source_dir "$source_dir" "$selected_backup" "$total_backup_files" "$restore_mode"); then
      local dir_size="${restore_result%% *}"
      local dir_files="${restore_result##* }"
      total_size=$((total_size + dir_size))
      total_files=$((total_files + dir_files))
      printf "\r%s\n" "$(log_success "目录 $source_dir 恢复完成 (${dir_files} 文件, $(format_file_size "$dir_size"))。")"
    else
      local restore_status=$?
      if [[ $restore_status -eq 1 ]]; then
        printf "\r%s\n" "$(log_fail "目录 $source_dir 恢复失败。")"
      fi
    fi
  done

  local end_time
  end_time=$(date +%s)
  local restore_log
  restore_log="$selected_backup/$(build_operation_log_name "restore")"
  generate_operation_log "$restore_log" "$start_time" "$end_time" "restore" \
    "$(basename "$selected_backup")" "$restore_mode"
  log_success "Docker 恢复完成。"
  log_info "恢复统计: ${total_files} 文件, $(format_file_size "$total_size")"
  log_info "恢复日志: $restore_log"
}

# 显示主菜单
