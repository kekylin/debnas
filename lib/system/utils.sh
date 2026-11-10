#!/bin/bash
# 功能：系统版本检查工具库

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap-core.sh 加载）

# ==================== 底层 OS 信息获取函数 ====================

# os-release 路径（不设 readonly，允许测试覆盖；与 lib/ui/sysinfo.sh 共用同名变量）
DEBNAS_OS_RELEASE="${DEBNAS_OS_RELEASE:-/etc/os-release}"

# 读取 os-release 中的单个字段
# 说明：逐行解析 KEY=VALUE 并去掉成对引号，不 source 文件，不污染调用方变量，也不 fork 外部命令；
#       未显式指定 DEBNAS_OS_RELEASE 且 /etc/os-release 不可读时回退 /usr/lib/os-release（os-release(5)）
# 参数：$1 - 字段名（如 ID、VERSION_CODENAME）
# 输出：字段值（字段不存在时输出空行）
# 返回：0 已读取文件，1 文件不可读
_os_release_field() {
  local want="$1" file="$DEBNAS_OS_RELEASE" line value=""
  if [[ ! -r "$file" ]]; then
    [[ "$file" == "/etc/os-release" && -r /usr/lib/os-release ]] || return 1
    file="/usr/lib/os-release"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "${want}="* ]] || continue
    value="${line#*=}"
    if [[ ${#value} -ge 2 && ( "$value" == \"*\" || "$value" == \'*\' ) ]]; then
      value="${value:1:${#value}-2}"
    fi
    break
  done < "$file"
  printf '%s\n' "$value"
}

# 获取操作系统 ID
# 说明：优先读 os-release 的 ID；为空时回退 lsb_release（Debian 12 上是 Python 程序，启动慢）
# 参数：无
# 返回：操作系统 ID 字符串（小写）
_get_os_id() {
  local os_id="" have_file=1
  os_id=$(_os_release_field ID) || have_file=0
  if [[ -z "$os_id" ]] && command -v lsb_release >/dev/null 2>&1; then
    os_id=$(lsb_release -is)
  elif [[ -z "$os_id" && "$have_file" -eq 0 ]]; then
    return 1
  fi
  echo "${os_id,,}"
}

# 获取系统代号
# 说明：优先读 os-release 的 VERSION_CODENAME；为空时回退 lsb_release -cs
# 参数：无
# 返回：系统代号字符串
_get_os_codename() {
  local codename="" have_file=1
  codename=$(_os_release_field VERSION_CODENAME) || have_file=0
  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    lsb_release -cs
    return
  elif [[ -z "$codename" && "$have_file" -eq 0 ]]; then
    return 1
  fi
  echo "$codename"
}

# 获取系统版本号
# 参数：无
# 返回：系统版本号字符串
_get_os_version_id() {
  _os_release_field VERSION_ID
}

# ==================== 版本验证函数 ====================

# 验证系统是否为 Debian
# 参数：无
# 返回：0 是 Debian，非 0 不是
_verify_os_is_debian() {
  local os_id
  os_id=$(_get_os_id)

  if [[ "$os_id" != "debian" ]]; then
    return 1
  fi

  return 0
}

# 检查 codename 是否为开发版本
# 参数：$1 - 系统代号
# 返回：0 是开发版本，非 0 不是
_is_development_codename() {
  local codename="$1"
  case "$codename" in
    "sid" | "testing")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# 验证 Debian 最小版本（支持 sid 和 testing）
# 参数：$1 - 最小版本代号（如 "bookworm"）
# 返回：0 满足要求，非 0 不满足
_verify_debian_min_codename() {
  local min_codename="$1"
  local current_codename
  local codename_order=("bullseye" "bookworm" "trixie" "forky")
  local min_index=-1
  local current_index=-1
  local i

  current_codename=$(_get_os_codename)

  if _is_development_codename "$current_codename"; then
    return 0
  fi

  for i in "${!codename_order[@]}"; do
    if [[ "${codename_order[$i]}" == "$min_codename" ]]; then
      min_index=$i
    fi
    if [[ "${codename_order[$i]}" == "$current_codename" ]]; then
      current_index=$i
    fi
  done

  if [[ $min_index -ge 0 ]] && [[ $current_index -ge 0 ]]; then
    if [[ $current_index -ge $min_index ]]; then
      return 0
    else
      return 1
    fi
  fi

  local version_id
  version_id=$(_get_os_version_id)

  if [[ "$version_id" =~ ^([0-9]+) ]]; then
    local major_version="${BASH_REMATCH[1]}"
    local min_major=12

    case "$min_codename" in
      "bookworm")
        min_major=12
        ;;
      "trixie")
        min_major=13
        ;;
      *)
        min_major=12
        ;;
    esac

    if [[ $major_version -ge $min_major ]]; then
      return 0
    else
      return 1
    fi
  fi

  return 1
}

