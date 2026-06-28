#!/bin/bash
# @module: docker-apps
# @name: 容器应用
# @category: 容器管理
# @depends: docker
# @depend_modules: docker-ce
# @version: 1.0.0
# @order: 52
# 功能：交互式批量安装常用 Docker 容器应用（仅 compose 方式）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查依赖
REQUIRED_CMDS=(docker curl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 Docker 或 curl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查 compose 目录
COMPOSE_DIR="${SCRIPT_DIR}/compose"
if [[ ! -d "$COMPOSE_DIR" ]]; then
  log_error "compose 目录不存在：$COMPOSE_DIR。"
  exit "${ERROR_GENERAL}"
fi

# 容器定义（内联，扩展时在此添加新条目）
declare -A container_desc=(
  ["portainer"]="Portainer"
)
declare -A container_compose=(
  ["portainer"]="portainer.yaml"
)
declare -a container_order=("portainer")

# 部署指定容器
deploy_container() {
  local key="$1"
  local yaml_file="$COMPOSE_DIR/${container_compose[$key]}"
  if ! docker ps -a --format '{{.Names}}' | grep -qw "$key"; then
    log_info "部署 ${container_desc[$key]}..."
    if [[ ! -f "$yaml_file" ]]; then
      log_error "compose 文件不存在：$yaml_file，跳过该容器。"
      return 1
    fi
    if docker compose -p "$key" -f "$yaml_file" up -d; then
      log_success "${container_desc[$key]} 就绪"
    else
      log_error "${container_desc[$key]} 失败"
      return 1
    fi
  else
    log_info "${container_desc[$key]} 已存在，跳过部署。"
  fi
  return 0
}

# 主流程（直接部署所有容器，无交互）
main() {
  log_info "部署 Docker 容器应用..."
  local failed=0
  for key in "${container_order[@]}"; do
    if ! deploy_container "$key"; then
      ((failed++))
    fi
  done

  if [[ $failed -eq 0 ]]; then
    log_success "容器应用 就绪"
  else
    log_error "${failed} 个容器失败"
    return 1
  fi
}

main "$@"