#!/bin/bash
# @module: cockpit-shares
# @name: 安装共享管理面板
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 31
# 功能：安装 Cockpit「共享管理」面板（Samba 共享 / NFS 导出 / 共享用户）
# 说明：按 debnas.conf 的 file_sharing_ui 二选一：
#       debnas（默认）  部署 DebNAS 自研插件到 /usr/share/cockpit/debnas-shares/
#       45drives        改为执行 cockpit-45drives 模块（45Drives cockpit-file-sharing + cockpit-identities）
#       两者共用后端（Samba 注册表 + /etc/exports.d/cockpit-file-sharing.exports），切换后共享不丢失。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 常量 ====================

# 插件安装目录（固定常量，cockpit-45drives 模块切换时按同一常量删除）
SHARES_PLUGIN_DIR="/usr/share/cockpit/debnas-shares"
SHARES_PLUGIN_SRC="${MODULE_DIR}/plugin"
SHARES_SMB_CONF="${SHARES_SMB_CONF:-/etc/samba/smb.conf}"
SHARES_EXPORTS_DIR="${SHARES_EXPORTS_DIR:-/etc/exports.d}"
# 45Drives 文件共享插件包名（cockpit-identities 是用户/组插件，与本插件不冲突，不处理）
SHARES_45DRIVES_PKG="cockpit-file-sharing"
# _shares_plugin_diff 的输出
SHARES_DIFF_CHANGED=()
SHARES_DIFF_STALE=()

# ==================== 配置读取 ====================

# 读取界面选择：debnas | 45drives（非法值按默认 debnas 处理）
# 参数：$1 - --quiet 时不打告警日志（只读探测用）
shares_ui_choice() {
	local v
	v=$(config_read "global" "file_sharing_ui" "debnas" 2>/dev/null) || v="debnas"
	v="${v,,}"
	case "$v" in
	debnas | 45drives) echo "$v" ;;
	*)
		[[ "${1:-}" == "--quiet" ]] || log_warning "debnas.conf 中 file_sharing_ui=${v} 无效（可选 debnas | 45drives），按 debnas 处理"
		echo "debnas"
		;;
	esac
}

# 是否安装 NFS 服务端：file_sharing_nfs=1 装 / 0 不装 / 留空：已装则保持，交互模式询问，非交互不装
# 返回：0 安装，1 不安装
shares_want_nfs() {
	local rc=0
	config_get_bool file_sharing_nfs "" || rc=$?
	[[ $rc -ne 2 ]] && return "$rc"
	pkg_is_installed nfs-kernel-server && return 0
	if [[ -t 0 && "${DEBNAS_FORCE_YES:-0}" -ne 1 ]]; then
		[[ "$(ui_confirm "同时安装 NFS 服务端（nfs-kernel-server）？" "供 Linux / macOS 客户端以 NFS 挂载共享目录。\n不需要可选否，以后可在 debnas.conf 设置 file_sharing_nfs=1 后重新运行本模块。")" == "0" ]]
		return $?
	fi
	log_info "未安装 NFS 服务端（如需要请在 debnas.conf 设置 file_sharing_nfs=1 后重新运行）"
	return 1
}

# ==================== 工具函数 ====================

# 是否切换（移除另一种插件）：交互模式询问；非交互 / --yes 按 file_sharing_ui 配置
# 参数：$1 - 本模块要安装的界面（debnas|45drives），$2 - 提示标题，$3 - 说明
# 返回：0 移除另一种并继续，1 不移除（调用方应中止）
shares_confirm_switch() {
	local wanted="$1" title="$2" desc="$3"
	if [[ -t 0 && "${DEBNAS_FORCE_YES:-0}" -ne 1 ]]; then
		[[ "$(ui_confirm "$title" "$desc")" == "0" ]]
		return $?
	fi
	[[ "$(shares_ui_choice)" == "$wanted" ]]
}

# ==================== smb.conf：include = registry ====================

