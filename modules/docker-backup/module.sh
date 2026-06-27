#!/bin/bash
# @module: docker-backup
# @name: Docker 备份恢复
# @category: 容器管理
# @depends: docker,tar,rsync
# @depend_modules: docker-ce
# @version: 2.0.0
# @order: 53
# 功能：Docker 容器与数据卷的备份与恢复工具（目录模块入口）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

source "${MODULE_DIR}/backup.sh"
source "${MODULE_DIR}/restore.sh"
source "${MODULE_DIR}/verify.sh"

# Docker 服务状态由全局变量维护，便于退出时恢复服务
DOCKER_WAS_ACTIVE="inactive"

cleanup_on_exit() {
  restore_docker_service_if_needed
}

handle_interrupt() {
  log_warning "脚本中断，Docker 服务保持停止状态以便检查数据完整性。"
  log_warning "请手动检查数据后执行: systemctl start docker"
  DOCKER_WAS_ACTIVE="inactive"
  exit 1
}

# 退出与中断时统一执行清理逻辑
trap cleanup_on_exit EXIT
trap handle_interrupt INT TERM

# 检查依赖，确保 Docker、tar、rsync、systemctl 已安装（自动安装缺失项）
readonly REQUIRED_CMDS=(docker tar rsync systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_warning "检测到依赖缺失，正在尝试自动安装..."
  install_missing_dependencies "${REQUIRED_CMDS[@]}"
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖自动安装失败，请手动安装 Docker、tar、rsync 和 systemctl。"
    exit "${ERROR_DEPENDENCY}"
  fi
fi

# 默认配置文件路径（模块内配置文件）
readonly DEFAULT_CONFIG_FILE="${MODULE_DIR}/config/docker_backup.conf.default"
# 备份配置运行时变量，需先初始化以兼容 set -u
declare -a SOURCE_DIRS=()
declare -a EXCLUDED_DIRS=()
BACKUP_DEST=""

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

# 去除字符串首尾空白字符
trim_whitespace() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf "%s\n" "$value"
}

# 规范化配置值，保留内部内容，仅移除包裹型引号
normalize_config_value() {
  local raw_value="$1"
  local value
  value="$(trim_whitespace "$raw_value")"
  value="${value//[$'\x00'-$'\x1f'$'\x7f']/}"

  if [[ "$value" =~ ^\"(.*)\"$ ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi

  printf "%s\n" "$value"
}

# 解析空格分隔的路径列表
parse_space_separated_paths() {
  local raw_value="$1"
  # shellcheck disable=SC2034  # Bash nameref 用于回写调用方数组
  local -n output_ref="$2"
  local normalized_value

  output_ref=()
  normalized_value="$(normalize_config_value "$raw_value")"
  if [[ -n "$normalized_value" ]]; then
    # shellcheck disable=SC2034  # Bash nameref 用于 read -a 目标数组
    IFS=' ' read -r -a output_ref <<< "$normalized_value"
  fi
}

# 从配置文件读取并解析备份配置
parse_config_file() {
  local config_file="$1"
  local line

  SOURCE_DIRS=()
  EXCLUDED_DIRS=()
  BACKUP_DEST=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    local key_part="${line%%=*}"
    local value_part=""
    if [[ "$line" == *=* ]]; then
      value_part="${line#*=}"
    fi

    local key
    key="$(trim_whitespace "$key_part")"
    key="${key//[[:space:]]/}"

    case "$key" in
      BACKUP_DIRS)
        parse_space_separated_paths "$value_part" SOURCE_DIRS
        ;;
      BACKUP_DEST)
        BACKUP_DEST="$(normalize_config_value "$value_part")"
        ;;
      EXCLUDE_DIRS)
        parse_space_separated_paths "$value_part" EXCLUDED_DIRS
        ;;
      *)
        log_warning "未知配置项: $key"
        ;;
    esac
  done < "$config_file"

  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
    log_error "配置文件缺少 BACKUP_DIRS 或 BACKUP_DIRS 为空。"
    exit "${ERROR_CONFIG}"
  fi
}

