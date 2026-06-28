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

# 确保配置目录存在
# 参数：无
# 返回：0 成功，1 失败
_ensure_conf_dir() {
  if [[ ! -d "$DEBNAS_CONF_DIR" ]]; then
    mkdir -p "$DEBNAS_CONF_DIR" 2>/dev/null || {
      log_error "无法创建配置目录：${DEBNAS_CONF_DIR}"
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
  value=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf_file" 2>/dev/null \
          | head -1 \
          | sed 's/^[^=]*=[[:space:]]*//' \
          | sed 's/[[:space:]]*$//')

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
  local file_perm="${4:-644}"
  local conf_file

  if [[ "$module_name" == "global" ]]; then
    conf_file="$DEBNAS_GLOBAL_CONF"
    mkdir -p "$(dirname "$conf_file")" 2>/dev/null
  else
    conf_file=$(_config_file "$module_name")
    if ! _ensure_conf_dir; then
      return 1
    fi
  fi

  # 如果文件不存在则创建
  if [[ ! -f "$conf_file" ]]; then
    {
      echo "# DebNAS 配置文件 - ${module_name}"
      echo "# 创建时间: $(date '+%Y-%m-%d %H:%M:%S')"
    } > "$conf_file"
    chmod "$file_perm" "$conf_file"
  fi

  # 更新或追加键值对
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$conf_file" 2>/dev/null; then
    # 替换已有行（使用 ENVIRON 传递变量，避免 awk -v 解释转义序列）
    export _DEBNAS_CFG_KEY="$key" _DEBNAS_CFG_VAL="$value"
    awk '{
      line = $0
      sub(/^[[:space:]]*/, "", line)
      k = ENVIRON["_DEBNAS_CFG_KEY"]
      if (line ~ "^"k"[[:space:]]*=") {
        print k"="ENVIRON["_DEBNAS_CFG_VAL"]
      } else {
        print $0
      }
    }' "$conf_file" > "${conf_file}.tmp"
    unset _DEBNAS_CFG_KEY _DEBNAS_CFG_VAL
    mv "${conf_file}.tmp" "$conf_file"
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

  if [[ "$module_name" == "global" ]]; then
    conf_file="$DEBNAS_GLOBAL_CONF"
  else
    conf_file=$(_config_file "$module_name")
  fi

  if [[ -f "$conf_file" ]]; then
    sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" "$conf_file" 2>/dev/null || true
  fi
  return 0
}

# 校验配置文件格式
# 参数：$1 - 模块名（"global" 表示全局配置）
# 返回：0 格式正确，1 格式有误
# 说明：检查每行是否为有效格式（key=value、注释、空行）
config_validate() {
  local module_name="${1:?config_validate: 缺少模块名}"
  local conf_file

  if [[ "$module_name" == "global" ]]; then
    conf_file="$DEBNAS_GLOBAL_CONF"
  else
    conf_file=$(_config_file "$module_name")
  fi

  if [[ ! -f "$conf_file" ]]; then
    return 0
  fi

  local line_num=0
  local has_error=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    (( ++line_num ))

    # 跳过空行和注释
    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    # 检查是否为 key=value 格式
    if ! [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*= ]]; then
      log_error "配置文件格式错误: ${conf_file} 第 ${line_num} 行"
      log_error "  内容: ${line}"
      log_error "  期望格式: key=value"
      has_error=1
    fi
  done < "$conf_file"

  if [[ "$has_error" -eq 1 ]]; then
    return 1
  fi

  return 0
}

# 读取全局配置（便捷封装）
# 参数：$1 - 键名
#       $2 - 默认值（可选）
# 输出：配置值
config_read_global() {
  config_read "global" "$@"
}

# 写入全局配置（便捷封装）
# 参数：$1 - 键名
#       $2 - 键值
config_write_global() {
  config_write "global" "$@"
}
