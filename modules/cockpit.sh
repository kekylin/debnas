#!/bin/bash
# @module: cockpit
# @name: Cockpit 面板
# @category: 管理面板
# @depends: curl
# @version: 4.0.0
# @order: 30
# 功能：安装 Cockpit 核心组件（从 backports 获取最新版本）
# 说明：45Drives 扩展组件已剥离至独立模块 cockpit-45drives，按需安装。

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== Cockpit 核心安装 ====================

install_core_cockpit_packages() {
	log_info "安装 Cockpit 核心组件..."

	local -a pkgs=(cockpit cockpit-files pcp python3-pcp tuned)

	# APT Pinning 已配置 ${codename}-backports 优先级 500，无需手动指定 -t
	if ! apt_install_packages "${pkgs[@]}"; then
		log_error "Cockpit 组件安装失败。"
		return 1
	fi

	log_success "Cockpit 核心就绪"
}

# ==================== Cockpit 运行时配置 ====================

configure_cockpit_runtime_files() {
	local system_name="$1"
	local config_changed=0

	local cockpit_conf="[Session]
IdleTimeout=15
Banner=/etc/cockpit/issue.cockpit

[WebService]
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
LoginTo = false
LoginTitle = HomeNAS"
	if write_file_if_changed "/etc/cockpit/cockpit.conf" "$cockpit_conf"; then
		config_changed=1
	fi

	local motd_content="我们信任您已经从系统管理员那里了解了日常注意事项。
总结起来无外乎这三点：
1、尊重别人的隐私；
2、输入前要先考虑（后果和风险）；
3、权力越大，责任越大。"
	if write_file_if_changed "/etc/motd" "$motd_content"; then
		config_changed=1
	fi

	local issue_content="基于${system_name}搭建 HomeNAS"
	if write_file_if_changed "/etc/cockpit/issue.cockpit" "$issue_content"; then
		config_changed=1
	fi

	printf '%d' "$config_changed"
}

# ==================== 主入口 ====================

main() {
	local system_name system_codename
	system_name=$(get_system_name)
	system_codename=$(get_system_codename)

	log_debug "${system_name} ${system_codename}"

	case "${system_codename}" in
	"bookworm"|"trixie")
		;;
	*)
		log_error "不支持的 Debian 版本: ${system_codename}"
		log_error "仅支持 Debian 12 (bookworm) 和 Debian 13 (trixie)"
		exit "${ERROR_UNSUPPORTED_OS}"
		;;
	esac

	# APT Pinning：确保 cockpit 从 backports 安装最新版
	if ! configure_cockpit_pinning "${system_codename}"; then
		log_error "APT Pinning 配置失败。"
		exit "${ERROR_GENERAL}"
	fi
	if ! apply_pinning_config; then
		log_error "APT Pinning 配置应用失败。"
		exit "${ERROR_GENERAL}"
	fi

	# 安装核心包
	install_core_cockpit_packages

	# 运行时配置
	local config_changed
	config_changed=$(configure_cockpit_runtime_files "${system_name}")

	if [[ "$config_changed" -eq 1 ]]; then
		if ! service_ensure "cockpit" "restarted"; then
			log_error "Cockpit 服务重启失败。"
			exit "${ERROR_GENERAL}"
		fi
	else
		if ! service_ensure "cockpit" "started"; then
			log_error "Cockpit 服务启动失败。"
			exit "${ERROR_GENERAL}"
		fi
	fi
}

main "$@"
