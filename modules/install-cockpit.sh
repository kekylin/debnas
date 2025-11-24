#!/bin/bash
# 功能：安装 Cockpit 及 45Drives 组件（支持 Debian 12/13）
# 说明：Debian 12 通过官方仓库安装；Debian 13 通过本地 .deb 安装。

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/system/apt-pinning.sh"

readonly -a GITHUB_PROXY_ENDPOINTS=(
	"https://ghfast.top"
	"https://gitproxy.click"
	"https://hubproxy.jiaozi.live"
	"https://gh.llkk.cc"
	"https://gh-proxy.top"
)

BEST_GITHUB_PROXY_SELECTION_STATE=""
BEST_GITHUB_PROXY=""
BEST_GITHUB_PROXY_LATENCY=""

measure_ping_latency() {
	local target="$1"
	local output latency
	if ! output=$(ping -c 1 -W 1 "${target}" 2>/dev/null); then
		return 1
	fi
	latency=$(printf '%s\n' "${output}" | awk -F'time=' '/time=/{split($2,a," "); print a[1]; exit}')
	if [[ -z "${latency}" ]]; then
		return 1
	fi
	printf '%s\n' "${latency}"
	return 0
}

select_best_github_proxy() {
	if [[ "${BEST_GITHUB_PROXY_SELECTION_STATE}" == "done" || "${BEST_GITHUB_PROXY_SELECTION_STATE}" == "skip" ]]; then
		[[ "${BEST_GITHUB_PROXY_SELECTION_STATE}" == "done" ]]
		return
	fi

	if ! command -v ping >/dev/null 2>&1; then
		log_warning "ping 未安装，无法执行 GitHub 镜像延迟检测，将按预设顺序尝试下载"
		BEST_GITHUB_PROXY_SELECTION_STATE="skip"
		return 1
	fi

	local -a measurements=()
	local prefix host latency
	for prefix in "${GITHUB_PROXY_ENDPOINTS[@]}"; do
		host=$(printf '%s\n' "${prefix}" | sed -E 's#^[a-z]+://([^/]+).*#\1#')
		if latency=$(measure_ping_latency "${host}"); then
			measurements+=("${latency}|${prefix}")
		else
			measurements+=("999999|${prefix}")
		fi
	done
	if latency=$(measure_ping_latency "github.com"); then
		measurements+=("${latency}|DIRECT")
	else
		measurements+=("999999|DIRECT")
	fi

	local best_entry
	best_entry=$(printf '%s\n' "${measurements[@]}" | sort -t'|' -k1,1g | head -n1)
	local best_prefix="${best_entry#*|}"
	BEST_GITHUB_PROXY_LATENCY="${best_entry%%|*}"

	if [[ "${best_prefix}" == "DIRECT" ]]; then
		BEST_GITHUB_PROXY="DIRECT"
		log_info "选定下载地址: GitHub 源站（延迟 ${BEST_GITHUB_PROXY_LATENCY} ms）"
	else
		BEST_GITHUB_PROXY="${best_prefix}"
		log_info "选定下载地址: ${BEST_GITHUB_PROXY}（延迟 ${BEST_GITHUB_PROXY_LATENCY} ms）"
	fi

	BEST_GITHUB_PROXY_SELECTION_STATE="done"
	return 0
}

build_ordered_github_candidates() {
	local source_url="$1"
	local -a ordered_urls=()

	if select_best_github_proxy; then
		if [[ "${BEST_GITHUB_PROXY}" == "DIRECT" ]]; then
			ordered_urls+=("${source_url}")
			for prefix in "${GITHUB_PROXY_ENDPOINTS[@]}"; do
				ordered_urls+=("${prefix}/${source_url}")
			done
		else
			ordered_urls+=("${BEST_GITHUB_PROXY}/${source_url}")
			for prefix in "${GITHUB_PROXY_ENDPOINTS[@]}"; do
				[[ "${prefix}" == "${BEST_GITHUB_PROXY}" ]] && continue
				ordered_urls+=("${prefix}/${source_url}")
			done
			ordered_urls+=("${source_url}")
		fi
	else
		for prefix in "${GITHUB_PROXY_ENDPOINTS[@]}"; do
			ordered_urls+=("${prefix}/${source_url}")
		done
		ordered_urls+=("${source_url}")
	fi

	printf '%s\n' "${ordered_urls[@]}"
}

# download_from_github_mirrors 优先通过 GitHub 镜像站下载文件，自动选择最快镜像并回退到源站。
# 参数：
#   $1 - 原始 GitHub 下载地址
#   $2 - 输出文件名
# 返回：
#   0 - 下载成功
#   1 - 所有镜像均失败
download_from_github_mirrors() {
	local source_url="$1"
	local output_name="$2"
	local tmp_file

	tmp_file="${output_name}.tmp"
	rm -f "${tmp_file}"

	local candidate
	while IFS= read -r candidate; do
		[[ -z "${candidate}" ]] && continue
		log_info "开始下载: ${candidate}"
		if curl -fL --connect-timeout 10 --retry 2 --retry-delay 3 -o "${tmp_file}" "${candidate}"; then
			mv "${tmp_file}" "${output_name}"
			log_info "下载完成: ${candidate}"
			return 0
		fi
		log_warning "下载失败: ${candidate}"
		rm -f "${tmp_file}"
	done < <(build_ordered_github_candidates "${source_url}")

	return 1
}

