#!/bin/bash
# 功能：为 Docker 配置国内镜像加速地址（多源，自动合并，自动重启）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查依赖，确保 Docker 已安装
REQUIRED_CMDS=(docker)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 Docker。"
  exit "${ERROR_DEPENDENCY}"
fi

# 镜像加速地址列表，便于后续维护和扩展
MIRRORS=(
  "https://docker.ketches.cn"
  "https://hub.iyuu.cn"
  "https://docker.1panelproxy.com"
  "https://docker.1panel.live"
)
DAEMON_JSON="/etc/docker/daemon.json"

# 将 Bash 数组转换为 JSON 数组字符串
array_to_json_array() {
  local arr=("$@")
  local json_array="[\n"
  local len=${#arr[@]}
  for ((i = 0; i < len; i++)); do
    json_array+="    \"${arr[i]}\""
    [[ $i -lt $((len - 1)) ]] && json_array+="," 
    json_array+="\n"
  done
  json_array+="  ]"
  echo -e "$json_array"
}

# 合并并去重 registry-mirrors，优先保留已有配置
update_registry_mirrors() {
  local new_mirrors=("$@")
  local existing_mirrors=()
  if [[ -f "$DAEMON_JSON" ]]; then
    while IFS= read -r line; do
      existing_mirrors+=("${line//\"/}")
    done < <(grep -oP '"https?://[^\"]+"' "$DAEMON_JSON")
  else
    log_warning "配置文件 $DAEMON_JSON 不存在，将创建新文件。"
  fi
  local all_mirrors=("${existing_mirrors[@]}")
  for mirror in "${new_mirrors[@]}"; do
    local found=0
    for exist in "${existing_mirrors[@]}"; do
      [[ "$mirror" == "$exist" ]] && found=1 && break
    done
    [[ $found -eq 0 ]] && all_mirrors+=("$mirror")
  done
  local unique_mirrors=()
  for m in "${all_mirrors[@]}"; do
    local seen=0
    for u in "${unique_mirrors[@]}"; do
      [[ "$m" == "$u" ]] && seen=1 && break
    done
    [[ $seen -eq 0 ]] && unique_mirrors+=("$m")
  done
  local updated_mirrors_json
  updated_mirrors_json=$(array_to_json_array "${unique_mirrors[@]}")
  log_info "正在更新 Docker 镜像加速配置..."
  echo -e "{\n  \"registry-mirrors\": $updated_mirrors_json\n}" > "$DAEMON_JSON"
}

# 重启 Docker 服务，确保新配置生效
reload_and_restart_docker() {
  log_info "正在重启 Docker 服务..."
  systemctl daemon-reload
  if ! systemctl restart docker; then
    log_error "重启 Docker 服务失败，请检查 systemctl 状态或日志。"
    exit 1
  fi
}

# 主流程，自动合并镜像源并重启服务
update_registry_mirrors "${MIRRORS[@]}"
reload_and_restart_docker 