# 提示用户输入绝对路径
prompt_absolute_path() {
  local prompt_message="$1"
  local input_path=""

  while true; do
    log_info "$prompt_message"
    read -r -e -p "" input_path
    input_path="$(trim_whitespace "$input_path")"
    if [[ -n "$input_path" && "$input_path" =~ ^/ ]]; then
      realpath -s "$input_path" 2>/dev/null || printf "%s\n" "$input_path"
      return 0
    fi
    log_error "备份路径必须是绝对路径（以 / 开头），请重新输入。" >&2
  done
}

# 加载备份配置，支持交互输入和文件加载
load_backup_config() {

  local config_path
  log_info "请输入 docker_backup.conf 配置文件路径（留空使用默认配置）："
  read -r -e -p "" config_path
  config_path="$(trim_whitespace "$config_path")"
  if [[ -z "$config_path" ]]; then
    log_info "未提供配置文件，使用默认配置文件：$DEFAULT_CONFIG_FILE。"
    if [[ ! -f "$DEFAULT_CONFIG_FILE" ]]; then
      log_error "默认配置文件 $DEFAULT_CONFIG_FILE 不存在。"
      exit "${ERROR_CONFIG}"
    fi
    parse_config_file "$DEFAULT_CONFIG_FILE"
    BACKUP_DEST="$(prompt_absolute_path "请输入备份文件存储路径（例如 /mnt/backup）：")"
  else
    local config_file
    config_file=$(realpath -s "$config_path" 2>/dev/null || printf "%s\n" "$config_path")
    if [[ ! -f "$config_file" ]]; then
      log_error "配置文件 $config_file 不存在。"
      exit "${ERROR_CONFIG}"
    fi
    log_info "加载用户提供的配置文件: $config_file"
    parse_config_file "$config_file"
    # 使用自定义配置文件时，直接使用配置中的备份路径
    if [[ -z "$BACKUP_DEST" ]]; then
      log_error "配置文件缺少 BACKUP_DEST。"
      exit "${ERROR_CONFIG}"
    fi
  fi

  # 验证配置
  for dir in "${SOURCE_DIRS[@]}"; do
    if [[ ! "$dir" =~ ^/ ]]; then
      log_error "BACKUP_DIRS 中的路径必须是绝对路径: $dir"
      exit "${ERROR_CONFIG}"
    fi
  done
  if [[ ! "$BACKUP_DEST" =~ ^/ ]]; then
    log_error "BACKUP_DEST 必须是绝对路径: $BACKUP_DEST"
    exit "${ERROR_CONFIG}"
  fi
  for dir in "${EXCLUDED_DIRS[@]}"; do
    # 只校验非空且非全空格的字符串
    if [[ -n "${dir// }" ]]; then
      if [[ ! "$dir" =~ ^/ ]]; then
        log_error "EXCLUDE_DIRS 中的路径必须是绝对路径: $dir"
        exit "${ERROR_CONFIG}"
      fi
    fi
  done

  return 0
}

# 生成备份目录名，使用紧凑时间戳格式便于排序和识别
build_backup_dir_name() {
  echo "dockerbak-$(date '+%Y%m%dT%H%M%S')"
}

# 判断目录名是否属于备份目录
is_backup_dir_name() {
  local dir_name="$1"
  [[ "$dir_name" =~ ^dockerbak-[0-9]{8}T[0-9]{6}$ ]]
}

# 获取可用备份目录，按创建时间倒序排列
get_available_backup_dirs() {
  local dest_dir="$1"
  local candidate_dirs=()
  mapfile -t candidate_dirs < <(
    find "$dest_dir" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr
  )

  local entry
  for entry in "${candidate_dirs[@]}"; do
    local backup_dir="${entry#* }"
    local dir_name
    dir_name=$(basename "$backup_dir")
    if is_backup_dir_name "$dir_name"; then
      echo "$backup_dir"
    fi
  done

  return 0
}

