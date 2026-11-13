#!/bin/bash
# @module: cockpit
# @name: 安装 Cockpit 面板
# @category: 管理面板
# @depends: curl
# @version: 4.0.0
# @order: 30
# 功能：安装 Cockpit 核心组件（从 backports 获取最新版本）
# 说明：共享管理界面由 cockpit-45drives 模块安装（45Drives 官方插件）。

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# Cockpit 核心包清单（main 安装与只读探测共用）；cockpit-files 仅在有候选版本时安装（Debian 12 主仓/backports 均未提供）
COCKPIT_CORE_PACKAGES=(cockpit cockpit-files pcp python3-pcp tuned)

# cockpit.conf 中的 DebNAS 管理标记行（写入与只读探测共用）
COCKPIT_CONF_MARKER="# 由 DebNAS 管理：如需自定义请删除本行，DebNAS 将不再覆盖此文件"

# ==================== Cockpit 核心安装 ====================

# 软件包在当前 APT 源中是否有候选版本（只读：读本地 apt 缓存，不联网）
# 参数：$1 - 包名
# 返回：0 有候选版本，1 无（含包名未知）
_cockpit_pkg_has_candidate() {
	local line
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*Candidate:[[:space:]]*([^[:space:]]+) ]]; then
			[[ "${BASH_REMATCH[1]}" != "(none)" ]]
			return
		fi
	done < <(LC_ALL=C apt-cache policy "$1" 2>/dev/null)
	return 1
}

# 本机要安装的核心包：COCKPIT_CORE_PACKAGES 去掉无候选版本且未安装的 cockpit-files（只读）
# 输出：每行一个包名
_cockpit_wanted_packages() {
	local pkg
	for pkg in "${COCKPIT_CORE_PACKAGES[@]}"; do
		if [[ "$pkg" == "cockpit-files" ]] && ! pkg_is_installed "$pkg" && ! _cockpit_pkg_has_candidate "$pkg"; then
			continue
		fi
		printf '%s\n' "$pkg"
	done
}

install_core_cockpit_packages() {
	log_info "安装 Cockpit 核心组件..."

	local IFS=$' \n\t'
	local -a pkgs=()
	mapfile -t pkgs < <(_cockpit_wanted_packages)
	if [[ " ${pkgs[*]} " != *" cockpit-files "* ]]; then
		log_warning "当前软件源无 cockpit-files（Debian 12 未提供），跳过；如需网页文件管理可升级 Debian 13 或另装文件管理插件"
	fi

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
	_COCKPIT_WRITE_FAILED=0

	# 旧版本写入的内容（用于识别可安全迁移的 DebNAS 生成文件）
	local legacy_conf="[Session]
IdleTimeout=15
Banner=/etc/cockpit/issue.cockpit

[WebService]
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
LoginTo = false
LoginTitle = DebNAS"
	local marker="$COCKPIT_CONF_MARKER"

	# 信任 X-Forwarded-* 头只在 Cockpit 位于反向代理之后才安全；直连时客户端可伪造
	# 来源 IP/协议。默认不写，需要时在 /etc/debnas/debnas.conf 设置 cockpit_behind_proxy=1
	local proxy_headers=""
	if config_get_bool cockpit_behind_proxy 0; then
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
	[[ -f "$conf_path" && -r "$conf_path" ]] && current_conf=$(< "$conf_path")
	if [[ ! -f "$conf_path" ]] || [[ "$current_conf" == "$legacy_conf" ]] \
		|| grep -qxF "$marker" "$conf_path" 2>/dev/null; then
		local wrc=0
		write_file_if_changed "$conf_path" "$cockpit_conf" || wrc=$?
		if [[ "$wrc" -eq 0 ]]; then
			config_changed=1
		elif [[ "$wrc" -eq 2 ]]; then
			log_error "写入 ${conf_path} 失败"
			_COCKPIT_WRITE_FAILED=1
		fi
	else
		log_warning "${conf_path} 已被用户自定义，跳过覆盖（如需恢复默认请删除该文件后重新运行）"
	fi

	local motd_content="我们信任您已经从系统管理员那里了解了日常注意事项。
总结起来无外乎这三点：
1、尊重别人的隐私；
2、输入前要先考虑（后果和风险）；
3、权力越大，责任越大。"
	local wrc=0
	write_file_if_changed "/etc/motd" "$motd_content" || wrc=$?
	if [[ "$wrc" -eq 0 ]]; then
		config_changed=1
	elif [[ "$wrc" -eq 2 ]]; then
		log_error "写入 /etc/motd 失败"
		_COCKPIT_WRITE_FAILED=1
	fi

	local issue_content="基于${system_name}搭建 DebNAS"
	wrc=0
	write_file_if_changed "/etc/cockpit/issue.cockpit" "$issue_content" || wrc=$?
	if [[ "$wrc" -eq 0 ]]; then
		config_changed=1
	elif [[ "$wrc" -eq 2 ]]; then
		log_error "写入 /etc/cockpit/issue.cockpit 失败"
		_COCKPIT_WRITE_FAILED=1
	fi

	printf '%d' "$config_changed"
}

