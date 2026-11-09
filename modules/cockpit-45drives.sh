#!/bin/bash
# @module: cockpit-45drives
# @name: 安装 45Drives 扩展
# @category: 管理面板
# @depends: curl
# @depend_modules: cockpit
# @version: 1.1.0
# @order: 31
# 功能：安装 45Drives Cockpit 扩展组件（文件共享、身份管理）
# 说明：Debian 12/13 均通过 45Drives 官方仓库安装；与 DebNAS 自研「共享管理」插件（cockpit-shares）二选一

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 通过官方仓库安装 ====================

# 可覆盖路径（测试时可注入临时目录）
FD45_KEYRING_FILE="${FD45_KEYRING_FILE:-/usr/share/keyrings/45drives-archive-keyring.gpg}"
FD45_SOURCES_DIR="${FD45_SOURCES_DIR:-/etc/apt/sources.list.d}"

# 仓库参数取自官方 https://repo.45drives.com/setup（2026-11-09 只读核对，未执行）：
#   公钥  https://repo.45drives.com/key/gpg.asc，dearmor 后存 /usr/share/keyrings/45drives-archive-keyring.gpg
#   源    https://repo.45drives.com/repofiles/debian/45drives-enterprise-<codename>.list，bookworm/trixie 均为：
#         deb [arch=amd64 signed-by=…] https://repo.45drives.com/enterprise/debian <codename> main
# 本模块不再下载/执行该脚本，而是按上述参数自行写源；公钥必须匹配下方固定指纹。
# 仓库地址/公钥地址可在 /etc/debnas/debnas.conf 用 repo_45drives_url / repo_45drives_key_url 换成镜像，
# 指纹校验不变，apt 仍用钉死的 keyring 校验 Release 签名，镜像无法篡改软件包。
FD45_DEFAULT_KEY_URL="https://repo.45drives.com/key/gpg.asc"
FD45_DEFAULT_REPO_URL="https://repo.45drives.com/enterprise/debian"

# 45Drives 仓库签名主密钥指纹（FourFiveDrives Repo <repo@45drives.com>，rsa4096，2021-06-29 创建）
# 来源：首次获取固定（TOFU）。官方未在网页公布指纹；2026-11-09 从 repo.45drives.com 获取，
# 与 keyserver.ubuntu.com 上同指纹公钥一致，且该密钥能验证 bookworm/trixie 的 InRelease 签名。
FD45_GPG_FINGERPRINT="3FBD7E034E80BAF63D5AA9BB9889DBBC731C472B"

# 读取可配置的地址（留空=官方地址）；只接受 http(s):// 且不含空白的单个 URL，去掉末尾 /
# 参数：$1 - 配置键名，$2 - 默认地址
read_45drives_url() {
	local key="$1" default_url="$2" url
	url=$(config_read "global" "$key" "" 2>/dev/null) || url=""
	[[ -n "$url" ]] || url="$default_url"
	if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
		log_error "debnas.conf 中 ${key} 不是合法的 http(s) 地址：${url}"
		return 1
	fi
	echo "${url%/}"
}

# 校验公钥文件：只允许包含一个主密钥，且指纹等于固定指纹
# 参数：$1 - 公钥文件路径（armored 或二进制均可）
# 返回：0 校验通过，1 失败
verify_45drives_gpg_fingerprint() {
	local key_file="$1"
	local gpg_home fprs

	gpg_home=$(create_temp_dir "45drives-gpg") || return 1
	# --with-colons 输出中 pub 行之后的第一条 fpr 为主密钥指纹（跳过子密钥）
	fprs=$(gpg --homedir "$gpg_home" --batch --quiet --show-keys --with-colons "$key_file" 2>/dev/null \
		| awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }') || return 1

	if [[ "$fprs" != "$FD45_GPG_FINGERPRINT" ]]; then
		log_error "45Drives GPG 公钥指纹不匹配（期望 ${FD45_GPG_FINGERPRINT}，实际 ${fprs:-无}），拒绝安装"
		return 1
	fi
	return 0
}

