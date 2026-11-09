#!/bin/bash
# 功能：统一配置管理模块
# 说明：提供配置文件的读写和校验功能
# 配置路径：/etc/debnas/conf.d/<module>.conf
# 格式：key=value（每行一个配置项，# 开头为注释）

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap.sh 加载）

# ==================== 常量定义 ====================

# 配置目录（不设 readonly，允许测试 Mock）
DEBNAS_CONF_DIR="${DEBNAS_CONF_DIR:-/etc/debnas/conf.d}"

# 全局配置文件
DEBNAS_GLOBAL_CONF="${DEBNAS_GLOBAL_CONF:-/etc/debnas/debnas.conf}"

# ==================== 内部函数 ====================

# 获取模块配置文件路径
# 参数：$1 - 模块名
# 输出：配置文件绝对路径
_config_file() {
  local module_name="${1:?_config_file: 缺少模块名}"
  echo "${DEBNAS_CONF_DIR}/${module_name}.conf"
}

# 校验模块名与键名（防止路径穿越与正则/sed 注入）
# 键名会被拼入 grep/awk/sed 正则（sed 的 e 命令可执行任意命令），模块名会被拼入文件路径。
# 参数：$1 - 模块名，$2 - 键名
# 返回：0 合法，1 非法（已输出错误）
_config_validate_names() {
  local module_name="$1" key="$2"
  if [[ ! "$module_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ || "$module_name" == *..* ]]; then
    echo "debNAS: 非法的配置模块名：${module_name}" >&2
    return 1
  fi
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
    echo "debNAS: 非法的配置键名：${key}（仅允许字母、数字、_ . -）" >&2
    return 1
  fi
  return 0
}

# 确保配置目录存在
# 参数：无
# 返回：0 成功，1 失败
_ensure_conf_dir() {
  if [[ ! -d "$DEBNAS_CONF_DIR" ]]; then
    mkdir -p "$DEBNAS_CONF_DIR" 2>/dev/null || {
      echo "debNAS: 无法创建配置目录：${DEBNAS_CONF_DIR}" >&2
      return 1
    }
    chmod 755 "$DEBNAS_CONF_DIR"
  fi
  return 0
}

# ==================== 公共接口 ====================

# 读取配置值
# 参数：$1 - 模块名（"global" 表示全局配置）
#       $2 - 键名
#       $3 - 默认值（可选，不存在时返回此值）
# 输出：配置值
# 返回：0 找到，1 未找到（无默认值时）
config_read() {
  local module_name="${1:?config_read: 缺少模块名}"
  local key="${2:?config_read: 缺少键名}"
  local default_value="${3:-}"
  local conf_file

  _config_validate_names "$module_name" "$key" || return 1

  if [[ "$module_name" == "global" ]]; then
    conf_file="$DEBNAS_GLOBAL_CONF"
  else
    conf_file=$(_config_file "$module_name")
  fi

  if [[ ! -f "$conf_file" ]]; then
    if [[ -n "$default_value" ]]; then
      echo "$default_value"
      return 0
    fi
    return 1
  fi

  # 读取值（忽略注释行和空行，取第一个匹配）
  local value
  # 末尾 || true：键不存在时 grep 返回 1，在 pipefail + set -e 下会使调用方直接退出
  value=$(grep -E "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$conf_file" 2>/dev/null \
          | head -1 \
          | sed 's/^[^=]*=[[:space:]]*//' \
          | sed 's/[[:space:]]*$//') || true

  if [[ -n "$value" ]]; then
    echo "$value"
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    echo "$default_value"
    return 0
  fi

  return 1
}

# 写入配置值
# 参数：$1 - 模块名（"global" 表示全局配置）
#       $2 - 键名
#       $3 - 键值
#       $4 - 文件权限（可选，默认 644；敏感信息应设为 600）
# 返回：0 成功，1 失败
config_write() {
  local module_name="${1:?config_write: 缺少模块名}"
  local key="${2:?config_write: 缺少键名}"
  local value="${3:?config_write: 缺少键值}"
  local file_perm="${4:-}"
  local conf_file

  _config_validate_names "$module_name" "$key" || return 1
  # 值中含换行会注入额外的键值行
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "debNAS: 配置值不能包含换行：${key}" >&2
    return 1
  fi

  if [[ "$module_name" == "global" ]]; then
    conf_file="$DEBNAS_GLOBAL_CONF"
    mkdir -p "$(dirname "$conf_file")" 2>/dev/null
  else
    conf_file=$(_config_file "$module_name")
    if ! _ensure_conf_dir; then
      return 1
    fi
  fi

  # 未显式指定权限：已存在文件保留原权限（避免把 600 的敏感配置改回 644），新文件默认 644
  if [[ -z "$file_perm" ]]; then
    if [[ -f "$conf_file" ]]; then
      file_perm=$(stat -c '%a' "$conf_file" 2>/dev/null) || file_perm="644"
    else
      file_perm="644"
    fi
  fi

  # 如果文件不存在则创建（umask 077：先以 600 创建，chmod 前不暴露内容）
  if [[ ! -f "$conf_file" ]]; then
    (
      umask 077
      {
        echo "# DebNAS 配置文件 - ${module_name}"
        echo "# 创建时间: $(date '+%Y-%m-%d %H:%M:%S')"
      } > "$conf_file"
    ) || return 1
    chmod "$file_perm" "$conf_file"
  fi

  # 更新或追加键值对
  local key_re="${key//./\\.}"
  if grep -qE "^[[:space:]]*${key_re}[[:space:]]*=" "$conf_file" 2>/dev/null; then
    # 替换已有行（使用 ENVIRON 传递变量，避免 awk -v 解释转义序列）
    # 临时文件以 umask 077 创建：含敏感值的 600 文件在替换期间不会以 644 暴露
    if ! (
      umask 077
      export _DEBNAS_CFG_KEY="$key" _DEBNAS_CFG_RE="$key_re" _DEBNAS_CFG_VAL="$value"
      awk '{
        line = $0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ "^"ENVIRON["_DEBNAS_CFG_RE"]"[[:space:]]*=") {
          print ENVIRON["_DEBNAS_CFG_KEY"]"="ENVIRON["_DEBNAS_CFG_VAL"]
        } else {
          print $0
        }
      }' "$conf_file" > "${conf_file}.tmp"
    ); then
      rm -f "${conf_file}.tmp"
      return 1
    fi
    chmod "$file_perm" "${conf_file}.tmp" 2>/dev/null || true
    if ! mv "${conf_file}.tmp" "$conf_file"; then
      rm -f "${conf_file}.tmp"
      return 1
    fi
  else
    # 追加新行
    echo "${key}=${value}" >> "$conf_file"
  fi

  # 确保文件权限正确
  chmod "$file_perm" "$conf_file"

  return 0
}

# 删除配置键
# 参数：$1 - 模块名（"global" 表示全局配置）
#       $2 - 键名
# 返回：0 成功（包括原本不存在的情况）
config_delete() {
  local module_name="${1:?config_delete: 缺少模块名}"
  local key="${2:?config_delete: 缺少键名}"
  local conf_file

  _config_validate_names "$module_name" "$key" || return 1

  if [[ "$module_name" == "global" ]]; then
    conf_file="$DEBNAS_GLOBAL_CONF"
  else
    conf_file=$(_config_file "$module_name")
  fi

  if [[ -f "$conf_file" ]]; then
    sed -i "/^[[:space:]]*${key//./\\.}[[:space:]]*=/d" "$conf_file" 2>/dev/null || true
  fi
  return 0
}

