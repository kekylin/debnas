#!/bin/bash
# 功能：模块自动发现与注册模块
# 说明：扫描 modules/ 目录，解析模块元数据，提供模块查询和依赖解析功能
# 元数据格式：文件头部的 # @key: value 注释行

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap.sh 加载）

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
  "系统维护"
  "系统工具"
  "一键部署"
)

# 默认 order 值（未声明时排在最后）
readonly DEFAULT_ORDER=999

# ==================== 内部状态 ====================

# 模块元数据存储（关联数组）
# 键格式：<module_name>.<field>
# 例如：cockpit.name = "安装 Cockpit"
declare -g -A _MODULE_REGISTRY=()

# 已发现模块列表
declare -g -a _DISCOVERED_MODULES=()

# 是否已执行过发现
declare -g _MODULES_DISCOVERED=0

# 最近一次 _parse_single_file 解析得到的模块名（供目录模块定位注册键）
declare -g _LAST_PARSED_MODULE=""

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

# 注册表字段（_reset_registry_entry 写默认值；@module 改名时按此清除旧条目）
readonly -a _MODULE_FIELDS=(module name category description depends depend_modules version debian_min arch order path type cron cron_schedule author since interactive kind)

# 写入一个模块的全部默认字段
# 参数：$1 - 模块名，$2 - 入口文件路径
_reset_registry_entry() {
  local m="$1"
  _MODULE_REGISTRY["${m}.module"]="$m"
  _MODULE_REGISTRY["${m}.name"]="$m"
  _MODULE_REGISTRY["${m}.category"]="未分类"
  _MODULE_REGISTRY["${m}.description"]=""
  _MODULE_REGISTRY["${m}.depends"]=""
  _MODULE_REGISTRY["${m}.depend_modules"]=""
  _MODULE_REGISTRY["${m}.version"]="1.0.0"
  _MODULE_REGISTRY["${m}.debian_min"]="bookworm"
  _MODULE_REGISTRY["${m}.arch"]=""
  _MODULE_REGISTRY["${m}.order"]="$DEFAULT_ORDER"
  _MODULE_REGISTRY["${m}.path"]="$2"
  _MODULE_REGISTRY["${m}.type"]="file"
  _MODULE_REGISTRY["${m}.cron"]="false"
  _MODULE_REGISTRY["${m}.cron_schedule"]=""
  _MODULE_REGISTRY["${m}.author"]=""
  _MODULE_REGISTRY["${m}.since"]=""
  _MODULE_REGISTRY["${m}.interactive"]="false"
  _MODULE_REGISTRY["${m}.kind"]=""
}

