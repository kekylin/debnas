#!/bin/bash
# 功能：安装 Cockpit 面板

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查 apt、curl、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(apt curl systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 apt、curl 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 读取系统信息，默认 Debian
. /etc/os-release
SYSTEM_NAME="Debian"

# 配置 45Drives 软件源，便于后续安装 Cockpit 组件
log_info "正在配置 45Drives 软件源..."
if ! command -v lsb_release >/dev/null; then
  if ! apt install -y lsb-release; then
    log_error "lsb-release 安装失败。"
    exit "${ERROR_DEPENDENCY}"
  fi
fi

if ! curl -sSL https://repo.45drives.com/setup | bash; then
  if [ ! -f /etc/apt/sources.list.d/45drives.sources ]; then
    log_error "45Drives 软件源配置失败。"
    exit "${ERROR_GENERAL}"
  fi
fi

if ! apt update; then
  log_error "软件源更新失败。"
  exit "${ERROR_GENERAL}"
fi

# 安装 Cockpit 及其常用组件，提升系统管理能力
log_info "正在安装 Cockpit 及其组件..."
if ! apt install -y -t ${VERSION_CODENAME}-backports \
    cockpit pcp python3-pcp cockpit-navigator cockpit-file-sharing cockpit-identities \
    tuned; then
  log_error "Cockpit 及其组件安装失败。"
  exit "${ERROR_GENERAL}"
fi

# 创建 Cockpit 配置目录
mkdir -p /etc/cockpit

# 写入 Cockpit 配置文件，设置会话超时与登录信息
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

# 写入 motd 文件，规范登录提示，强化安全意识
cat > "/etc/motd" << 'EOF'
我们信任您已经从系统管理员那里了解了日常注意事项。
总结起来无外乎这三点：
1、尊重别人的隐私；
2、输入前要先考虑（后果和风险）；
3、权力越大，责任越大。
EOF

# 写入 Cockpit 欢迎信息，便于用户识别平台
cat > "/etc/cockpit/issue.cockpit" << EOF
基于${SYSTEM_NAME}搭建 HomeNAS
EOF

# 重启 Cockpit 服务，确保配置生效
if ! systemctl try-restart cockpit; then
  log_error "Cockpit 服务重启失败。"
  exit "${ERROR_GENERAL}"
fi