# 从 stdin 读 smb.conf，输出加入 include = registry 后的内容
# 规则：[global] 中已有 include = registry 或 config backend = registry 时原样输出；
#       否则插在 [global] 最后一个参数行之后；没有 [global] 时在文件开头新建
smbconf_with_registry() {
	awk '
	function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
	{ lines[NR] = $0 }
	END {
		in_global = 0; global_start = 0; last_param = 0; has = 0
		for (i = 1; i <= NR; i++) {
			t = trim(lines[i])
			if (t ~ /^\[/) {
				name = tolower(t); gsub(/^\[[ \t]*|[ \t]*\].*$/, "", name)
				in_global = (name == "global")
				if (in_global && global_start == 0) { global_start = i; last_param = i }
				continue
			}
			if (!in_global || t == "" || t ~ /^[#;]/) continue
			last_param = i
			eq = index(t, "=")
			if (eq > 0) {
				k = tolower(trim(substr(t, 1, eq - 1))); gsub(/[ \t]+/, " ", k)
				v = tolower(trim(substr(t, eq + 1)))
				if ((k == "include" || k == "config backend") && v == "registry") has = 1
			}
		}
		if (has) { for (i = 1; i <= NR; i++) print lines[i]; exit }
		if (global_start == 0) {
			print "[global]"; print "   include = registry"; print ""
			for (i = 1; i <= NR; i++) print lines[i]
			exit
		}
		for (i = 1; i <= NR; i++) {
			print lines[i]
			if (i == last_param) print "   include = registry"
		}
	}'
}

# 确保 smb.conf 启用注册表（write_file_if_changed 负责备份与原子写入，不改动其他内容）
# 返回：0 已启用或已写入，1 失败
shares_ensure_registry_include() {
	local conf="$SHARES_SMB_CONF" current new rc=0
	if [[ ! -f "$conf" ]]; then
		log_warning "未找到 ${conf}，跳过启用 Samba 注册表"
		return 0
	fi
	current=$(< "$conf") || return 1
	new=$(smbconf_with_registry <<< "$current") || return 1
	if [[ "$new" == "$current" ]]; then
		log_info "Samba 注册表已启用（include = registry）"
		return 0
	fi
	write_file_if_changed "$conf" "$new" || rc=$?
	if [[ $rc -eq 2 ]]; then
		log_error "写入 ${conf} 失败"
		return 1
	fi
	if command -v testparm >/dev/null 2>&1 && ! testparm -s "$conf" >/dev/null 2>&1; then
		log_warning "testparm 校验 ${conf} 未通过，请检查（原文件已备份到 /var/backups/debnas）"
	fi
	log_success "已在 ${conf} 的 [global] 中启用 include = registry"
}

# ==================== 插件部署 ====================

# 比较插件源目录与目标目录（只读）
# 参数：$1 - 源目录，$2 - 目标目录
# 输出：写全局数组 SHARES_DIFF_CHANGED（将新增/更新的文件名）、SHARES_DIFF_STALE（目标中多余的文件名）
_shares_plugin_diff() {
	local src="$1" dst="$2" f name
	SHARES_DIFF_CHANGED=()
	SHARES_DIFF_STALE=()
	for f in "$src"/*; do
		[[ -f "$f" ]] || continue
		name="${f##*/}"
		[[ -f "${dst}/${name}" ]] && cmp -s -- "$f" "${dst}/${name}" && continue
		SHARES_DIFF_CHANGED+=("$name")
	done
	for f in "$dst"/*; do
		[[ -f "$f" ]] || continue
		name="${f##*/}"
		[[ -e "${src}/${name}" ]] || SHARES_DIFF_STALE+=("$name")
	done
}

# 把插件文件安装到目标目录：目录 755、文件 644、root 属主；内容相同的文件跳过；删除目标中多余的旧文件
# 参数：$1 - 源目录，$2 - 目标目录，$3 - 属主（可选，默认 root；测试时传当前用户）
shares_deploy_plugin() {
	local src="$1" dst="$2" owner="${3:-root}"
	local name changed=0
	local -a own_opts=()
	[[ -n "$src" && -d "$src" && -f "${src}/manifest.json" ]] || {
		log_error "插件源目录不完整：${src}"
		return 1
	}
	[[ -n "$dst" ]] || return 1
	[[ "$owner" == "root" ]] && own_opts=(-o root -g root)

	install -d -m 755 "${own_opts[@]}" -- "$dst" || return 1
	_shares_plugin_diff "$src" "$dst"
	for name in "${SHARES_DIFF_CHANGED[@]}"; do
		install -m 644 "${own_opts[@]}" -- "${src}/${name}" "${dst}/${name}" || return 1
		changed=1
	done
	# 目标目录只属于本插件：清理源中已不存在的文件
	for name in "${SHARES_DIFF_STALE[@]}"; do
		[[ -n "$name" ]] || continue
		rm -f -- "${dst}/${name}"
		changed=1
	done
	if [[ $changed -eq 1 ]]; then
		log_success "共享管理插件已部署到 ${dst}"
	else
		log_info "共享管理插件未变更：${dst}"
	fi
}

# 检测到 45Drives 文件共享插件时按二选一规则移除
shares_remove_45drives() {
	pkg_is_installed "$SHARES_45DRIVES_PKG" || return 0
	log_warning "检测到 45Drives 文件共享插件（${SHARES_45DRIVES_PKG}），两种共享管理插件只能保留一个"
	if ! shares_confirm_switch "debnas" "卸载 45Drives 文件共享插件，改用 DebNAS 共享管理？" \
		"两者共用 Samba 注册表与 ${SHARES_EXPORTS_DIR}/cockpit-file-sharing.exports，已有共享不会丢失。\ncockpit-identities（用户/组插件）保留不动。"; then
		log_error "已取消：保留 45Drives 插件。如需继续使用它，请在 /etc/debnas/debnas.conf 设置 file_sharing_ui=45drives"
		return 1
	fi
	# apt_remove_safe 会 autoremove：先把 Samba/NFS 标记为手动安装，避免随 45Drives 插件被连带卸载
	local -a keep=() p
	for p in samba samba-common-bin nfs-kernel-server; do
		pkg_is_installed "$p" && keep+=("$p")
	done
	if [[ ${#keep[@]} -gt 0 ]]; then
		apt-mark manual "${keep[@]}" >/dev/null 2>&1 || log_warning "apt-mark manual 失败：${keep[*]}"
	fi
	APT_REMOVE_PURGE=0 apt_remove_safe "$SHARES_45DRIVES_PKG"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# smb.conf 是否已启用注册表：yes | no | missing（文件不存在）| unreadable（非 root 读不到）
# 判据与 shares_ensure_registry_include 相同：smbconf_with_registry 输出与原文相同即已启用
_shares_probe_registry() {
	local conf="$SHARES_SMB_CONF" current new
	[[ -e "$conf" ]] || { echo "missing"; return 0; }
	[[ -r "$conf" ]] || { echo "unreadable"; return 0; }
	current=$(< "$conf") 2>/dev/null || { echo "unreadable"; return 0; }
	new=$(smbconf_with_registry <<< "$current" 2>/dev/null) || { echo "unreadable"; return 0; }
	if [[ "$new" == "$current" ]]; then echo "yes"; else echo "no"; fi
}

# file_sharing_ui=45drives 时委托 cockpit-45drives 的探测函数（子 shell 中加载，不影响本模块函数）
# 参数：$1 - status|plan
_shares_probe_delegate() {
	local action="$1"
	(
		export DEBNAS_MODULE_ACTION="$action"
		unset -f module_status module_plan 2>/dev/null || true
		# shellcheck disable=SC1091
		source "${SCRIPT_DIR}/modules/cockpit-45drives.sh" </dev/null >/dev/null 2>&1 || exit 3
		declare -F "module_${action}" >/dev/null || exit 3
		"module_${action}" </dev/null 2>/dev/null
	)
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
	local choice reg nfs_note smbd_note reg_note manifest="${SHARES_PLUGIN_DIR}/manifest.json" sub
	choice=$(shares_ui_choice --quiet)
	if [[ "$choice" == "45drives" ]]; then
		# 配置为 45Drives：本模块执行时改为安装 45Drives 插件，状态取 cockpit-45drives 的检测结果
		sub=$(_shares_probe_delegate status) || sub=""
		sub="${sub%%$'\n'*}"
		if [[ "$sub" == *"|"* ]]; then
			echo "${sub%%|*}|file_sharing_ui=45drives（由 45Drives 插件提供）：${sub#*|}"
		else
			echo "unknown|file_sharing_ui=45drives（由 45Drives 插件提供），状态未知"
		fi
		return 0
	fi

	if [[ ! -f "$manifest" ]]; then
		if pkg_is_installed "$SHARES_45DRIVES_PKG"; then
			echo "absent|未部署共享管理插件；已装 45Drives cockpit-file-sharing（执行时会卸载）"
		else
			echo "absent|未部署共享管理插件"
		fi
		return 0
	fi
	if pkg_is_installed "$SHARES_45DRIVES_PKG"; then
		echo "warn|共享管理插件与 45Drives cockpit-file-sharing 同时存在"
		return 0
	fi
	if ! pkg_is_installed samba; then
		echo "partial|插件已部署，未安装 samba"
		return 0
	fi
	if pkg_is_installed nfs-kernel-server; then nfs_note="NFS 已装"; else nfs_note="未装 NFS"; fi
	reg=$(_shares_probe_registry)
	case "$reg" in
	yes) reg_note="注册表已启用" ;;
	no) reg_note="smb.conf 缺 include = registry" ;;
	missing) reg_note="未找到 smb.conf" ;;
	*) reg_note="smb.conf 不可读，未核对注册表" ;;
	esac
	if ! systemctl is-active --quiet smbd 2>/dev/null; then
		echo "warn|插件已部署，smbd 未运行 · ${reg_note} · ${nfs_note}"
		return 0
	fi
	smbd_note="smbd 运行中"
	if [[ "$reg" == "no" || "$reg" == "missing" ]]; then
		echo "partial|插件已部署 · ${smbd_note} · ${reg_note} · ${nfs_note}"
		return 0
	fi
	echo "running|插件已部署 · ${smbd_note} · ${reg_note} · ${nfs_note}"
}

# 预演：每行 "类型|目标|备注"（无副作用；不联网；与 main 的判断保持一致；已满足的不列）
module_plan() {
	local IFS=$' \n\t'
	local codename choice nfs="0" nfs_rc=0 reg sub
	local -a want=(samba samba-common-bin) missing=() p
	codename=$(get_system_codename 2>/dev/null) || codename=""
	case "$codename" in
	bookworm | trixie) ;;
	*)
		echo "risk|系统版本|当前系统代号 ${codename:-未知} 不受支持，执行时会直接中止"
		return 0
		;;
	esac

	choice=$(shares_ui_choice --quiet)
	if [[ "$choice" == "45drives" ]]; then
		echo "info|cockpit-45drives|file_sharing_ui=45drives：本模块改为执行 cockpit-45drives（exec），以下为该模块的预演"
		sub=$(_shares_probe_delegate plan) || sub=""
		if [[ -n "$sub" ]]; then
			printf '%s\n' "$sub"
		else
			echo "info|cockpit-45drives|无法获取 cockpit-45drives 预演"
		fi
		return 0
	fi

	if pkg_is_installed "$SHARES_45DRIVES_PKG"; then
		for p in samba samba-common-bin nfs-kernel-server; do
			pkg_is_installed "$p" && missing+=("$p")
		done
		[[ ${#missing[@]} -gt 0 ]] && echo "info|${missing[*]}|apt-mark manual，防止随 45Drives 插件被 autoremove 连带卸载"
		missing=()
		echo "risk|${SHARES_45DRIVES_PKG}|二选一：apt remove（不 purge，随后 autoremove）卸载 45Drives 文件共享插件；交互模式先确认，非交互按 file_sharing_ui=debnas 执行；cockpit-identities 保留"
	fi

	config_get_bool file_sharing_nfs "" || nfs_rc=$?
	case "$nfs_rc" in
	0) nfs=1 ;;
	1) nfs=0 ;;
	*)
		if pkg_is_installed nfs-kernel-server; then
			nfs=1
		else
			echo "info|nfs-kernel-server|file_sharing_nfs 未设置：交互模式询问是否安装，非交互不装"
		fi
		;;
	esac
	[[ "$nfs" == "1" ]] && want+=(nfs-kernel-server)
	for p in "${want[@]}"; do
		pkg_is_installed "$p" || missing+=("$p")
	done
	[[ ${#missing[@]} -gt 0 ]] && echo "pkg|${missing[*]}|apt 安装"

	reg=$(_shares_probe_registry)
	case "$reg" in
	no) echo "write|${SHARES_SMB_CONF}|[global] 追加 include = registry（write_file_if_changed，原件备份到 /var/backups/debnas/），随后 testparm 校验" ;;
	missing) echo "write|${SHARES_SMB_CONF}|安装 samba 后检查，缺 include = registry 则追加（原件备份到 /var/backups/debnas/）" ;;
	unreadable) echo "info|${SHARES_SMB_CONF}|当前用户不可读，执行时检查并按需追加 include = registry（原件备份到 /var/backups/debnas/）" ;;
	esac
	[[ "$nfs" == "1" && ! -d "$SHARES_EXPORTS_DIR" ]] && echo "write|${SHARES_EXPORTS_DIR}/|创建目录（不写导出规则）"

	# 插件文件：与源逐个比较，列出将新增/更新与将删除的文件
	_shares_plugin_diff "$SHARES_PLUGIN_SRC" "$SHARES_PLUGIN_DIR"
	if [[ ${#SHARES_DIFF_CHANGED[@]} -gt 0 ]]; then
		echo "write|${SHARES_PLUGIN_DIR}/|install 部署 ${SHARES_DIFF_CHANGED[*]}（目录 755/文件 644，root 属主；直接覆盖，不另做备份；登记到文件清单）"
	else
		echo "info|${SHARES_PLUGIN_DIR}/|插件文件与源一致，跳过"
	fi
	[[ ${#SHARES_DIFF_STALE[@]} -gt 0 ]] && echo "write|${SHARES_PLUGIN_DIR}/|删除源中已不存在的旧文件 ${SHARES_DIFF_STALE[*]}（不另做备份）"

	if systemctl is-active --quiet smbd 2>/dev/null; then
		echo "service|smbd|已运行；确保开机自启"
	else
		echo "service|smbd|启动并设为开机自启"
	fi
	if [[ "$nfs" == "1" ]]; then
		if systemctl is-active --quiet nfs-server 2>/dev/null; then
			echo "service|nfs-server|已运行；确保开机自启"
		else
			echo "service|nfs-server|启动并设为开机自启"
		fi
	fi
	echo "port|445/tcp 139/tcp|Samba（smbd）；本模块不改防火墙（firewall 模块放行 samba 服务）"
	[[ "$nfs" == "1" ]] && echo "port|2049/tcp 111/tcp+udp|NFS（nfs-server/rpcbind）；本模块不改防火墙"
	pkg_is_installed samba || echo "risk|smbd|安装并启用 Samba 服务，局域网可访问 445/139 端口（一键方案默认包含）"
	return 0
}

# ==================== 主入口 ====================

main() {
	local system_codename choice
	system_codename=$(get_system_codename)
	case "${system_codename}" in
	"bookworm" | "trixie") ;;
	*)
		log_error "不支持的 Debian 版本: ${system_codename}"
		log_error "仅支持 Debian 12 (bookworm) 和 Debian 13 (trixie)"
		exit "${ERROR_UNSUPPORTED_OS}"
		;;
	esac

	choice=$(shares_ui_choice)
	if [[ "$choice" == "45drives" ]]; then
		log_info "file_sharing_ui=45drives：改为安装 45Drives 文件共享插件"
		exec bash "${SCRIPT_DIR}/modules/cockpit-45drives.sh" "$@"
	fi

	shares_remove_45drives || exit "${ERROR_GENERAL}"

	local -a pkgs=(samba samba-common-bin)
	local nfs=0
	if shares_want_nfs; then
		pkgs+=(nfs-kernel-server)
		nfs=1
	fi
	if ! apt_install_packages "${pkgs[@]}"; then
		log_error "共享服务组件安装失败：${pkgs[*]}"
		exit "${ERROR_GENERAL}"
	fi

	shares_ensure_registry_include || exit "${ERROR_GENERAL}"
	if [[ $nfs -eq 1 ]]; then
		install -d -m 755 -- "$SHARES_EXPORTS_DIR"
	fi

	shares_deploy_plugin "$SHARES_PLUGIN_SRC" "$SHARES_PLUGIN_DIR" || {
		log_error "共享管理插件部署失败"
		exit "${ERROR_GENERAL}"
	}
	declare -F manifest_add >/dev/null 2>&1 && manifest_add "$SHARES_PLUGIN_DIR" || true

	service_ensure "smbd" "enabled" || true
	service_ensure "smbd" "started" || log_warning "smbd 启动失败，可在 Cockpit「共享管理 → Samba 设置」查看"
	if [[ $nfs -eq 1 ]]; then
		service_ensure "nfs-server" "enabled" || true
		service_ensure "nfs-server" "started" || log_warning "nfs-server 启动失败"
	fi

	log_success "共享管理面板就绪：Cockpit 左侧菜单「共享管理」（刷新浏览器页面后出现）"
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
