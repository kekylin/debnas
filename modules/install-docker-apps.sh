#!/bin/bash
# 功能：交互式批量安装常用 Docker 容器应用（仅 compose 方式）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/lib/core/constants.sh"
source "${PROJECT_ROOT}/lib/core/logging.sh"
source "${PROJECT_ROOT}/lib/system/dependency.sh"

# 检查 docker、curl 依赖，确保后续操作可用
REQUIRED_CMDS=(docker curl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 Docker 或 curl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 获取 compose 目录，确保容器编排文件存在
COMPOSE_DIR="${PROJECT_ROOT}/docker-compose"
if [[ ! -d "$COMPOSE_DIR" ]]; then
  log_error "compose 目录不存在：$COMPOSE_DIR。"
  exit 1
fi

# 容器配置（名称、描述、compose 文件名）
declare -A container_desc=(
  [ddns-go]="DDNS-GO"
  [dockge]="Dockge"
  [nginx-ui]="Nginx UI"
  [portainer_zh-cn]="Portainer 中文版"
  [scrutiny]="Scrutiny"
  [dweebui]="DweebUI"
  [portainer_compose]="Portainer"
)
declare -A container_compose=(
  [ddns-go]="ddns-go.yaml"
  [dockge]="dockge.yaml"
  [nginx-ui]="nginx-ui.yaml"
  [portainer_zh-cn]="portainer_zh-cn.yaml"
  [scrutiny]="scrutiny.yaml"
  [dweebui]="dweebui.yaml"
  [portainer_compose]="portainer.yaml"
)

# 显示容器应用菜单，便于用户选择
show_container_menu() {
  echo "---------------- 容器应用安装 ----------------"
  local idx=1
  for key in ddns-go dockge nginx-ui portainer_zh-cn scrutiny dweebui portainer_compose; do
    echo "$idx、${container_desc[$key]}"
    idx=$((idx+1))
  done
  echo "99、全部安装"
  echo "0、返回"
  echo "支持多选，空格分隔，如：1 2 3"
  echo -n "请选择编号: "
}

# 部署指定容器，自动检测是否已存在
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

# 主流程，处理用户选择并批量部署
main() {
  show_container_menu
  read -r -a choices
  if [[ " ${choices[*]} " =~ " 0 " ]]; then
    return 0
  fi
  if [[ " ${choices[*]} " =~ " 99 " ]]; then
    choices=(1 2 3 4 5 6 7)
  fi
  for choice in "${choices[@]}"; do
    case $choice in
      1) deploy_container ddns-go ;;
      2) deploy_container dockge ;;
      3) deploy_container nginx-ui ;;
      4) deploy_container portainer_zh-cn ;;
      5) deploy_container scrutiny ;;
      6) deploy_container dweebui ;;
      7) deploy_container portainer_compose ;;
      *) log_warn "无效选项：$choice。" ;;
    esac
    sleep 1
  done
}

main
