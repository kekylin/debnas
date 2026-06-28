#!/bin/bash
# @module: tailscale
# @name: Tailscale
# @category: 系统工具
# @depends: curl
# @version: 1.0.0
# @order: 74
# 功能：安装并配置 Tailscale 内网穿透服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
main() {
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查 curl、apt、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(curl apt systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 curl、apt 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性，防止在不支持的平台运行
if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

# 动态获取系统代号，避免硬编码导致跨版本不兼容
CODENAME=$(get_system_codename)
if [[ -z "${CODENAME}" ]]; then
  log_error "无法获取系统版本代号。"
  exit "${ERROR_GENERAL}"
fi

log_info "安装 Tailscale..."

# 添加 Tailscale 的包签名密钥和存储库，确保软件源可信
log_info "配置 Tailscale 源..."
curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
  | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list" \
  | tee /etc/apt/sources.list.d/tailscale.list

# 安装 Tailscale
log_info "安装 Tailscale 组件..."
apt_install_packages tailscale

# 提示用户启动 Tailscale 并进行身份验证
log_info "请运行以下命令启动 Tailscale 并完成身份验证："
echo ""
log_info "  tailscale up"
echo ""



}

main "$@"
