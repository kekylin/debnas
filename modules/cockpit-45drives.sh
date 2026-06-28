#!/bin/bash
# @module: cockpit-45drives
# @name: 45Drives 扩展
# @category: 管理面板
# @depends: curl
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 31
# 功能：安装 45Drives Cockpit 扩展组件（文件共享、身份管理、导航器）
# 说明：Debian 12 通过 45Drives 官方仓库安装；Debian 13 从 GitHub 手动下载 .deb 安装

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== GitHub 代理探测 ====================

BEST_GITHUB_PROXY_SELECTION_STATE=""
BEST_GITHUB_PROXY=""
BEST_GITHUB_PROXY_LATENCY=""

readonly PING_TIMEOUT=3

measure_ping_latency() {
	local target="$1"
	local output latency

	if ! output=$(ping -c 1 -W "${PING_TIMEOUT}" "${target}" 2>/dev/null); then
		return 1
	fi

	latency=$(printf '%s\n' "${output}" | awk -F'time=' '/time=/{split($2,a," "); print a[1]; exit}')
	if [[ -z "${latency}" ]]; then
		return 1
	fi

	printf '%s\n' "${latency}"
	return 0
}

_measure_proxy_latency_async() {
	local prefix="$1"
	local result_file="$2"
	local host latency

	if [[ "$prefix" == "DIRECT" ]]; then
		host="github.com"
	else
		host=$(printf '%s\n' "${prefix}" | sed -E 's#^[a-z]+://([^/]+).*#\1#')
	fi

	if latency=$(measure_ping_latency "${host}"); then
		printf '%s|%s\n' "${latency}" "${prefix}" > "${result_file}"
	else
		printf '%s|%s\n' "999999" "${prefix}" > "${result_file}"
	fi
}