# ==================== 公共接口函数 ====================

# 验证系统支持，支持 Debian 12 及以上版本（包括 sid 和 testing）
# 参数：无
# 返回：0 成功，非 0 失败
verify_system_support() {
  if ! _verify_os_is_debian; then
    local os_id
    os_id=$(_get_os_id)
    log_error "不支持 ${os_id}，需要 Debian 12+"
    return 1
  fi

  if ! _verify_debian_min_codename "bookworm"; then
    local codename version_id
    codename=$(_get_os_codename)
    version_id=$(_get_os_version_id)
    log_error "需要 Debian 12+ (${codename:-${version_id}})"
    return 1
  fi

  return 0
}

# 验证系统支持，支持 Debian 12 及以上版本（包括 sid 和 testing）
# 参数：无
# 返回：0 成功，非 0 失败
verify_debian_12_13_support() {
  if ! _verify_os_is_debian; then
    local os_id
    os_id=$(_get_os_id)
    log_error "不支持的操作系统 (${os_id})，需要 Debian 12 或更高版本"
    return 1
  fi

  local codename
  codename=$(_get_os_codename)

  if _is_development_codename "$codename"; then
    log_info "Debian 开发版 $codename"
    return 0
  fi

  case "$codename" in
    "bookworm" | "trixie" | "forky")
      log_info "系统版本 ${codename}"
      return 0
      ;;
    *)
      if _verify_debian_min_codename "bookworm"; then
        log_info "检测到支持的 Debian 版本: $codename"
        return 0
      else
        log_error "需要 Debian 12+${codename}"
        return 1
      fi
      ;;
  esac
}

# 获取系统代号
# 参数：无
# 返回：系统代号字符串
get_system_codename() {
  _get_os_codename
}

# 检查系统代号是否支持
# 参数：$1 - 系统代号
# 返回：0 支持，非 0 不支持
is_supported_codename() {
  local codename="$1"

  if _is_development_codename "$codename"; then
    return 0
  fi

  case "$codename" in
    "bookworm" | "trixie" | "forky")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# 获取系统名称
# 参数：无
# 返回：系统名称字符串
get_system_name() {
  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -is
  else
    if [[ -f /etc/os-release ]]; then
      # shellcheck source=/dev/null
      (. /etc/os-release && echo "${NAME:-}")
    else
      echo "未知"
    fi
  fi
}

# 获取系统版本
# 参数：无
# 返回：系统版本字符串
get_system_version() {
  local version_id
  version_id=$(_get_os_version_id)

  if [[ -n "$version_id" ]]; then
    echo "$version_id"
  elif [[ -f /etc/debian_version ]]; then
    cat /etc/debian_version
  else
    echo "未知"
  fi
}

# 获取系统架构
# 参数：无
# 返回：系统架构字符串（如 x86_64、arm64 等）
get_system_architecture() {
  uname -m 2>/dev/null || echo "未知"
}

# 验证系统架构是否支持
# 参数：$1 - 支持的架构列表（空格分隔，如 "x86_64 amd64"）
# 返回：0 支持，非 0 不支持
verify_architecture_support() {
  local supported_archs="$1"
  local current_arch arch
  current_arch=$(get_system_architecture)

  if [[ -z "$supported_archs" ]]; then
    return 1
  fi

  # 临时设置 IFS 为空格以正确分词（全局 IFS=$'\n\t' 不分割空格）
  local old_ifs="$IFS"
  IFS=' '
  for arch in $supported_archs; do
    if [[ "$current_arch" == "$arch" ]]; then
      IFS="$old_ifs"
      return 0
    fi
  done
  IFS="$old_ifs"

  return 1
}

