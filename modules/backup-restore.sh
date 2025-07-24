#!/bin/bash
# 功能：Docker 容器与数据卷的备份与恢复工具

set -euo pipefail
IFS=$'\n\t'

# 加载新项目公共库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
  log_error "此脚本需要 root 权限运行。"
  exit "${ERROR_PERMISSION}"
fi

# 信号处理，确保中断时清理和恢复服务状态
trap 'log_info "脚本中断，正在清理..."; if [[ "${docker_was_active:-}" == "active" ]]; then start_docker_service; fi; exit 1' SIGINT

# 检查依赖，确保 Docker、tar、rsync、systemctl 已安装
REQUIRED_CMDS=(docker tar rsync systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 Docker、tar、rsync 和 systemctl。"
  exit "${ERROR_DEPENDENCY}"
fi

# 默认配置文件路径
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/config/docker_backup.conf"

# 服务管理函数，确保备份/恢复前后 Docker 状态一致
stop_docker_service() {
  log_action "停止 Docker 服务"
  systemctl stop docker.service docker.socket || log_error "无法停止 Docker 服务。"
  timeout 30 bash -c 'while systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket; do sleep 1; done' || log_error "无法停止 Docker 服务。"
  log_success "Docker 服务已停止。"
}

start_docker_service() {
  log_action "启动 Docker 服务"
  systemctl start docker.service docker.socket || log_error "无法启动 Docker 服务。"
  log_success "Docker 服务已启动。"
}

# 配置解析函数，支持默认和自定义配置
parse_config_content() {
  local config_content="$1"
  mapfile -t config_entries < <(echo "$config_content" | grep -Ev '^#|^\s*$')
  for line in "${config_entries[@]}"; do
    IFS='=' read -r key value <<< "$line"
    value="${value//[! -~]/}"  # 移除不可打印字符
    value="${value//\"/}"      # 移除引号
    case "$key" in
      BACKUP_DIRS) 
        # 确保每个目录都是独立的
        BACKUP_DIRS="$value"
        # 使用 read -a 正确分割空格分隔的目录列表
        IFS=' ' read -r -a SOURCE_DIRS <<< "$BACKUP_DIRS"
        ;;
      BACKUP_DEST) BACKUP_DEST="$value" ;;
      EXCLUDE_DIRS) 
        EXCLUDE_DIRS="$value"
        # 同样使用 read -a 处理排除目录
        if [[ -n "$EXCLUDE_DIRS" ]]; then
          IFS=' ' read -r -a EXCLUDED_DIRS <<< "$EXCLUDE_DIRS"
        else
          EXCLUDED_DIRS=()
        fi
        ;;
      *) log_warning "未知配置项: $key" ;;
    esac
  done
  
  # 验证必要的配置项
  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
    log_error "配置文件缺少 BACKUP_DIRS 或 BACKUP_DIRS 为空。"
    exit "${ERROR_CONFIG}"
  fi
}

