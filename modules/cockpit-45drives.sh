#!/bin/bash
# @module: cockpit-45drives
# @name: 安装 45Drives 官方插件
# @category: 管理面板
# @depends: curl
# @depend_modules: cockpit
# @version: 2.0.0
# @order: 31
# 功能：安装 45Drives Cockpit 官方插件（文件共享、身份管理）
# 说明：Debian 12/13 均通过 45Drives 官方仓库安装；这是 DebNAS 唯一的共享管理界面

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

# 配置 45Drives APT 源（不执行任何远程脚本）
# 参数：$1 - 系统代号（bookworm/trixie）
configure_45drives_repo() {
	local codename="$1"
	local repo_url key_url legacy content rc=0
	log_info "配置 45Drives 源..."

	repo_url=$(config_get_url repo_45drives_url "$FD45_DEFAULT_REPO_URL") || return 1
	key_url=$(config_get_url repo_45drives_key_url "$FD45_DEFAULT_KEY_URL") || return 1

	# 官方提供 ASCII armored 公钥，dearmor 为二进制 keyring（与官方脚本相同格式）；镜像若已是二进制则原样使用
	command -v gpg >/dev/null 2>&1 || apt_install_packages gnupg || {
		log_error "gnupg 安装失败，无法校验 45Drives 公钥"
		return 1
	}
	if ! keyring_install_verified "$key_url" "$FD45_GPG_FINGERPRINT" "$FD45_KEYRING_FILE" --dearmor --label 45Drives; then
		log_error "网络不通时可在 /etc/debnas/debnas.conf 配置 repo_45drives_key_url / repo_45drives_url 镜像地址（指纹校验不变）"
		return 1
	fi

	# 官方脚本写入的 .list（及更早的 45drives.list）与本模块的 .sources 重复，备份停用，避免重复源告警
	for legacy in "${FD45_SOURCES_DIR}/45drives-enterprise-${codename}.list" "${FD45_SOURCES_DIR}/45drives.list"; do
		if [[ -f "$legacy" ]]; then
			# 集中备份到 /var/backups/debnas 后移除；备份失败则改名为 APT 会忽略的 .bak
			if debnas_backup_file "$legacy"; then
				rm -f -- "$legacy"
				log_info "旧 45Drives 源已移除（原件在 ${DEBNAS_BACKUP_ROOT}/）：${legacy}"
			else
				mv -f -- "$legacy" "${legacy}.$(printf '%(%Y%m%d%H%M%S)T' -1).bak"
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

install_45drives_components_repo() {
	log_info "通过源安装 45Drives 组件..."
	if ! apt_install_packages cockpit-file-sharing cockpit-identities; then
		log_error "45Drives Cockpit 组件安装失败。"
		return 1
	fi
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
	local IFS=$' \n\t'
	local fs=0 ids=0 src=0 key=0
	local -a lacks=()
	pkg_is_installed cockpit-file-sharing && fs=1
	pkg_is_installed cockpit-identities && ids=1
	[[ -f "${FD45_SOURCES_DIR}/45drives.sources" ]] && src=1
	[[ -f "$FD45_KEYRING_FILE" ]] && key=1

	if [[ $fs -eq 0 && $ids -eq 0 ]]; then
		echo "absent|未安装 45Drives 官方插件"
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
	local codename repo_url key_url legacy
	local -a missing=() pkg
	codename=$(get_system_codename 2>/dev/null) || codename=""
	case "$codename" in
	bookworm | trixie) ;;
	*)
		echo "risk|系统版本|当前系统代号 ${codename:-未知} 不受支持，执行时会直接中止"
		return 0
		;;
	esac

	command -v gpg >/dev/null 2>&1 || echo "pkg|gnupg|apt 安装（用于校验 45Drives 公钥指纹）"
	repo_url=$(config_get_url repo_45drives_url "$FD45_DEFAULT_REPO_URL" 2>/dev/null) \
		|| { repo_url="$FD45_DEFAULT_REPO_URL"; echo "risk|repo_45drives_url|debnas.conf 中地址不是合法的 http(s) 地址，执行时会中止"; }
	key_url=$(config_get_url repo_45drives_key_url "$FD45_DEFAULT_KEY_URL" 2>/dev/null) \
		|| { key_url="$FD45_DEFAULT_KEY_URL"; echo "risk|repo_45drives_key_url|debnas.conf 中地址不是合法的 http(s) 地址，执行时会中止"; }
	echo "info|45Drives 公钥|执行时从 ${key_url} 下载（需联网）"
	echo "write|${FD45_KEYRING_FILE}|公钥指纹校验通过后原子替换；内容相同跳过；旧文件备份到 /var/backups/debnas/"
	echo "risk|45Drives 公钥|指纹 ${FD45_GPG_FINGERPRINT} 为首次获取固定（TOFU），官方未公布指纹"
	for legacy in "${FD45_SOURCES_DIR}/45drives-enterprise-${codename}.list" "${FD45_SOURCES_DIR}/45drives.list"; do
		[[ -f "$legacy" ]] && echo "write|${legacy}|旧格式源集中备份到 /var/backups/debnas/ 后移除"
	done
	echo "write|${FD45_SOURCES_DIR}/45drives.sources|DEB822 源 ${repo_url} ${codename} main（amd64）；内容未变则跳过，变更时原件备份到 /var/backups/debnas/"

	for pkg in cockpit-file-sharing cockpit-identities; do
		pkg_is_installed "$pkg" || missing+=("$pkg")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "pkg|${missing[*]}|apt update 后从 45Drives 第三方仓库安装（依赖由 apt 解析）"
	else
		echo "info|cockpit-file-sharing cockpit-identities|已安装，跳过"
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
		configure_45drives_repo "${system_codename}" || exit "${ERROR_DEPENDENCY}"
		install_45drives_components_repo || exit "${ERROR_GENERAL}"
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