select_best_github_proxy() {
	if [[ "${BEST_GITHUB_PROXY_SELECTION_STATE}" == "done" || "${BEST_GITHUB_PROXY_SELECTION_STATE}" == "skip" ]]; then
		[[ "${BEST_GITHUB_PROXY_SELECTION_STATE}" == "done" ]]
		return
	fi

	# 非国内用户：跳过镜像测速，直接使用 GitHub 官方源
	if [[ "${DEBNAS_REGION:-global}" != "cn" ]]; then
		log_info "Region: ${DEBNAS_REGION:-global} — 使用 GitHub 官方源直连"
		BEST_GITHUB_PROXY="DIRECT"
		BEST_GITHUB_PROXY_SELECTION_STATE="done"
		return 0
	fi

	if ! command -v ping >/dev/null 2>&1; then
		log_warning "ping 未安装，无法执行 GitHub 镜像延迟检测，将按预设顺序尝试下载"
		BEST_GITHUB_PROXY_SELECTION_STATE="skip"
		return 1
	fi

	log_info "测试 GitHub 镜像延迟..."

	local temp_dir
	temp_dir=$(create_temp_dir "github-proxy-test")
	local -a result_files=()
	local -a pids=()

	for prefix in $(get_github_proxy_endpoints); do
		local result_file="${temp_dir}/$(basename "${prefix}" | tr -cd '[:alnum:]').result"
		result_files+=("${result_file}")
		_measure_proxy_latency_async "${prefix}" "${result_file}" &
		pids+=($!)
	done

	local direct_result_file="${temp_dir}/direct.result"
	result_files+=("${direct_result_file}")
	_measure_proxy_latency_async "DIRECT" "${direct_result_file}" &
	pids+=($!)

	local failed_count=0
	for pid in "${pids[@]}"; do
		if ! wait "${pid}"; then
			((failed_count++)) || true
		fi
	done

	local -a measurements=()
	for result_file in "${result_files[@]}"; do
		if [[ -f "${result_file}" ]]; then
			measurements+=("$(cat "${result_file}")")
		fi
	done

	rm -rf "${temp_dir}"

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

# 构建有序下载候选列表（纯函数，不执行测速；依赖已缓存的 BEST_GITHUB_PROXY）
build_ordered_github_candidates() {
	local source_url="$1"
	local -a ordered_urls=()

	# 非国内用户：仅使用 GitHub 官方源
	if [[ "${DEBNAS_REGION:-global}" != "cn" ]]; then
		printf '%s\n' "${source_url}"
		return 0
	fi

	if [[ -n "${BEST_GITHUB_PROXY}" && "${BEST_GITHUB_PROXY}" == "DIRECT" ]]; then
		ordered_urls+=("${source_url}")
		for prefix in $(get_github_proxy_endpoints); do
			ordered_urls+=("${prefix}/${source_url}")
		done
	elif [[ -n "${BEST_GITHUB_PROXY}" ]]; then
		ordered_urls+=("${BEST_GITHUB_PROXY}/${source_url}")
		for prefix in $(get_github_proxy_endpoints); do
			[[ "${prefix}" == "${BEST_GITHUB_PROXY}" ]] && continue
			ordered_urls+=("${prefix}/${source_url}")
		done
		ordered_urls+=("${source_url}")
	else
		# 测速未执行（skip），按预设顺序
		for prefix in $(get_github_proxy_endpoints); do
			ordered_urls+=("${prefix}/${source_url}")
		done
		ordered_urls+=("${source_url}")
	fi

	printf '%s\n' "${ordered_urls[@]}"
}

download_from_github_mirrors() {
	local source_url="$1"
	local output_name="$2"
	local tmp_file

	tmp_file="${output_name}.tmp"
	rm -f "${tmp_file}"

	# 先构建候选列表到数组（在父 shell 中执行，避免进程替换子 shell）
	local -a candidates=()
	local candidate
	while IFS= read -r candidate; do
		[[ -z "${candidate}" ]] && continue
		candidates+=("${candidate}")
	done < <(build_ordered_github_candidates "${source_url}")

	local attempt_count=0
	local max_attempts=3

	for candidate in "${candidates[@]}"; do
		((attempt_count++)) || true
		log_info "开始下载 (尝试 ${attempt_count}/${max_attempts}): ${candidate}"

		if curl -fL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 3 -o "${tmp_file}" "${candidate}"; then
			mv "${tmp_file}" "${output_name}"
			log_info "下载完成: ${candidate}"
			return 0
		fi

		log_warning "下载失败: ${candidate}"
		rm -f "${tmp_file}"

		if [[ $attempt_count -ge $max_attempts ]]; then
			break
		fi
	done

	return 1
}

# ==================== Debian 13: 手动下载安装 ====================

install_45drives_components_manual() {
	local apt_dir
	apt_dir=$(create_temp_dir "45drives")
	local oldpwd
	oldpwd="$(pwd)"
	trap 'trap - RETURN; cd "${oldpwd}" >/dev/null 2>&1 || true; rm -rf "${apt_dir}"' RETURN

	local upstream_urls=(
		"https://github.com/45Drives/cockpit-file-sharing/releases/download/v4.6.0/cockpit-file-sharing_4.6.0-1bookworm_all.deb"
		"https://github.com/45Drives/cockpit-identities/releases/download/v0.1.12/cockpit-identities_0.1.12-1focal_all.deb"
	)

	log_info "下载并安装 45Drives 组件..."

	# 一次性测速（当前会话内缓存，后续下载复用）
	select_best_github_proxy 2>/dev/null || true

	cd "${apt_dir}"

	for source_url in "${upstream_urls[@]}"; do
		local filename
		filename=$(basename "${source_url}")
		log_info "下载 ${filename}"

		if ! download_from_github_mirrors "${source_url}" "${filename}"; then
			log_error "下载失败: ${filename}"
			return 1
		fi
	done

	for deb_file in *.deb; do
		if [[ -f "$deb_file" ]]; then
			log_info "安装 ${deb_file}..."
			if ! apt install -y "./${deb_file}"; then
				log_error "安装失败: ${deb_file}"
				return 1
			fi
		fi
	done

	log_success "45Drives 组件就绪"
	return 0
}

# ==================== Debian 12: 通过官方仓库安装 ====================

configure_45drives_repo() {
	log_info "配置 45Drives 源..."
	if ! command -v lsb_release >/dev/null; then
		if ! apt_install_packages lsb-release; then
			log_error "lsb-release 安装失败。"
			return 1
		fi
	fi
	if ! curl -sSL --max-time 60 --connect-timeout 15 https://repo.45drives.com/setup | bash; then
		if [ ! -f /etc/apt/sources.list.d/45drives.sources ]; then
			log_error "45Drives 软件源配置失败。"
			return 1
		fi
	fi
}

install_45drives_components_repo() {
	log_info "通过源安装 45Drives 组件..."
	if ! apt_install_packages cockpit-navigator cockpit-file-sharing cockpit-identities; then
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
	"bookworm")
		log_info "Debian 12: 45Drives 仓库"
		configure_45drives_repo
		install_45drives_components_repo
		;;
	"trixie")
		log_info "Debian 13: GitHub .deb"
		if ! install_45drives_components_manual; then
			log_error "45Drives Cockpit 组件手动安装失败。"
			exit "${ERROR_GENERAL}"
		fi
		;;
	*)
		log_error "不支持的 Debian 版本: ${system_codename}"
		log_error "仅支持 Debian 12 (bookworm) 和 Debian 13 (trixie)"
		exit "${ERROR_UNSUPPORTED_OS}"
		;;
	esac

}

main "$@"