# 将备份目录名格式化为便于用户识别的展示文本
format_backup_display_name() {
  local backup_dir="$1"
  local dir_name
  dir_name=$(basename "$backup_dir")

  if [[ "$dir_name" =~ ^dockerbak-([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    return 0
  fi

  echo "$dir_name"
}

# 统一生成操作日志文件名，保持备份与恢复文件名固定
build_operation_log_name() {
  local operation_type="$1"

  printf "%s-%s.log\n" "$operation_type" "$(date '+%Y%m%dT%H%M%S')"
}

# 获取备份目录中的备份日志文件，优先使用新命名，兼容旧文件名
get_backup_log_file() {
  local backup_dir="$1"
  local backup_logs=()
  mapfile -t backup_logs < <(
    find "$backup_dir" -maxdepth 1 -type f \( -name 'backup-*.log' -o -name 'backup_*.log' \) 2>/dev/null \
      | sort
  )

  if [[ ${#backup_logs[@]} -gt 0 ]]; then
    printf "%s\n" "${backup_logs[-1]}"
    return 0
  fi

  if [[ -f "$backup_dir/backup.log" ]]; then
    printf "%s\n" "$backup_dir/backup.log"
    return 0
  fi

  if [[ -f "$backup_dir/backup_info.txt" ]]; then
    printf "%s\n" "$backup_dir/backup_info.txt"
    return 0
  fi

  return 1
}

# 生成操作日志文件，便于后续审计和追踪
generate_operation_log() {
  local log_file="$1" start_time="$2" end_time="$3" type="$4" target_value="$5"
  local restore_mode="${6:-}"
  local duration=$((end_time - start_time))
  local duration_str
  duration_str=$(printf "%02d:%02d:%02d" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60)))
  local num_excludes
  num_excludes=$(count_configured_excludes EXCLUDED_DIRS)

  local log_title="Docker ${type^^} 日志"
  local target_label="备份源        "
  if [[ "$type" == "backup" ]]; then
    target_label="备份路径      "
  fi

  cat > "$log_file" << EOF
====================================================
$log_title
====================================================

[执行概览]
操作类型      : ${type^^}
开始时间      : $(date -d "@$start_time" '+%Y-%m-%d %H:%M:%S')
结束时间      : $(date -d "@$end_time" '+%Y-%m-%d %H:%M:%S')
执行时长      : $duration_str
源目录数量    : ${#SOURCE_DIRS[@]}
排除目录数量  : $num_excludes
EOF

  if [[ "$type" == "backup" ]]; then
    cat >> "$log_file" << EOF
备份结构版本  : source-path-v1
备份内容根目录: source
EOF
  fi

  if [[ "$type" == "restore" ]]; then
    printf "恢复模式      : %s\n" "$restore_mode" >> "$log_file"
  fi

  printf "%s: %s\n" "$target_label" "$target_value" >> "$log_file"

  printf "\n[源目录清单]\n" >> "$log_file"
  local source_index=1
  local source_dir
  for source_dir in "${SOURCE_DIRS[@]}"; do
    printf "%02d. 源目录: %s\n" "$source_index" "$source_dir" >> "$log_file"
    ((source_index += 1))
  done

  printf "\n[目录明细]\n" >> "$log_file"
  local target_dir
  for dir in "${SOURCE_DIRS[@]}"; do
    local before_stats
    before_stats=$(get_dir_stats "$dir")
    local before_size
    before_size=$(echo "$before_stats" | cut -d' ' -f1)
    local before_files
    before_files=$(echo "$before_stats" | cut -d' ' -f2)

    if [[ "$type" == "backup" ]]; then
      target_dir=$(get_backup_source_dir "$target_value" "$dir")
    else
      target_dir="$dir"
    fi

    local after_stats
    after_stats=$(get_dir_stats "$target_dir")
    local after_size
    after_size=$(echo "$after_stats" | cut -d' ' -f1)
    local after_files
    after_files=$(echo "$after_stats" | cut -d' ' -f2)

    local size_diff=$((after_size - before_size))
    local files_diff=$((after_files - before_files))
    local size_diff_text
    size_diff_text="$(format_file_size "${size_diff#-}")"
    if ((size_diff < 0)); then
      size_diff_text="-${size_diff_text}（减少）"
    else
      size_diff_text="+${size_diff_text}（增加）"
    fi

    cat >> "$log_file" << EOF
----------------------------------------------------
目录: $dir
  操作前 : $before_files 文件 | $(format_file_size "$before_size")
  操作后 : $after_files 文件 | $(format_file_size "$after_size")
  变化   : $(printf "%+d" "$files_diff") 文件 | $size_diff_text
EOF
  done

  if [[ $num_excludes -gt 0 ]]; then
    printf "\n[排除目录]\n" >> "$log_file"
    local exclude_index=1
    for dir in "${EXCLUDED_DIRS[@]}"; do
      if [[ -n "$dir" ]]; then
        printf "%02d. %s\n" "$exclude_index" "$dir" >> "$log_file"
        if [[ -d "$dir" ]]; then
          local exclude_stats
          exclude_stats=$(get_dir_stats "$dir")
          local exclude_size
          exclude_size=$(echo "$exclude_stats" | cut -d' ' -f1)
          local exclude_files
          exclude_files=$(echo "$exclude_stats" | cut -d' ' -f2)
          printf "    统计   : %s 文件 | %s\n" \
            "$exclude_files" "$(format_file_size "$exclude_size")" >> "$log_file"
        fi
        ((exclude_index += 1))
      fi
    done
  fi

  printf "\n[完整性校验]\n" >> "$log_file"
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

    if [[ "$type" == "backup" ]]; then
      target_dir=$(get_backup_source_dir "$target_value" "$dir")
    else
      target_dir="$dir"
    fi

    local after_stats
    after_stats=$(get_dir_stats "$target_dir")
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
  local total_size_diff_text
  total_size_diff_text="$(format_file_size "${total_size_diff#-}")"
  if ((total_size_diff < 0)); then
    total_size_diff_text="-${total_size_diff_text}（减少）"
  else
    total_size_diff_text="+${total_size_diff_text}（增加）"
  fi
  local integrity_status="警告：文件数量异常"
  if [[ "$type" == "backup" && $total_files_diff -ge 0 ]] || \
     [[ "$type" == "restore" && $total_files_diff -eq 0 ]]; then
    integrity_status="正常"
  fi

  cat >> "$log_file" << EOF
操作前合计 : $total_before_files 文件 | $(format_file_size "$total_before_size")
操作后合计 : $total_after_files 文件 | $(format_file_size "$total_after_size")
变化合计   : $(printf "%+d" "$total_files_diff") 文件 | $total_size_diff_text
完整性状态 : $integrity_status
EOF
}

# 工具函数，按源目录绝对路径生成备份目录中的存储路径
get_backup_source_dir() {
  local backup_root="$1"
  local source_path="$2"
  local normalized_source="${source_path%/}"
  echo "$backup_root/source$normalized_source"
}

# 工具函数，从备份说明文件中读取源目录列表
load_backup_sources_from_info() {
  local info_file="$1"
  SOURCE_DIRS=()
  local legacy_source_dirs=()

  while IFS= read -r line; do
    if [[ "$line" =~ ^([0-9]{2}\.[[:space:]]+)?源目录:[[:space:]]+(.+)$ ]]; then
      local source_path="${BASH_REMATCH[2]}"
      SOURCE_DIRS+=("$source_path")
    elif [[ "$line" =~ ^目录:[[:space:]]+(/.+)$ ]]; then
      legacy_source_dirs+=("${BASH_REMATCH[1]}")
    fi
  done < "$info_file"

  if [[ ${#SOURCE_DIRS[@]} -eq 0 && ${#legacy_source_dirs[@]} -gt 0 ]]; then
    local source_dir
    local seen_dirs='|'
    for source_dir in "${legacy_source_dirs[@]}"; do
      if [[ "$seen_dirs" != *"|$source_dir|"* ]]; then
        SOURCE_DIRS+=("$source_dir")
        seen_dirs+="$source_dir|"
      fi
    done
  fi

  [[ ${#SOURCE_DIRS[@]} -gt 0 ]]
}

# 工具函数，根据备份结构解析实际的备份目录路径
get_restore_backup_dir() {
  local backup_root="$1"
  local source_path="$2"
  local source_based_dir
  source_based_dir=$(get_backup_source_dir "$backup_root" "$source_path")
  if [[ -d "$source_based_dir" ]]; then
    echo "$source_based_dir"
    return 0
  fi

  local normalized_source="${source_path%/}"
  local legacy_dir_name="${normalized_source//\//_}"
  legacy_dir_name="${legacy_dir_name#_}"
  echo "$backup_root/$legacy_dir_name"
}

# 统计有效排除目录数量
count_configured_excludes() {
  # shellcheck disable=SC2034
  local -n excluded_dirs_ref="$1"
  local exclude_count=0
  local excluded_dir

  for excluded_dir in "${excluded_dirs_ref[@]}"; do
    if [[ -n "$excluded_dir" ]]; then
      ((exclude_count += 1))
    fi
  done

  printf "%s\n" "$exclude_count"
}

# 统计源目录总文件数
calculate_total_files_for_sources() {
  # shellcheck disable=SC2034
  local -n source_dirs_ref="$1"
  local total_files=0
  local source_dir

  for source_dir in "${source_dirs_ref[@]}"; do
    if [[ -d "$source_dir" ]]; then
      total_files=$((total_files + $(get_total_files "$source_dir")))
    fi
  done

  printf "%s\n" "$total_files"
}

# 统计备份目录中的总文件数
calculate_total_files_for_backup() {
  local selected_backup="$1"
  # shellcheck disable=SC2034
  local -n source_dirs_ref="$2"
  local total_files=0
  local source_dir

  for source_dir in "${source_dirs_ref[@]}"; do
    local backup_dir
    backup_dir=$(get_restore_backup_dir "$selected_backup" "$source_dir")
    if [[ -d "$backup_dir" ]]; then
      total_files=$((total_files + $(get_total_files "$backup_dir")))
    fi
  done

  printf "%s\n" "$total_files"
}

# 获取 Docker 当前运行状态并在需要时停止服务
prepare_docker_service_for_data_operation() {
  DOCKER_WAS_ACTIVE=$(systemctl is-active docker.service 2>/dev/null || printf "%s\n" "inactive")
  if [[ "$DOCKER_WAS_ACTIVE" == "active" ]]; then
    stop_docker_service
  fi
}

# 数据操作结束后恢复 Docker 服务状态
restore_docker_service_if_needed() {
  if [[ "$DOCKER_WAS_ACTIVE" == "active" ]]; then
    start_docker_service
  fi
  DOCKER_WAS_ACTIVE="inactive"
}

# 创建备份目录并完成可写性校验

main_menu() {
  while true; do
    print_separator "-"
    print_menu_item "1" "执行备份"
    print_menu_item "2" "执行恢复"
    print_menu_item "3" "备份列表"
    print_menu_item "0" "返回" "true"
    print_separator "-"
    print_prompt "请选择编号: "
    read -r choice
    
    # 验证输入
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      log_error "请输入数字编号"
      continue
    fi
    
    if [[ "$choice" -lt 0 ]] || [[ "$choice" -gt 3 ]]; then
      log_error "无效选择，请输入 0-3"
      continue
    fi
    
    case $choice in
      1)
        load_backup_config
        perform_backup
        ;;
      2)
        perform_restore
        ;;
      3)
        BACKUP_DEST="$(prompt_absolute_path "请输入备份文件存储路径（例如 /mnt/backup）：")"
        local available_backups=()
        set +e
        mapfile -t available_backups < <(get_available_backup_dirs "$BACKUP_DEST")
        set -e
        if [[ ${#available_backups[@]} -eq 0 ]]; then
          log_info "暂无备份记录"
        else
          echo "备份列表:"
          local idx=1
          for backup_dir in "${available_backups[@]}"; do
            if [[ -d "$backup_dir" ]]; then
              local display_name
              display_name=$(format_backup_display_name "$backup_dir")
              local backup_date
              backup_date=$(stat -c %y "$backup_dir" | cut -d'.' -f1)
              local backup_size
              backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
              echo "  ${idx}. $display_name (创建于 $backup_date, 大小: $backup_size)"
              ((idx++))
            fi
          done
        fi
        ;;
      0) log_action "返回"; return 0 ;;
      *) log_error "无效的操作选项，请重新选择。" ;;
    esac
  done
}

main() {
  case "${1:-}" in
    "--backup")
      load_backup_config
      perform_backup
      ;;
    "--restore")
      perform_restore
      ;;
    *)
      main_menu
      ;;
  esac
}

main "$@"