# Debian 13：手动下载并安装 45Drives 组件
install_45drives_components_manual() {
	local base_tmp_root="/tmp/debian-homenas"
	mkdir -p "${base_tmp_root}"
	# 临时设置根目录为 0711，允许 `_apt` 遍历以读取本地 .deb
	local base_orig_mode
	base_orig_mode="$(stat -c '%a' "${base_tmp_root}" 2>/dev/null || echo 700)"
	chmod 711 "${base_tmp_root}" || true
	# 创建 0755 子目录，供 `_apt` 读取 .deb
	local apt_dir
	apt_dir=$(mktemp -d -p "${base_tmp_root}" "45drives.XXXXXXXX")
	chmod 755 "${apt_dir}" || true
	local oldpwd
	oldpwd="$(pwd)"
	# 在 RETURN 时恢复工作目录与权限，并清理临时目录
	trap 'trap - RETURN; cd "${oldpwd}" >/dev/null 2>&1 || true; chmod "${base_orig_mode}" "${base_tmp_root}" >/dev/null 2>&1 || true; rm -rf "${apt_dir}"' RETURN

	local upstream_urls=(
		"https://github.com/45Drives/cockpit-navigator/releases/download/v0.5.10/cockpit-navigator_0.5.10-1focal_all.deb"
		"https://github.com/45Drives/cockpit-file-sharing/releases/download/v4.3.2/cockpit-file-sharing_4.3.2-2bookworm_all.deb"
		"https://github.com/45Drives/cockpit-identities/releases/download/v0.1.12/cockpit-identities_0.1.12-1focal_all.deb"
	)

	log_info "正在手动下载并安装 45Drives Cockpit 组件..."

	cd "${apt_dir}"

	# 下载 .deb 包
	for source_url in "${upstream_urls[@]}"; do
		local filename
		filename=$(basename "${source_url}")
		log_info "正在下载: ${filename}"

		if ! download_from_github_mirrors "${source_url}" "${filename}"; then
			log_error "下载失败: ${filename}"
			return 1
		fi
	done

	# 使用 apt 安装本地 .deb；目录权限已满足 `_apt` 读取要求
	for deb_file in *.deb; do
		if [[ -f "$deb_file" ]]; then
			log_info "正在安装: ${deb_file}"
			if ! apt install -y "./${deb_file}"; then
				log_error "安装失败: ${deb_file}"
				return 1
			fi
		fi
	done

	log_success "45Drives Cockpit 组件手动安装完成"
	return 0
}

configure_45drives_repo() {
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
}

install_core_cockpit_packages() {
	log_info "正在安装 Cockpit 核心组件..."
	if ! apt install -y cockpit pcp python3-pcp tuned; then
		log_error "Cockpit 核心组件安装失败。"
		exit "${ERROR_GENERAL}"
	fi
}

install_45drives_components_repo() {
	log_info "正在通过软件源安装 45Drives Cockpit 组件..."
	if ! apt install -y cockpit-navigator cockpit-file-sharing cockpit-identities; then
		log_error "45Drives Cockpit 组件安装失败。"
		exit "${ERROR_GENERAL}"
	fi
}

configure_cockpit_runtime_files() {
	local system_name="$1"
	mkdir -p /etc/cockpit
	cat >"/etc/cockpit/cockpit.conf" <<'EOF'
[Session]
IdleTimeout=15
Banner=/etc/cockpit/issue.cockpit

[WebService]
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
LoginTo = false
LoginTitle = HomeNAS
EOF

	cat >"/etc/motd" <<'EOF'
我们信任您已经从系统管理员那里了解了日常注意事项。
总结起来无外乎这三点：
1、尊重别人的隐私；
2、输入前要先考虑（后果和风险）；
3、权力越大，责任越大。
EOF

	cat >"/etc/cockpit/issue.cockpit" <<EOF
基于${system_name}搭建 HomeNAS
EOF
}

main() {
	local system_name system_codename support_45drives
	system_name=$(get_system_name)
	system_codename=$(get_system_codename)

	log_info "检测到系统: ${system_name} ${system_codename}"

	case "${system_codename}" in
	"bookworm")
		log_info "Debian 12 (bookworm) - 支持 45Drives 软件源"
		support_45drives=true
		;;
	"trixie")
		log_info "Debian 13 (trixie) - 不支持 45Drives 软件源，将使用手动下载安装"
		support_45drives=false
		;;
	*)
		log_error "不支持的 Debian 版本: ${system_codename}"
		log_error "仅支持 Debian 12 (bookworm) 和 Debian 13 (trixie)"
		exit "${ERROR_UNSUPPORTED_OS}"
		;;
	esac

	if [[ "${support_45drives}" == true ]]; then
		configure_45drives_repo
	else
		log_info "Debian 13 不支持 45Drives 软件源，跳过配置步骤"
	fi

	if ! configure_cockpit_pinning "${system_codename}"; then
		log_error "APT Pinning 配置失败。"
		exit "${ERROR_GENERAL}"
	fi
	if ! apply_pinning_config; then
		log_error "APT Pinning 配置应用失败。"
		exit "${ERROR_GENERAL}"
	fi

	install_core_cockpit_packages

	if [[ "${support_45drives}" == true ]]; then
		install_45drives_components_repo
	else
		if ! install_45drives_components_manual; then
			log_error "45Drives Cockpit 组件手动安装失败。"
			exit "${ERROR_GENERAL}"
		fi
	fi

	configure_cockpit_runtime_files "${system_name}"

	if ! systemctl try-restart cockpit; then
		log_error "Cockpit 服务重启失败。"
		exit "${ERROR_GENERAL}"
	fi

	log_success "Cockpit 管理面板安装完成"
}

main "$@"