# 解析单个模块文件的元数据
# 参数：$1 - 模块文件路径
#       $2 - 默认模块名（可选，默认取文件名；目录模块传目录名，避免缺少 @module 时注册成 "module"）
# 输出：设置 _MODULE_REGISTRY 关联数组，并把最终模块名写入 _LAST_PARSED_MODULE
# 返回：0 成功，1 失败
_parse_single_file() {
  local file_path="$1"
  local file_name="${file_path##*/}"
  file_name="${file_name%.sh}"
  local module_name="${2:-$file_name}"

  # 从文件头部提取元数据（只扫描前 30 行，避免性能问题；mapfile 一次读入，不 fork head）
  local line key value field
  local has_metadata=0
  local -a head_lines=()
  mapfile -n 30 -t head_lines 2>/dev/null < "$file_path" || true

  # 预扫描 @module：它可能排在 @name/@category 之后。先确定最终模块名再解析其它字段，
  # 避免 @module 改名时把已解析字段清空；空值按“使用文件名”处理并告警。
  local pre_line pre_val
  for pre_line in "${head_lines[@]+"${head_lines[@]}"}"; do
    if [[ "$pre_line" == "#"*"@"*":"* ]]; then
      pre_val="${pre_line#\#}"
      pre_val="${pre_val#"${pre_val%%[![:space:]]*}"}"
      if [[ "$pre_val" == @module:* ]]; then
        pre_val="${pre_val#@module:}"
        pre_val="${pre_val#"${pre_val%%[![:space:]]*}"}"
        pre_val="${pre_val%"${pre_val##*[![:space:]]}"}"
        if [[ -n "$pre_val" ]]; then
          module_name="$pre_val"
        else
          log_warning "模块 @module 为空，使用文件名作为模块名：${file_path}"
        fi
        break
      fi
    fi
    # 遇到第一个非注释、非空行时停止扫描
    if [[ -n "$pre_line" && "${pre_line#"${pre_line%%[![:space:]]*}"}" != "#"* ]]; then
      break
    fi
  done

  _reset_registry_entry "$module_name" "$file_path"

  for line in "${head_lines[@]+"${head_lines[@]}"}"; do
    # 跳过非注释行（元数据必须在文件头部注释中）
    # 格式 "#<空白>@key:<空白>value"，key 仅含 a-z 与 _；用参数展开解析
    # （等价于 ^#[[:space:]]*@([a-z_]+):[[:space:]]*(.*)，省去逐行正则匹配）
    key=""
    if [[ "$line" == "#"*"@"*":"* ]]; then
      value="${line#\#}"
      value="${value#"${value%%[![:space:]]*}"}"
      if [[ "$value" == "@"*":"* ]]; then
        key="${value%%:*}"
        key="${key#@}"
        [[ -n "$key" && "$key" != *[!a-z_]* ]] || key=""
      fi
    fi
    if [[ -n "$key" ]]; then
      value="${value#*:}"
      value="${value#"${value%%[![:space:]]*}"}"
      # 去除尾部空格
      value="${value%"${value##*[![:space:]]}"}"

      case "$key" in
        module)
          # 模块名已由预扫描确定；这里忽略，避免再次 reset 清空已解析字段
          ;;
        path|type) ;;  # 由发现流程决定，不接受头部声明
        *)
          # 只接受已知字段（默认值已写入的键），未知 @key 忽略
          [[ -v "_MODULE_REGISTRY[${module_name}.${key}]" ]] && _MODULE_REGISTRY["${module_name}.${key}"]="$value"
          ;;
      esac
      has_metadata=1
    fi
    # 遇到第一个非注释、非空行时停止扫描（去掉前导空白后不以 # 开头）
    if [[ -n "$line" && "${line#"${line%%[![:space:]]*}"}" != "#"* ]]; then
      break
    fi
  done

  if [[ "$has_metadata" -eq 0 ]]; then
    log_warning "模块缺少元数据声明：${file_path}（使用默认值）"
  fi

  _LAST_PARSED_MODULE="$module_name"
  return 0
}