# passwd 文件路径（不设 readonly，允许测试覆盖）
DEBNAS_PASSWD_FILE="${DEBNAS_PASSWD_FILE:-/etc/passwd}"

# 获取主普通用户：passwd 中首个 UID ≥ 1000 的用户（排除 nobody / UID 65534）
# 说明：纯 bash 逐行解析，不 fork awk；只读本地 passwd（不查 LDAP/NSS）
# 参数：无
# 输出：用户名；找不到时输出空
# 返回：始终 0
get_primary_user() {
  local name uid _
  [[ -r "$DEBNAS_PASSWD_FILE" ]] || return 0
  while IFS=: read -r name _ uid _ || [[ -n "$name" ]]; do
    [[ "$uid" =~ ^[0-9]{1,10}$ && "$name" != "nobody" ]] || continue
    if (( 10#$uid >= 1000 && 10#$uid != 65534 )); then
      printf '%s\n' "$name"
      return 0
    fi
  done < "$DEBNAS_PASSWD_FILE"
  return 0
}

# deprecated：旧名，保留为薄包装，新代码请用 get_primary_user
get_first_regular_user() {
  get_primary_user
}

# 智能写入文件（内容比较去重）
# 参数：$1 - 目标文件路径
#       $2 - 新内容
#       $3 - 文件权限（可选；新文件默认 644，已存在文件未指定时保留原权限）
#       $4 - 静默模式（可选，1=不输出"未变更"日志）
# 返回：0 表示已写入（内容变更），1 表示未变更（跳过写入），2 表示写入失败或缺少参数（已记录 error 日志）
# 空内容：合法，写入 0 字节空文件（已是空文件/只有空白换行时视为未变更）；非空内容末尾补一个换行
# 说明：比较现有文件内容，相同则跳过（避免无意义的文件写入和服务重启）
#       写入采用"同目录临时文件 + mv"原子替换，避免写到一半（磁盘满/中断）留下截断的 /etc 配置；
#       已存在文件的属主/属组会被保留；目标为符号链接时写入其指向的真实文件（不破坏链接）。
#       内容变化且原文件存在时，先经 debnas_backup_file 备份到 /var/backups/debnas（失败只告警）；
#       写入成功后经 manifest_add 登记到文件清单（/var/lib/debnas/manifest）。
write_file_if_changed() {
  # 参数缺失按"写入失败"返回 2（${2:?} 在内容为空时会直接结束整个进程）
  if [[ $# -lt 2 || -z "${1:-}" ]]; then
    log_error "write_file_if_changed: 缺少文件路径或内容参数"
    return 2
  fi
  local file="$1"
  local new_content="$2"
  local file_perm="${3:-}"
  local quiet="${4:-0}"

  # 符号链接（如 /etc/resolv.conf）：解析到真实文件，保持旧版"写穿链接"的语义
  if [[ -L "$file" ]]; then
    local resolved=""
    resolved=$(readlink -f -- "$file" 2>/dev/null) || resolved=""
    if [[ -z "$resolved" ]]; then
      log_error "无法解析符号链接：$file"
      return 2
    fi
    file="$resolved"
  fi

  if [[ -e "$file" && ! -f "$file" ]]; then
    log_error "目标不是普通文件，拒绝写入：$file"
    return 2
  fi

  # 确保父目录存在（参数展开取目录，不 fork dirname）
  local dir="." base="${file##*/}"
  [[ "$file" == */* ]] && dir="${file%/*}"
  [[ -n "$dir" ]] || dir="/"
  mkdir -p -- "$dir" 2>/dev/null || true

  # 内容比较：相同则跳过
  if [[ -f "$file" ]]; then
    local current_content cmp_content="$new_content"
    { current_content=$(< "$file"); } 2>/dev/null || current_content=""
    # $(...) 会去掉文件末尾换行，新内容也做同样处理，否则以换行结尾的内容每次都被判为"已变更"
    while [[ "$cmp_content" == *$'\n' ]]; do
      cmp_content="${cmp_content%$'\n'}"
    done
    if [[ "$current_content" == "$cmp_content" ]]; then
      if [[ "$quiet" != "1" ]]; then
        log_info "配置文件未变更，跳过写入：$file"
      fi
      return 1
    fi
    # 内容确实变化：修改前把原件备份到 /var/backups/debnas（见 backup.sh）。
    # 备份失败只告警、继续写入：备份是辅助恢复手段，许多调用方以 `|| true` 忽略返回值，
    # 若因备份盘满/只读而拒绝写入，安全加固等必要变更会被静默跳过，风险更大。
    if declare -F debnas_backup_file >/dev/null 2>&1; then
      local backup_rc=0
      debnas_backup_file "$file" || backup_rc=$?
      if [[ "$backup_rc" -eq 1 ]]; then
        log_warning "备份原文件失败（继续写入）：$file"
      fi
    fi
  fi

  # 写入同目录临时文件（mktemp 创建为 0600，写入期间内容不会被其他用户读到）
  local tmp_file=""
  tmp_file=$(mktemp -- "${dir}/.${base}.debnas.XXXXXX" 2>/dev/null) || tmp_file=""
  if [[ -z "$tmp_file" ]]; then
    log_error "写入失败（无法创建临时文件）：$file"
    return 2
  fi
  # 空内容写成 0 字节空文件；非空内容末尾补一个换行
  local write_ok=0
  if [[ -z "$new_content" ]]; then
    : > "$tmp_file" && write_ok=1
  else
    printf '%s\n' "$new_content" > "$tmp_file" && write_ok=1
  fi
  if (( write_ok == 0 )); then
    rm -f -- "$tmp_file"
    log_error "写入失败：$file"
    return 2
  fi

  # 权限/属主：显式指定权限优先；否则已存在文件保留原权限，新文件默认 644
  if [[ -f "$file" ]]; then
    chown --reference="$file" -- "$tmp_file" 2>/dev/null || true
    if [[ -z "$file_perm" ]]; then
      chmod --reference="$file" -- "$tmp_file" 2>/dev/null || file_perm="644"
    fi
  elif [[ -z "$file_perm" ]]; then
    file_perm="644"
  fi
  if [[ -n "$file_perm" ]] && ! chmod "$file_perm" "$tmp_file"; then
    rm -f -- "$tmp_file"
    log_error "写入失败（权限设置失败 ${file_perm}）：$file"
    return 2
  fi

  # 原子替换；失败时（如 bind mount 的文件无法 rename）回退为原地覆写
  if ! mv -fT -- "$tmp_file" "$file" 2>/dev/null; then
    if cat -- "$tmp_file" > "$file"; then
      [[ -z "$file_perm" ]] || chmod "$file_perm" "$file" 2>/dev/null || true
      rm -f -- "$tmp_file"
    else
      rm -f -- "$tmp_file"
      log_error "写入失败：$file"
      return 2
    fi
  fi
  # 登记到文件清单（DebNAS 自有目录内的文件由 manifest_add 自动忽略）
  if declare -F manifest_add >/dev/null 2>&1; then
    manifest_add "$file" || true
  fi
  return 0
}

# ==================== 后台任务进程组 ====================

# 后台探测（模块状态、可更新包统计等）的子 shell 里还会起 systemctl/apt-get 等命令；
# 只 kill 子 shell 时这些命令会变成孤儿持续累积。启动后台任务时临时打开 job control（set -m），
# bash 会让 & 启动的任务自成进程组（pgid = pid）；终止时 kill 整个进程组。
# 子 shell 内 job control 自动关闭，其中的命令仍留在该进程组内。
# 用法：bg_group_begin; ( ... ) & pid=$!; bg_group_end; …; bg_group_kill "$pid"
bg_group_begin() {
  _DEBNAS_BG_OLDFLAGS="$-"
  set -m 2>/dev/null || true
}

bg_group_end() {
  [[ "${_DEBNAS_BG_OLDFLAGS:-}" == *m* ]] || set +m 2>/dev/null || true
}

# 终止后台任务及其进程组（进程组不存在时回退为只终止该进程）
# 参数：$1 - bg_group_begin/end 之间启动的后台任务 pid
# 返回：始终 0
bg_group_kill() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  return 0
}
