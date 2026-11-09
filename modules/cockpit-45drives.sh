#!/bin/bash
# @module: cockpit-45drives
# @name: 安装 45Drives 扩展
# @category: 管理面板
# @depends: curl
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 31
# 功能：安装 45Drives Cockpit 扩展组件（文件共享、身份管理）
# 说明：Debian 12/13 均通过 45Drives 官方仓库安装

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 通过官方仓库安装 ====================

configure_45drives_repo() {
	local setup_url="https://repo.45drives.com/setup"
	local setup_script
	log_info "配置 45Drives 源..."

	# 已配置过 45Drives 源则不再重复执行远程脚本（幂等）
	if [[ -f /etc/apt/sources.list.d/45drives.sources || -f /etc/apt/sources.list.d/45drives.list ]]; then
		log_info "45Drives 源已存在，跳过配置"
		return 0
	fi

	if ! command -v lsb_release >/dev/null; then
		if ! apt_install_packages lsb-release; then
			log_error "lsb-release 安装失败。"
			return 1
		fi
	fi

	# 先完整下载到临时文件（-f：HTTP 错误不把错误页当脚本执行；避免管道截断后半截执行），
	# 仅允许 HTTPS，下载失败或脚本执行失败均视为失败，不再吞掉错误
	setup_script=$(create_temp_file "45drives-setup" ".sh") || return 1
	if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 --connect-timeout 15 \
		-o "$setup_script" "$setup_url"; then
		log_error "45Drives 安装脚本下载失败：${setup_url}"
		return 1
	fi
	if [[ ! -s "$setup_script" ]]; then
		log_error "45Drives 安装脚本为空，已中止"
		return 1
	fi
	log_warning "即将以 root 执行 45Drives 官方安装脚本：${setup_url}"
	if ! bash "$setup_script"; then
		log_error "45Drives 软件源配置失败。"
		return 1
	fi
}

install_45drives_components_repo() {
	log_info "通过源安装 45Drives 组件..."
	if ! apt_install_packages cockpit-file-sharing cockpit-identities; then
		log_error "45Drives Cockpit 组件安装失败。"
		return 1
	fi
}

# ==================== 主入口 ====================

main() {
	local system_codename
	system_codename=$(get_system_codename)

	log_info "检测到系统版本: ${system_codename}"

	case "${system_codename}" in
	"bookworm"|"trixie")
		log_info "Debian ${system_codename}: 45Drives 仓库"
		configure_45drives_repo
		install_45drives_components_repo
		;;
	*)
		log_error "不支持的 Debian 版本: ${system_codename}"
		log_error "仅支持 Debian 12 (bookworm) 和 Debian 13 (trixie)"
		exit "${ERROR_UNSUPPORTED_OS}"
		;;
	esac

}

main "$@"
