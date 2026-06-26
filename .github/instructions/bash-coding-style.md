# DebNAS Bash 编码规范

> 基于 [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)，结合 DebNAS 项目特点制定。
> 所有代码贡献必须遵循此规范。

---

## 1. 文件组织

### 1.1 Shebang

```bash
#!/bin/bash
```

统一使用 `#!/bin/bash`，不使用 `#!/usr/bin/env bash`。Debian 系统中 `/bin/bash` 始终存在。

### 1.2 文件头注释

每个文件必须以以下格式开头：

```bash
#!/bin/bash
# <模块名> — <一句话功能描述>
#
# 详细说明（可选，复杂逻辑必须写）
```

### 1.3 模块元数据

每个模块文件必须在文件头注释之后声明元数据：

```bash
#!/bin/bash
# install-cockpit.sh — 安装 Cockpit Web 管理面板及 45Drives 组件
#
# 支持 Debian 12 (bookworm, 通过 APT 仓库) 和 Debian 13 (trixie, 手动下载 .deb)。
# 自动选择最快的 GitHub 代理进行下载。

# @module: install-cockpit
# @name: 安装 Cockpit
# @category: 管理面板
# @description: 安装 Cockpit Web 管理面板及 45Drives 文件共享组件
# @depends: curl,apt,systemctl
# @depend_modules: configure-sources,install-basic-tools
# @version: 3.0.0
# @debian_min: bookworm
# @cron: false
# @order: 30
```

### 1.4 安全设置

每个文件在元数据之后立即设置：

```bash
set -euo pipefail
IFS=$'\n\t'
```

### 1.5 库加载

所有模块统一使用 `bootstrap.sh` 加载库：

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
```

**禁止**：手动逐个 source 库文件。`bootstrap.sh` 是唯一入口。

### 1.6 入口守卫

模块文件必须支持被 source（用于测试），因此需要入口守卫：

```bash
# 模块公共函数定义在这里...

# === 入口 ===
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

---

## 2. 命名规范

### 2.1 函数命名

| 类型 | 命名规则 | 示例 |
|------|---------|------|
| 公共函数（库导出） | `snake_case`，无前缀 | `apt_update_safe()`, `config_read()`, `service_ensure()` |
| 模块内部函数 | `snake_case`，无前缀 | `download_threat_list()`, `parse_ip_entries()` |
| 库私有函数 | `_` 前缀 + snake_case | `_apt_lock_available()`, `_get_os_id()` |
| 模块入口函数 | `main()` | `main()` |
| Cron 回调 | `module_cron()` | `module_cron()` |

**规则**：
- 函数名使用动词开头，描述其行为：`check_*`、`get_*`、`set_*`、`install_*`、`configure_*`、`ensure_*`、`parse_*`、`write_*`、`probe_*`
- 私有函数必须有 `_` 前缀
- 禁止大写函数名（除非是兼容旧代码的别名）

### 2.2 变量命名

| 类型 | 命名规则 | 示例 |
|------|---------|------|
| 全局常量 | `UPPER_SNAKE_CASE` | `DEBNAS_TMP_BASE`, `DEFAULT_THREAT_LEVEL`, `REQUIRED_CMDS` |
| 环境变量 | `UPPER_SNAKE_CASE` | `LOG_LEVEL`, `DEBNAS_REGION`, `NO_COLOR` |
| 框架内部全局变量 | `_UPPER_SNAKE_CASE`（`_` 前缀） | `_DEBNAS_ROOT`, `_DEBNAS_APT_UPDATED`, `_DEBNAS_BOOTSTRAPPED` |
| 局部变量 | `lower_snake_case` | `temp_file`, `selected_mirror`, `threat_level` |
| 数组变量 | 复数形式 | `mirrors`, `pids`, `required_cmds` |

**规则**：
- 使用 `readonly` 声明真正的常量
- 使用 `declare` 声明全局变量时明确作用域（`-g`）
- 使用 `local` 声明函数内局部变量
- 禁止使用单字母变量名（循环索引 `i` 除外）

### 2.3 关联数组命名

```bash
# 映射表：<key>_BY_<value> 或 <key>_TO_<value>
declare -A CMD_TO_PKG      # 命令名 → 包名
declare -A DNS_IP_BY_NAME  # DNS 名称 → IP 地址
```

---

## 3. 格式化

### 3.1 缩进

使用 **4 个空格**缩进，不使用 Tab。

### 3.2 行长度

每行最多 **100 个字符**。超长行在管道符或逻辑运算符处换行：

```bash
# 好的换行
if [[ -z "${remaining_sources}" ]] && [[ -z "${has_services}" ]] \
  && [[ -z "${has_ports}" ]]; then
  return 0
fi

# 管道换行
firewall-cmd --permanent \
  --zone="${ZONE}" \
  --add-source="ipset:${ipset_name}" &>/dev/null
```

### 3.3 空行

- 函数之间空一行
- 逻辑段落之间空一行
- 文件末尾保留一个空行

### 3.4 条件判断

