# DebNAS 开发指南

> 版本：1.7.0 | 更新：2026-11-09
> 更新触发：新增§3.6 公共函数强制使用清单（第一阶段收拢的 keyring/sshd 端口/cron_state/config_get_bool/get_primary_user 等）与 lib 写法约定；§4.6 守卫行识别规则与只读工具约定

---

## 一、开发流程

开发流程（标准流程 / 轻量通道）和 AI 行为约束统一定义在 [CLAUDE.md](../CLAUDE.md)，此处不重复。

本文档聚焦以下开发规范：
- Git 提交约定与 CHANGELOG 更新制度
- 代码风格与实现决策阶梯
- 模块开发模板与元数据规范
- **Bug 修复与代码修改规范（§五）**
- 版本迁移框架

## 二、Git 规范

### 2.1 提交约定

- **提交信息必须使用简体中文**
- 遵循 Conventional Commits 格式：`<type>: <简短描述>`
- 常用 type：
  - `feat` — 新功能
  - `fix` — 修复
  - `refactor` — 重构（不改变外部行为）
  - `chore` — 杂务（构建、CI、依赖更新）
  - `docs` — 文档

示例：
```
feat: 新增邮件账户模块（支持 QQ/163/Gmail 等多提供商）
fix: 修复 cron_register 未传递 DEBNAS_CRON_MODE 导致定时执行失败
refactor: 统一模块入口点为 main() { ... }; main "$@" 模式
```

### 2.2 分支策略

| 分支 | 用途 |
|------|------|
| `main` | 稳定发布分支 |
| `refactor/debnas-v2` | 当前开发分支 |
| `feature/<name>` | 功能开发分支 |

### 2.3 .gitignore 注意事项

`CLAUDE.md`、`docs/`、`tests/` 被 gitignore 排除，**永久不入库**（减少用户下载体积）。

**制度约束：**
- `docs/` 和 `tests/` **在任何情况下都不得提议纳入版本控制**
- 不得提议移除 `.gitignore` 中对应的忽略规则
- 这两个目录仅存在于开发工作区，不在 Git 历史中（已于 2026-07-04 通过 `git filter-branch` 彻底清理）

在以下操作中注意保护这些文件：
- `git clean -fdX` 会删除被 gitignore 的文件

### 2.4 CHANGELOG 更新制度（强制）

项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 规范，`CHANGELOG.md` 位于仓库根目录。

**每次提交必须同步更新 CHANGELOG：**

1. **每次 `git commit` 前**，将本次变更按类别追加到 `CHANGELOG.md` 的 `[Unreleased]` 章节
2. 变更条目必须归入以下分类之一：
   - `Added` — 新增功能
   - `Changed` — 功能变更
   - `Deprecated` — 即将废弃
   - `Removed` — 已移除
   - `Fixed` — Bug 修复
   - `Security` — 安全修复
3. 条目格式：`- <描述>（可含模块名/文件名定位）`，使用简体中文
4. **版本发布时**（`git tag`）：
   - 将 `[Unreleased]` 内容移至新版本章节（`## [x.y.z] — YYYY-MM-DD`）
   - 版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)
   - 重置 `[Unreleased]` 为空章节

**AI 协作约束**：AI 在完成每次代码修改提交后，必须同步更新 CHANGELOG.md。这是强制步骤，不可跳过。

**轻量豁免**：仅限以下情况可跳过 CHANGELOG 更新：
- 纯文档修正（`docs/` 目录、README 错别字）
- 仅修改 `CLAUDE.md` 或 `.gitignore`
- 无行为影响的代码格式调整（注释修正、缩进统一）

## 三、代码风格

### 3.1 文件头

所有 `.sh` 文件必须包含：
```bash
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
```

### 3.2 命名约定

| 类型 | 约定 | 示例 |
|------|------|------|
| 公共函数 | `snake_case` | `write_file_if_changed` |
| 全局变量 | `UPPER_SNAKE_CASE` | `DEBNAS_ROOT`、`ERROR_GENERAL` |
| 模块内部变量 | `snake_case` 或 `local` | `local tmp_dir` |
| 私有函数 | 无强制前缀约定 | `_parse_early_flags`（`_` 前缀表示内部使用） |