# 下载 45Drives 公钥 → 校验指纹 → dearmor → 原子替换 keyring（任一步失败都不动已有 keyring）
# 参数：$1 - 公钥下载地址
install_45drives_keyring() {
	local key_url="$1"
	local tmp_key tmp_bin gpg_home keyring_dir tmp_dst attempt downloaded=0

	command -v gpg >/dev/null 2>&1 || apt_install_packages gnupg || {
		log_error "gnupg 安装失败，无法校验 45Drives 公钥"
		return 1
	}

	tmp_key=$(create_temp_file "45drives-gpg" ".asc") || return 1
	tmp_bin=$(create_temp_file "45drives-gpg" ".gpg") || return 1
	# 下载失败重试 1 次
	for attempt in 1 2; do
		if curl -fsSL --max-time 30 --connect-timeout 10 -o "$tmp_key" "$key_url" && [[ -s "$tmp_key" ]]; then
			downloaded=1
			break
		fi
		[[ $attempt -eq 2 ]] || { log_warning "45Drives GPG 公钥下载失败，重试中..."; sleep 2; }
	done
	if [[ $downloaded -ne 1 ]]; then
		log_error "45Drives GPG 公钥下载失败：${key_url}"
		log_error "网络不通时可在 /etc/debnas/debnas.conf 配置 repo_45drives_key_url / repo_45drives_url 镜像地址（指纹校验不变）"
		return 1
	fi
	verify_45drives_gpg_fingerprint "$tmp_key" || return 1

	# 官方提供 ASCII armored 公钥，转为二进制 keyring（与官方脚本相同格式）；镜像若已是二进制则原样使用
	if grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$tmp_key" 2>/dev/null; then
		gpg_home=$(create_temp_dir "45drives-gpg") || return 1
		gpg --homedir "$gpg_home" --batch --yes --dearmor -o "$tmp_bin" "$tmp_key" 2>/dev/null || tmp_bin=""
	else
		cp -- "$tmp_key" "$tmp_bin" || tmp_bin=""
	fi
	if [[ -z "$tmp_bin" || ! -s "$tmp_bin" ]] || ! verify_45drives_gpg_fingerprint "$tmp_bin"; then
		log_error "45Drives GPG 公钥转换失败"
		return 1
	fi

	if [[ -f "$FD45_KEYRING_FILE" ]] && cmp -s "$tmp_bin" "$FD45_KEYRING_FILE"; then
		log_info "45Drives GPG 密钥未变更，跳过"
		return 0
	fi
	# 同目录临时文件 + rename 原子替换，不截断已有 keyring
	keyring_dir=$(dirname -- "$FD45_KEYRING_FILE")
	install -m 0755 -d "$keyring_dir"
	tmp_dst=$(mktemp -- "${keyring_dir}/.45drives-keyring.debnas.XXXXXX") || return 1
	if ! cat -- "$tmp_bin" > "$tmp_dst" || ! chmod 644 "$tmp_dst" \
		|| ! mv -fT -- "$tmp_dst" "$FD45_KEYRING_FILE"; then
		[[ -n "$tmp_dst" ]] && rm -f -- "$tmp_dst"
		log_error "45Drives GPG 密钥写入失败：${FD45_KEYRING_FILE}"
		return 1
	fi
	log_info "45Drives GPG 密钥已更新（指纹 ${FD45_GPG_FINGERPRINT}）"
}

# 配置 45Drives APT 源（不执行任何远程脚本）
# 参数：$1 - 系统代号（bookworm/trixie）
configure_45drives_repo() {
	local codename="$1"
	local repo_url key_url legacy content rc=0
	log_info "配置 45Drives 源..."

	repo_url=$(read_45drives_url "repo_45drives_url" "$FD45_DEFAULT_REPO_URL") || return 1
	key_url=$(read_45drives_url "repo_45drives_key_url" "$FD45_DEFAULT_KEY_URL") || return 1

	install_45drives_keyring "$key_url" || return 1

	# 官方脚本写入的 .list（及更早的 45drives.list）与本模块的 .sources 重复，备份停用，避免重复源告警
	for legacy in "${FD45_SOURCES_DIR}/45drives-enterprise-${codename}.list" "${FD45_SOURCES_DIR}/45drives.list"; do
		if [[ -f "$legacy" ]]; then
			# 集中备份到 /var/backups/debnas 后移除；备份失败则改名为 APT 会忽略的 .bak
			if debnas_backup_file "$legacy"; then
				rm -f -- "$legacy"
				log_info "旧 45Drives 源已移除（原件在 ${DEBNAS_BACKUP_ROOT}/）：${legacy}"
			else
				mv -f -- "$legacy" "${legacy}.$(date +%Y%m%d%H%M%S).bak"
				log_info "旧 45Drives 源已改名备份：${legacy}.*.bak"
			fi
		fi
	done

	# DEB822 格式，幂等写入（与官方 .list 等价：仅 amd64，suite=系统代号，component=main）
	content="Types: deb
URIs: ${repo_url}
Suites: ${codename}
Components: main
Architectures: amd64
Signed-By: ${FD45_KEYRING_FILE}"
	write_file_if_changed "${FD45_SOURCES_DIR}/45drives.sources" "$content" "644" || rc=$?
	if [[ $rc -eq 2 ]]; then
		log_error "45Drives 软件源写入失败。"
		return 1
	fi
}