# 解析目录式模块
# 参数：$1 - 模块目录路径
# 说明：目录式模块的入口文件为 module.sh
_parse_directory_module() {
  local dir_path="${1%/}"
  local dir_name="${dir_path##*/}"
  local entry_file="${dir_path}/module.sh"

  if [[ -f "$entry_file" ]]; then
    _parse_single_file "$entry_file" "$dir_name"
    # 覆盖类型为 directory（使用解析得到的真实模块名；@module 与目录名不一致时，
    # 旧实现按目录名写入 type/path，会产生只有 type/path 的幽灵条目）
    local module_name
    module_name="${_LAST_PARSED_MODULE:-$dir_name}"
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

  # 扫描 .sh 文件（简单模块）与目录式模块，按解析顺序记录模块名
  # （原实现事后遍历整个注册表的全部键筛 *.module，模块数 × 字段数次比较）
  local entry module_name
  local -a parsed=()
  for entry in "${modules_dir}"/*.sh; do
    [[ -f "$entry" ]] || continue
    _LAST_PARSED_MODULE=""
    _parse_single_file "$entry"
    [[ -n "$_LAST_PARSED_MODULE" ]] && parsed+=("$_LAST_PARSED_MODULE")
  done
  for entry in "${modules_dir}"/*/; do
    [[ -d "$entry" ]] || continue
    _LAST_PARSED_MODULE=""
    _parse_directory_module "$entry"
    [[ -n "$_LAST_PARSED_MODULE" ]] && parsed+=("$_LAST_PARSED_MODULE")
  done

  # 构建已发现模块列表（去重；只保留注册表中仍存在的模块——@module 改名会清掉同名旧条目）
  local -A seen_modules=()
  for module_name in "${parsed[@]+"${parsed[@]}"}"; do
    [[ -z "${seen_modules[$module_name]:-}" && -n "${_MODULE_REGISTRY["${module_name}.module"]:-}" ]] || continue
    seen_modules["$module_name"]=1
    _DISCOVERED_MODULES+=("$module_name")
  done

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
  local line n=0
  [[ -r "$file_path" ]] || return 0
  while (( n++ < 30 )) && IFS= read -r line; do
    if [[ "$line" =~ ^#[[:space:]]*@([a-z_]+):[[:space:]]*(.*) ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}"
      metadata["$key"]="$value"
    fi
    if [[ ! "$line" =~ ^[[:space:]]*# ]] && [[ -n "$line" ]]; then
      break
    fi
  done < "$file_path"

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

# 读取模块元数据字段到变量（get_module_field 的无子 shell 版本，供热路径使用）
# 说明：get_module_field 经 $(...) 调用时每次 fork 一个子 shell，且子 shell 中的
#       惰性 discover_modules 结果不会保留；本函数在当前 shell 内完成
# 参数：$1 - 接收结果的变量名
#       $2 - 模块名
#       $3 - 字段名
#       $4 - 默认值（可选）
# 返回：0 有值（或使用了非空默认值），1 无值（变量置空）
get_module_field_var() {
  local _gmfv_var="${1:?get_module_field_var: 缺少变量名}"
  local _gmfv_module="${2:?get_module_field_var: 缺少模块名}"
  local _gmfv_field="${3:?get_module_field_var: 缺少字段名}"
  local _gmfv_value

  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi
  _gmfv_value="${_MODULE_REGISTRY["${_gmfv_module}.${_gmfv_field}"]:-${4:-}}"
  printf -v "$_gmfv_var" '%s' "$_gmfv_value"
  [[ -n "$_gmfv_value" ]]
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
      local -a dep_list=()
      IFS=' ,' read -ra dep_list <<< "$deps_str"
      for dep in "${dep_list[@]}"; do
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

  # 输出排序结果（空数组保护）
  if [[ ${#result[@]} -eq 0 ]]; then
    return 0
  fi
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

# 检查依赖模块是否已就绪（全部成功完成）
# 参数：$1 - 目标模块名
# 输出：未就绪的依赖模块名列表（每行一个，为空则全部就绪）
# 返回：0 全部就绪，1 有未就绪的依赖
check_module_deps_ready() {
  local target="${1:?check_module_deps_ready: 缺少模块名}"

  if [[ "$_MODULES_DISCOVERED" -eq 0 ]]; then
    discover_modules
  fi

  local deps_str="${_MODULE_REGISTRY["${target}.depend_modules"]:-}"
  if [[ -z "$deps_str" ]]; then
    return 0
  fi

  local -a not_ready=()
  local dep
  local -a dep_list=()
  IFS=' ,' read -ra dep_list <<< "$deps_str"
  for dep in "${dep_list[@]}"; do
    dep="${dep#"${dep%%[![:space:]]*}"}"
    dep="${dep%"${dep##*[![:space:]]}"}"
    [[ -n "$dep" ]] || continue

    if ! state_is_installed "$dep" 2>/dev/null; then
      not_ready+=("$dep")
    fi
  done

  if [[ ${#not_ready[@]} -gt 0 ]]; then
    printf '%s\n' "${not_ready[@]}"
    return 1
  fi
  return 0
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