# ==================== NetworkManager 与 systemd-networkd 共存 ====================
# cockpit 的依赖会带入 NetworkManager。在 netplan / systemd-networkd 管理网络的系统（云镜像等）上，
# NM 会给不在 ifupdown 里的网卡自动建 "Wired connection" 并 DHCP，同一网卡于是多出一个地址。
# 处理：写 conf.d 片段让 NM 不接管 networkd 已管理的网卡。没有 networkd 管理网卡的系统
# （ifupdown 的常规安装）不写该文件、行为不变。cockpit-net 跳过切换时也调用这里的函数。

COCKPIT_NM_GUARD_CONF="/etc/NetworkManager/conf.d/10-debnas-unmanaged.conf"

# systemd-networkd 正在管理的网卡（只读）：networkctl list 的 SETUP 列为 configured / configuring，不含 lo
# 输出：每行一个网卡名（networkd 未运行、无 networkctl 时无输出）
_cockpit_networkd_ifaces() {
	command -v networkctl &>/dev/null || return 0
	systemctl is-active --quiet systemd-networkd 2>/dev/null || return 0
	local out link setup
	out=$(timeout 2 networkctl list --no-legend --no-pager 2>/dev/null) || return 0
	while IFS=$' \t' read -r _ link _ _ setup _; do
		[[ "$link" != "lo" && "$link" =~ ^[A-Za-z0-9._@-]+$ ]] || continue
		[[ "$setup" == "configured" || "$setup" == "configuring" ]] || continue
		printf '%s\n' "$link"
	done <<< "$out"
	return 0
}

# 生成片段内容（只读）
# 参数：$@ - 网卡名
# 写法（Debian 12 的 NM 1.42、Debian 13 的 NM 1.52 实测）：必须用 [keyfile] unmanaged-devices；
# [device] managed=0 会被 /run/NetworkManager/devices/ 里记下的"曾显式接管"状态盖过，重启后 NM 照样接管。
# 用 += 追加，不覆盖 NetworkManager.conf 或其他片段里已有的 unmanaged-devices
_cockpit_nm_guard_render() {
	local iface spec=""
	for iface in "$@"; do
		spec+="${spec:+,}interface-name:${iface}"
	done
	printf '%s\n' \
		"# 由 DebNAS 管理（cockpit 模块生成）：下列网卡已由 systemd-networkd 管理（netplan 默认 renderer 即 networkd），" \
		"# 这里让 NetworkManager 不再接管它们，否则同一网卡会被两边各配一个 DHCP 地址。" \
		"# 如果以后改由 NetworkManager 管理网络（例如把 netplan 的 renderer 改为 NetworkManager），本片段不再适用：" \
		"# 请先删除本文件并执行 systemctl reload NetworkManager，再 netplan apply；否则 NetworkManager 不会接管这些网卡。" \
		"[keyfile]" \
		"unmanaged-devices+=${spec}"
}

# 参数所列网卡中仍被 NetworkManager 接管的（只读；NM 未运行或无 nmcli 时无输出）
# 参数：$@ - 网卡名；输出：每行一个网卡名
_cockpit_nm_managed_ifaces() {
	command -v nmcli &>/dev/null || return 0
	local out dev state iface
	out=$(timeout 3 nmcli -t -f DEVICE,STATE device status 2>/dev/null) || return 0
	while IFS=: read -r dev state; do
		[[ -n "$dev" && "$state" != "unmanaged" ]] || continue
		for iface in "$@"; do
			[[ "$dev" == "$iface" ]] && printf '%s\n' "$dev"
		done
	done <<< "$out"
	return 0
}

