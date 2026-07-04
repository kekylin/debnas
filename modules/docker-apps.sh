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

# 自动发现 compose 目录下的容器应用
# 约定：compose/<key>.yaml（或 .yml），文件名即容器 key
# 可选元数据（YAML 注释）：# @name: 显示名称
discover_containers() {
  CONTAINER_KEYS=()
  declare -g -A CONTAINER_NAMES=()
  declare -g -A CONTAINER_FILES=()

  local yaml_file key display_name
  for yaml_file in "$COMPOSE_DIR"/*.yaml "$COMPOSE_DIR"/*.yml; do
    [[ -f "$yaml_file" ]] || continue
    key=$(basename "$yaml_file" | sed 's/\.\(yaml\|yml\)$//')
    # 尝试从 YAML 文件头部注释提取显示名称
    display_name=$(grep -m1 '^# *@name:' "$yaml_file" 2>/dev/null | sed 's/^# *@name: *//' || true)
    if [[ -z "$display_name" ]]; then
      display_name="${key^}"
    fi
    CONTAINER_KEYS+=("$key")
    CONTAINER_NAMES["$key"]="$display_name"
    CONTAINER_FILES["$key"]="$(basename "$yaml_file")"
  done
}

discover_containers

# 部署指定容器
deploy_container() {
  local key="$1"
  local yaml_file="$COMPOSE_DIR/${CONTAINER_FILES[$key]}"
  if ! docker ps -a --format '{{.Names}}' | grep -qw "$key"; then
    log_info "部署 ${CONTAINER_NAMES[$key]}..."
    if [[ ! -f "$yaml_file" ]]; then
      log_error "compose 文件不存在：$yaml_file，跳过该容器。"
      return 1
    fi
    if docker compose -p "$key" -f "$yaml_file" up -d; then
      log_success "${CONTAINER_NAMES[$key]} 就绪"
    else
      log_error "${CONTAINER_NAMES[$key]} 失败"
      return 1
    fi
  else
    log_info "${CONTAINER_NAMES[$key]} 已存在，跳过部署。"
  fi
  return 0
}

# 主流程（直接部署所有容器，无交互）
main() {
  log_info "部署 Docker 容器应用..."
  local failed=0
  for key in "${CONTAINER_KEYS[@]}"; do
    if ! deploy_container "$key"; then
      ((failed++)) || true
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