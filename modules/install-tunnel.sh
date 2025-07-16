#!/bin/bash
# 功能：安装并配置 Tailscale 内网穿透服务
# 参数：无
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
source "${SCRIPT_DIR}/lib/system/utils.sh"

# 检查依赖
REQUIRED_CMDS=(curl apt systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_fail "依赖缺失，请先安装 curl、apt、systemctl"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统类型
if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

log_action "开始安装 Tailscale ..."

# 添加Tailscale的包签名密钥和存储库
log_action "添加Tailscale密钥和存储库..."
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

# 安装Tailscale
apt update
log_action "安装Tailscale..."
apt install -y tailscale

# 连接到Tailscale网络
log_action "运行以下命令启动Tailscale，复制输出的链接到浏览器中打开进行身份验证："
echo ""  # 添加空行
log_action "启动命令: tailscale up"
echo ""  # 添加空行

log_success "Tailscale 安装和配置已全部完成。"
