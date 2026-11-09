#!/bin/bash
# @module: docker-mirror
# @name: 配置镜像加速
# @category: 容器管理
# @depends: docker
# @depend_modules: docker-ce
# @version: 1.0.0
# @order: 51
# 功能：为 Docker 配置国内镜像加速地址（多源，自动合并，自动重启）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 从统一配置库获取 Docker 镜像加速地址
DOCKER_MIRRORS=("${DOCKER_REGISTRY_MIRRORS[@]}")

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

# 合并并去重 registry-mirrors，优先保留已有配置，返回最终 JSON 内容
# 说明：
#   - 只合并 daemon.json 中 "registry-mirrors" 键，不再把 proxies 等其他 URL 误当镜像源
#   - 已有 daemon.json 一律用 jq 解析合并，保留 data-root 等其他配置项；
#     JSON 不合法或无法解析时返回失败，绝不整体覆盖用户配置
build_merged_daemon_json() {
  local new_mirrors=("$@")

  log_info "构建 Docker 镜像加速配置..."

  if [[ ! -s "$DAEMON_JSON" ]]; then
    log_warning "配置文件 $DAEMON_JSON 不存在或为空，将创建新文件。"
    local mirrors_json
    mirrors_json=$(array_to_json_array "${new_mirrors[@]}")
    printf '{\n  "registry-mirrors": %s\n}\n' "$mirrors_json"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1 && ! apt_install_packages jq >&2; then
    log_error "缺少 jq，无法安全合并已有的 $DAEMON_JSON，已跳过（未修改）"
    return 1
  fi

  # 已有镜像在前、新镜像追加在后，按首次出现去重（不排序）
  if ! jq --indent 2 '
    if type != "object" then error("daemon.json 顶层不是对象") else . end
    | .["registry-mirrors"] = (((.["registry-mirrors"] // []) + $ARGS.positional)
        | reduce .[] as $m ([]; if index([$m]) != null then . else . + [$m] end))
  ' "$DAEMON_JSON" --args "${new_mirrors[@]}"; then
    log_error "$DAEMON_JSON 不是合法 JSON，已跳过（未修改），请手动修正后重试"
    return 1
  fi
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 输出 daemon.json 中已配置的 registry-mirrors（每行一个；无 jq 时按文本粗略提取）
_dm_configured_mirrors() {
  [[ -r "$DAEMON_JSON" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.["registry-mirrors"] // [])[]? | strings' "$DAEMON_JSON" 2>/dev/null || true
  else
    tr -d '\n' < "$DAEMON_JSON" 2>/dev/null \
      | grep -o '"registry-mirrors"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
      | grep -o '"[a-z]*://[^"]*"' | tr -d '"' || true
  fi
}

# daemon.json 是否为合法 JSON 对象（无 jq 时视为合法，无法判断）
_dm_json_valid() {
  command -v jq >/dev/null 2>&1 || return 0
  jq -e 'type == "object"' "$DAEMON_JSON" >/dev/null 2>&1
}

# DebNAS 加速源中尚未配置的（每行一个）
_dm_missing_mirrors() {
  local configured m
  configured=$(_dm_configured_mirrors)
  for m in "${DOCKER_MIRRORS[@]}"; do
    grep -qxF -- "$m" <<< "$configured" || printf '%s\n' "$m"
  done
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local configured missing n_all=0 n_missing=0 total=${#DOCKER_MIRRORS[@]}
  if ! command -v docker >/dev/null 2>&1; then
    echo "absent|未安装 Docker"
    return 0
  fi
  if [[ ! -s "$DAEMON_JSON" ]]; then
    echo "absent|未配置镜像加速（无 ${DAEMON_JSON}）"
    return 0
  fi
  if [[ ! -r "$DAEMON_JSON" ]]; then
    echo "unknown|无权限读取 ${DAEMON_JSON}"
    return 0
  fi
  if ! _dm_json_valid; then
    echo "error|${DAEMON_JSON} 不是合法 JSON 对象，执行时会跳过"
    return 0
  fi
  configured=$(_dm_configured_mirrors)
  [[ -n "$configured" ]] && n_all=$(grep -c . <<< "$configured")
  missing=$(_dm_missing_mirrors)
  [[ -n "$missing" ]] && n_missing=$(grep -c . <<< "$missing")
  if [[ $n_all -eq 0 ]]; then
    echo "absent|daemon.json 未含 registry-mirrors"
  elif [[ $n_missing -eq 0 ]]; then
    echo "applied|已配置 ${n_all} 个加速源（含 DebNAS 默认 ${total} 个）"
  else
    echo "partial|已有 ${n_all} 个加速源，缺 DebNAS 默认 ${n_missing}/${total} 个"
  fi
}

# 预演：每行 "类型|目标|备注"
module_plan() {
  local IFS=$' \n\t'
  local missing
  if ! command -v docker >/dev/null 2>&1; then
    echo "info|docker|未安装 Docker，执行时会直接失败（请先运行 docker-ce 模块）"
    return 0
  fi
  if [[ ! -s "$DAEMON_JSON" ]]; then
    echo "write|${DAEMON_JSON}|新建，写入 registry-mirrors：${DOCKER_MIRRORS[*]}"
  elif [[ ! -r "$DAEMON_JSON" ]]; then
    command -v jq >/dev/null 2>&1 || echo "pkg|jq|合并已有 daemon.json 需要"
    echo "write|${DAEMON_JSON}|无权限预读；执行时 jq 合并 registry-mirrors（保留其他键），内容变化时旧文件备份到 /var/backups/debnas/"
  elif ! _dm_json_valid; then
    echo "risk|${DAEMON_JSON}|不是合法 JSON 对象，执行时跳过且模块报错，需先手动修正"
    return 0
  else
    command -v jq >/dev/null 2>&1 || echo "pkg|jq|合并已有 daemon.json 需要"
    missing=$(_dm_missing_mirrors)
    if [[ -z "$missing" ]]; then
      echo "info|${DAEMON_JSON}|DebNAS 加速源均已配置，不改动、不重启 Docker"
      return 0
    fi
    echo "write|${DAEMON_JSON}|jq 合并追加 $(tr '\n' ' ' <<< "$missing" | sed 's/ $//')（保留已有镜像与其他键）；旧文件备份到 /var/backups/debnas/"
  fi
  echo "service|docker|配置变化时重启 Docker"
  echo "risk|Docker 重启|运行中的容器会被停止，按各自 restart 策略恢复"
  echo "risk|第三方加速源|${DOCKER_MIRRORS[*]} 为第三方服务，拉取的镜像内容由其提供"
  return 0
}

main() {
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查依赖，确保 Docker 已安装
REQUIRED_CMDS=(docker)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 Docker。"
  exit "${ERROR_DEPENDENCY}"
fi

# 主流程：构建配置、智能写入、按需重启
log_warning "镜像加速地址为第三方服务（$(printf "%s " "${DOCKER_MIRRORS[@]}")），拉取的镜像内容由其提供，请按需评估"
if ! new_content=$(build_merged_daemon_json "${DOCKER_MIRRORS[@]}"); then
  exit "${ERROR_GENERAL}"
fi

# daemon.json 变更只需重启 docker，无需 systemctl daemon-reload（未修改 unit 文件）
if write_file_if_changed "$DAEMON_JSON" "$new_content"; then
  log_info "重启 Docker 服务以应用配置..."
  if ! service_ensure docker restarted; then
    log_error "重启 Docker 服务失败，请检查 systemctl 状态或日志。"
    exit "${ERROR_GENERAL}"
  fi
  log_success "镜像加速 就绪"
else
  log_info "镜像加速配置未变"
fi


}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