```bash
# 使用 [[ ]] 而非 [ ]
if [[ "${value}" -gt 0 ]]; then

# 检查变量是否设置
if [[ -n "${var:-}" ]]; then

# 检查变量是否未设置
if [[ -z "${var:-}" ]]; then

# 正则匹配
if [[ "${input}" =~ ^[0-9]+$ ]]; then
```

### 3.5 case 语句

```bash
case "${choice}" in
  1)
    action_one
    ;;
  2)
    action_two
    ;;
  *)
    log_error "无效选择: ${choice}"
    ;;
esac
```

---

## 4. 变量使用

### 4.1 变量引用

```bash
# 始终加引号
log_info "正在安装: ${package}"

# 数组展开
for pkg in "${packages[@]}"; do

# 关联数组访问
echo "${CMD_TO_PKG[${cmd}]:-}"
```

### 4.2 默认值

```bash
# 使用 :- 提供默认值
local timeout="${1:-30}"
local log_level="${LOG_LEVEL:-INFO}"
```

### 4.3 命令替换

```bash
# 优先使用 $() 而非 ``
local codename
codename=$(get_system_codename)
```

### 4.4 printf vs echo

```bash
# 涉及变量内容时使用 printf（避免转义问题）
printf '%s\n' "${value}"

# 仅输出固定文本时可用 echo
echo "操作完成"
```

---

## 5. 函数设计

### 5.1 函数结构

```bash
# 函数名 — 一句话描述功能
#
# 参数：
#   $1 - 参数说明（必填/可选）
#   $2 - 参数说明
# 输出（stdout）：返回值说明
# 返回：0 成功，1 失败，2 特定含义
function_name() {
  # 参数校验
  local param1="${1:?function_name: 缺少必要参数}"
  local param2="${2:-default_value}"

  # 逻辑
  ...

  # 返回
  return 0
}
```

### 5.2 函数原则

- **单一职责**：一个函数只做一件事
- **长度控制**：单个函数不超过 50 行（超过则拆分）
- **参数数量**：不超过 5 个参数
- **DRY**：重复 3 次以上的逻辑必须提取为函数

### 5.3 库函数设计

新增库函数时，考虑以下问题：
1. 这个函数是否在两个以上模块中有用？
2. 它的行为是否足够通用？
3. 它是否有清晰的输入输出契约？

如果 1-3 都是"是"，放入 `lib/`。否则留在模块内部。

### 5.4 模块标准函数

每个模块必须实现：

```bash
main() {
  # 模块入口。框架调用此函数。
  case "${1:-}" in
    --help) print_module_help; return 0 ;;
    "")     module_menu; return 0 ;;
    *)      log_error "未知参数: $1"; return "${ERROR_PARAMETER}" ;;
  esac
}
```

支持 cron 的模块额外实现：

```bash
module_cron() {
  # 由框架在 cron 模式下调用
  # 无 UI 输出、无颜色、最小化日志
  ...
}
```

---

## 6. 错误处理

### 6.1 退出码

使用 `lib/core/constants.sh` 中定义的标准退出码：

| 常量 | 值 | 含义 |
|------|---|------|
| `SUCCESS` | 0 | 成功 |
| `ERROR_GENERAL` | 1 | 通用错误 |
| `ERROR_DEPENDENCY` | 2 | 依赖缺失 |
| `ERROR_CONFIG` | 3 | 配置错误 |
| `ERROR_PERMISSION` | 4 | 权限不足 |
| `ERROR_PARAMETER` | 5 | 参数错误 |
| `ERROR_UNSUPPORTED_OS` | 6 | 不支持的操作系统 |

```bash
# 好的用法
if ! apt_update_safe; then
  log_error "软件源更新失败"
  return "${ERROR_GENERAL}"
fi

# 禁止
exit 1  # 使用常量而非魔法数字
```

### 6.2 错误消息

```bash
# 错误消息格式：[级别] 描述（上下文）
log_error "下载失败: ${url}（请检查网络连接）"
log_fail "配置写入失败: ${config_file}"
log_warning "镜像源不可用: ${mirror}，使用备用源"
```

### 6.3 防御性编程

```bash
# 检查命令是否存在
if ! command -v systemctl >/dev/null 2>&1; then
  log_error "systemctl 未安装"
  return "${ERROR_DEPENDENCY}"
fi

# 检查文件是否存在
if [[ ! -f "${config_file}" ]]; then
  log_error "配置文件不存在: ${config_file}"
  return "${ERROR_CONFIG}"
fi

# 检查目录是否可写
if [[ ! -w "${log_dir}" ]]; then
  log_error "日志目录不可写: ${log_dir}"
  return "${ERROR_PERMISSION}"
fi
```

---

## 7. 注释规范

### 7.1 文件头注释

```bash
#!/bin/bash
# create-lvm.sh — LVM 逻辑卷管理工具
#
# 支持创建物理卷、卷组和逻辑卷，包含交互式菜单和 CLI 两种模式。
# 自动检测可用磁盘并推荐配置。
```

### 7.2 函数注释

每个公共函数必须有注释：

