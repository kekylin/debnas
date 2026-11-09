#!/bin/bash
# @module: docker-apps
# @name: 部署容器应用
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

# compose 应用目录（依赖检查与目录存在性检查在 main 中进行，加载/只读探测阶段无副作用）
COMPOSE_DIR="${SCRIPT_DIR}/compose"
REQUIRED_CMDS=(docker curl)

# 自动发现 compose 目录下的容器应用
# 约定：compose/<key>.yaml（或 .yml），文件名即容器 key
# 可选元数据（YAML 注释）：
#   # @name: 显示名称
#   # @description: 简要描述
#   # @category: 分类标签
#   # @require: 前置依赖容器 key（逗号或空格分隔）
discover_containers() {
  CONTAINER_KEYS=()
  declare -g -A CONTAINER_NAMES=()
  declare -g -A CONTAINER_FILES=()
  declare -g -A CONTAINER_DESCRIPTIONS=()
  declare -g -A CONTAINER_CATEGORIES=()
  declare -g -A CONTAINER_REQUIRES=()

  local yaml_file key display_name desc cat require
  for yaml_file in "$COMPOSE_DIR"/*.yaml "$COMPOSE_DIR"/*.yml; do
    [[ -f "$yaml_file" ]] || continue
    key=$(basename "$yaml_file" | sed 's/\.\(yaml\|yml\)$//')
    # 尝试从 YAML 文件头部注释提取元数据
    display_name=$(grep -m1 '^# *@name:' "$yaml_file" 2>/dev/null | sed 's/^# *@name: *//' || true)
    desc=$(grep -m1 '^# *@description:' "$yaml_file" 2>/dev/null | sed 's/^# *@description: *//' || true)
    cat=$(grep -m1 '^# *@category:' "$yaml_file" 2>/dev/null | sed 's/^# *@category: *//' || true)
    require=$(grep -m1 '^# *@require:' "$yaml_file" 2>/dev/null | sed 's/^# *@require: *//' || true)
    if [[ -z "$display_name" ]]; then
      display_name="${key^}"
    fi
    CONTAINER_KEYS+=("$key")
    CONTAINER_NAMES["$key"]="$display_name"
    CONTAINER_FILES["$key"]="$(basename "$yaml_file")"
    CONTAINER_DESCRIPTIONS["$key"]="$desc"
    CONTAINER_CATEGORIES["$key"]="$cat"
    CONTAINER_REQUIRES["$key"]="$require"
  done
}

# 递归部署追踪栈（全局，用于循环依赖检测）
declare -g -A _DEPLOY_STACK=()