### 3.3 I/O 约定

- **日志输出到 stderr**：`log_info "消息" >&2`（`lib/core/logging.sh` 已处理）
- **函数返回值输出到 stdout**：`echo "$result"`
- **退出码**：使用 `lib/core/constants.sh` 中定义的语义化常量

### 3.4 禁止事项

关键禁止项统一定义在 [CLAUDE.md](../CLAUDE.md) §3（项目特定禁止红线），此处不重复。

开发中最常涉及的要点速查：
- 使用 `service_ensure` 而非 `systemctl enable/start`
- 使用 `write_file_if_changed` 而非直接写 `/etc/apt/sources.list`
- 使用 `check_dependencies` + `install_missing_dependencies` 而非手动 `command -v` 循环

### 3.5 实现决策阶梯（强制）

每次编写代码前，按以下阶梯自底向上逐级检查。只有当前级不满足时才进入下一级——**目的是用最少的代码解决问题**。

```
1. 这一步真的需要存在吗？     → 不需要 = 跳过（YAGNI，不做多余的事）
2. 本仓库已有实现？           → 复用，不要重写
3. 标准库（bash 内置）能做到？ → 用内置
4. 系统原生功能（systemd/apt）？→ 用原生
5. 已安装的依赖（dpkg 包）？   → 用依赖
6. 一行能写完？               → 就一行
7. 以上都不满足：写最少可工作的实现
```

**示例：**

| 想要做的事 | 落在哪级 | 实际做法 |
|-----------|---------|---------|
| 给模块加"已完成"状态 | 第 2 级 | `module-runner.sh` 已自动管理，不需要模块自己写 |
| 检查命令是否存在 | 第 3 级 | `command -v curl`（bash 内置），不需要 `which curl` |
| 启用/重启服务 | 第 4 级 | `service_ensure nginx`（封装 systemctl），不直接调 systemctl |
| 解析 JSON | 第 5 级 | `jq`（apt 包），不手写正则解析 |
| YAGNI 典型 | 第 1 级 | "以后可能需要"的功能不写；只有一个调用者的私有函数合并回调用处 |

**AI 协作约束**：AI 在提出或实现任何功能变更时，必须在此阶梯上明确停靠位置（停在第几级、为什么），并在方案说明中体现。

### 3.6 公共函数强制使用清单（2026-11-09 起，强制）

**新代码必须使用下表中的公共函数，不得在模块内再写同类实现**；存量模块按第二阶段计划逐个替换。签名与语义见 [ARCHITECTURE.md §3.1](ARCHITECTURE.md)。