# 加载备份配置，支持交互输入和文件加载
load_backup_config() {
  log_info "请输入 docker_backup.conf 配置文件路径（留空使用默认配置）："
  read -r -e -p "" config_path
  if [[ -z "$config_path" ]]; then
    log_info "未提供配置文件，使用默认配置文件：$DEFAULT_CONFIG_FILE。"
    if [[ ! -f "$DEFAULT_CONFIG_FILE" ]]; then
      log_error "默认配置文件 $DEFAULT_CONFIG_FILE 不存在。"
      exit "${ERROR_CONFIG}"
    fi
    parse_config_content "$(cat "$DEFAULT_CONFIG_FILE")"
    # 使用默认配置文件时，必须询问备份路径
    while true; do
      log_info "请输入备份文件存储路径（例如 /mnt/backup）："
      read -e -p "" backup_dest
      if [[ -n "$backup_dest" && "$backup_dest" =~ ^/ ]]; then
        BACKUP_DEST=$(realpath -s "$backup_dest" 2>/dev/null || echo "$backup_dest")
        break
      else
        log_error "备份路径必须是绝对路径（以 / 开头），请重新输入。"
      fi
    done
  else
    local config_file
    config_file=$(realpath -s "$config_path" 2>/dev/null || echo "$config_path")
    if [[ ! -f "$config_file" ]]; then
      log_error "配置文件 $config_file 不存在。"
      exit "${ERROR_CONFIG}"
    fi
    log_info "加载用户提供的配置文件: $config_file"
    parse_config_content "$(cat "$config_file")"
    # 使用自定义配置文件时，直接使用配置中的备份路径
    if [[ -z "$BACKUP_DEST" ]]; then
      log_error "配置文件缺少 BACKUP_DEST。"
      exit "${ERROR_CONFIG}"
    fi
  fi

  # 验证配置
  for dir in "${SOURCE_DIRS[@]}"; do
    [[ ! "$dir" =~ ^/ ]] && log_error "BACKUP_DIRS 中的路径必须是绝对路径: $dir" && exit "${ERROR_CONFIG}"
  done
  [[ ! "$BACKUP_DEST" =~ ^/ ]] && log_error "BACKUP_DEST 必须是绝对路径: $BACKUP_DEST" && exit "${ERROR_CONFIG}"
  for dir in "${EXCLUDED_DIRS[@]}"; do
    # 只校验非空且非全空格的字符串
    if [[ -n "${dir// }" ]]; then
      [[ ! "$dir" =~ ^/ ]] && log_error "EXCLUDE_DIRS 中的路径必须是绝对路径: $dir" && exit "${ERROR_CONFIG}"
    fi
  done
}

# 获取下一个版本号，便于备份版本管理
get_next_version() {
  local dest_dir="$1" base_name="$2"
  local version=0
  for dir in "$dest_dir/${base_name}_v"*; do
    if [[ -d "$dir" && "$(basename "$dir")" =~ ^${base_name}_v([0-9]+)$ ]]; then
      local v=${BASH_REMATCH[1]}
      ((v > version)) && version=$v
    fi
  done
  echo $((version + 1))
}

# 生成操作日志文件，便于后续审计和追踪
generate_operation_log() {
  local log_file="$1" start_time="$2" end_time="$3" type="$4" num_excludes="$5"
  local restore_mode=""
  if [[ "$type" == "restore" ]]; then
    restore_mode="$6"
  fi
  local duration=$((end_time - start_time))
  local duration_str
  duration_str=$(printf "%02d:%02d:%02d" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60)))

  # 写入基本信息
  cat > "$log_file" << EOF
