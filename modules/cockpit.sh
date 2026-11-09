#!/bin/bash
# @module: cockpit
# @name: 安装 Cockpit 面板
# @category: 管理面板
# @depends: curl
# @version: 4.0.0
# @order: 30
# 功能：安装 Cockpit 核心组件（从 backports 获取最新版本）
# 说明：共享管理面板由 cockpit-shares 模块安装（按 debnas.conf 的 file_sharing_ui 选择 DebNAS 自研插件或 45Drives 扩展，二选一）。

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

	# 旧版本写入的内容（用于识别可安全迁移的 DebNAS 生成文件）
	local legacy_conf="[Session]
IdleTimeout=15
Banner=/etc/cockpit/issue.cockpit

[WebService]
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
LoginTo = false
LoginTitle = DebNAS"
	local marker="# 由 DebNAS 管理：如需自定义请删除本行，DebNAS 将不再覆盖此文件"

	# 信任 X-Forwarded-* 头只在 Cockpit 位于反向代理之后才安全；直连时客户端可伪造
	# 来源 IP/协议。默认不写，需要时在 /etc/debnas/debnas.conf 设置 cockpit_behind_proxy=1
	local proxy_headers=""
	if [[ "$(config_read "global" "cockpit_behind_proxy" "0" 2>/dev/null || echo 0)" == "1" ]]; then
		proxy_headers="ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
"
	fi

	local cockpit_conf="${marker}
[Session]
IdleTimeout=15
Banner=/etc/cockpit/issue.cockpit

[WebService]
${proxy_headers}LoginTo = false
LoginTitle = DebNAS"

	# 仅在文件不存在、由 DebNAS 管理或为旧版生成内容时写入，避免冲掉用户自定义配置
	local conf_path="/etc/cockpit/cockpit.conf"
	local current_conf=""
	[[ -f "$conf_path" ]] && current_conf=$(cat "$conf_path" 2>/dev/null || true)
	if [[ ! -f "$conf_path" ]] || [[ "$current_conf" == "$legacy_conf" ]] \
		|| grep -qxF "$marker" "$conf_path" 2>/dev/null; then
		if write_file_if_changed "$conf_path" "$cockpit_conf"; then
			config_changed=1
		fi
	else
		log_warning "${conf_path} 已被用户自定义，跳过覆盖（如需恢复默认请删除该文件后重新运行）"
	fi

	local motd_content="我们信任您已经从系统管理员那里了解了日常注意事项。
总结起来无外乎这三点：
1、尊重别人的隐私；
2、输入前要先考虑（后果和风险）；
3、权力越大，责任越大。"
	if write_file_if_changed "/etc/motd" "$motd_content"; then
		config_changed=1
	fi

	local issue_content="基于${system_name}搭建 DebNAS"
	if write_file_if_changed "/etc/cockpit/issue.cockpit" "$issue_content"; then
		config_changed=1
	fi

	printf '%d' "$config_changed"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 与 configure_cockpit_runtime_files 中的标记行保持一致
COCKPIT_CONF_MARKER="# 由 DebNAS 管理：如需自定义请删除本行，DebNAS 将不再覆盖此文件"

