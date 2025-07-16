#!/bin/bash
# 功能：Docker 容器与数据卷的备份与恢复工具（完整版）
# 参数：无
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 检查依赖
REQUIRED_CMDS=(docker tar rsync systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 Docker、tar、rsync 和 systemctl"
  exit "${ERROR_DEPENDENCY}"
fi

# 信号处理
trap 'log_info "脚本中断，正在清理..."; if [[ "$docker_was_active" == "active" ]]; then start_docker_service; fi; exit 1' SIGINT

# 默认配置
DEFAULT_CONFIG=$(cat << 'EOF'
# docker_backup.conf 配置文件
#
# 此文件用于配置 Docker 备份脚本的行为
# 请确保配置文件格式正确，否则脚本将无法正常运行
# 所有路径必须是绝对路径（以 / 开头）
# BACKUP_DIRS: 需要备份的目录列表，以空格分隔
# 示例：BACKUP_DIRS="/var/lib/docker /etc/docker /opt/docker"
BACKUP_DIRS="/var/lib/docker /etc/docker /opt/docker"

# BACKUP_DEST: 备份文件存储的根路径
# 建议设置在系统盘以外的路径，如 /mnt/backup 或 /media/backup
# 示例：BACKUP_DEST="/mnt/backup"
BACKUP_DEST="/mnt/backup"

# EXCLUDE_DIRS: 在备份时需要排除的目录列表，以空格分隔
# 示例：EXCLUDE_DIRS="/var/lib/docker/tmp /opt/docker/cache"
EXCLUDE_DIRS=
EOF
)

# 服务管理函数
stop_docker_service() {
  log_info "停止 Docker 服务"
  systemctl stop docker.service docker.socket || log_error "无法停止 Docker 服务"
  timeout 30 bash -c 'while systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket; do sleep 1; done' || log_error "无法停止 Docker 服务"
  log_success "Docker 服务已停止"
}

start_docker_service() {
  log_info "启动 Docker 服务"
  systemctl start docker.service docker.socket || log_error "无法启动 Docker 服务"
  log_success "Docker 服务已启动"
}

# 配置解析函数
parse_config_content() {
  local config_content="$1"
  mapfile -t config_entries < <(echo "$config_content" | grep -Ev '^#|^\s*$')
  for line in "${config_entries[@]}"; do
    IFS='=' read -r key value <<< "$line"
    value="${value//[! -~]/}"
    value="${value//\"/}"
    case "$key" in
      BACKUP_DIRS) BACKUP_DIRS="$value" ;;
      BACKUP_DEST) BACKUP_DEST="$value" ;;
      EXCLUDE_DIRS) EXCLUDE_DIRS="$value" ;;
      *) log_warn "未知配置项: $key" ;;
    esac
  done
  [[ -z "$BACKUP_DIRS" ]] && log_error "配置文件缺少 BACKUP_DIRS" && exit "${ERROR_CONFIG}"
  read -r -a SOURCE_DIRS <<< "$BACKUP_DIRS"
  read -r -a EXCLUDED_DIRS <<< "$EXCLUDE_DIRS"
}

# 加载备份配置
load_backup_config() {
  log_info "请输入 docker_backup.conf 配置文件路径（留空使用默认配置）:"
  read -e -p "" config_path

  if [[ -z "$config_path" ]]; then
    log_info "未提供配置文件，使用默认配置"
    parse_config_content "$DEFAULT_CONFIG"
    while true; do
      log_info "请输入备份文件存储路径（例如 /mnt/backup）:"
      read -e -p "" backup_dest
      if [[ -n "$backup_dest" && "$backup_dest" =~ ^/ ]]; then
        BACKUP_DEST=$(realpath -s "$backup_dest" 2>/dev/null || echo "$backup_dest")
        break
      else
        log_error "备份路径必须是绝对路径（以 / 开头），请重新输入"
      fi
    done
  else
    local config_file=$(realpath -s "$config_path" 2>/dev/null || echo "$config_path")
    if [[ ! -f "$config_file" ]]; then
      log_error "配置文件 $config_file 不存在"
      exit "${ERROR_CONFIG}"
    fi
    log_info "加载用户提供的配置文件: $config_file"
    parse_config_content "$(cat "$config_file")"
    [[ -z "$BACKUP_DEST" ]] && log_error "配置文件缺少 BACKUP_DEST" && exit "${ERROR_CONFIG}"
  fi

  # 验证路径
  for dir in "${SOURCE_DIRS[@]}"; do
    [[ ! "$dir" =~ ^/ ]] && log_error "BACKUP_DIRS 中的路径必须是绝对路径: $dir" && exit "${ERROR_CONFIG}"
  done
  [[ ! "$BACKUP_DEST" =~ ^/ ]] && log_error "BACKUP_DEST 必须是绝对路径: $BACKUP_DEST" && exit "${ERROR_CONFIG}"
  for dir in "${EXCLUDED_DIRS[@]}"; do
    [[ -n "$dir" && ! "$dir" =~ ^/ ]] && log_error "EXCLUDE_DIRS 中的路径必须是绝对路径: $dir" && exit "${ERROR_CONFIG}"
  done
}

