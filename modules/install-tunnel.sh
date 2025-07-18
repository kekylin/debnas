#!/bin/bash
# 功能：安装并配置 Tailscale 内网穿透服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"

# 检查 curl、apt、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(curl apt systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_fail "缺少 curl、apt 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性，防止在不支持的平台运行
if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

log_action "开始安装 Tailscale..."

# 添加 Tailscale 的包签名密钥和存储库，确保软件源可信
log_action "添加 Tailscale 密钥和存储库..."
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

# 安装 Tailscale，保障内网穿透能力
apt update
log_action "安装 Tailscale..."
apt install -y tailscale

# 提示用户启动 Tailscale 并进行身份验证
log_action "请运行以下命令启动 Tailscale，并复制输出的链接到浏览器完成身份验证："
echo ""
log_action "启动命令：tailscale up"
echo ""