# 共存状态（只读）：一行 "<状态>|<网卡，逗号分隔>"
#   none     没有 networkd 管理的网卡（常规安装），无需片段
#   ok       片段已就位，NM 未接管这些网卡
#   missing  需要写入/更新片段（NM 未安装/未运行/尚未接管）
#   conflict 片段已就位，但运行中的 NM 仍接管着列出的网卡（需重启 NM 放开）
#   unwritten-conflict 片段未写入，且运行中的 NM 已接管列出的网卡（双重管理，即多出一个地址的现象）
#   stale    片段还在，但已没有 networkd 管理的网卡（如 renderer 已改为 NetworkManager），应删除
_cockpit_nm_guard_state() {
	local IFS=$' \n\t'
	local -a ifaces=() managed=()
	local want cur=""
	mapfile -t ifaces < <(_cockpit_networkd_ifaces)
	if [[ ${#ifaces[@]} -eq 0 ]]; then
		if [[ -e "$COCKPIT_NM_GUARD_CONF" ]]; then echo "stale|"; else echo "none|"; fi
		return 0
	fi
	local IFS=','
	want=$(_cockpit_nm_guard_render "${ifaces[@]}")
	[[ -r "$COCKPIT_NM_GUARD_CONF" ]] && cur=$(< "$COCKPIT_NM_GUARD_CONF")
	mapfile -t managed < <(_cockpit_nm_managed_ifaces "${ifaces[@]}")
	if [[ ${#managed[@]} -gt 0 ]]; then
		if [[ "$cur" != "$want" ]]; then echo "unwritten-conflict|${managed[*]}"; else echo "conflict|${managed[*]}"; fi
	elif [[ "$cur" != "$want" ]]; then
		echo "missing|${ifaces[*]}"
	else
		echo "ok|${ifaces[*]}"
	fi
}

# 预演行（只读，cockpit 与 cockpit-net 的 module_plan 共用）
_cockpit_nm_guard_plan() {
	local state ifaces
	state=$(_cockpit_nm_guard_state)
	ifaces="${state#*|}"
	state="${state%%|*}"
	case "$state" in
	missing | unwritten-conflict)
		echo "write|${COCKPIT_NM_GUARD_CONF}|网卡 ${ifaces} 由 systemd-networkd 管理：写入片段让 NetworkManager 不接管（避免同一网卡两个 DHCP 地址）；已有文件时原件备份到 /var/backups/debnas/"
		;;&
	conflict | unwritten-conflict)
		echo "service|NetworkManager|仍接管 systemd-networkd 管理的网卡 ${ifaces}：重启一次使其放开，删除它自动建的连接并移除它 DHCP 到的多余地址（networkd 的地址、路由不动，SSH 不断）"
		;;
	ok)
		echo "info|${COCKPIT_NM_GUARD_CONF}|NetworkManager 已不接管 systemd-networkd 管理的网卡 ${ifaces}（已满足）；改由 NetworkManager 管理网络前需先删除该文件"
		;;
	stale)
		echo "info|${COCKPIT_NM_GUARD_CONF}|已没有 systemd-networkd 管理的网卡，该片段不再适用（模块不自动删除）：如需 NetworkManager 接管，请删除该文件并 systemctl reload NetworkManager"
		;;
	esac
	return 0
}

# NetworkManager 在某网卡上自己 DHCP 到的 IPv4 地址（需在 NM 放开网卡之前调用）
# 参数：$1 - 网卡名；输出：地址（无则空）
_cockpit_nm_dhcp4_addr() {
	local out line
	out=$(timeout 3 nmcli -t -f DHCP4.OPTION device show "$1" 2>/dev/null) || return 0
	while IFS= read -r line; do
		if [[ "$line" =~ ip_address[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
			printf '%s' "${BASH_REMATCH[1]}"
			return 0
		fi
	done <<< "$out"
	return 0
}

# 移除 NetworkManager 留在网卡上的 DHCP 地址；拿不准就不删（该地址带租约有效期，到期后内核会自行移除）
# 参数：$1 - 网卡名；$2 - NM 放开网卡前记录的它自己的 DHCP 地址
_cockpit_drop_nm_addr() {
	local iface="$1" addr="$2"
	local line prefix="" primary=1 others=0 ifindex="" lease_addr="" promote="" f
	while IFS= read -r line; do
		if [[ "$line" =~ [[:space:]]inet[[:space:]]${addr//./\\.}/([0-9]+)[[:space:]] ]]; then
			# 只认 NM 加的地址：dynamic + noprefixroute（networkd 的地址不带 noprefixroute）
			[[ "$line" == *" dynamic "* && "$line" == *" noprefixroute "* ]] || return 0
			prefix="${BASH_REMATCH[1]}"
			[[ "$line" == *" secondary "* ]] && primary=0
		elif [[ "$line" == *" inet "* ]]; then
			others=$((others + 1))
		fi
	done < <(ip -o -4 addr show dev "$iface" 2>/dev/null || true)
	[[ -n "$prefix" ]] || return 0

	# networkd 自己的租约恰好是同一个地址：不动
	[[ -r "/sys/class/net/${iface}/ifindex" ]] && ifindex=$(< "/sys/class/net/${iface}/ifindex")
	if [[ -n "$ifindex" && -r "/run/systemd/netif/leases/${ifindex}" ]]; then
		while IFS='=' read -r f line; do
			[[ "$f" == "ADDRESS" ]] && lease_addr="$line"
		done < "/run/systemd/netif/leases/${ifindex}"
	fi
	if [[ "$lease_addr" == "$addr" ]]; then
		return 0
	fi
	# 有连接正在使用该地址（SSH / 网页会话连的是这个地址）：不删，等租约到期
	local ssh_local="${SSH_CONNECTION:-}"
	ssh_local="${ssh_local% *}"
	ssh_local="${ssh_local##* }"
	if [[ "$ssh_local" == "$addr" ]] || [[ -n "$(ss -Htn state established src "$addr" 2>/dev/null || true)" ]]; then
		log_warning "网卡 ${iface} 上 NetworkManager 留下的地址 ${addr} 仍有连接在使用，未移除；租约到期后会自行消失，也可改用 systemd-networkd 的地址连接后执行：ip addr del ${addr}/${prefix} dev ${iface}"
		return 0
	fi
	# 它是主地址且网卡未开 promote_secondaries：删除会连带删掉同网段的其他地址，不删
	if [[ $primary -eq 1 && $others -gt 0 ]]; then
		for f in "/proc/sys/net/ipv4/conf/${iface}/promote_secondaries" /proc/sys/net/ipv4/conf/all/promote_secondaries; do
			[[ -r "$f" && "$(< "$f")" == "1" ]] && promote=1
		done
		if [[ "$promote" != "1" ]]; then
			log_warning "网卡 ${iface} 上 NetworkManager 留下的地址 ${addr} 是主地址，未移除（租约到期后会自行消失）"
			return 0
		fi
	fi
	if ip -4 addr del "${addr}/${prefix}" dev "$iface" 2>/dev/null; then
		log_success "已移除网卡 ${iface} 上 NetworkManager 多拿的地址 ${addr}/${prefix}"
	else
		log_warning "移除网卡 ${iface} 上的地址 ${addr}/${prefix} 失败（租约到期后会自行消失）"
	fi
	return 0
}

# 让运行中的 NetworkManager 放开已被它接管的网卡，并清理它留下的连接与地址
# 参数：$@ - 仍被 NM 接管的网卡名
# 说明：不用 reload——运行中的 NM 把活动网卡改为 unmanaged 时会撤销配置并把网卡置 down，SSH 会断；
#       重启时 NM 退出不动现场，启动后读到片段就不再接管，再由本函数只移除 NM 自己拿的那个地址
_cockpit_nm_release_ifaces() {
	local IFS=$' \n\t'
	local iface uuid dev file addr entry
	local -a uuids=() addrs=() still=()
	# 重启前记录：NM 为这些网卡自动生成的连接（只认 /run 下的内存连接，用户自建的落盘连接不动）与它 DHCP 到的地址
	while IFS=: read -r uuid dev file; do
		[[ -n "$uuid" && "$file" == /run/NetworkManager/system-connections/* ]] || continue
		for iface in "$@"; do
			[[ "$dev" == "$iface" ]] && uuids+=("$uuid")
		done
	done < <(timeout 5 nmcli -t -f UUID,DEVICE,FILENAME connection show --active 2>/dev/null || true)
	for iface in "$@"; do
		addr=$(_cockpit_nm_dhcp4_addr "$iface")
		[[ -n "$addr" ]] && addrs+=("${iface}/${addr}")
	done
	# /etc/resolv.conf 为普通文件（未用 systemd-resolved）时留底：NM 放开网卡后若把它写空则恢复
	local resolv="/etc/resolv.conf" resolv_before=""
	[[ -f "$resolv" && ! -L "$resolv" ]] && resolv_before=$(< "$resolv")

	log_info "重启 NetworkManager，使其放开 systemd-networkd 管理的网卡：$*"
	if ! service_ensure "NetworkManager" "restarted"; then
		log_warning "NetworkManager 重启失败，网卡 $* 仍可能被两边同时管理；请手动执行 systemctl restart NetworkManager"
		return 0
	fi
	# 等 NM 启动完成（启动过程中设备状态尚未定型）
	if command -v nm-online &>/dev/null; then
		nm-online -s -q -t 20 &>/dev/null || true
	else
		sleep 3
	fi
	mapfile -t still < <(_cockpit_nm_managed_ifaces "$@")
	if [[ ${#still[@]} -gt 0 ]]; then
		log_warning "NetworkManager 重启后仍接管网卡 ${still[*]}，未做清理；请检查 ${COCKPIT_NM_GUARD_CONF} 是否被其他配置覆盖"
		return 0
	fi

	local all_uuids
	all_uuids=$(timeout 5 nmcli -t -f UUID connection show 2>/dev/null) || all_uuids=""
	for uuid in "${uuids[@]}"; do
		[[ $'\n'"${all_uuids}"$'\n' == *$'\n'"${uuid}"$'\n'* ]] || continue
		timeout 10 nmcli connection delete uuid "$uuid" &>/dev/null \
			|| log_warning "删除 NetworkManager 自动生成的连接 ${uuid} 失败（不影响网络）"
	done
	for entry in "${addrs[@]}"; do
		_cockpit_drop_nm_addr "${entry%%/*}" "${entry#*/}"
	done
	if [[ -n "$resolv_before" && "$resolv_before" == *nameserver* && -f "$resolv" && ! -L "$resolv" ]] \
		&& ! grep -q '^[[:space:]]*nameserver' "$resolv" 2>/dev/null; then
		write_file_if_changed "$resolv" "$resolv_before" "" 1 || log_warning "恢复 ${resolv} 失败，请手动检查"
		log_warning "NetworkManager 放开网卡后清空了 ${resolv} 的 DNS，已恢复为之前的内容"
	fi
	log_success "网卡 $* 现仅由 systemd-networkd 管理"
	return 0
}

# 入口：网卡已由 systemd-networkd 管理时，写片段让 NetworkManager 不接管，并清理已发生的双重管理
# 可在安装 NetworkManager 之前调用（先写好片段，NM 首次启动即不接管）；幂等；任何失败只告警
configure_nm_networkd_guard() {
	local IFS=$' \n\t'
	local -a ifaces=() managed=()
	local content rc=0
	mapfile -t ifaces < <(_cockpit_networkd_ifaces)
	if [[ ${#ifaces[@]} -eq 0 ]]; then
		if [[ -e "$COCKPIT_NM_GUARD_CONF" ]]; then
			log_warning "已没有 systemd-networkd 管理的网卡，${COCKPIT_NM_GUARD_CONF} 不再适用：如需 NetworkManager 接管网卡，请删除该文件并执行 systemctl reload NetworkManager"
		fi
		return 0
	fi
	content=$(_cockpit_nm_guard_render "${ifaces[@]}")
	write_file_if_changed "$COCKPIT_NM_GUARD_CONF" "$content" "" 1 || rc=$?
	if [[ $rc -eq 2 ]]; then
		log_warning "写入 ${COCKPIT_NM_GUARD_CONF} 失败，NetworkManager 可能与 systemd-networkd 同时管理网卡 ${ifaces[*]}"
		return 0
	fi
	if [[ $rc -eq 0 ]]; then
		log_info "网卡 ${ifaces[*]} 由 systemd-networkd 管理，已写入 ${COCKPIT_NM_GUARD_CONF} 让 NetworkManager 不接管（改由 NetworkManager 管理网络前请先删除该文件）"
	fi
	mapfile -t managed < <(_cockpit_nm_managed_ifaces "${ifaces[@]}")
	if [[ ${#managed[@]} -gt 0 ]]; then
		_cockpit_nm_release_ifaces "${managed[@]}"
	fi
	return 0
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

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
	if ! pkg_is_installed cockpit; then
		echo "absent|未安装 Cockpit"
		return 0
	fi
	port=$(_cockpit_listen_port)
	if ! systemctl is-active --quiet cockpit.socket 2>/dev/null; then
		echo "warn|已安装但 cockpit.socket 未激活（端口 ${port}）"
		return 0
	fi
	owner=$(_cockpit_conf_owner)
	local files_ok=1
	if pkg_is_installed cockpit-files; then
		files_note="cockpit-files 已装"
	elif _cockpit_pkg_has_candidate cockpit-files; then
		files_note="缺 cockpit-files"
		files_ok=0
	else
		files_note="软件源无 cockpit-files"
	fi
	case "$owner" in
	debnas) conf_note="DebNAS 配置" ;;
	absent) conf_note="未写入 cockpit.conf" ;;
	custom) conf_note="cockpit.conf 无 DebNAS 标记（用户自定义或旧版生成）" ;;
	*) conf_note="cockpit.conf 不可读" ;;
	esac
	local nm_state
	nm_state=$(_cockpit_nm_guard_state)
	case "${nm_state%%|*}" in
	conflict | unwritten-conflict)
		echo "partial|运行中 · 端口 ${port} · 网卡 ${nm_state#*|} 被 NetworkManager 与 systemd-networkd 同时管理（会多出一个 DHCP 地址），重新执行本模块可修复"
		return 0
		;;
	stale) conf_note+=" · ${COCKPIT_NM_GUARD_CONF##*/} 已不适用（无 networkd 管理的网卡）" ;;
	esac
	if [[ $files_ok -eq 0 || "$owner" == "absent" ]]; then
		echo "partial|运行中 · 端口 ${port} · ${files_note} · ${conf_note}"
		return 0
	fi
	echo "running|运行中 · 端口 ${port} · ${files_note} · ${conf_note}"
}

# 预演：每行 "类型|目标|备注"（无副作用；与 main 的判断保持一致；已满足的不列）
module_plan() {
	local IFS=$' \n\t'
	local -a pkgs=() missing=()
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
	mapfile -t pkgs < <(_cockpit_wanted_packages)
	if [[ " ${pkgs[*]} " != *" cockpit-files "* ]]; then
		echo "info|cockpit-files|当前软件源无候选版本（Debian 12 未提供），执行时跳过；可升级 Debian 13 或另装文件管理插件"
	fi
	for pkg in "${pkgs[@]}"; do
		pkg_is_installed "$pkg" || missing+=("$pkg")
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
	if config_get_bool cockpit_behind_proxy 0; then
		echo "risk|cockpit.conf|cockpit_behind_proxy=1：信任 X-Forwarded-* 头，仅在 Cockpit 位于反向代理之后才安全"
	fi
	_cockpit_nm_guard_plan
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

	# 网卡已由 systemd-networkd 管理时，先写好片段再装包：cockpit 带入的 NetworkManager 首次启动就不会接管这些网卡
	configure_nm_networkd_guard

	# 安装核心包
	install_core_cockpit_packages || exit "${ERROR_GENERAL}"

	# 装包后复核一次（NM 早已装好并接管了网卡的存量系统在上一步已处理，这里通常无事可做）
	configure_nm_networkd_guard

	# 运行时配置
	local config_changed
	config_changed=$(configure_cockpit_runtime_files "${system_name}")
	if [[ "${_COCKPIT_WRITE_FAILED:-0}" -eq 1 ]]; then
		log_error "Cockpit 运行时配置写入失败"
		exit "${ERROR_GENERAL}"
	fi

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