# 获取下一个版本号
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

# 生成操作日志文件
generate_operation_log() {
  local log_file="$1" start_time="$2" end_time="$3" type="$4" num_excludes="$5"
  local restore_mode=""
  local offset=5

  if [[ "$type" == "restore" ]]; then
    restore_mode="$6"
    offset=6
  fi

  local duration=$((end_time - start_time))
  local duration_str=$(printf "%02d:%02d:%02d" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60)))

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

  echo "" >> "$log_file"
  echo "源目录列表:" >> "$log_file"
  for dir in "${SOURCE_DIRS[@]}"; do
    echo "  - $dir" >> "$log_file"
  done

  if [[ $num_excludes -gt 0 ]]; then
    echo "" >> "$log_file"
    echo "排除目录列表:" >> "$log_file"
    for dir in "${EXCLUDED_DIRS[@]}"; do
      [[ -n "$dir" ]] && echo "  - $dir" >> "$log_file"
    done
  fi
}

# 执行备份
perform_backup() {
  log_action "开始执行 Docker 备份..."
  
  local start_time=$(date +%s)
  
  # 记录 Docker 服务状态
  docker_was_active=$(systemctl is-active docker.service 2>/dev/null || echo "inactive")
  
  # 停止 Docker 服务
  if [[ "$docker_was_active" == "active" ]]; then
    stop_docker_service
  fi
  
  # 创建备份目录
  local backup_date=$(date +%Y%m%d_%H%M%S)
  local backup_name="docker_backup_v$(get_next_version "$BACKUP_DEST" "docker_backup")"
  local backup_path="$BACKUP_DEST/$backup_name"
  
  mkdir -p "$backup_path"
  
  # 执行备份
  local total_files=0
  local total_size=0
  
  for source_dir in "${SOURCE_DIRS[@]}"; do
    if [[ -d "$source_dir" ]]; then
      local dir_name=$(basename "$source_dir")
      log_action "备份目录: $source_dir"
      
      # 构建 rsync 排除参数
      local exclude_args=""
      for exclude_dir in "${EXCLUDED_DIRS[@]}"; do
        if [[ -n "$exclude_dir" ]]; then
          exclude_args+=" --exclude=$exclude_dir"
        fi
      done
      
      # 执行 rsync 备份
      if rsync -av --delete $exclude_args "$source_dir/" "$backup_path/$dir_name/"; then
        local dir_stats=$(get_dir_stats "$backup_path/$dir_name")
        local dir_size=$(echo "$dir_stats" | cut -d' ' -f1)
        local dir_files=$(echo "$dir_stats" | cut -d' ' -f2)
        total_size=$((total_size + dir_size))
        total_files=$((total_files + dir_files))
        log_success "目录 $source_dir 备份完成 (${dir_files} 文件, $(format_file_size $dir_size))"
      else
        log_fail "目录 $source_dir 备份失败"
      fi
    else
      log_warning "目录不存在，跳过: $source_dir"
    fi
  done
  
  # 生成备份信息文件
  local end_time=$(date +%s)
  local num_excludes=0
  for dir in "${EXCLUDED_DIRS[@]}"; do
    [[ -n "$dir" ]] && ((num_excludes++))
  done
  
  generate_operation_log "$backup_path/backup_info.txt" "$start_time" "$end_time" "backup" "$num_excludes"
  
  # 添加备份统计信息
  cat >> "$backup_path/backup_info.txt" << EOF

备份统计:
总文件数: $total_files
总大小: $(format_file_size $total_size)
备份路径: $backup_path
EOF
  
  # 重新启动 Docker 服务
  if [[ "$docker_was_active" == "active" ]]; then
    start_docker_service
  fi
  
  log_success "Docker 备份完成: $backup_path"
  log_info "备份统计: ${total_files} 文件, $(format_file_size $total_size)"
}