| 场景 | 必须使用 | 禁止的自写写法 |
|------|---------|---------------|
| 下载并安装第三方 APT 源公钥 | `keyring_install_verified <url> <指纹> <目标> [--dearmor] [--label 名称]` | 自写 curl + gpg --show-keys + awk 取指纹 + install/cat 覆盖 |
| 只校验公钥指纹 | `gpg_key_fingerprint_verify <文件> <指纹> [名称]` | 各模块 `verify_*_gpg_fingerprint` |
| 取 sshd 监听端口（防火墙放行/fail2ban） | `sshd_listen_ports` / `sshd_listen_ports_csv` | 自写 `sshd -T \| awk` + 解析 sshd_config |
| module_status/plan 里查定时任务 | `cron_state <模块> [变体参数]`（on/off/unknown） | 自写 `[[ $EUID -eq 0 ]] \|\| echo unknown` + `cron_is_registered` |
| 读 debnas.conf 开关 | `if config_get_bool <键> <默认>; then` | `[[ "$(config_read global k 1)" == "0" ]]`、`grep -qE '^k=1' debnas.conf` |
| 可换镜像的仓库/公钥地址 | `config_get_url <键> <默认地址>` | 各模块 `read_*_url` |
| module_status/plan 里查包是否已装 | `pkg_is_installed <包>` | 各模块 `_xx_pkg_installed`、内联 `dpkg-query -W -f='${db:Status-Status}'` |
| 首个普通用户 | `get_primary_user` | `awk -F: '$3>=1000…' /etc/passwd`、`get_first_regular_user`（deprecated） |
| 系统代号 | `get_system_codename` | `lsb_release -cs`、`. /etc/os-release` |
| 写 sysctl 持久化 | `sysctl_persist <名> <值> [文件]` | `echo >> /etc/sysctl.d/…`、`sed -i` |
| backports 优先级 | `write_pinning_file` / `configure_component_pinning`；预演比较用 `pinning_render`，只读判断用 `pinning_file_exists` | 直接 `>` 写 preferences.d、`check_pinning_status`（带日志） |
| 热路径读模块元数据 | `get_module_field_var <变量> <模块> <字段> [默认]` | 循环里 `$(get_module_field …)` |
| 发布产物校验 / 安装目录替换 | 只改 `lib/system/installer.sh` 的 DEBNAS-RELEASE-VERIFY / DEBNAS-DEPLOY 区块，再 `bash tools/release.sh --sync-verify` | 手改 install.sh 中的同名区块（测试会失败）、`cp -rf … \|\| true` 覆盖安装 |
| crontab / 配置 / 状态文件的读改写 | `cron_register*`、`config_write`、`state_set`（内部已持锁）；新的读改写用 `debnas_locked <锁名> <命令>` | 无锁的读 → 改 → 写回 |
| 仪表盘/探测的后台任务 | `bg_group_begin; ( … ) & pid=$!; bg_group_end`，终止用 `bg_group_kill "$pid"` | `( … ) &` + `kill "$pid"`（子 shell 里的命令成孤儿） |

**lib/ 写法约定**（新增/修改的 lib 代码）：

- 函数内变量一律 `local` 声明；判断一律 `[[ ]]`，算术用 `(( ))`；数值字段用 `10#$v` 防八进制
- 日志只用 `log_info/log_warning/log_error/log_success`；库层出错 `return 1`（或 `log_fatal_return`），不 `exit`
- 只读查询函数（供 module_status/module_plan 调用）不打日志、不写文件，状态码表达结果
- 热路径少开子进程：取文件名/目录用 `${p##*/}` / `${p%/*}`，读小文件用 `$(< f)` 或 `while read`，结果写全局变量或 `printf -v` 代替 `$(…)`
- 写系统文件经 `write_file_if_changed`（二进制文件参照 `keyring_install_verified` 的同目录临时文件 + `mv -fT`）
- 每个公共函数头部注释写明：用途、参数、输出、返回；注释密度与现有 lib 文件一致，不写与代码重复的逐行注释
- 只做格式统一时不重排缩进（各文件保持原有 tab/空格）

## 四、模块开发

### 4.1 模块模板

**单文件模块：**
```bash
#!/bin/bash
# @module: my-module
# @name: 我的模块
# @category: 系统工具
# @depends: curl,wget
# @depend_modules: sources
# @version: 1.0.0
# @order: 80
# 功能：模块功能描述

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 函数定义 ====================

my_function() {
  log_info "执行操作..."
  # 业务逻辑
}

# ==================== 主入口 ====================

main() {
  if ! verify_system_support; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi

  # 模块逻辑调用
  my_function

  log_success "模块执行完成"
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
```

> 新模块一律使用守卫形式结尾，并按 §4.6 实现 `module_status` / `module_plan`。

### 4.2 目录模块

目录模块入口文件 `modules/<name>/module.sh`，子模块按功能拆分：
- 使用 `MODULE_DIR` 定位子模块文件
- `source` 所有子模块
- 必要时使用 `export -f` 导出函数供并行子 shell 使用

### 4.3 元数据字段说明