操作类型: ${type^^}
开始时间: $(date -d "@$start_time" '+%Y-%m-%d %H:%M:%S')
结束时间: $(date -d "@$end_time" '+%Y-%m-%d %H:%M:%S')
执行时长: $duration_str
源目录数量: ${#SOURCE_DIRS[@]}
排除目录数量: $num_excludes
EOF

  if [[ "$type" == "restore" ]]; then
    echo "恢复模式: $restore_mode" >> "$log_file"
  fi

  # 写入源目录列表和详细统计
  echo -e "\n源目录详细统计:" >> "$log_file"
  for dir in "${SOURCE_DIRS[@]}"; do
    echo -e "\n目录: $dir" >> "$log_file"
    
    # 获取操作前的统计信息
    local before_stats
    before_stats=$(get_dir_stats "$dir")
    local before_size
    before_size=$(echo "$before_stats" | cut -d' ' -f1)
    local before_files
    before_files=$(echo "$before_stats" | cut -d' ' -f2)

    # 获取操作后的统计信息
    local after_dir
    if [[ "$type" == "backup" ]]; then
      case "$dir" in
        "/var/lib/docker") after_dir="$backup_path/docker" ;;
        "/etc/docker") after_dir="$backup_path/etc" ;;
        "/opt/docker") after_dir="$backup_path/opt" ;;
        *) after_dir="$backup_path/$(basename "$dir")" ;;
      esac
    else
      after_dir="$dir"
    fi

    local after_stats
    after_stats=$(get_dir_stats "$after_dir")
    local after_size
    after_size=$(echo "$after_stats" | cut -d' ' -f1)
    local after_files
    after_files=$(echo "$after_stats" | cut -d' ' -f2)

    # 计算差异
    local size_diff=$((after_size - before_size))
    local files_diff=$((after_files - before_files))

    # 写入统计信息
    cat >> "$log_file" << EOF
  操作前:
    文件数量: $before_files
    总大小: $(format_file_size "$before_size")
  操作后:
    文件数量: $after_files
    总大小: $(format_file_size "$after_size")
  变化:
    文件数量: $(printf "%+d" $files_diff)
    总大小: $(printf "%+s" "$(format_file_size "${size_diff#-}")")$(if ((size_diff < 0)); then echo " (减少)"; else echo " (增加)"; fi)
EOF
  done

  # 写入排除目录信息
  if [[ $num_excludes -gt 0 ]]; then
    echo -e "\n排除目录列表:" >> "$log_file"
    for dir in "${EXCLUDED_DIRS[@]}"; do
      if [[ -n "$dir" ]]; then
        echo "  - $dir" >> "$log_file"
        # 获取排除目录的统计信息
        if [[ -d "$dir" ]]; then
          local exclude_stats
          exclude_stats=$(get_dir_stats "$dir")
          local exclude_size
          exclude_size=$(echo "$exclude_stats" | cut -d' ' -f1)
          local exclude_files
          exclude_files=$(echo "$exclude_stats" | cut -d' ' -f2)
          echo "    文件数量: $exclude_files" >> "$log_file"
          echo "    总大小: $(format_file_size "$exclude_size")" >> "$log_file"
        fi
      fi
    done
  fi

  # 写入完整性校验信息
  echo -e "\n完整性校验:" >> "$log_file"
  local total_before_size=0
  local total_before_files=0
  local total_after_size=0
  local total_after_files=0

  for dir in "${SOURCE_DIRS[@]}"; do
    local before_stats
    before_stats=$(get_dir_stats "$dir")
    local before_size
    before_size=$(echo "$before_stats" | cut -d' ' -f1)
    local before_files
    before_files=$(echo "$before_stats" | cut -d' ' -f2)
    total_before_size=$((total_before_size + before_size))
    total_before_files=$((total_before_files + before_files))

    local after_dir
    if [[ "$type" == "backup" ]]; then
      case "$dir" in
        "/var/lib/docker") after_dir="$backup_path/docker" ;;
        "/etc/docker") after_dir="$backup_path/etc" ;;
        "/opt/docker") after_dir="$backup_path/opt" ;;
        *) after_dir="$backup_path/$(basename "$dir")" ;;
      esac
    else
      after_dir="$dir"
    fi

    local after_stats
    after_stats=$(get_dir_stats "$after_dir")
    local after_size
    after_size=$(echo "$after_stats" | cut -d' ' -f1)
    local after_files
    after_files=$(echo "$after_stats" | cut -d' ' -f2)
    total_after_size=$((total_after_size + after_size))
    total_after_files=$((total_after_files + after_files))
  done

  # 计算总体差异
  local total_size_diff=$((total_after_size - total_before_size))
  local total_files_diff=$((total_after_files - total_before_files))

  cat >> "$log_file" << EOF
总体统计:
  操作前:
    总文件数量: $total_before_files
    总大小: $(format_file_size "$total_before_size")
  操作后:
    总文件数量: $total_after_files
    总大小: $(format_file_size "$total_after_size")
  总体变化:
    文件数量: $(printf "%+d" $total_files_diff)
    总大小: $(printf "%+s" "$(format_file_size "${total_size_diff#-}")")$(if ((total_size_diff < 0)); then echo " (减少)"; else echo " (增加)"; fi)

完整性状态: $(if [[ "$type" == "backup" && $total_files_diff -ge 0 ]] || [[ "$type" == "restore" && $total_files_diff -eq 0 ]]; then echo "正常"; else echo "警告：文件数量异常"; fi)

EOF

  # 写入操作路径信息
  if [[ "$type" == "backup" ]]; then
    echo "备份路径: $backup_path" >> "$log_file"
  elif [[ "$type" == "restore" ]]; then
    echo "备份源: $(basename "$selected_backup")" >> "$log_file"
  fi
}

# 工具函数，统计目录大小和文件数
get_dir_stats() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    local size
    size=$(du -s "$dir" 2>/dev/null | awk '{print $1}')
    local count
    count=$(find "$dir" -type f 2>/dev/null | wc -l)
    echo "$size $count"
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
  local progress=$((current * width / total))
  local percent=$((current * 100 / total))
  printf "\r进度: ["
  for ((i = 0; i < width; i++)); do
    if [[ $i -lt $progress ]]; then
      printf "#"
    else
      printf " "
    fi
  done
  printf "] %d%%" "$percent"
  if [[ $current -eq $total ]]; then
    printf "\n"
  fi
}