# 部署指定容器（含描述输出与递归依赖解析）
deploy_container() {
  local key="$1"

  # 循环依赖检测
  if [[ -n "${_DEPLOY_STACK[$key]:-}" ]]; then
    log_error "${CONTAINER_NAMES[$key]}: 检测到循环依赖，跳过。"
    return 1
  fi
  _DEPLOY_STACK["$key"]=1

  # 解析 @require 前置依赖，递归部署
  local requires="${CONTAINER_REQUIRES[$key]:-}"
  if [[ -n "$requires" ]]; then
    local -a dep_list=()
    local dep
    IFS=', ' read -ra dep_list <<< "$requires"
    for dep in "${dep_list[@]}"; do
      [[ -z "$dep" ]] && continue
      if [[ -n "${CONTAINER_FILES[$dep]:-}" ]]; then
        deploy_container "$dep" || log_warning "${CONTAINER_NAMES[$key]}: 依赖 ${dep} 部署失败"
      else
        log_warning "${CONTAINER_NAMES[$key]}: 未知依赖 ${dep}，跳过。"
      fi
    done
  fi

  local yaml_file="$COMPOSE_DIR/${CONTAINER_FILES[$key]}"
  if ! docker ps -a --format '{{.Names}}' | grep -qxF "$key"; then
    local desc="${CONTAINER_DESCRIPTIONS[$key]:-}"
    if [[ -n "$desc" ]]; then
      log_info "${CONTAINER_NAMES[$key]}: ${desc}"
    fi
    log_info "部署 ${CONTAINER_NAMES[$key]}..."
    if [[ ! -f "$yaml_file" ]]; then
      log_error "compose 文件不存在：$yaml_file，跳过该容器。"
      unset "_DEPLOY_STACK[$key]"
      return 1
    fi
    if docker compose -p "$key" -f "$yaml_file" up -d; then
      log_success "${CONTAINER_NAMES[$key]} 就绪"
    else
      log_error "${CONTAINER_NAMES[$key]} 失败"
      unset "_DEPLOY_STACK[$key]"
      return 1
    fi
  else
    log_info "${CONTAINER_NAMES[$key]} 已存在，跳过部署。"
  fi

  unset "_DEPLOY_STACK[$key]"
  return 0
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 列出 compose 应用文件（每行一个绝对路径）
_da_compose_files() {
  local f
  [[ -d "$COMPOSE_DIR" ]] || return 0
  for f in "$COMPOSE_DIR"/*.yaml "$COMPOSE_DIR"/*.yml; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# compose 文件对应的 key（文件名去扩展名，与 discover_containers 一致）
_da_key() {
  local base
  base=$(basename "$1")
  base="${base%.yaml}"
  printf '%s' "${base%.yml}"
}

# compose 文件中的显示名（@name，缺省为 key 首字母大写）
_da_display_name() {
  local file="$1" key="$2" name
  name=$(grep -m1 '^# *@name:' "$file" 2>/dev/null | sed 's/^# *@name: *//' || true)
  printf '%s' "${name:-${key^}}"
}

# compose 文件发布到宿主机的端口（每行 "端口/协议"，读取短格式 ports 与长格式 published）
_da_host_ports() {
  local file="$1" p
  {
    sed -nE 's/^[[:space:]]*-[[:space:]]*["'"'"']?(([0-9.]+|\[[0-9a-fA-F:]+\]):)?([0-9]+(-[0-9]+)?):[0-9]+(-[0-9]+)?(\/(tcp|udp))?["'"'"']?[[:space:]]*(#.*)?$/\3\6/p' "$file" 2>/dev/null
    sed -nE 's/^[[:space:]]*published:[[:space:]]*["'"'"']?([0-9]+(-[0-9]+)?)["'"'"']?[[:space:]]*(#.*)?$/\1/p' "$file" 2>/dev/null
  } | while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" == */* ]] || p="${p}/tcp"
    printf '%s\n' "$p"
  done | awk '!seen[$0]++'
}

# 全部容器的 "名称 状态"（docker 不可用/无权限时返回 1）
_da_container_states() {
  command -v docker >/dev/null 2>&1 || return 1
  timeout 2 docker ps -a --format '{{.Names}} {{.State}}' 2>/dev/null
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local IFS=$' \n\t'
  local files states file key state
  local -a running=() stopped=() missing=()
  if ! command -v docker >/dev/null 2>&1; then
    echo "absent|未安装 Docker"
    return 0
  fi
  files=$(_da_compose_files)
  if [[ -z "$files" ]]; then
    echo "unknown|compose 目录下没有应用定义"
    return 0
  fi
  if ! states=$(_da_container_states); then
    echo "unknown|无法查询容器（需 root 或 docker 组权限）"
    return 0
  fi
  while IFS= read -r file; do
    key=$(_da_key "$file")
    state=$(awk -v k="$key" '$1 == k { print $2; exit }' <<< "$states")
    case "$state" in
      running) running+=("$key") ;;
      "")      missing+=("$key") ;;
      *)       stopped+=("${key}(${state})") ;;
    esac
  done <<< "$files"
  local total=$(( ${#running[@]} + ${#stopped[@]} + ${#missing[@]} ))
  if [[ ${#stopped[@]} -gt 0 ]]; then
    echo "warn|${#running[@]}/${total} 运行中，未运行：${stopped[*]}"
  elif [[ ${#missing[@]} -eq 0 ]]; then
    echo "running|${total}/${total} 个应用运行中：${running[*]}"
  elif [[ ${#running[@]} -eq 0 ]]; then
    echo "absent|未部署：${missing[*]}"
  else
    echo "partial|${#running[@]}/${total} 运行中，未部署：${missing[*]}"
  fi
}

# 预演：每行 "类型|目标|备注"（端口/风险均从 compose 文件读取）
module_plan() {
  local IFS=$' \n\t'
  local files states="" can_query=1 file key name image ports note
  if ! command -v docker >/dev/null 2>&1; then
    echo "info|docker|未安装 Docker，执行时会直接失败（请先运行 docker-ce 模块）"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || echo "info|curl|未安装 curl，执行时依赖检查失败退出"
  files=$(_da_compose_files)
  if [[ -z "$files" ]]; then
    echo "info|${COMPOSE_DIR}|没有 compose 应用定义，执行时不做任何事"
    return 0
  fi
  states=$(_da_container_states) || can_query=0
  [[ $can_query -eq 1 ]] || echo "info|容器|无法查询已有容器（需 root 或 docker 组），以下按未部署列出，执行时已存在的会跳过"

  while IFS= read -r file; do
    key=$(_da_key "$file")
    name=$(_da_display_name "$file" "$key")
    if [[ $can_query -eq 1 ]] && awk -v k="$key" '$1 == k { f = 1 } END { exit !f }' <<< "$states"; then
      echo "info|${name}|容器 ${key} 已存在，跳过部署"
      continue
    fi
    image=$(grep -m1 -E '^[[:space:]]*image:' "$file" 2>/dev/null | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/["'"'"']//g' || true)
    echo "service|${key}|docker compose up -d 部署 ${name}（compose/$(basename "$file")${image:+，镜像 ${image}}，需联网拉取）"
    ports=$(_da_host_ports "$file")
    if [[ -n "$ports" ]]; then
      echo "port|$(tr '\n' ' ' <<< "$ports" | sed 's/ $//')|${name} 发布到宿主机（Docker 自行放行，不受 firewalld public 区限制）"
    fi
    if grep -qE '^[[:space:]]*-[[:space:]]*["'"'"']?/var/run/docker\.sock:' "$file" 2>/dev/null; then
      echo "risk|${name}|挂载 /var/run/docker.sock，容器拥有等同 root 的 Docker 控制权"
    fi
    note=$(grep -m1 '首次访问' "$file" 2>/dev/null | sed -E 's/^[[:space:]]*#[[:space:]]*//; s/^注意[：:][[:space:]]*//' || true)
    [[ -n "$note" ]] && echo "risk|${name}|${note}"
  done <<< "$files"
  return 0
}

# 主流程（直接部署所有容器，无交互）
main() {
  # 检查依赖
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "缺少 Docker 或 curl，请先手动安装。"
    exit "${ERROR_DEPENDENCY}"
  fi

  # 检查 compose 目录
  if [[ ! -d "$COMPOSE_DIR" ]]; then
    log_error "compose 目录不存在：$COMPOSE_DIR。"
    exit "${ERROR_GENERAL}"
  fi

  discover_containers

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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
