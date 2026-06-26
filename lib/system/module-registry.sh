#!/bin/bash
# 功能：模块自动发现与注册模块
# 说明：扫描 modules/ 目录，解析模块元数据，提供模块查询和依赖解析功能
# 元数据格式：文件头部的 # @key: value 注释行

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"

# ==================== 常量定义 ====================

# 模块目录
readonly DEBNAS_MODULES_DIR="${DEBNAS_MODULES_DIR:-}"

# 分类显示顺序（硬编码，对应路线图 §7.1）
readonly -a CATEGORY_ORDER=(
  "基础系统"
  "管理面板"
  "安全防护"
  "容器管理"
  "通知服务"
  "系统工具"
  "一键部署"
  "系统维护"
)

# 默认 order 值（未声明时排在最后）
readonly DEFAULT_ORDER=999

# ==================== 内部状态 ====================

# 模块元数据存储（关联数组）
# 键格式：<module_name>.<field>
# 例如：install-cockpit.name = "安装 Cockpit"
declare -g -A _MODULE_REGISTRY=()

# 已发现模块列表
declare -g -a _DISCOVERED_MODULES=()

# 是否已执行过发现
declare -g _MODULES_DISCOVERED=0

# ==================== 内部函数 ====================

# 获取模块目录路径
# 参数：无
# 输出：模块目录绝对路径
_get_modules_dir() {
  if [[ -n "$DEBNAS_MODULES_DIR" ]] && [[ -d "$DEBNAS_MODULES_DIR" ]]; then
    echo "$DEBNAS_MODULES_DIR"
  elif [[ -n "${_DEBNAS_ROOT:-}" ]] && [[ -d "${_DEBNAS_ROOT}/modules" ]]; then
    echo "${_DEBNAS_ROOT}/modules"
  else
    # 回退：基于当前文件位置推算
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    echo "${script_dir}/modules"
  fi
}