| 字段 | 必填 | 说明 |
|------|------|------|
| `@module` | 是 | 模块唯一标识（与文件名一致） |
| `@name` | 是 | 显示名称 |
| `@category` | 是 | 分类（使用中文分类名称） |
| `@version` | 是 | 语义化版本 |
| `@order` | 是 | 菜单排序权重（数字越小越靠前） |
| `@depends` | 否 | 依赖的系统命令（逗号分隔） |
| `@depend_modules` | 否 | 依赖的其他模块（逗号分隔） |
| `@cron` | 否 | 是否支持定时执行（true/false） |
| `@cron_schedule` | 否 | 默认 cron 表达式（5 字段，统一默认 `0 0 * * *`） |
| `@interactive` | 否 | 是否为交互式模块（true/false），用于菜单系统区分交互/非交互环境 |
| `@debian_min` | 否 | 最低 Debian 主版本号（如 12） |

### 4.4 模块状态管理

模块状态由 `bin/module-runner.sh` 统一管理。模块**不需要**调用 `state_mark_success`（自动管理）。

模块内如果已有 `state_mark_success` 调用，是安全的（幂等写入），但属于冗余代码。

### 4.5 依赖检查

模块应在 `main()` 中检查依赖：

```bash
# 方式一：使用 check_dependencies（推荐）
local -a required_cmds=(curl wget dig)
if ! check_dependencies "${required_cmds[@]}"; then
  log_error "依赖缺失"
  exit "${ERROR_DEPENDENCY}"
fi

# 方式二：使用 install_missing_dependencies（自动安装）
install_missing_dependencies curl wget dig
```

### 4.6 只读探测契约：module_status / module_plan（可选，推荐）

契约定义与加载机制见 [ARCHITECTURE.md §4.5](ARCHITECTURE.md)。仪表盘用它显示每个功能的**当前状态**和执行前的**预演清单**。

**改造步骤（每个模块三步）：**

1. 末行 `main "$@"` 替换为守卫行（必须原样、顶格写在行首；加载器只认以 `if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]` 开头的行，注释或字符串里出现该文字不算）：
   ```bash
   # 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
   if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
   ```
2. 确认 main 之外的顶层代码只有变量/函数定义与 `source`（有顶层副作用的先移进 main，否则探测时会执行）。
3. 在 `main()` 之前加入两个函数（只加函数，不改原有逻辑）：

```bash
# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
  if [[ "$(dpkg-query -W -f='${db:Status-Status}' foo 2>/dev/null)" != "installed" ]]; then
    echo "absent|未安装 foo"
  elif ! systemctl is-active --quiet foo 2>/dev/null; then
    echo "warn|已安装但 foo 未运行"
  elif [[ ! -f /etc/foo/debnas.conf ]]; then
    echo "partial|运行中，DebNAS 配置未写入"
  else
    echo "running|运行中"
  fi
}

# 预演：每行 "类型|目标|备注"（无副作用；与 main 的判断保持一致；已满足的不列）
module_plan() {
  local IFS=$' \n\t'   # 项目全局 IFS 不含空格，拼接数组前需局部设置
  local -a missing=() pkg
  for pkg in foo foo-utils; do
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" == "installed" ]] || missing+=("$pkg")
  done
  [[ ${#missing[@]} -gt 0 ]] && echo "pkg|${missing[*]}|apt 安装"
  echo "write|/etc/foo/debnas.conf|内容未变则跳过；旧文件备份到 /var/backups/debnas/"
  echo "service|foo|启动并设为开机自启"
  echo "port|8080/tcp|firewalld 放行"
  [[ -n "${SSH_CONNECTION:-}" ]] && echo "risk|SSH|重启 sshd，当前会话不受影响"
  return 0
}
```

**编写要点：**

