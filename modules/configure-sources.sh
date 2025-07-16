#!/bin/bash
# 功能：配置软件源（支持自动备份原sources.list并切换为国内源）
# 参数：无（可根据需要扩展）
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 备份指定文件
backup() {
  local file="$1"
  if [ -f "$file" ]; then
    local backup_file="${file}.$(date +%F_%T).bak"
    cp "$file" "$backup_file"
    # 只保留最新3个备份
    local backups=($(ls -t ${file}.*.bak 2>/dev/null))
    local count=${#backups[@]}
    if [ $count -gt 3 ]; then
      local to_delete=$((count - 3))
      for ((i=count-1; i>=count-to_delete; i--)); do
        rm -f "${backups[$i]}"
      done
    fi
  fi
}

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查依赖
REQUIRED_CMDS=(cp mv grep sed awk apt)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_fail "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}"
  exit "${ERROR_DEPENDENCY}"
fi

# 镜像源基础URL
MIRROR="https://mirrors.tuna.tsinghua.edu.cn"

# 仅赋值 VERSION，假定环境已满足要求
VERSION="$(lsb_release -cs 2>/dev/null || echo bookworm)"

# 只处理 debian.sources
ACTIVE_SOURCE="/etc/apt/sources.list.d/debian.sources"
backup "$ACTIVE_SOURCE"
log_success "已完成软件源文件的备份"

log_action "配置 DEB822 格式软件源内容..."
cat > "$ACTIVE_SOURCE" <<EOF
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian
Suites: $VERSION $VERSION-updates $VERSION-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian-security
Suites: $VERSION-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

log_action "开始刷新软件包列表..."
apt update

log_success "软件源配置已全部完成。"
