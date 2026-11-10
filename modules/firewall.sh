#!/bin/bash
# @module: firewall
# @name: 配置防火墙
# @category: 安全防护
# @depends:
# @version: 1.0.0
# @order: 41
# 功能：安装 firewalld 防火墙服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

_FW_CONF="/etc/firewalld/firewalld.conf"
_FW_ZONES_DIR="/etc/firewalld/zones"
_FW_SYS_ZONES_DIR="/usr/lib/firewalld/zones"

# 默认区（只读）：firewalld.conf 的 DefaultZone（firewall-cmd --set-default-zone 即写此处），缺省 public；
# 文件存在但当前用户不可读时问运行中的 firewalld，仍问不到按 public
# 指向不存在的区（/etc 与 /usr/lib 下均无对应文件）时 firewalld 自身回退 public，这里保持一致
_fw_default_zone() {
  local line zone=""
  if [[ -r "$_FW_CONF" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*DefaultZone[[:space:]]*=[[:space:]]*([A-Za-z0-9_-]+) ]]; then
        zone="${BASH_REMATCH[1]}"
      fi
    done < "$_FW_CONF"
  elif [[ -e "$_FW_CONF" ]]; then
    # firewall-cmd --set-default-zone 改写后的 firewalld.conf 为 600，普通用户读不到：改问运行中的 firewalld（D-Bus，免授权）
    line=$(timeout 1 busctl --system call org.fedoraproject.FirewallD1 /org/fedoraproject/FirewallD1 \
      org.fedoraproject.FirewallD1 getDefaultZone 2>/dev/null) || line=""
    [[ "$line" =~ ^s[[:space:]]+\"([A-Za-z0-9_-]+)\" ]] && zone="${BASH_REMATCH[1]}"
  fi
  if [[ -n "$zone" && "$zone" != "public" && ! -f "${_FW_ZONES_DIR}/${zone}.xml" \
    && ! -f "${_FW_SYS_ZONES_DIR}/${zone}.xml" ]]; then
    zone=""
  fi
  printf '%s' "${zone:-public}"
}

# 某个区当前生效的定义文件（只读）：/etc/firewalld/zones 优先，其次 /usr/lib/firewalld/zones；都没有输出空
# 参数：$1 - 区名
_fw_zone_effective_file() {
  if [[ -f "${_FW_ZONES_DIR}/${1}.xml" ]]; then
    printf '%s' "${_FW_ZONES_DIR}/${1}.xml"
  elif [[ -f "${_FW_SYS_ZONES_DIR}/${1}.xml" ]]; then
    printf '%s' "${_FW_SYS_ZONES_DIR}/${1}.xml"
  fi
}

# 在区定义 XML 的最后一个 </zone> 之前插入条目（纯内存计算，不写文件）
# 参数：$1 - 现有 XML 内容；$2.. - 条目（如 <service name="cockpit"/>）
# 输出：新内容；返回：1 内容中没有 </zone>（不是可追加的区定义）
_fw_zone_insert() {
  local content="$1" entry ins=""
  shift
  [[ "$content" == *"</zone>"* ]] || return 1
  for entry in "$@"; do
    ins+="  ${entry}"$'\n'
  done
  printf '%s' "${content%"</zone>"*}${ins}</zone>${content##*"</zone>"}"
}

# 当前状态：一行 "状态码|说明"（只读、不联网）
module_status() {
  local zone cfg
  if ! pkg_is_installed firewalld; then
    if command -v ufw &>/dev/null && service_is_active ufw; then
      echo "absent|未安装；UFW 运行中，安装时会停用 UFW"
    else
      echo "absent|未安装 firewalld"
    fi
    return 0
  fi
  if ! service_is_active firewalld; then
    echo "warn|已安装但 firewalld 未运行"
    return 0
  fi
  zone=$(_fw_default_zone)
  if [[ "$zone" == "trusted" ]]; then
    echo "warn|运行中 · 默认区为 trusted（放行全部入站，防火墙不起拦截作用）"
    return 0
  fi
  cfg=$(_fw_zone_effective_file "$zone")
  if [[ -n "$cfg" && -r "$cfg" ]] && ! grep -q '<service name="cockpit"/>' "$cfg" 2>/dev/null; then
    echo "partial|运行中 · ${zone} 区未放行 cockpit"
    return 0
  fi
  echo "running|运行中 · ${zone} 区已放行 ssh/cockpit"
}

# 预演：每行 "类型|目标|备注"（只读，与 main 的判断逻辑保持一致）
module_plan() {
  local IFS=$' \n\t'
  local zone cfg base
  zone=$(_fw_default_zone)
  cfg="${_FW_ZONES_DIR}/${zone}.xml"
  local -a services=(ssh dhcpv6-client cockpit) ports=() missing=()
  local port svc

  if pkg_is_installed firewalld; then
    echo "info|firewalld|已安装，跳过安装"
  else
    echo "pkg|firewalld|apt 安装（Debian 安装后立即启动）"
  fi
  if command -v ufw &>/dev/null; then
    echo "service|ufw|停用并取消开机自启（避免与 firewalld 冲突）"
    echo "risk|UFW|现有 UFW 规则将不再生效"
  fi

  # firewalld 的 ssh 服务只含 22，自定义端口必须单独放行（含当前会话端口），否则会被锁在门外
  for port in $(sshd_listen_ports); do
    [[ "$port" != "22" ]] && ports+=("$port")
  done
  service_is_installed smbd && services+=(samba)
  service_is_installed nfs-server && services+=(nfs mountd rpc-bind)

  [[ "$zone" == "public" ]] || echo "info|默认区|firewalld 默认区为 ${zone}（非 public），放行规则写入 ${zone} 区"
  if [[ "$zone" == "trusted" ]]; then
    echo "risk|${zone} 区|默认区 trusted 放行全部入站，无需也不写入放行规则；防火墙不起拦截作用，建议改回 public（firewall-cmd --set-default-zone=public）"
  elif [[ ! -f "$cfg" && "$zone" == "public" ]]; then
    echo "write|${cfg}|新建 public 区（放行 ${services[*]}${ports[*]:+ 及端口 ${ports[*]}}）"
  else
    # 已有区文件，或以 /usr/lib/firewalld/zones 的系统定义为基础：只补缺失项（dhcpv6-client 不强行补回）
    base=$(_fw_zone_effective_file "$zone")
    for svc in "${services[@]}"; do
      [[ "$svc" == "dhcpv6-client" ]] && continue
      grep -qF "<service name=\"${svc}\"/>" "$base" 2>/dev/null || missing+=("$svc")
    done
    for port in "${ports[@]}"; do
      grep -qF "<port protocol=\"tcp\" port=\"${port}\"/>" "$base" 2>/dev/null || missing+=("${port}/tcp")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
      echo "info|${base}|规则已齐全，不改动"
    elif [[ -f "$cfg" ]]; then
      echo "write|${cfg}|追加 ${missing[*]}（原件备份到 /var/backups/debnas/）"
    else
      echo "write|${cfg}|新建：以 ${base} 为基础追加 ${missing[*]}"
    fi
  fi
  for port in "${ports[@]}"; do
    echo "port|${port}/tcp|放行自定义 SSH 端口"
  done
  [[ "$zone" == "trusted" ]] || echo "port|${services[*]}|${zone} 区放行服务（cockpit=9090）"

  if service_is_active firewalld; then
    echo "service|firewalld|已运行：新规则仅追加到运行时（不 reload，保留 fail2ban 规则）"
  else
    echo "service|firewalld|启动并设为开机自启"
  fi

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local conn_ip="${SSH_CONNECTION%% *}" conn_port="${SSH_CONNECTION##* }"
    echo "risk|SSH|当前连接来自 ${conn_ip}，服务端端口 ${conn_port} 在放行列表内，不会断连"
  fi
  [[ "$zone" == "trusted" ]] || echo "risk|入站|启用后 ${zone} 区未放行的入站端口将被拦截（其他自建服务需另行放行）"
  return 0
}

main() {
  # 放行规则写入 firewalld 实际的默认区（用户可能已改成 home/internal 等，写 public 不生效）
  # 运行中以 firewall-cmd 的回答为准，否则读 firewalld.conf 的 DefaultZone（缺省 public）
  local zone=""
  if service_is_active firewalld && command -v firewall-cmd &> /dev/null; then
    zone=$(firewall-cmd --get-default-zone 2> /dev/null) || zone=""
  fi
  [[ "$zone" =~ ^[A-Za-z0-9_-]+$ ]] || zone=$(_fw_default_zone)
  local -r CONFIG_FILE="${_FW_ZONES_DIR}/${zone}.xml"
  
  log_info "安装 Firewalld..."
  
  # 禁用 UFW 防火墙，避免冲突
  if command -v ufw &> /dev/null; then
    log_warning "检测到 UFW，已停用"
    service_ensure ufw stopped
    service_ensure ufw disabled
    log_info "UFW 已禁用"
  fi

  # 需要放行的服务与端口
  local -a services=(ssh dhcpv6-client cockpit)
  local -a ports=()
  local port
  for port in $(sshd_listen_ports); do
    if [[ "$port" != "22" ]]; then
      ports+=("$port")
      log_info "检测到 SSH 监听端口 ${port}，将一并放行"
    fi
  done
  # NAS 共享服务：已安装才放行，避免防火墙启用后共享被挡
  if service_is_installed smbd; then
    services+=(samba)
  fi
  if service_is_installed nfs-server; then
    services+=(nfs mountd rpc-bind)
  fi

  local -a zone_entries=()
  local svc
  for svc in "${services[@]}"; do
    zone_entries+=("<service name=\"${svc}\"/>")
  done
  for port in "${ports[@]}"; do
    zone_entries+=("<port protocol=\"tcp\" port=\"${port}\"/>")
  done

  # 配置 firewalld 防火墙规则，确保基础服务可用
  # 必须在安装之前写好：Debian 安装 firewalld 后会立即启动，先写配置才不会在启动瞬间挡掉自定义 SSH 端口
  local entry entries_xml="" firewall_config
  for entry in "${zone_entries[@]}"; do
    entries_xml+="  ${entry}"$'\n'
  done
  firewall_config='<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <description>For use in public areas. You do not trust the other computers on networks to not harm your computer. Only selected incoming connections are accepted.</description>
'"${entries_xml}"'  <forward/>
</zone>'
  # 上方模板展开后包含 <service name="ssh"/>、<service name="dhcpv6-client"/>、<service name="cockpit"/>

  local config_changed=0 base_file current new_content wrc=0
  local -a to_add=()
  if [[ "$zone" != "public" ]]; then
    log_info "firewalld 默认区为 ${zone}（非 public），放行规则写入 ${zone} 区"
  fi
  if [[ "$zone" == "trusted" ]]; then
    # trusted 区放行全部入站：无需放行规则，也不替用户改默认区
    log_warning "默认区 trusted 放行全部入站，无需写入放行规则；防火墙不起拦截作用，建议改回 public（firewall-cmd --set-default-zone=public）"
  elif [[ ! -f "$CONFIG_FILE" && "$zone" == "public" ]]; then
    log_info "配置防火墙规则..."
    if write_file_if_changed "$CONFIG_FILE" "$firewall_config"; then
      config_changed=1
    fi
  else
    # 区文件已存在：在其基础上补缺；不存在（非 public 默认区，含 drop/block）：以 /usr/lib/firewalld/zones 的系统定义为基础
    # 读出 → 内存中插到 </zone> 之前（不依赖 <forward/> 是否存在）→ write_file_if_changed 写回（备份、原子替换、登记清单）
    base_file=$(_fw_zone_effective_file "$zone")
    current=$(cat -- "$base_file" 2> /dev/null) || current=""
    for entry in "${zone_entries[@]}"; do
      # dhcpv6-client 属于默认项，用户可能有意删除（或该区本就不含），不强行补回
      [[ "$entry" == *'"dhcpv6-client"'* ]] && continue
      if [[ "$current" != *"$entry"* ]]; then
        log_info "添加防火墙规则（${zone} 区）：${entry}"
        to_add+=("$entry")
      fi
    done
    if [[ ${#to_add[@]} -gt 0 ]]; then
      if new_content=$(_fw_zone_insert "$current" "${to_add[@]}"); then
        write_file_if_changed "$CONFIG_FILE" "$new_content" || wrc=$?
        if [[ $wrc -eq 0 ]]; then
          config_changed=1
        elif [[ $wrc -eq 2 ]]; then
          log_error "写入 ${CONFIG_FILE} 失败，放行规则未生效"
          exit "${ERROR_GENERAL}"
        fi
      else
        log_warning "${base_file:-${CONFIG_FILE}} 不是可识别的区定义（缺少 </zone>），未写入放行规则，请手动检查"
      fi
    fi
  fi

  # 安装 firewalld，保障系统安全
  local was_active=0
  if service_is_active firewalld; then
    was_active=1
  fi
  apt_install_packages firewalld

  # 已在运行时把新增规则同步到运行时配置；不用 --reload，避免清掉 fail2ban 的运行时规则
  if [[ $config_changed -eq 1 && $was_active -eq 1 ]] && command -v firewall-cmd &> /dev/null; then
    for svc in "${services[@]}"; do
      firewall-cmd --zone="$zone" --query-service="$svc" &> /dev/null \
        || firewall-cmd --zone="$zone" --add-service="$svc" &> /dev/null \
        || log_warning "运行时放行服务 ${svc} 失败（重启 firewalld 后生效）"
    done
    for port in "${ports[@]}"; do
      firewall-cmd --zone="$zone" --query-port="${port}/tcp" &> /dev/null \
        || firewall-cmd --zone="$zone" --add-port="${port}/tcp" &> /dev/null \
        || log_warning "运行时放行端口 ${port}/tcp 失败（重启 firewalld 后生效）"
    done
    # firewalld 运行中不会重读区文件：其内存里的永久配置仍是旧的，之后任何 firewall-cmd --permanent
    # 操作都会用旧内容重写该文件、丢掉上面写入的条目。把本次新增项逐个补进它的永久配置
    #（它会重写同一文件，内容等价；原件已由 write_file_if_changed 备份并登记清单）
    local -a perm_sync=("${to_add[@]}")
    [[ ${#perm_sync[@]} -gt 0 ]] || perm_sync=("${zone_entries[@]}")
    for entry in "${perm_sync[@]}"; do
      if [[ "$entry" =~ ^\<service\ name=\"([^\"]+)\"/\>$ ]]; then
        svc="${BASH_REMATCH[1]}"
        firewall-cmd --permanent --zone="$zone" --query-service="$svc" &> /dev/null \
          || firewall-cmd --permanent --zone="$zone" --add-service="$svc" &> /dev/null \
          || log_warning "同步 firewalld 永久配置失败：服务 ${svc}（区文件已写入，重启 firewalld 后生效）"
      elif [[ "$entry" =~ port=\"([0-9]+)\" ]]; then
        port="${BASH_REMATCH[1]}"
        firewall-cmd --permanent --zone="$zone" --query-port="${port}/tcp" &> /dev/null \
          || firewall-cmd --permanent --zone="$zone" --add-port="${port}/tcp" &> /dev/null \
          || log_warning "同步 firewalld 永久配置失败：端口 ${port}/tcp（区文件已写入，重启 firewalld 后生效）"
      fi
    done
  fi
  
  # 启动并启用 firewalld 服务
  service_ensure firewalld started
  service_ensure firewalld enabled
  log_success "Firewalld 就绪"
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