| 要点 | 说明 |
|------|------|
| 只读 | 禁止 `apt update`、写文件、启停服务、联网探测镜像；需要联网的步骤用 `info` 说明"执行时探测" |
| 快速 | `module_status` < 300ms（超 3s 被终止显示"检测超时"）；`module_plan` 超 8s 被终止 |
| 非 root 可运行 | 读不到的文件按"未知/跳过"处理，不要报错退出 |
| 不读 stdin、不交互 | 探测时 stdin 为 `/dev/null`，stdout 只输出契约行（日志会被丢弃） |
| 状态码选择 | 服务类：`running`/`warn`/`absent`；配置类：`applied`/`partial`/`absent`；检测出冲突或故障：`warn`/`error`；只读工具（无"已应用"概念）：`unknown\|只读工具 …`（以"只读工具"开头时不合并执行记录） |
| 公共函数 | 定时任务用 `cron_state`、sshd 端口用 `sshd_listen_ports`、开关用 `config_get_bool`（§3.6） |
| 备份说明 | `write` 行的备注写清楚备份位置；原地 `sed -i` 无备份的如实写"不另做备份" |
| 自测 | `bash bin/module-runner.sh --probe status <模块>`、`--probe plan <模块>`；BATS 参考 `tests/unit/lib/test-module-probe.bats` |

样板：`modules/firewall.sh`、`modules/docker-ce.sh`。

## 五、Bug 修复与代码修改规范

> 本节是对 [CLAUDE.md](../CLAUDE.md) §2（A-E 决策控制流）在 Bug 修复场景下的细化展开。
> CLAUDE.md 定义 AI 行为边界与决策门禁；本文档定义具体执行标准。

DebNAS 不允许"哪里报错就改哪里"的临时修补方式。任何 Bug 修复都必须遵循软件工程流程。

### 5.1 修复流程总览

Bug 修复流程与 CLAUDE.md A-E 阶段的对应关系：

```
发现 Bug
    ↓
复现问题 ───────────────────────────────────────┐
    ↓                                            │
定位根因（Root Cause Analysis）                  │
    ↓                                            │
分析调用关系（Call Graph Analysis）               │ 阶段 A：分析设计
    ↓                                            │
分析影响范围（Impact Analysis）                   │
    ↓                                            │
制定修复方案 ───────────────────────────────────┘
    ↓
【轻量通道？→ 直接执行 | 否则 → 等待用户确认】 ── 阶段 B：拦截确认
    ↓
实施代码修改（最小化变更） ────────────────────── 阶段 C：实施执行
    ↓
执行回归测试（失败 → 自修补，最多 3 轮）───────── 阶段 D：自行回归
    ↓
提交修复报告 + 更新 CHANGELOG ────────────────── 阶段 E：结果回登
```

**严禁跳过任何步骤直接修改代码。**

### 5.2 根因分析（RCA）

收到 Bug 后，**禁止立即修改代码**。必须先完成：

1. 复现问题
2. 找到真正根因（不是表象）
3. 说明为什么发生
4. 找出所有调用位置
5. 找出所有受影响模块
6. 判断是否存在同类问题（见 §5.4 关联修复）
7. 给出修复方案

禁止采用以下方式：

> 哪里报错改哪里

### 5.3 影响范围分析

任何函数、变量、配置项、公共模块发生修改时，必须进行影响范围分析。

**函数调用关系**：使用 `grep -rn` 查找：
- 谁调用该函数（上游）
- 该函数调用了哪些函数（下游）
- 是否属于公共接口（`lib/` 目录）

```
main
 ├── install
 │      └── check_os
 ├── upgrade
 │      └── check_os
 └── diagnose
        └── check_os
```

如果修改 `check_os()`，则 `install`、`upgrade`、`diagnose` 均属于影响范围，必须全部验证。

**配置依赖**：检查是否读取/修改配置文件，是否影响默认配置。

**全局变量**：检查是否引用全局变量，是否影响其他模块。

### 5.4 关联修复

发现 Bug 后，不允许仅修复当前报错位置。必须继续检查：

- 是否还有相同实现（复制粘贴代码）
- 是否还有相同逻辑（不同位置、相同模式）
- 是否存在同类 Bug（同类型错误在其他函数中）

使用 `grep -rn` 搜索所有同类实现，统一修复。避免"今天修 A、下周修 B、下个月再修 C"。