# 执行备份，自动处理服务状态和统计
perform_backup() {
  log_action "开始执行 Docker 备份..."
  local start_time
  start_time=$(date +%s)
  local docker_was_active
  docker_was_active=$(systemctl is-active docker.service 2>/dev/null || echo "inactive")
  if [[ "$docker_was_active" == "active" ]]; then
    stop_docker_service
  fi
  local backup_date
  backup_date=$(date +%Y%m%d_%H%M%S)
  local backup_name
  backup_name="docker_backup_v$(get_next_version "$BACKUP_DEST" "docker_backup")"
  local backup_path="$BACKUP_DEST/$backup_name"
  mkdir -p "$backup_path"
  local total_files=0
  local total_size=0
  local processed_files=0

  # 预先计算总文件数
  log_info "正在统计文件数量..."
  local total_source_files=0
  for source_dir in "${SOURCE_DIRS[@]}"; do
    if [[ -d "$source_dir" ]]; then
      total_source_files=$((total_source_files + $(get_total_files "$source_dir")))
    fi
  done
  log_info "共发现 $total_source_files 个文件需要备份"

  for source_dir in "${SOURCE_DIRS[@]}"; do
    if [[ -d "$source_dir" ]]; then
      # 根据源目录路径确定备份目录名
      case "$source_dir" in
        "/var/lib/docker") dir_name="docker" ;;
        "/etc/docker") dir_name="etc" ;;
        "/opt/docker") dir_name="opt" ;;
        *) dir_name=$(basename "$source_dir") ;;
      esac
      log_action "备份目录: $source_dir"
      local exclude_args=()
      for exclude_dir in "${EXCLUDED_DIRS[@]}"; do
        if [[ -n "$exclude_dir" ]]; then
          exclude_args+=(--exclude="$exclude_dir")
        fi
      done

      # 使用 rsync 的进度输出来更新总进度
      if rsync -a --info=progress2 --no-i-r --delete "${exclude_args[@]}" "$source_dir/" "$backup_path/$dir_name/" 2>&1 | 
        while IFS= read -r line; do
          if [[ $line =~ ^[0-9,]+ ]]; then
            processed_files=$(( (processed_files + 100) > total_source_files ? total_source_files : (processed_files + 100) ))
            show_progress "$processed_files" "$total_source_files"
          fi
        done; then
        local dir_stats
        dir_stats=$(get_dir_stats "$backup_path/$dir_name")
        local dir_size
        dir_size=$(echo "$dir_stats" | cut -d' ' -f1)
        local dir_files
        dir_files=$(echo "$dir_stats" | cut -d' ' -f2)
        total_size=$((total_size + dir_size))
        total_files=$((total_files + dir_files))
        log_success "目录 $source_dir 备份完成 (${dir_files} 文件, $(format_file_size "$dir_size"))。"
      else
        log_fail "目录 $source_dir 备份失败。"
      fi
    else
      log_warning "目录不存在，已跳过: $source_dir"
    fi
  done

  # 检查是否有任何目录被成功备份
  if [[ $total_files -eq 0 ]]; then
    log_error "没有找到任何有效的源目录，备份操作已取消。"
    rm -rf "$backup_path"
    if [[ "$docker_was_active" == "active" ]]; then
      start_docker_service
    fi
    return 1
  fi

  local end_time
  end_time=$(date +%s)
  local num_excludes=0
  for dir in "${EXCLUDED_DIRS[@]}"; do
    [[ -n "$dir" ]] && ((num_excludes++))
  done
  generate_operation_log "$backup_path/backup_info.txt" "$start_time" "$end_time" "backup" "$num_excludes"
  if [[ "$docker_was_active" == "active" ]]; then
    start_docker_service
  fi
  log_success "Docker 备份完成: $backup_path"
  log_info "备份统计: ${total_files} 文件, $(format_file_size "$total_size")"
}