# 包是否已安装（只读）
_cockpit_pkg_installed() {
	[[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# 读取 Cockpit 监听端口：cockpit.socket drop-in 中最后一个非空 ListenStream=，默认 9090（只读）
_cockpit_listen_port() {
	local f line v port="9090"
	for f in /etc/systemd/system/cockpit.socket.d/*.conf; do
		[[ -r "$f" ]] || continue
		while IFS= read -r line; do
			[[ "$line" =~ ^[[:space:]]*ListenStream[[:space:]]*=[[:space:]]*([^[:space:]]*) ]] || continue
			v="${BASH_REMATCH[1]}"
			[[ -n "$v" ]] || continue
			v="${v##*:}"
			[[ "$v" =~ ^[0-9]+$ ]] && port="$v"
		done < "$f"
	done
	printf '%s' "$port"
}

# cockpit.conf 归属：debnas（带标记）| absent（不存在）| custom（用户自定义）| unreadable
_cockpit_conf_owner() {
	local conf="/etc/cockpit/cockpit.conf"
	if [[ ! -e "$conf" ]]; then
		echo "absent"
	elif [[ ! -r "$conf" ]]; then
		echo "unreadable"
	elif grep -qxF "$COCKPIT_CONF_MARKER" "$conf" 2>/dev/null; then
		echo "debnas"
	else
		echo "custom"
	fi
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
	local port owner files_note conf_note
	if ! _cockpit_pkg_installed cockpit; then
		echo "absent|未安装 Cockpit"
		return 0
	fi
	port=$(_cockpit_listen_port)
	if ! systemctl is-active --quiet cockpit.socket 2>/dev/null; then
		echo "warn|已安装但 cockpit.socket 未激活（端口 ${port}）"
		return 0
	fi
	owner=$(_cockpit_conf_owner)
	if _cockpit_pkg_installed cockpit-files; then files_note="cockpit-files 已装"; else files_note="缺 cockpit-files"; fi
	case "$owner" in
	debnas) conf_note="DebNAS 配置" ;;
	absent) conf_note="未写入 cockpit.conf" ;;
	custom) conf_note="cockpit.conf 无 DebNAS 标记（用户自定义或旧版生成）" ;;
	*) conf_note="cockpit.conf 不可读" ;;
	esac
	if ! _cockpit_pkg_installed cockpit-files || [[ "$owner" == "absent" ]]; then
		echo "partial|运行中 · 端口 ${port} · ${files_note} · ${conf_note}"
		return 0
	fi
	echo "running|运行中 · 端口 ${port} · ${files_note} · ${conf_note}"
}

# 预演：每行 "类型|目标|备注"（无副作用；与 main 的判断保持一致；已满足的不列）
module_plan() {
	local IFS=$' \n\t'
	local -a pkgs=(cockpit cockpit-files pcp python3-pcp tuned) missing=()
	local pkg codename owner port
	codename=$(get_system_codename 2>/dev/null) || codename=""
	case "$codename" in
	bookworm | trixie) ;;
	*)
		echo "risk|系统版本|当前系统代号 ${codename:-未知} 不受支持，执行时会直接中止"
		return 0
		;;
	esac

	echo "write|/etc/apt/preferences.d/cockpit-backports.pref|cockpit、cockpit-*、pcp、python3-pcp、tuned 优先 ${codename}-backports（Pin 500）；每次直接覆盖写入（含时间戳），不另做备份"
	echo "info|apt update|执行时 apt update 使 pinning 生效（需联网）"
	for pkg in "${pkgs[@]}"; do
		_cockpit_pkg_installed "$pkg" || missing+=("$pkg")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "pkg|${missing[*]}|apt 安装（经 backports pinning 取 ${codename}-backports 版本）"
	else
		echo "info|${pkgs[*]}|已安装，跳过"
	fi

	owner=$(_cockpit_conf_owner)
	case "$owner" in
	absent) echo "write|/etc/cockpit/cockpit.conf|新建（带 DebNAS 管理标记：空闲 15 分钟超时、登录标题 DebNAS、禁止 LoginTo）" ;;
	debnas) echo "write|/etc/cockpit/cockpit.conf|DebNAS 管理文件：内容未变则跳过，变更时原件备份到 /var/backups/debnas/" ;;
	custom) echo "info|/etc/cockpit/cockpit.conf|无 DebNAS 标记：若为旧版 DebNAS 生成内容则迁移（原件备份到 /var/backups/debnas/），否则视为用户自定义跳过" ;;
	*) echo "info|/etc/cockpit/cockpit.conf|当前用户不可读，执行时判断是否覆盖" ;;
	esac
	if [[ "$(config_read "global" "cockpit_behind_proxy" "0" 2>/dev/null || echo 0)" == "1" ]]; then
		echo "risk|cockpit.conf|cockpit_behind_proxy=1：信任 X-Forwarded-* 头，仅在 Cockpit 位于反向代理之后才安全"
	fi
	echo "write|/etc/motd|登录提示语：内容未变则跳过，变更时原件备份到 /var/backups/debnas/"
	echo "write|/etc/cockpit/issue.cockpit|登录页横幅：内容未变则跳过，变更时原件备份到 /var/backups/debnas/"

	port=$(_cockpit_listen_port)
	if systemctl is-active --quiet cockpit 2>/dev/null; then
		echo "service|cockpit|配置有变化时重启，否则保持运行"
		echo "risk|Cockpit 会话|配置变化时重启 cockpit，已登录的网页会话需重新登录"
	else
		echo "service|cockpit|配置有变化时重启，否则启动（开机由 cockpit.socket 按需激活）"
	fi
	echo "port|${port}/tcp|Cockpit 网页端口；本模块不改防火墙（firewall 模块放行 cockpit 服务）"
	return 0
}

# ==================== 主入口 ====================

main() {
	local system_name system_codename
	system_name=$(get_system_name)
	system_codename=$(get_system_codename)

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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
