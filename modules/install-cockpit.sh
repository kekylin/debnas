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
)

# 构建镜像候选列表，包含镜像站与源站
build_github_candidate_urls() {
	local source_url="$1"
	local -a candidate_urls=()
	local proxy_prefix
	for proxy_prefix in "${GITHUB_PROXY_ENDPOINTS[@]}"; do
		candidate_urls+=("${proxy_prefix}/${source_url}")
	done
	candidate_urls+=("${source_url}")

	printf '%s\n' "${candidate_urls[@]}"
}

# 对镜像候选执行健康检查并按延迟排序，返回最优顺序
rank_github_candidate_urls() {
	local source_url="$1"
	local -a candidate_urls=()
	local candidate
	while IFS= read -r candidate; do
		candidate_urls+=("${candidate}")
	done < <(build_github_candidate_urls "${source_url}")

	local -a scored_urls=()
	local -a unreachable_urls=()
	local idx=0
	for candidate in "${candidate_urls[@]}"; do
		local start_ns end_ns elapsed_ms
		start_ns="$(date +%s%N)"
		if curl -fsI --connect-timeout 5 --max-time 8 "${candidate}" >/dev/null 2>&1; then
			end_ns="$(date +%s%N)"
			elapsed_ms=$(((end_ns - start_ns) / 1000000))
			scored_urls+=("${elapsed_ms}|${idx}|${candidate}")
		else
			unreachable_urls+=("${idx}|${candidate}")
		fi
		idx=$((idx + 1))
	done

	if ((${#scored_urls[@]} > 0)); then
		printf '%s\n' "${scored_urls[@]}" | sort -t'|' -k1,1n -k2,2n | cut -d'|' -f3
		if ((${#unreachable_urls[@]} > 0)); then
			printf '%s\n' "${unreachable_urls[@]}" | sort -t'|' -k1,1n | cut -d'|' -f2
		fi
	else
		printf '%s\n' "${candidate_urls[@]}"
	fi
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
		log_info "尝试下载镜像: ${candidate}"
		if curl -fL --connect-timeout 10 --retry 2 --retry-delay 3 -o "${tmp_file}" "${candidate}"; then
			mv "${tmp_file}" "${output_name}"
			log_info "镜像下载成功: ${candidate}"
			return 0
		fi
		log_warning "镜像不可用: ${candidate}"
		rm -f "${tmp_file}"
	done < <(rank_github_candidate_urls "${source_url}")

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
		"https://github.com/45Drives/cockpit-navigator/releases/download/v0.6.0/cockpit-navigator_0.6.0-1bookworm_all.deb"
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
