#!/bin/bash
# 功能：交互式批量安装常用 Docker 容器应用（仅 compose 方式）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/lib/core/constants.sh"
source "${PROJECT_ROOT}/lib/core/logging.sh"
source "${PROJECT_ROOT}/lib/system/dependency.sh"

# 容器配置文件
CONTAINER_CONFIG="${PROJECT_ROOT}/config/containers.conf"

# 检查依赖
REQUIRED_CMDS=(docker curl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 Docker 或 curl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查 compose 目录
COMPOSE_DIR="${PROJECT_ROOT}/docker-compose"
if [[ ! -d "$COMPOSE_DIR" ]]; then
  log_error "compose 目录不存在：$COMPOSE_DIR。"
  exit 1
fi

# 读取容器配置
declare -A container_desc
declare -A container_compose
declare -a container_order
load_container_config() {
  if [[ ! -f "$CONTAINER_CONFIG" ]]; then
    log_error "容器配置文件不存在：$CONTAINER_CONFIG"
    exit 1
  fi
  container_order=()
  # 使用 while read ... || [ -n "$key" ] 方式，确保最后一行无换行符也能被处理
  while IFS='|' read -r key yaml || [ -n "$key" ]; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    container_desc["$key"]="${key^}"
    container_compose["$key"]="$yaml"
    container_order+=("$key")
  done < "$CONTAINER_CONFIG"
}

# 显示容器应用菜单（按容器名称字母顺序）
show_container_menu() {
  echo "---------------- 容器应用安装 ----------------"
  # 生成按字母序排序的新数组
  local -a sorted_keys=("${container_order[@]}")
  IFS=$'\n' sorted_keys=($(sort <<<"${sorted_keys[*]}"))
  unset IFS
  local idx=1
  declare -A index_to_key
  for key in "${sorted_keys[@]}"; do
    echo "$idx、${container_desc[$key]}"
    index_to_key[$idx]="$key"
    idx=$((idx+1))
  done
  echo "99、安装全部"
  echo "0、返回"
  echo "支持多选，空格分隔，如：1 2 3"
  echo -n "请选择编号: "
  # 返回 index_to_key 供后续选择映射
  export MENU_INDEX_TO_KEY=$(declare -p index_to_key)
  export MENU_SORTED_KEYS=$(IFS=,; echo "${sorted_keys[*]}")
  return 0
}

# 部署指定容器
deploy_container() {
  local key="$1"
  local yaml_file="$COMPOSE_DIR/${container_compose[$key]}"
  if ! docker ps -a --format '{{.Names}}' | grep -qw "$key"; then
    log_info "正在部署 ${container_desc[$key]}..."
    if [[ ! -f "$yaml_file" ]]; then
      log_error "compose 文件不存在：$yaml_file，跳过该容器。"
      return
    fi
    if docker compose -p "$key" -f "$yaml_file" up -d; then
      log_info "${container_desc[$key]} 部署完成。"
    else
      log_error "${container_desc[$key]} 部署失败。"
    fi
  else
    log_info "${container_desc[$key]} 已存在，跳过部署。"
  fi
}

# 主流程
main() {
  load_container_config
  show_container_menu
  read -r -a choices
  [[ " ${choices[*]} " =~ " 0 " ]] && return 0

  local containers=()
  # 解析 index_to_key 和 sorted_keys
  eval "${MENU_INDEX_TO_KEY}"
  IFS=',' read -r -a sorted_keys <<< "${MENU_SORTED_KEYS}"

  if [[ " ${choices[*]} " =~ " 99 " ]]; then
    containers=("${sorted_keys[@]}")
  else
    for choice in "${choices[@]}"; do
      if [[ -n "${index_to_key[$choice]:-}" ]]; then
        containers+=("${index_to_key[$choice]}")
      else
        log_warning "无效选项：$choice。"
      fi
    done
  fi

  for key in "${containers[@]}"; do
    deploy_container "$key"
    sleep 1
  done
}

main