```bash
# 安全执行 apt update（带防重复和锁检测）
# 说明：同一进程树内通过 _DEBNAS_APT_UPDATED 防重复。
#       跨进程通过锁文件检测保护。
# 返回：0 成功，1 失败
apt_update_safe() {
```

### 7.3 行内注释

```bash
# 复杂逻辑必须注释
# 示例：具体说明为什么这样做
```

**禁止**：无意义的注释（如 `i=$((i+1))  # i 加 1`）

### 7.4 TODO 标记

```bash
# TODO(kekylin): 此 API 在中国可能不可用，需要国内替代服务
# FIXME: 此函数在并发场景下不安全
```

---

## 8. 日志规范

### 8.1 日志函数

使用 `lib/core/logging.sh` 提供的标准函数：

| 函数 | 用途 | 示例 |
|------|------|------|
| `log_info` | 一般信息 | `log_info "正在更新软件包列表..."` |
| `log_success` | 操作成功 | `log_success "Docker 安装完成"` |
| `log_warning` | 警告（可恢复） | `log_warning "镜像源不可用，已跳过"` |
| `log_error` | 错误（操作失败） | `log_error "下载失败: ${url}"` |
| `log_action` | 用户操作 | `log_action "正在安装: Cockpit"` |
| `log_debug` | 调试信息 | `log_debug "候选镜像站数量: ${#mirrors[@]}"` |

### 8.2 日志原则

- 正常模式的日志用 log_info/log_success
- 只在 `--debug` 模式显示详细信息（使用 log_debug）
- 禁止直接使用 echo/printf 输出日志（除非在 cron 最小化模式中）
- 所有日志输出到 stderr（框架默认行为）

---

## 9. 临时文件

### 9.1 使用框架 API

```bash
# 框架在 bootstrap.sh 中自动调用了 register_temp_cleanup
# 模块无需手动注册 trap

# 创建临时文件
local temp_file
temp_file=$(create_temp_file "prefix" ".txt")

# 创建临时目录
local temp_dir
temp_dir=$(create_temp_dir "prefix")
```

### 9.2 原则

- 禁止手动使用 `mktemp` 而不用框架
- 禁止手动注册 trap 进行清理
- 临时文件超出函数作用域时，确保文件名被记录（框架自动跟踪）

---

## 10. 测试规范

### 10.1 可测试性

模块代码应支持被 source 而不执行：

```bash
#!/bin/bash
# 模块函数定义...

# 入口守卫 — 仅在直接运行时执行
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

### 10.2 测试文件命名

```
tests/unit/lib/test-apt.bats
tests/unit/modules/test-configure-sources.bats
tests/unit/modules/block-threat-ips/test-download.bats
```

### 10.3 测试原则

- 纯逻辑函数必须有单元测试
- 集成测试在真实 Debian VM 中运行
- 测试函数名描述被测试的行为：`@test "apt_update_safe should skip when already updated"`
- 每个 PR 必须通过所有测试

---

## 11. 禁止事项

| 禁止 | 原因 | 替代方案 |
|------|------|---------|
| 手动 `echo`/`printf` 输出日志 | 破坏统一的日志格式 | 使用 `log_*` 函数 |
| `exit 1` 魔法数字 | 无上下文 | 使用 `exit "${ERROR_GENERAL}"` |
| 直接 `trap ... EXIT` | 与框架 trap 冲突 | 使用 `register_temp_cleanup` |
| 模块内手动 source 库 | 可能遗漏、顺序错误 | 使用 `source bootstrap.sh` |
| 函数内 `exit` | 无法测试、无法恢复 | `return` 错误码 |
| 全局变量无 `declare -g` | 作用域不明确 | `declare -g VAR_NAME` |
| `[ ]` 条件判断 | 功能有限、易出错 | `[[ ]]` |
| 反引号命令替换 | 不可嵌套、易与引号混淆 | `$()` |
| `$var` 不加引号 | 单词分割风险 | `"${var}"` |
| 硬编码路径/版本号 | 维护困难 | 提取到 `urls.sh` 或配置 |

---

## 12. ShellCheck 要求

CI 中 ShellCheck 以 `--severity=error` 运行。以下规则必须零违反：

- SC2006 — 使用 `$()` 代替反引号
- SC2086 — 变量引用必须加双引号
- SC2155 — declare 和赋值应分离
- SC2164 — cd 无错误处理
- SC2181 — 直接使用退出码而非 `$?`

---

## 13. 审查清单

代码审查时检查以下项目：

- [ ] 文件头注释完整，包含 `@module` 元数据
- [ ] `set -euo pipefail` 和 `IFS=$'\n\t'`
- [ ] 使用 `source "${SCRIPT_DIR}/lib/bootstrap.sh"`
- [ ] 有入口守卫 `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"`
- [ ] 函数有注释（参数、返回值说明）
- [ ] 变量使用 `local` 或 `declare -g`
- [ ] 所有变量引用加双引号
- [ ] 退出码使用常量而非魔法数字
- [ ] 无 `exit` 在函数内部（除 main 外）
- [ ] 无手动 trap 注册
- [ ] 日志使用 `log_*` 函数
- [ ] 函数长度 ≤ 50 行
- [ ] ShellCheck 零 error