# ==================== 与 DebNAS 自研共享管理插件二选一 ====================

# 自研插件安装目录（与 modules/cockpit-shares/module.sh 中 SHARES_PLUGIN_DIR 相同的固定常量）
DEBNAS_SHARES_PLUGIN_DIR="/usr/share/cockpit/debnas-shares"

# 删除自研插件目录：只接受非空且严格等于固定常量的路径
# 参数：$1 - 待删除目录
remove_debnas_shares_plugin_dir() {
	local dir="$1"
	if [[ -z "$dir" || "$dir" != "$DEBNAS_SHARES_PLUGIN_DIR" ]]; then
		log_error "拒绝删除非预期目录：${dir:-（空）}"
		return 1
	fi
	[[ -d "$dir" && ! -L "$dir" ]] || return 0
	rm -rf -- "$dir"
	log_success "已移除 DebNAS 共享管理插件：${dir}"
}

# 检测到自研插件时提示二选一：交互模式询问；非交互 / --yes 时仅当 file_sharing_ui=45drives 才移除
# 返回：0 可继续安装 45Drives，1 用户取消
ensure_debnas_shares_removed() {
	local choice
	[[ -d "$DEBNAS_SHARES_PLUGIN_DIR" ]] || return 0
	log_warning "检测到 DebNAS 共享管理插件（${DEBNAS_SHARES_PLUGIN_DIR}），两种共享管理插件只能保留一个"
	if [[ -t 0 && "${DEBNAS_FORCE_YES:-0}" -ne 1 ]]; then
		if [[ "$(ui_confirm "移除 DebNAS 共享管理插件，改用 45Drives？" "两者共用 Samba 注册表与 /etc/exports.d/cockpit-file-sharing.exports，已有共享不会丢失。")" != "0" ]]; then
			log_error "已取消：保留 DebNAS 共享管理插件"
			return 1
		fi
	else
		choice=$(config_read "global" "file_sharing_ui" "debnas" 2>/dev/null) || choice="debnas"
		if [[ "${choice,,}" != "45drives" ]]; then
			log_error "非交互模式下不自动替换：请先在 /etc/debnas/debnas.conf 设置 file_sharing_ui=45drives"
			return 1
		fi
	fi
	remove_debnas_shares_plugin_dir "$DEBNAS_SHARES_PLUGIN_DIR"
}