### 5.5 最小修改原则

> 仅修改导致问题的必要代码。

禁止在 Bug 修复中夹带：
- 顺便重构
- 顺便优化
- 顺便修改命名
- 顺便调整目录结构
- 顺便抽象函数
- 顺便修改其他模块

此原则与 [§3.5 实现决策阶梯](#35-实现决策阶梯强制) 第 1 级（YAGNI）一致：不做多余的事。

例外：用户明确要求一并重构时，方可扩大修改范围。

### 5.6 修复方案审批

如果涉及以下任一情况，必须先输出修复方案并**等待用户确认**：
- 多文件修改（≥3 个文件）
- 核心模块修改（`lib/`、`bin/`）
- 架构调整
- 公共接口修改

修复方案格式见 [CLAUDE.md §2.1 技术方案输出模板](../CLAUDE.md#21-技术方案输出模板强制)。

轻量通道（<3 文件、纯重构、无系统权限变更）可直接执行，无需等待。此门禁逻辑统一定义在 [CLAUDE.md §2 阶段 B](../CLAUDE.md)，此处不重复。

### 5.7 修复报告模板（强制）

每次 Bug 修复完成后，必须输出修复报告。此模板整合并替代旧版 3 项简化模板：

```
## Bug
<问题描述>

## Root Cause
<真正原因>

## Modified Files
- <文件路径>：<修改内容>

## Impact
- 直接影响：<模块/函数>
- 间接影响（调用链）：<上游调用方>
- 关联修复：<同类问题及位置>

## Regression Test
- 原问题验证：<Bug 是否复现>
- 同模块功能验证：<相关功能是否正常>
- 调用方验证：<所有上游调用方>
- 依赖模块验证：<下游依赖>
- 边界条件验证：<空值/极端输入/并发>
- 已有功能验证：<历史功能未被破坏>

## Remaining Risks
<剩余风险。如无，明确说明：未发现新增风险。>
```

### 5.8 回归测试

任何修改完成后，必须执行 `bash tests/check.sh`，并针对变更范围补充验证：

| 验证层级 | 内容 | 通过标准 |
|---------|------|---------|
| 当前 Bug | 原问题是否修复 | 问题不再复现 |
| 同模块 | 相关功能是否正常 | 模块已有功能不受影响 |
| 调用方 | 所有上游调用位置 | 调用方行为不变 |
| 依赖模块 | 下游依赖模块 | 依赖模块正常运行 |
| 历史功能 | 已有功能未被破坏 | `tests/check.sh` 全部通过 |

不得仅验证"报错消失"即认为修复完成。

### 5.9 公共模块特殊规定

修改以下目录中的文件，**默认视为高风险修改**：

```
lib/
bin/
```

必须：
- 扩大影响分析范围（使用 `grep -rn` 全仓库搜索引用）
- 扩大回归测试范围（运行完整 `tests/check.sh` + 集成测试）
- 输出完整影响报告（§5.7 模板中的所有章节）

不得仅验证当前功能。

### 5.10 禁止行为

AI 在 Bug 修复过程中禁止以下行为：

- 未分析根因直接修改代码
- 未分析影响范围直接提交修复
- 只修复一个调用点，忽略其他调用位置
- 修改公共接口而不检查调用链
- 修改配置格式而不验证兼容性
- 修复 Bug 时顺便重构无关代码
- 未执行回归测试即宣布修复完成
- 因赶进度而跳过分析流程

以上行为均视为违反项目开发规范。相关红线另见 [CLAUDE.md §3](../CLAUDE.md#3-项目特定禁止红线)。

---

## 六、版本迁移

当项目升级需要修改配置格式或数据结构时，使用版本迁移框架：

1. 在 `lib/system/migration.sh` 中注册新版本
2. 实现 `_migrate_<version>()` 函数
3. 调用 `migration_run` 自动检测并执行所需迁移

迁移函数按版本号顺序执行，每个版本只执行一次（通过状态文件记录）。