# 执行恢复
perform_restore() {
  log_info "开始执行 Docker 恢复..."
  
  # 选择恢复模式
  echo -e "请选择恢复模式:\n1. 完全恢复（覆盖现有数据）\n2. 增量恢复（保留现有数据）"
  read -p "请选择 (1/2): " restore_mode_choice
  
  local restore_mode=""
  case "$restore_mode_choice" in
    1) restore_mode="完全恢复" ;;
    2) restore_mode="增量恢复" ;;
    *) log_error "无效选择，使用完全恢复模式"; restore_mode="完全恢复" ;;
  esac
  
  # 选择备份版本
  local available_backups=()
  local backup_index=1
  
  echo "可用的备份版本:"
  for backup_dir in "$BACKUP_DEST"/docker_backup_v*; do
    if [[ -d "$backup_dir" ]]; then
      local version=$(basename "$backup_dir" | sed 's/docker_backup_v//')
      local backup_date=$(stat -c %y "$backup_dir" | cut -d' ' -f1)
      echo "$backup_index. 版本 $version (创建于 $backup_date)"
      available_backups+=("$backup_dir")
      ((backup_index++))
    fi
  done
  
  if [[ ${#available_backups[@]} -eq 0 ]]; then
    log_error "未找到可用的备份"
    return 1
  fi
  
  read -p "请选择要恢复的备份版本 (1-${#available_backups[@]}): " backup_choice
  if [[ ! "$backup_choice" =~ ^[0-9]+$ ]] || [[ "$backup_choice" -lt 1 ]] || [[ "$backup_choice" -gt ${#available_backups[@]} ]]; then
    log_error "无效的备份版本选择"
    return 1
  fi
  
  local selected_backup="${available_backups[$((backup_choice - 1))]}"
  log_info "选择恢复备份: $(basename "$selected_backup")"
  
  local start_time=$(date +%s)
  
  # 记录 Docker 服务状态
  docker_was_active=$(systemctl is-active docker.service 2>/dev/null || echo "inactive")
  
  # 停止 Docker 服务
  if [[ "$docker_was_active" == "active" ]]; then
    stop_docker_service
  fi
  
  # 执行恢复
  local total_files=0
  local total_size=0
  
  for source_dir in "${SOURCE_DIRS[@]}"; do
    local dir_name=$(basename "$source_dir")
    local backup_dir="$selected_backup/$dir_name"
    
    if [[ -d "$backup_dir" ]]; then
      log_action "恢复目录: $source_dir"
      
      # 构建 rsync 参数
      local rsync_args="-av"
      if [[ "$restore_mode" == "完全恢复" ]]; then
        rsync_args+=" --delete"
      fi
      
      # 构建排除参数
      for exclude_dir in "${EXCLUDED_DIRS[@]}"; do
        if [[ -n "$exclude_dir" ]]; then
          rsync_args+=" --exclude=$exclude_dir"
        fi
      done
      
      # 执行恢复
      if rsync $rsync_args "$backup_dir/" "$source_dir/"; then
        local dir_stats=$(get_dir_stats "$source_dir")
        local dir_size=$(echo "$dir_stats" | cut -d' ' -f1)
        local dir_files=$(echo "$dir_stats" | cut -d' ' -f2)
        total_size=$((total_size + dir_size))
        total_files=$((total_files + dir_files))
        log_success "目录 $source_dir 恢复完成 (${dir_files} 文件, $(format_file_size $dir_size))"
      else
        log_fail "目录 $source_dir 恢复失败"
      fi
    else
      log_warning "备份中不存在目录: $dir_name"
    fi
  done
  
  # 生成恢复日志
  local end_time=$(date +%s)
  local num_excludes=0
  for dir in "${EXCLUDED_DIRS[@]}"; do
    [[ -n "$dir" ]] && ((num_excludes++))
  done
  
  local restore_log="/var/log/docker_restore_$(date +%Y%m%d_%H%M%S).log"
  generate_operation_log "$restore_log" "$start_time" "$end_time" "restore" "$num_excludes" "$restore_mode"
  
  # 添加恢复统计信息
  cat >> "$restore_log" << EOF

恢复统计:
总文件数: $total_files
总大小: $(format_file_size $total_size)
恢复模式: $restore_mode
备份源: $(basename "$selected_backup")
EOF
  
  # 重新启动 Docker 服务
  if [[ "$docker_was_active" == "active" ]]; then
    start_docker_service
  fi
  
  log_success "Docker 恢复完成"
  log_info "恢复统计: ${total_files} 文件, $(format_file_size $total_size)"
  log_info "恢复日志: $restore_log"
}

# 工具函数
get_dir_stats() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    local size=$(du -s "$dir" 2>/dev/null | awk '{print $1}')
    local count=$(find "$dir" -type f 2>/dev/null | wc -l)
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

# 显示主菜单
main_menu() {
  while true; do
    echo -e "------------------------------\n1. 执行备份\n2. 执行恢复\n3. 查看备份列表\n0. 退出\n------------------------------"
    read -p "请选择操作: " choice
    case $choice in
    1)
        load_backup_config
      perform_backup
      ;;
    2)
        load_backup_config
      perform_restore
      ;;
      3)
        load_backup_config
        echo "备份列表:"
        for backup_dir in "$BACKUP_DEST"/docker_backup_v*; do
          if [[ -d "$backup_dir" ]]; then
            local version=$(basename "$backup_dir" | sed 's/docker_backup_v//')
            local backup_date=$(stat -c %y "$backup_dir" | cut -d' ' -f1)
            local backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            echo "  版本 $version (创建于 $backup_date, 大小: $backup_size)"
          fi
        done
        ;;
      0) exit 0 ;;
      *) log_error "无效的操作选项，请重新选择" ;;
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
    load_backup_config
    perform_restore
    ;;
  *)
    main_menu
      ;;
  esac
