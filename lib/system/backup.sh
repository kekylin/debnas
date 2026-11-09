#!/bin/bash
# 功能：集中备份（修改系统文件前把原件复制到 /var/backups/debnas）
# 布局：${DEBNAS_BACKUP_ROOT}/<YYYYmmdd-HHMMSS-pid>/<原绝对路径>   每次 debnas 运行一个目录
#       ${DEBNAS_BACKUP_ROOT}/original/<原绝对路径>               每个文件首次被改前的原件（不轮转）
#       同一次运行（含 module-runner 派生的子进程）共用一个运行目录：运行 ID 在首次加载本库时生成并 export。
#       同一次运行内同一文件只备份第一次（即本次运行开始前的状态）。
# 开关：DEBNAS_BACKUP_ENABLED（环境变量）> debnas.conf 中 backup_enabled > 默认 1
#       DEBNAS_BACKUP_KEEP   （环境变量）> debnas.conf 中 backup_keep    > 默认 20（保留最近 N 次运行目录）
# 依赖: core/logging.sh、system/layout.sh（DEBNAS_BACKUP_ROOT）、system/manifest.sh（manifest_add）

set -euo pipefail
IFS=$'\n\t'

# 运行目录名格式
_DEBNAS_BACKUP_RUN_RE='^[0-9]{8}-[0-9]{6}-[0-9]+$'

# 本次运行 ID（子进程继承父进程的 ID，保证同一次 debnas 运行共用一个目录）
if [[ ! "${DEBNAS_BACKUP_RUN_ID:-}" =~ $_DEBNAS_BACKUP_RUN_RE ]]; then
  DEBNAS_BACKUP_RUN_ID="$(printf '%(%Y%m%d-%H%M%S)T' -1)-$$"
fi
export DEBNAS_BACKUP_RUN_ID

# ==================== 内部函数 ====================

# 读取全局配置项（config.sh 未加载时直接读 debnas.conf）
# 参数：$1 - 键名
_debnas_backup_conf() {
  local key="$1" value=""
  if declare -F config_read >/dev/null 2>&1; then
    value=$(config_read "global" "$key" "" 2>/dev/null) || value=""
  elif [[ -r "${DEBNAS_GLOBAL_CONF:-/etc/debnas/debnas.conf}" ]]; then
    value=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${DEBNAS_GLOBAL_CONF:-/etc/debnas/debnas.conf}" 2>/dev/null \
      | head -n 1 | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//') || value=""
  fi
  printf '%s' "$value"
}

# 是否启用备份
_debnas_backup_enabled() {
  local v="${DEBNAS_BACKUP_ENABLED:-}"
  [[ -n "$v" ]] || v=$(_debnas_backup_conf "backup_enabled")
  case "${v:-1}" in
    0 | no | false | off) return 1 ;;
    *) return 0 ;;
  esac
}

# 保留的运行目录数（≥1）
_debnas_backup_keep() {
  local v="${DEBNAS_BACKUP_KEEP:-}"
  [[ -n "$v" ]] || v=$(_debnas_backup_conf "backup_keep")
  if [[ "$v" =~ ^[0-9]+$ ]] && [[ "$((10#$v))" -ge 1 ]]; then
    printf '%s' "$((10#$v))"
  else
    printf '20'
  fi
}