install_45drives_components_repo() {
	log_info "通过源安装 45Drives 组件..."
	if ! apt_install_packages cockpit-file-sharing cockpit-identities; then
		log_error "45Drives Cockpit 组件安装失败。"
		return 1
	fi
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 包是否已安装（只读）
_fd45_pkg_installed() {
	[[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# 读取 file_sharing_ui（只读，小写；非法值按 debnas）
_fd45_ui_choice() {
	local v
	v=$(config_read "global" "file_sharing_ui" "debnas" 2>/dev/null) || v="debnas"
	v="${v,,}"
	case "$v" in
	debnas | 45drives) echo "$v" ;;
	*) echo "debnas" ;;
	esac
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
	local IFS=$' \n\t'
	local choice fs=0 ids=0 src=0 key=0
	local -a lacks=()
	choice=$(_fd45_ui_choice)
	_fd45_pkg_installed cockpit-file-sharing && fs=1
	_fd45_pkg_installed cockpit-identities && ids=1
	[[ -f "${FD45_SOURCES_DIR}/45drives.sources" ]] && src=1
	[[ -f "$FD45_KEYRING_FILE" ]] && key=1

	if [[ $fs -eq 0 && $ids -eq 0 ]]; then
		if [[ "$choice" == "45drives" ]]; then
			echo "absent|未安装 45Drives 插件（file_sharing_ui=45drives，执行后启用）"
		else
			echo "absent|未安装（file_sharing_ui=debnas，共享管理使用 DebNAS 自研插件）"
		fi
		return 0
	fi
	if [[ $fs -eq 1 && "$choice" != "45drives" ]]; then
		echo "warn|已安装 cockpit-file-sharing，与配置 file_sharing_ui=${choice} 不一致（运行 cockpit-shares 会卸载它）"
		return 0
	fi
	if [[ $fs -eq 1 && -d "$DEBNAS_SHARES_PLUGIN_DIR" ]]; then
		echo "warn|45Drives 与 DebNAS 共享管理插件同时存在（${DEBNAS_SHARES_PLUGIN_DIR}）"
		return 0
	fi
	[[ $fs -eq 1 ]] || lacks+=("cockpit-file-sharing")
	[[ $ids -eq 1 ]] || lacks+=("cockpit-identities")
	[[ $src -eq 1 ]] || lacks+=("45drives.sources")
	[[ $key -eq 1 ]] || lacks+=("keyring")
	if [[ ${#lacks[@]} -gt 0 ]]; then
		echo "partial|45Drives 插件部分就绪，缺 ${lacks[*]}"
		return 0
	fi
	echo "applied|cockpit-file-sharing + cockpit-identities 已安装 · 45Drives 源与 keyring 就绪"
}

# 预演：每行 "类型|目标|备注"（无副作用；不联网；与 main 的判断保持一致；已满足的不列）
module_plan() {
	local IFS=$' \n\t'
	local codename choice repo_url key_url legacy
	local -a missing=() pkg
	codename=$(get_system_codename 2>/dev/null) || codename=""
	case "$codename" in
	bookworm | trixie) ;;
	*)
		echo "risk|系统版本|当前系统代号 ${codename:-未知} 不受支持，执行时会直接中止"
		return 0
		;;
	esac
	choice=$(_fd45_ui_choice)

	if [[ -d "$DEBNAS_SHARES_PLUGIN_DIR" ]]; then
		if [[ "$choice" == "45drives" ]]; then
			echo "risk|${DEBNAS_SHARES_PLUGIN_DIR}|删除 DebNAS 共享管理插件（rm -rf，不另做备份；交互模式先确认）；Samba 注册表与 NFS 导出共享不受影响"
		else
			echo "risk|${DEBNAS_SHARES_PLUGIN_DIR}|二选一：交互确认后删除 DebNAS 共享管理插件（rm -rf，不另做备份）；非交互执行且 file_sharing_ui=${choice} 时会中止"
		fi
	fi

	command -v gpg >/dev/null 2>&1 || echo "pkg|gnupg|apt 安装（用于校验 45Drives 公钥指纹）"
	repo_url=$(config_read "global" "repo_45drives_url" "" 2>/dev/null) || repo_url=""
	key_url=$(config_read "global" "repo_45drives_key_url" "" 2>/dev/null) || key_url=""
	echo "info|45Drives 公钥|执行时从 ${key_url:-$FD45_DEFAULT_KEY_URL} 下载（需联网）"
	echo "write|${FD45_KEYRING_FILE}|公钥指纹校验通过后原子替换；内容相同跳过；不另做备份"
	echo "risk|45Drives 公钥|指纹 ${FD45_GPG_FINGERPRINT} 为首次获取固定（TOFU），官方未公布指纹"
	for legacy in "${FD45_SOURCES_DIR}/45drives-enterprise-${codename}.list" "${FD45_SOURCES_DIR}/45drives.list"; do
		[[ -f "$legacy" ]] && echo "write|${legacy}|旧格式源集中备份到 /var/backups/debnas/ 后移除"
	done
	echo "write|${FD45_SOURCES_DIR}/45drives.sources|DEB822 源 ${repo_url:-$FD45_DEFAULT_REPO_URL} ${codename} main（amd64）；内容未变则跳过，变更时原件备份到 /var/backups/debnas/"

	for pkg in cockpit-file-sharing cockpit-identities; do
		_fd45_pkg_installed "$pkg" || missing+=("$pkg")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "pkg|${missing[*]}|apt update 后从 45Drives 第三方仓库安装（依赖由 apt 解析）"
	else
		echo "info|cockpit-file-sharing cockpit-identities|已安装，跳过"
	fi
	if [[ "$choice" != "45drives" ]]; then
		echo "write|${DEBNAS_GLOBAL_CONF:-/etc/debnas/debnas.conf}|config_write 写入 file_sharing_ui=45drives（原地更新，不另做备份）"
	fi
	echo "info|端口|不新增端口与服务（共享服务端口由 Samba/NFS 决定，界面经 Cockpit 访问）"
	return 0
}

# ==================== 主入口 ====================

main() {
	local system_codename
	system_codename=$(get_system_codename)

	log_info "检测到系统版本: ${system_codename}"

	case "${system_codename}" in
	"bookworm"|"trixie")
		log_info "Debian ${system_codename}: 45Drives 仓库"
		ensure_debnas_shares_removed || exit "${ERROR_GENERAL}"
		configure_45drives_repo "${system_codename}"
		install_45drives_components_repo
		# 记录选择，避免之后运行一键方案时又切回自研插件
		config_write "global" "file_sharing_ui" "45drives" || log_warning "写入 file_sharing_ui=45drives 失败"
		;;
	*)
		log_error "不支持的 Debian 版本: ${system_codename}"
		log_error "仅支持 Debian 12 (bookworm) 和 Debian 13 (trixie)"
		exit "${ERROR_UNSUPPORTED_OS}"
		;;
	esac

}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