# 解析单个模块文件的元数据
# 参数：$1 - 模块文件路径
# 输出：设置 _MODULE_REGISTRY 关联数组
# 返回：0 成功，1 失败
_parse_single_file() {
  local file_path="$1"
  local file_name
  file_name=$(basename "$file_path" .sh)
  local module_name="$file_name"

  # 默认值
  _MODULE_REGISTRY["${module_name}.module"]="$module_name"
  _MODULE_REGISTRY["${module_name}.name"]="$module_name"
  _MODULE_REGISTRY["${module_name}.category"]="未分类"
  _MODULE_REGISTRY["${module_name}.description"]=""
  _MODULE_REGISTRY["${module_name}.depends"]=""
  _MODULE_REGISTRY["${module_name}.depend_modules"]=""
  _MODULE_REGISTRY["${module_name}.version"]="1.0.0"
  _MODULE_REGISTRY["${module_name}.debian_min"]="bookworm"
  _MODULE_REGISTRY["${module_name}.order"]="$DEFAULT_ORDER"
  _MODULE_REGISTRY["${module_name}.path"]="$file_path"
  _MODULE_REGISTRY["${module_name}.type"]="file"
  _MODULE_REGISTRY["${module_name}.cron"]="false"
  _MODULE_REGISTRY["${module_name}.cron_schedule"]=""

  # 从文件头部提取元数据（只扫描前 30 行，避免性能问题）
  local line key value
  local has_metadata=0
  while IFS= read -r line; do
    # 跳过非注释行（元数据必须在文件头部注释中）
    if [[ "$line" =~ ^#[[:space:]]*@([a-z_]+):[[:space:]]*(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      # 去除尾部空格
      value="${value%"${value##*[![:space:]]}"}"

      case "$key" in
        module)
          module_name="$value"
          _MODULE_REGISTRY["${module_name}.module"]="$module_name"
          _MODULE_REGISTRY["${module_name}.path"]="$file_path"
          _MODULE_REGISTRY["${module_name}.type"]="file"
          # 如果重新映射了名字，清除旧默认值
          _MODULE_REGISTRY["${module_name}.name"]="$module_name"
          _MODULE_REGISTRY["${module_name}.category"]="未分类"
          _MODULE_REGISTRY["${module_name}.description"]=""
          _MODULE_REGISTRY["${module_name}.depends"]=""
          _MODULE_REGISTRY["${module_name}.depend_modules"]=""
          _MODULE_REGISTRY["${module_name}.version"]="1.0.0"
          _MODULE_REGISTRY["${module_name}.debian_min"]="bookworm"
          _MODULE_REGISTRY["${module_name}.order"]="$DEFAULT_ORDER"
          _MODULE_REGISTRY["${module_name}.cron"]="false"
          _MODULE_REGISTRY["${module_name}.cron_schedule"]=""
          ;;
        name)          _MODULE_REGISTRY["${module_name}.name"]="$value" ;;
        category)      _MODULE_REGISTRY["${module_name}.category"]="$value" ;;
        description)   _MODULE_REGISTRY["${module_name}.description"]="$value" ;;
        depends)       _MODULE_REGISTRY["${module_name}.depends"]="$value" ;;
        depend_modules) _MODULE_REGISTRY["${module_name}.depend_modules"]="$value" ;;
        version)       _MODULE_REGISTRY["${module_name}.version"]="$value" ;;
        debian_min)    _MODULE_REGISTRY["${module_name}.debian_min"]="$value" ;;
        order)         _MODULE_REGISTRY["${module_name}.order"]="$value" ;;
        cron)          _MODULE_REGISTRY["${module_name}.cron"]="$value" ;;
        cron_schedule) _MODULE_REGISTRY["${module_name}.cron_schedule"]="$value" ;;
      esac
      has_metadata=1
    fi
    # 遇到第一个非注释、非空行时停止扫描
    if [[ ! "$line" =~ ^[[:space:]]*# ]] && [[ -n "$line" ]]; then
      break
    fi
  done < <(head -30 "$file_path")

  if [[ "$has_metadata" -eq 0 ]]; then
    log_warning "模块缺少元数据声明：${file_path}（使用默认值）"
  fi

  return 0
}

# 解析目录式模块
# 参数：$1 - 模块目录路径
# 说明：目录式模块的入口文件为 module.sh
_parse_directory_module() {
  local dir_path="$1"
  local dir_name
  dir_name=$(basename "$dir_path")
  local entry_file="${dir_path}/module.sh"

  if [[ -f "$entry_file" ]]; then
    _parse_single_file "$entry_file"
    # 覆盖类型为 directory
    local module_name
    module_name="${_MODULE_REGISTRY["${dir_name}.module"]:-$dir_name}"
    _MODULE_REGISTRY["${module_name}.type"]="directory"
    _MODULE_REGISTRY["${module_name}.path"]="$entry_file"
  else
    log_warning "目录模块缺少入口文件 module.sh：${dir_path}"
  fi
}

# ==================== 公共接口 ====================

# 扫描 modules/ 目录，发现并解析所有模块
# 参数：无
# 返回：0 成功
discover_modules() {
  local modules_dir
  modules_dir=$(_get_modules_dir)

  if [[ ! -d "$modules_dir" ]]; then
    log_error "模块目录不存在：${modules_dir}"
    return 1
  fi

  # 重置状态
  _MODULE_REGISTRY=()
  _DISCOVERED_MODULES=()
  _MODULES_DISCOVERED=1

  # 扫描 .sh 文件（简单模块）
  local entry
  for entry in "${modules_dir}"/*.sh; do
    [[ -f "$entry" ]] || continue
    _parse_single_file "$entry"
  done

  # 扫描目录式模块
  for entry in "${modules_dir}"/*/; do
    [[ -d "$entry" ]] || continue
    _parse_directory_module "$entry"
  done

  # 构建已发现模块列表（去重）
  local -A seen_modules=()
  local key module_name
  for key in "${!_MODULE_REGISTRY[@]}"; do
    if [[ "$key" == *.module ]]; then
      module_name="${_MODULE_REGISTRY[$key]}"
      if [[ -z "${seen_modules[$module_name]:-}" ]]; then
        seen_modules["$module_name"]=1
        _DISCOVERED_MODULES+=("$module_name")
      fi
    fi
  done

  log_debug "已发现 ${#_DISCOVERED_MODULES[@]} 个模块"
  return 0
}

# 解析指定模块文件的元数据
# 参数：$1 - 模块文件路径
# 输出：打印元数据键值对（key=value 格式）
parse_module_metadata() {
  local file_path="${1:?parse_module_metadata: 缺少文件路径}"

  if [[ ! -f "$file_path" ]]; then
    log_error "模块文件不存在：${file_path}"
    return 1
  fi

  # 临时解析到局部数组
  local -A metadata=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^#[[:space:]]*@([a-z_]+):[[:space:]]*(.*) ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}"
      metadata["$key"]="$value"
    fi
    if [[ ! "$line" =~ ^[[:space:]]*# ]] && [[ -n "$line" ]]; then
      break
    fi
  done < <(head -30 "$file_path")

  # 输出结果
  local k
  for k in "${!metadata[@]}"; do
    echo "${k}=${metadata[$k]}"
  done
}

# 获取所有已发现模块列表
# 参数：无
# 输出：每行一个模块名
get_module_list() {
  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi

  local module_name
  for module_name in "${_DISCOVERED_MODULES[@]}"; do
    echo "$module_name"
  done
}

# 按分类获取模块列表（已排序）
# 参数：$1 - 分类名（可选，为空则返回所有分类）
# 输出：模块名列表（每行一个，按 @order 升序排列）
get_modules_by_category() {
  local target_category="${1:-}"

  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi

  if [[ -n "$target_category" ]]; then
    # 返回指定分类的模块
    local module_name category order
    local -a category_modules=()

    for module_name in "${_DISCOVERED_MODULES[@]}"; do
      category="${_MODULE_REGISTRY["${module_name}.category"]:-未分类}"
      if [[ "$category" == "$target_category" ]]; then
        order="${_MODULE_REGISTRY["${module_name}.order"]:-$DEFAULT_ORDER}"
        category_modules+=("${order}:${module_name}")
      fi
    done

    # 按 order 排序后输出
    if [[ ${#category_modules[@]} -gt 0 ]]; then
      printf '%s\n' "${category_modules[@]}" | sort -t: -k1 -n | cut -d: -f2-
    fi
  else
    # 返回所有分类（按 CATEGORY_ORDER 顺序）
    local cat_name
    for cat_name in "${CATEGORY_ORDER[@]}"; do
      local -a cat_modules=()
      local module_name category order

      for module_name in "${_DISCOVERED_MODULES[@]}"; do
        category="${_MODULE_REGISTRY["${module_name}.category"]:-未分类}"
        if [[ "$category" == "$cat_name" ]]; then
          order="${_MODULE_REGISTRY["${module_name}.order"]:-$DEFAULT_ORDER}"
          cat_modules+=("${order}:${module_name}")
        fi
      done

      if [[ ${#cat_modules[@]} -gt 0 ]]; then
        echo "[$cat_name]"
        printf '%s\n' "${cat_modules[@]}" | sort -t: -k1 -n | cut -d: -f2- | while read -r mod; do
          echo "  $mod"
        done
      fi
    done
  fi
}

# 获取模块的指定元数据字段
# 参数：$1 - 模块名
#       $2 - 字段名（name|category|description|depends|depend_modules|version|order|path|cron|cron_schedule）
#       $3 - 默认值（可选）
# 输出：字段值
get_module_field() {
  local module_name="${1:?get_module_field: 缺少模块名}"
  local field="${2:?get_module_field: 缺少字段名}"
  local default_value="${3:-}"

  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi

  local value="${_MODULE_REGISTRY["${module_name}.${field}"]:-}"
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

# 解析模块依赖（拓扑排序）
# 参数：$1 - 目标模块名
# 输出：按执行顺序排列的模块名列表（依赖在前）
# 返回：0 成功，1 存在循环依赖
resolve_module_deps() {
  local target="${1:?resolve_module_deps: 缺少模块名}"

  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi

  # 拓扑排序
  local -a result=()
  local -A visited=()
  local -A in_stack=()

  _topo_visit() {
    local node="$1"

    # 循环依赖检测
    if [[ "${in_stack[$node]:-}" == "1" ]]; then
      log_error "检测到循环依赖：${node}"
      return 1
    fi

    # 已处理过
    if [[ "${visited[$node]:-}" == "1" ]]; then
      return 0
    fi

    in_stack["$node"]=1

    # 递归处理依赖
    local deps_str="${_MODULE_REGISTRY["${node}.depend_modules"]:-}"
    if [[ -n "$deps_str" ]]; then
      local dep
      for dep in $(echo "$deps_str" | tr ',' ' '); do
        # 去除空格
        dep="${dep#"${dep%%[![:space:]]*}"}"
        dep="${dep%"${dep##*[![:space:]]}"}"
        [[ -n "$dep" ]] || continue

        if ! _topo_visit "$dep"; then
          return 1
        fi
      done
    fi

    unset 'in_stack[$node]'
    visited["$node"]=1
    result+=("$node")
    return 0
  }

  if ! _topo_visit "$target"; then
    return 1
  fi

  # 输出排序结果
  printf '%s\n' "${result[@]}"
}

# 检查模块是否存在（已发现）
# 参数：$1 - 模块名
# 返回：0 存在，1 不存在
module_exists() {
  local module_name="${1:?module_exists: 缺少模块名}"

  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi

  [[ -n "${_MODULE_REGISTRY["${module_name}.path"]:-}" ]]
}

# 获取模块入口文件路径
# 参数：$1 - 模块名
# 输出：文件绝对路径
get_module_path() {
  local module_name="${1:?get_module_path: 缺少模块名}"

  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi

  local path="${_MODULE_REGISTRY["${module_name}.path"]:-}"
  if [[ -n "$path" ]]; then
    echo "$path"
    return 0
  fi

  log_error "模块不存在：${module_name}"
  return 1
}