# 校验备份根目录（绝对路径、非 /、不含 ..、不是符号链接）
_debnas_backup_root_ok() {
  local root="${DEBNAS_BACKUP_ROOT:-}"
  [[ -n "$root" && "$root" == /* && "$root" != "/" ]] || return 1
  [[ "$root" != *"/../"* && "$root" != *"/.." && "$root" != *"/./"* ]] || return 1
  [[ ! -L "$root" ]] || return 1
  return 0
}

# 确保备份根目录存在且为 700
_debnas_backup_ensure_root() {
  _debnas_backup_root_ok || return 1
  local root="$DEBNAS_BACKUP_ROOT"
  if [[ ! -d "$root" ]]; then
    # 上级目录按默认权限创建，只有备份根目录本身为 700（mkdir -p -m 只作用于最深一级）
    [[ -z "${root%/*}" ]] || mkdir -p -- "${root%/*}" 2>/dev/null || return 1
    mkdir -m 700 -- "$root" 2>/dev/null || [[ -d "$root" ]] || return 1
  fi
  [[ -d "$root" && ! -L "$root" ]] || return 1
  chmod 700 -- "$root" 2>/dev/null || true
  return 0
}

# 获取（必要时创建）本次运行目录；新建运行目录时顺带执行保留策略
# 输出：运行目录路径
_debnas_backup_run_dir() {
  _debnas_backup_ensure_root || return 1
  local dir="${DEBNAS_BACKUP_ROOT}/${DEBNAS_BACKUP_RUN_ID}"
  if [[ ! -d "$dir" ]]; then
    if ! mkdir -m 700 -- "$dir" 2>/dev/null && [[ ! -d "$dir" ]]; then
      return 1
    fi
    debnas_backup_prune || true
  fi
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  printf '%s' "$dir"
}

# 把文件复制到 <dest_root>/<绝对路径>（保留权限属主时间戳）
# 参数：$1 - 源（绝对路径，已解析符号链接）；$2 - 目标根目录
_debnas_backup_copy() {
  local src="$1" dest_root="$2" dest
  dest="${dest_root}${src}"
  mkdir -p -- "$(dirname -- "$dest")" 2>/dev/null || return 1
  if ! cp -a -- "$src" "$dest" 2>/dev/null; then
    [[ -z "$dest" ]] || rm -f -- "$dest" 2>/dev/null || true
    return 1
  fi
  return 0
}

# ==================== 公共接口 ====================

# 备份文件到集中备份目录
# 参数：$1 - 文件路径（符号链接会被解析为真实文件）
# 返回：0 已备份（或本次运行已备份过），1 备份失败，2 跳过（备份已关闭 / 文件不存在 / 不是普通文件）
debnas_backup_file() {
  local src="${1:-}"
  [[ -n "$src" ]] || return 1
  _debnas_backup_enabled || return 2
  [[ -f "$src" ]] || return 2

  local abs=""
  abs=$(readlink -f -- "$src" 2>/dev/null) || abs=""
  [[ -n "$abs" && "$abs" == /* && -f "$abs" ]] || return 1
  # 不备份备份目录自身的文件
  if [[ "$abs" == "${DEBNAS_BACKUP_ROOT}"/* ]]; then
    return 2
  fi

  local run_dir=""
  run_dir=$(_debnas_backup_run_dir) || run_dir=""
  [[ -n "$run_dir" ]] || return 1

  # 首次被改前的原件：只写一次，不参与轮转
  local orig_root="${DEBNAS_BACKUP_ROOT}/original"
  if [[ ! -e "${orig_root}${abs}" ]]; then
    if [[ -d "$orig_root" ]] || mkdir -m 700 -- "$orig_root" 2>/dev/null; then
      _debnas_backup_copy "$abs" "$orig_root" || true
    fi
  fi

  # 本次运行已备份过该文件：保留第一次（运行开始前）的版本
  if [[ ! -e "${run_dir}${abs}" ]]; then
    _debnas_backup_copy "$abs" "$run_dir" || return 1
  fi

  if declare -F manifest_add >/dev/null 2>&1; then
    manifest_add "$abs" || true
  fi
  return 0
}

# 保留策略：只保留最近 N 次运行的备份目录（按目录名排序，original/ 不参与）
# 参数：$1 - 保留数（可选，默认 _debnas_backup_keep）
# 返回：0 成功，1 备份根目录不合法
# shellcheck disable=SC2120  # 保留数参数可选，库内调用用默认值
debnas_backup_prune() {
  _debnas_backup_root_ok || return 1
  local root="$DEBNAS_BACKUP_ROOT"
  [[ -d "$root" ]] || return 0
  local keep="${1:-}"
  [[ "$keep" =~ ^[0-9]+$ && "$keep" -ge 1 ]] || keep=$(_debnas_backup_keep)

  local -a runs=()
  local d name
  for d in "$root"/*; do
    name="${d##*/}"
    [[ "$name" =~ $_DEBNAS_BACKUP_RUN_RE ]] || continue
    [[ -d "$d" && ! -L "$d" ]] || continue
    runs+=("$name")
  done
  [[ "${#runs[@]}" -gt "$keep" ]] || return 0

  # 日期、时间按字符串排序，pid 按数值排序
  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${runs[@]}" | LC_ALL=C sort -t '-' -k1,1 -k2,2 -k3,3n)

  local excess=$(( ${#sorted[@]} - keep )) i target
  for (( i = 0; i < excess; i++ )); do
    name="${sorted[$i]}"
    [[ -n "$name" && "$name" =~ $_DEBNAS_BACKUP_RUN_RE ]] || continue
    [[ "$name" != "${DEBNAS_BACKUP_RUN_ID:-}" ]] || continue
    target="${root}/${name}"
    [[ -n "$target" && "$target" == "${root}/"* && -d "$target" && ! -L "$target" ]] || continue
    rm -rf -- "$target" 2>/dev/null || log_warning "清理旧备份失败：${target}"
  done
  return 0
}
