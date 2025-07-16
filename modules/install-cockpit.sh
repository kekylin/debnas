#!/bin/bash
# 功能：安装 Cockpit 面板
# 参数：无（可根据需要扩展）
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

# 检查依赖
REQUIRED_CMDS=(apt curl systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 apt、curl、systemctl"
  exit "${ERROR_DEPENDENCY}"
fi

# 检测系统类型，默认Debian
. /etc/os-release
SYSTEM_NAME="Debian"

# 配置45Drives软件源
log_info "配置45Drives软件源..."
if ! command -v lsb_release >/dev/null; then
  if ! apt install -y lsb-release; then
    log_error "无法安装lsb-release"
    exit "${ERROR_DEPENDENCY}"
  fi
fi

if ! curl -sSL https://repo.45drives.com/setup | bash; then
  if [ ! -f /etc/apt/sources.list.d/45drives.sources ]; then
    log_error "45Drives软件源配置失败"
    exit "${ERROR_GENERAL}"
  fi
fi

if ! apt update; then
  log_error "软件源更新失败"
  exit "${ERROR_GENERAL}"
fi

# 安装Cockpit及其组件
log_info "安装Cockpit及其组件..."
if ! apt install -y -t ${VERSION_CODENAME}-backports \
    cockpit pcp python3-pcp cockpit-navigator cockpit-file-sharing cockpit-identities \
    tuned; then
  log_error "Cockpit及其组件安装失败"
  exit "${ERROR_GENERAL}"
fi

# Cockpit调优
mkdir -p /etc/cockpit

# 写入cockpit配置文件
cat > "/etc/cockpit/cockpit.conf" << 'EOF'
[Session]
IdleTimeout=15
Banner=/etc/cockpit/issue.cockpit

[WebService]
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
LoginTo = false
LoginTitle = HomeNAS
EOF

# 写入motd文件
cat > "/etc/motd" << 'EOF'
我们信任您已经从系统管理员那里了解了日常注意事项。
总结起来无外乎这三点：
1、尊重别人的隐私；
2、输入前要先考虑（后果和风险）；
3、权力越大，责任越大。
EOF

# 写入cockpit欢迎信息
cat > "/etc/cockpit/issue.cockpit" << EOF
基于${SYSTEM_NAME}搭建HomeNAS
EOF

# 重启服务
if ! systemctl try-restart cockpit; then
  log_error "Cockpit服务重启失败"
  exit "${ERROR_GENERAL}"
fi