# 执行恢复，支持完全恢复和增量恢复
perform_restore() {
  log_info "开始执行 Docker 恢复..."
  # 只需要询问备份文件存储路径
  while true; do
    log_info "请输入备份文件存储路径（例如 /mnt/backup）："
    read -r -e -p "" backup_dest
    if [[ -n "$backup_dest" && "$backup_dest" =~ ^/ ]]; then
      BACKUP_DEST=$(realpath -s "$backup_dest" 2>/dev/null || echo "$backup_dest")
      break
    else
      log_error "备份路径必须是绝对路径（以 / 开头），请重新输入。"
    fi
  done

  echo -e "请选择恢复模式:\n1. 完全恢复（覆盖现有数据）\n2. 增量恢复（保留现有数据）"
  read -r -p "请选择 (1/2): " restore_mode_choice
  local restore_mode=""
  case "$restore_mode_choice" in
    1) restore_mode="完全恢复" ;;
    2) restore_mode="增量恢复" ;;
    *) log_error "无效选择，使用完全恢复模式。"; restore_mode="完全恢复" ;;
  esac
  local available_backups=()
  local backup_index=1
  echo "可用的备份版本:"
  for backup_dir in "$BACKUP_DEST"/docker_backup_v*; do
    if [[ -d "$backup_dir" ]]; then
      local version
      version=$(basename "$backup_dir" | sed 's/docker_backup_v//')
      local backup_date
      backup_date=$(stat -c %y "$backup_dir" | cut -d' ' -f1)
      echo "$backup_index. 版本 $version (创建于 $backup_date)"
      available_backups+=("$backup_dir")
      ((backup_index++))
    fi
  done
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

  # 从备份目录中读取源目录列表
  SOURCE_DIRS=()
  for dir in "$selected_backup"/*; do
    if [[ -d "$dir" ]]; then
      local dir_name
      dir_name=$(basename "$dir")
      # 根据目录名构建完整的源路径
      case "$dir_name" in
        "docker") SOURCE_DIRS+=("/var/lib/docker") ;;
        "etc") SOURCE_DIRS+=("/etc/docker") ;;
        "opt") SOURCE_DIRS+=("/opt/docker") ;;
        *) log_warning "未知的备份目录: $dir_name，已跳过" ;;
      esac
    fi
  done

  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
    log_error "备份目录中未找到任何源目录。"
    return 1
  fi

  # 预先计算总文件数
  log_info "正在统计文件数量..."
  local total_backup_files=0
  for source_dir in "${SOURCE_DIRS[@]}"; do
    local dir_name
    case "$source_dir" in
      "/var/lib/docker") dir_name="docker" ;;
      "/etc/docker") dir_name="etc" ;;
      "/opt/docker") dir_name="opt" ;;
      *) dir_name=$(basename "$source_dir") ;;
    esac
    local backup_dir="$selected_backup/$dir_name"
    if [[ -d "$backup_dir" ]]; then
      total_backup_files=$((total_backup_files + $(get_total_files "$backup_dir")))
    fi
  done
  log_info "共发现 $total_backup_files 个文件需要恢复"

  local start_time
  start_time=$(date +%s)
  local docker_was_active
  docker_was_active=$(systemctl is-active docker.service 2>/dev/null || echo "inactive")
  if [[ "$docker_was_active" == "active" ]]; then
    stop_docker_service
  fi
  local total_files=0
  local total_size=0
  local processed_files=0

  for source_dir in "${SOURCE_DIRS[@]}"; do
    local dir_name
    # 根据源目录路径确定备份目录名
    case "$source_dir" in
      "/var/lib/docker") dir_name="docker" ;;
      "/etc/docker") dir_name="etc" ;;
      "/opt/docker") dir_name="opt" ;;
      *) dir_name=$(basename "$source_dir") ;;
    esac
    local backup_dir="$selected_backup/$dir_name"
    if [[ -d "$backup_dir" ]]; then
      log_action "恢复目录: $source_dir"
      local rsync_args=(-a --info=progress2 --no-i-r)
      if [[ "$restore_mode" == "完全恢复" ]]; then
        rsync_args+=(--delete)
      fi

      # 使用 rsync 的进度输出来更新总进度
      if rsync "${rsync_args[@]}" "$backup_dir/" "$source_dir/" 2>&1 |
        while IFS= read -r line; do
          if [[ $line =~ ^[0-9,]+ ]]; then
            processed_files=$(( (processed_files + 100) > total_backup_files ? total_backup_files : (processed_files + 100) ))
            show_progress "$processed_files" "$total_backup_files"
          fi
        done; then
        local dir_stats
        dir_stats=$(get_dir_stats "$source_dir")
        local dir_size
        dir_size=$(echo "$dir_stats" | cut -d' ' -f1)
        local dir_files
        dir_files=$(echo "$dir_stats" | cut -d' ' -f2)
        total_size=$((total_size + dir_size))
        total_files=$((total_files + dir_files))
        log_success "目录 $source_dir 恢复完成 (${dir_files} 文件, $(format_file_size "$dir_size"))。"
      else
        log_fail "目录 $source_dir 恢复失败。"
      fi
    else
      log_warning "备份中不存在目录: $dir_name"
    fi
  done

  local end_time
  end_time=$(date +%s)
  local num_excludes=0
  # 修改恢复日志路径，放在备份源目录下
  local restore_log
  restore_log="$selected_backup/restore_$(date +%Y%m%d_%H%M%S).log"
  generate_operation_log "$restore_log" "$start_time" "$end_time" "restore" "$num_excludes" "$restore_mode"
  if [[ "$docker_was_active" == "active" ]]; then
    start_docker_service
  fi
  log_success "Docker 恢复完成。"
  log_info "恢复统计: ${total_files} 文件, $(format_file_size "$total_size")"
  log_info "恢复日志: $restore_log"
}

# 显示主菜单
main_menu() {
  while true; do
    show_menu_with_border "Docker 备份恢复" "执行备份" "执行恢复" "查看备份列表"
    choice=$(get_user_choice 3)
    case $choice in
      1)
        load_backup_config
        perform_backup
        ;;
      2)
        perform_restore  # 移除 load_backup_config
        ;;
      3)
        # 只需要询问备份文件存储路径
        log_info "请输入备份文件存储路径（例如 /mnt/backup）："
        read -r -e -p "" backup_dest
        if [[ -n "$backup_dest" && "$backup_dest" =~ ^/ ]]; then
          BACKUP_DEST=$(realpath -s "$backup_dest" 2>/dev/null || echo "$backup_dest")
          echo "备份列表:"
          for backup_dir in "$BACKUP_DEST"/docker_backup_v*; do
            if [[ -d "$backup_dir" ]]; then
              local version
              version=$(basename "$backup_dir" | sed 's/docker_backup_v//')
              local backup_date
              backup_date=$(stat -c %y "$backup_dir" | cut -d' ' -f1)
              local backup_size
              backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
              echo "  版本 $version (创建于 $backup_date, 大小: $backup_size)"
            fi
          done
        else
          log_error "备份路径必须是绝对路径（以 / 开头）。"
        fi
        ;;
      0) log_action "返回"; return 0 ;;
      *) log_error "无效的操作选项，请重新选择。" ;;
    esac
  done
}

# 主程序入口
case "${1:-}" in
  "--backup")
    load_backup_config
    perform_backup
    ;;
  "--restore")
    perform_restore  # 移除 load_backup_config
    ;;
  *)
    main_menu
    ;;
esac
