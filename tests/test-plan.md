# DebNAS 测试计划

> 版本：5.0.0 | 更新：2026-07-12
> 覆盖范围：6 层测试体系（L1 语法 → L6 VM）| 26 个模块 + 9 个 CLI 子命令 + 菜单系统 + 幂等性 + 错误处理
> 测试用例总数：~1374（L3 单元 1014 + L5 集成 219 + L6 VM 141）| BATS 文件：68（50 unit + 18 integration）
> Phase 8 已交付：7 个新增模块单元测试文件（174 用例）+ 3 项反模式修复 + 4 项重复检查清理 + 1 项 Mock DRY
> Phase 9 已交付：14 个新增 + 2 个扩展测试文件（105 用例），Phase 4-5 计划 165 TC-ID 全部覆盖（157 显式标签 + 8 元任务）

---

## 测试体系总览

### 六层测试金字塔

```
                    ┌──────────────┐
                    │  L6: VM 测试  │  ← 141 用例，手动/AI 辅助（SSH + 真实 Debian）
                    │  覆盖率 48.3%  │
                    ├──────────────┤
                    │ L5: 集成测试  │  ← 219 用例（Phase 4-5 计划已全部实施）
                    │  BATS + Mock  │
                    ├──────────────┤
                    │ L4: 冒烟测试  │  ← 2 检查（元数据完整性 + 依赖引用有效性）
                    │  grep/awk     │
                    ├──────────────┤
                    │ L3: 单元测试  │  ← 1014 用例（lib 180 + modules 834）
                    │  BATS         │
                    ├──────────────┤
                    │ L2: 静态分析  │  ← ShellCheck error 级别
                    ├──────────────┤
                    │ L1: 语法检查  │  ← bash -n 全部 .sh 文件
                    └──────────────┘
```

### 测试用例总览

| 层级 | 工具 | 现有用例 | Phase 4-5 计划新增 | 合计 | 自动化 |
|------|------|:---:|:---:|:---:|:---:|
| L1 语法 | `bash -n` | 1 门禁 | — | 1 | ✅ 全自动 |
| L2 静态分析 | ShellCheck | 1 门禁 | — | 1 | ✅ 全自动 |
| L3 单元 | BATS | 1014（50 文件） | — | 1014 | ✅ 全自动 |
| L4 冒烟 | grep/awk | 2 检查 | — | 2 | ✅ 全自动 |
| L5 集成 | BATS | 219（18 文件） | — | 219 | ✅ 全自动 |
| L6 VM | SSH + 手动 | 141 | — | 141 | 🔄 可下沉 |
| **合计** | | **1376** | **—** | **~1376** | |

> L3 1014 用例由 Phase 8 新增 7 个模块单元测试文件（174 用例）+ Phase 9 新增/扩展 18 个文件（105 用例）+ 现有测试扩展 + Phase 7 前存量测试构成。L5 219 用例包含 Phase 9 新增 10 个集成测试文件（79 用例）。Phase 4-5 设计的 165 个 TC-ID 已全部覆盖。

### 覆盖率现状与目标

| 指标 | Phase 9 后（当前） | Phase 4-5 目标 | 提升 |
|------|:---:|:---:|:---:|
| L1-L5 BATS 自动化用例数 | 1233（68 文件） | ~627 | +606（目标超额完成） |
| L6 手动覆盖用例数 | 141 | ~100 | −41（下沉至 L5） |
| 显式 TC-ID 标签覆盖 | 157 | ~155 | ✅ 全部覆盖 |
| Phase 4-5 待实施的 TC-ID | 0 | — | ✅ 全部完成 |

> **关键数据**：Phase 8 通过零依赖 Mock（PATH Injection + 结构验证 + 纯函数提取）将 7 个模块从零自动化覆盖提升至 L3 全自动。Phase 9 完成剩余全部 14 个计划文件 + 2 个扩展现有文件（105 新用例）。Phase 4-5 设计的 165 个 TC-ID 中，157 个有显式 BATS 标签，8 个元任务（AUTO-001~004/MOCKFIX-001~004）通过代码重构和现有测试覆盖完成。 |

### 如何使用本文档

- **L1-L5 自动化测试** → 见各功能章节的"自动化覆盖"子章节，详细规格见 [自动化测试用例文档](../docs/自动化测试用例文档.md)
- **L6 VM 测试** → 见各功能章节的测试用例表（保持原有 Legacy ID）
- **TC-ID 查找** → 见 [§11 Legacy ID ↔ TC-ID 映射表](#十一legacy-id--tc-id-映射表)
- **Mock 方案速查** → 见 [§10 Mock 策略速查](#十mock-策略速查)
- **新增测试文件清单** → 见 [附录 A](#附录-a新增-bats-测试文件清单)
- **自动化等级符号说明** → 见 [附录 B](#附录-b自动化等级标注符号说明)

---

## 测试环境

### 虚拟机信息

| 项目 | 值 |
|------|-----|
| 系统版本 | Debian 13 (trixie) amd64 |
| IP 地址 | 见本地测试环境（不要提交到仓库） |
| 普通账号 | kekylin |
| 普通账号密码 | 见本地测试环境（不要提交到仓库） |
| root 提权密码 | 见本地测试环境（不要提交到仓库） |
| 安装类型 | 最小化安装（无软件源、无 sudo） |

### 约束条件

以下约束模拟真实用户场景，测试必须严格遵守：

1. **禁止直接使用 root 登录** — 必须普通账号 SSH → `su -` 切换到 root
2. **无 APT 软件源** — 最小化安装默认无源，`apt update` 会失败。**禁止手动为 VM 配置软件源**，软件源必须通过 `debnas run sources` 模块配置（这是项目核心功能之一）
3. **无 sudo** — 最小化安装不含 sudo，仅 `su -` 可用
4. **仅基础工具** — wget、bash 等最小工具集
5. **部署方式由用户指定** — AI 根据用户指令选择"本地模式"或"远程模式"部署代码（见下方说明），禁止自行决定

### 测试模式与代码部署

测试分为两种模式，**由用户明确指定**，AI 不得自行选择：

| 模式 | 触发指令示例 | 部署方式 | 测试对象 |
|------|------------|---------|---------|
| **本地模式** | "本地测试"、"推送到 VM 测试" | SCP 推送本地代码 | 当前开发中的代码 |
| **远程模式** | "远程测试"、"用 install.sh 测试" | 在 VM 上执行 install.sh | 已发布到仓库的代码 |

> ⚠️ **默认使用本地模式**。仅在用户明确要求时才使用远程模式。本地开发阶段直接运行 `install.sh` 会用旧代码覆盖本地修改。

#### 本地模式：SCP 推送部署

```bash
# 本地终端先导出测试机参数（不要写入仓库）：
#   export TEST_VM_IP='192.168.x.x' TEST_VM_PASSWORD='...'
# 0. 准备 SSH 密码自动填充脚本（只需首次执行一次）
cat > /tmp/ssh-askpass.sh << 'EOF'
#!/bin/bash
printf '%s\n' "${TEST_VM_PASSWORD:?请先 export TEST_VM_PASSWORD}"
EOF
chmod +x /tmp/ssh-askpass.sh

# 1. 打包 → 推送 → 部署（一行完成）
cd /path/to/debnas && \
rm -f /tmp/debnas.tar.gz && \
tar -czf /tmp/debnas.tar.gz \
  --exclude='.git' \
  --exclude='CLAUDE.md' \
  --exclude='docs' \
  --exclude='tests' \
  --exclude='.claude' \
  --exclude='*.bak' \
  --exclude='*.swp' \
  --exclude='tmp' \
  . && \
SSH_ASKPASS=/tmp/ssh-askpass.sh DISPLAY=:0 \
scp -o StrictHostKeyChecking=no /tmp/debnas.tar.gz kekylin@${TEST_VM_IP}:/tmp/ && \
SSH_ASKPASS=/tmp/ssh-askpass.sh DISPLAY=:0 \
ssh -o StrictHostKeyChecking=no -t kekylin@${TEST_VM_IP} \
  "printf '%s\n' '${TEST_VM_PASSWORD:?}' | su -c '
    rm -rf /opt/debnas
    mkdir -p /opt/debnas
    tar -xzf /tmp/debnas.tar.gz -C /opt/debnas/
    ln -sf /opt/debnas/bin/debnas /usr/local/bin/debnas
    mkdir -p /etc/debnas /var/log/debnas /var/lib/debnas/state
    echo region=cn > /etc/debnas/debnas.conf
    echo deploy done
  '"
```

#### 远程模式：install.sh 部署

> 需先按上一节导出 `TEST_VM_IP` 与 `TEST_VM_PASSWORD`。

仅在用户明确指示时使用。在 VM 上直接执行安装脚本：

```bash
# 国内用户
SSH_ASKPASS=/tmp/ssh-askpass.sh DISPLAY=:0 \
ssh -o StrictHostKeyChecking=no -t kekylin@${TEST_VM_IP} \
  "printf '%s\n' '${TEST_VM_PASSWORD:?}' | su -c '
    wget -q https://gitee.com/kekylin/debnas/raw/main/install.sh -O /tmp/install.sh
    bash /tmp/install.sh --region cn --yes
  '"
```

---

## 一、安装脚本测试

### 1.1 L3-L5 自动化覆盖

以下 Phase 4-5 设计的自动化测试用例覆盖了安装脚本的核心逻辑路径。详细规格见 [自动化测试用例文档 §4.3、§7.2-§7.3](../docs/自动化测试用例文档.md)。

| TC-ID 范围 | 测试目标 | 自动化等级 | 覆盖现有用例 |
|------------|---------|:---:|------|
| TC-P1-INST-001~005 | installer 下载/解压/部署/验证 E2E 链 | ★★★★☆ | A-01~A-04, A-09~A-10 |
| TC-P2-MIG-001~004 | migration 版本迁移框架（首装/版本不变/版本变更/兼容检查） | ★★★☆☆ | — |
| TC-P0-MOCK-001~003 | installer_download Mock（成功/双源回退/全失败） | ★★★★☆ | A-09~A-10 |

> 上述 TC-ID 的完整 9 字段自动化规格（前置条件、Mock 方案、执行步骤、预期结果等）参见 [自动化测试用例文档](../docs/自动化测试用例文档.md) 对应章节。test-plan.md 仅保留 3 字段摘要以避免内容重复。

### 1.2 L6 VM 测试

#### 1.2.1 首次安装

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| A-01 | GitHub 默认安装 | `wget <github>/install.sh && bash install.sh` | 安装成功，自动启动菜单 | ★★☆☆☆ | L6 VM（需真实网络下载） |
| A-02 | Gitee 国内安装 | `wget <gitee>/install.sh && bash install.sh --region cn` | 安装成功，使用国内源下载 | ★★☆☆☆ | L6 VM（需真实网络下载） |
| A-03 | --help 参数 | `bash install.sh --help` | 输出帮助信息，零退出 | ★★★★☆ | 可自动化（纯 CLI 参数） |
| A-04 | --yes 自动确认 | `bash install.sh --region cn --yes` | 跳过所有交互确认 | ★★☆☆☆ | L6 VM（需真实安装流程） |
| A-05 | 运行时目录创建 | 安装后检查 | `/etc/debnas/`、`/var/log/debnas/`、`/var/lib/debnas/state/` 均存在 | ★★★☆☆ | 临时目录 Mock（TEMP-CONFIG/STATE/LOG-DIR） |
| A-06 | 全局命令安装 | 安装后 `which debnas` | 输出 `/usr/local/bin/debnas` | ★★★☆☆ | 临时目录 Mock |
| A-07 | 配置文件写入 | 安装后 `cat /etc/debnas/debnas.conf` | 包含 region 配置项 | ★★★☆☆ | 临时目录 Mock |
| A-08 | 重复安装检测 | 已安装后再次运行 install.sh | 提示覆盖更新确认 | ★★★☆☆ | 临时目录 + 状态 Mock |
| A-09 | SHA256 校验通过 | 正常安装 | 下载包 SHA256 校验通过，无报错 | 🔄 TC-P0-MOCK-001~003 | PATH Injection (`MOCK-WGET-OK`) |
| A-10 | SHA256 校验失败 | 篡改下载包后安装 | 报 SHA256 校验失败，中止安装 | 🔄 TC-P0-MOCK-003 | PATH Injection (`MOCK-WGET-FAIL`) |

#### 1.2.2 卸载测试

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| A-11 | 正常卸载 | `bash install.sh --uninstall` 确认 y | 清理 `/opt/debnas/`、`/usr/local/bin/debnas`、cron 条目 | ★★☆☆☆ | L6 VM（需真实文件系统清理验证） |
| A-12 | 取消卸载 | `bash install.sh --uninstall` 确认 n | 无任何文件变动 | ★★☆☆☆ | L6 VM |
| A-13 | 不影响已装软件 | 卸载后检查 Docker/Cockpit | 已安装的系统软件不受影响 | ★★☆☆☆ | L6 VM（需真实软件环境） |

---

## 二、CLI 命令测试

### 2.1 L3-L5 自动化覆盖

| TC-ID 范围 | 测试目标 | 自动化等级 | 覆盖现有用例 |
|------------|---------|:---:|------|
| TC-P0-CLI-001~016 | CLI 子命令路由（8 个 cmd_* + main 分发 + cron 重写 + 未知命令拒绝） | ★★★★☆ | C-01~C-14, C-22~C-28 |
| TC-P1-AUTO-001 | L6→L5 下沉：C-01~C-08 转为 BATS 自动化 | ★★★★☆ | C-01~C-08 |

### 2.2 全局参数

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| C-01 | 版本号 | `debnas --version` | 输出 `DebNAS v` 前缀 + 版本号（默认 v2026.06，可通过 DEBNAS_VERSION 环境变量覆盖） | 🔄 TC-P1-AUTO-001 | 子 shell 捕获输出 |
| C-02 | 帮助信息 | `debnas --help` | 显示 install/run/config/update/uninstall/doctor/cron 子命令 | 🔄 TC-P1-AUTO-001 | 子 shell 捕获输出 |
| C-03 | 无参数启动菜单 | `debnas`（无参数） | 进入交互菜单 | 🔄 TC-P0-CLI-001 | PATH Injection + Function Override |
| C-04 | 未知子命令 | `debnas --invalid` | 报错并提示用法 | 🔄 TC-P0-CLI-014 | 子 shell 捕获输出 |
| C-05 | --dry-run 模式 | `debnas --dry-run run firewall` | 仅打印执行计划，不实际操作 | 🔄 TC-P0-PRE-001 | Function Override (preflight 全 Mock) |
| C-06 | --yes 模式 | `debnas --yes run basic-tools` | 跳过所有确认提示 | 🔄 TC-P1-CFG-004 | 环境变量注入 |
| C-07 | --region 指定 | `debnas --region cn run sources` | 使用指定区域配置 | 🔄 TC-P1-CFG-001~002 | 环境变量注入 |
| C-08 | --cron 模式 | `debnas --cron run sys-patches` | 以 cron 模式执行（跳过 UI 加载、日志无颜色） | 🔄 TC-P0-CLI-015 | 环境变量 + PATH Injection |

### 2.3 install / run 子命令

> `install` 和 `run` 路由到同一处理函数，行为完全一致。

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| C-09 | 执行已知模块 | `debnas run sources` | 模块正常执行 | ★★★☆☆ | L6 VM（需真实模块执行） |
| C-10 | 执行已知模块（install） | `debnas install sources` | 与 run 结果一致 | ★★★☆☆ | L6 VM |
| C-11 | 不存在的模块 | `debnas run nonexistent` | 报错，列出可用模块 | 🔄 TC-P0-PRE-013 | Function Override (discover_modules) |
| C-12 | 无参数报错 | `debnas run` | 报错提示需要模块名 + 列出可用模块 | 🔄 TC-P0-CLI-002 | 子 shell + 参数注入 |
| C-13 | 幂等性 | 重复执行已成功模块 | `debnas run sources` 两次，第二次提示已安装跳过 | 🔄 TC-P1-AUTO-003 | Function Override (state_is_installed) |
| C-14 | 失败后重试 | 模拟失败后再次执行 | 从头重新执行，不跳过 | 🔄 TC-P1-AUTO-003 | Function Override (state_is_installed→fail) |

### 2.4 config 子命令

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| C-15 | 设置配置项 | `debnas config region cn` | `/etc/debnas/debnas.conf` 写入 `region=cn` | ★★★★☆ | 临时目录 Mock（TEMP-CONFIG-DIR） |
| C-16 | 读取配置项 | `debnas config region` | 输出当前 region 值 | ★★★★☆ | 临时目录 Mock |
| C-17 | 列出所有配置 | `debnas config`（无参数） | 列出所有配置项及当前值 | ★★★★☆ | 临时目录 Mock |
| C-18 | 无效配置项 | `debnas config nonexistent_key` | 报错提示 | ★★★★☆ | 临时目录 Mock |

### 2.5 doctor 子命令

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| C-19 | doctor 完整运行 | `debnas doctor` | 输出：版本/系统兼容性/磁盘/APT/网络/状态/服务 检查 | ★★★☆☆ | 临时目录 + PATH Injection（df/free/curl） |
| C-20 | doctor 只读 | `debnas doctor` | 不修改任何系统文件或状态 | ★★★☆☆ | 临时目录 Mock |
| C-21 | doctor 已安装模块 | 安装几个模块后运行 doctor | 已安装模块列表正确显示 | ★★★☆☆ | L6 VM（需真实模块状态） |

### 2.6 cron 子命令

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| C-22 | cron list（空） | `debnas cron list` | 提示无已注册任务 | 🔄 TC-P0-CLI-013 | PATH Injection (MOCK-CRONTAB) |
| C-23 | cron add（指定表达式） | `debnas cron add threat-ips "0 */6 * * *"` | 注册成功，crontab 出现 DEBNAS-CRON 标记 | 🔄 TC-P0-CLI-011 | PATH Injection (MOCK-CRONTAB) |
| C-24 | cron add（使用模块默认） | `debnas cron add sys-patches` | 使用模块 @cron_schedule 默认值 | 🔄 TC-P0-CLI-011 | PATH Injection + 临时模块目录 |
| C-25 | cron list（有任务） | add 后 `debnas cron list` | 显示已注册任务 | 🔄 TC-P0-CLI-013 | PATH Injection (MOCK-CRONTAB) |
| C-26 | cron remove | `debnas cron remove threat-ips` | 移除成功，crontab 中该条目消失 | 🔄 TC-P0-CLI-012 | PATH Injection (MOCK-CRONTAB) |
| C-27 | cron 无参数 | `debnas cron` | 报错提示 add/remove/list | 🔄 TC-P0-CLI-013 | 子 shell 捕获输出 |
| C-28 | cron add 无模块 | `debnas cron add` | 报错提示需要模块名 | 🔄 TC-P0-CLI-011 | 子 shell 捕获输出 |

### 2.7 update / uninstall 子命令

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| C-29 | update 正常 | `debnas update` | 下载最新版覆盖 `/opt/debnas/`，保留配置 | ★★☆☆☆ | L6 VM（需真实网络下载） |
| C-30 | update 保留配置 | update 后检查 `/etc/debnas/debnas.conf` | 配置未被覆盖 | ★★☆☆☆ | L6 VM |
| C-31 | uninstall 正常 | `debnas uninstall` 确认 y | 清理所有 DebNAS 文件 | ★★☆☆☆ | L6 VM（需真实文件系统清理验证） |
| C-32 | uninstall 取消 | `debnas uninstall` 确认 n | 无任何变动 | ★★☆☆☆ | L6 VM |

---

## 三、菜单交互测试

### 3.1 L3-L5 自动化覆盖

| TC-ID 范围 | 测试目标 | 自动化等级 | 覆盖现有用例 |
|------------|---------|:---:|------|
| TC-P1-MENU-001~006 | 主菜单循环（退出/无效输入/范围校验/EOF/空分类过滤/方案检测） | ★★★★☆ | M-01~M-04 |
| TC-P1-UI-001~010 | UI 输入处理函数（get_user_choice 全边界 + run_submenu 回调分发） | ★★★★★ | M-03~M-04 |
| TC-P1-IMOD-001~003 | 交互模块管道自动化（mail-account/acl-manager/bbr 参数模式） | ★★★☆☆ | M-51, M-67~M-68 |

> ⚠️ **已知反模式**：`test-solution.bats` 完全重定义了 `execute_solution()` 函数（绕过真实 `bin/menu.sh` 代码）。修复方案见 TC-P1-MOCKFIX-003。

### 3.2 主菜单

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-01 | 主菜单显示 | `debnas` | 显示横幅 + 8 个分类（基础系统/管理面板/安全防护/容器管理/通知服务/系统维护/系统工具/一键部署）+ 退出 | 🔄 TC-P1-MENU-005~006 | stdin 注入 + Function Override (discover_modules) |
| M-02 | 退出菜单 | 输入 `0` | 正常退出，退出码 0 | 🔄 TC-P1-MENU-001 | stdin 注入 (`echo "0"`) |
| M-03 | 无效输入 | 输入字母或符号 | 提示重新输入 | 🔄 TC-P1-UI-007 | stdin 注入 |
| M-04 | 超范围数字 | 输入 `99` | 提示无效选择 | 🔄 TC-P1-UI-005 | stdin 注入 |

### 3.3 基础系统（分类 1）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-10 | 子菜单显示 | 主菜单选 1 | 显示 sources、basic-tools | ★★☆☆☆ | L6 VM（需真实模块发现） |
| M-11 | 配置软件源 | 选 1 | sources 模块执行，APT 源配置成功 | ★★☆☆☆ | L6 VM |
| M-12 | 安装基础工具 | 选 2 | basic-tools 执行，sudo/curl 等安装成功 | ★★☆☆☆ | L6 VM |
| M-13 | 返回上级 | 输入 `0` | 返回主菜单 | ★★☆☆☆ | L6 VM |

### 3.4 管理面板（分类 2）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-20 | 子菜单显示 | 主菜单选 2 | 显示 7 个模块（cockpit/cockpit-45drives/cockpit-ext-on/cockpit-ext-off/cockpit-net/vm-components/wallpaper） | ★★☆☆☆ | L6 VM |
| M-21 | 安装 Cockpit 面板 | 选 cockpit 对应编号 | 安装成功，`systemctl is-active cockpit` = active | ★★☆☆☆ | L6 VM |
| M-22 | 安装 45Drives 扩展 | 选 cockpit-45drives | 扩展安装成功 | ★★☆☆☆ | L6 VM |
| M-23 | 启用 Cockpit 外网访问 | 选 cockpit-ext-on | 提示输入域名 | ★★☆☆☆ | L6 VM |
| M-24 | 禁用 Cockpit 外网访问 | 选 cockpit-ext-off | 配置被移除 | ★★☆☆☆ | L6 VM |
| M-25 | 面板管理网络 | 选 cockpit-net | Cockpit 网络配置 | ★★☆☆☆ | L6 VM |
| M-26 | 安装虚拟机组件 | 选 vm-components | libvirt/qemu 安装 | ★★☆☆☆ | L6 VM |
| M-27 | 面板必应壁纸 | 选 wallpaper | 壁纸下载 + CSS 生成 | ★★☆☆☆ | L6 VM |

### 3.5 安全防护（分类 3）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-30 | 子菜单显示 | 主菜单选 3 | 显示 security/firewall/fail2ban/threat-ips | ★★☆☆☆ | L6 VM |
| M-31 | 基础安全配置 | 选 security | su 限制/超时登出配置 | ★★☆☆☆ | L6 VM |
| M-32 | 配置防火墙 | 选 firewall | firewalld 安装运行，SSH 端口保持开放 | ★★☆☆☆ | L6 VM |
| M-33 | 配置 Fail2ban | 选 fail2ban | 服务运行，jail 配置正确 | ★★☆☆☆ | L6 VM |
| M-34 | IP 封禁工具 | 选 threat-ips | 进入威胁 IP 子菜单 | ★★☆☆☆ | L6 VM |

### 3.6 容器管理（分类 4）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-40 | 子菜单显示 | 主菜单选 4 | 显示 docker-ce/docker-mirror/docker-apps | ★★☆☆☆ | L6 VM |
| M-41 | 安装 Docker CE | 选 docker-ce | `docker --version` 正确输出 | ★★☆☆☆ | L6 VM |
| M-42 | 配置镜像加速 | 选 docker-mirror | `/etc/docker/daemon.json` 配置 registry-mirrors | ★★☆☆☆ | L6 VM |
| M-43 | 部署容器应用 | 选 docker-apps | 进入容器选择菜单，可部署 Portainer | ★★☆☆☆ | L6 VM |

### 3.7 通知服务（分类 5）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-50 | 子菜单显示 | 主菜单选 5 | 显示 mail-account/login-mail-on/login-mail-off | ★★☆☆☆ | L6 VM |
| M-51 | 配置邮件账户 | 选 mail-account | Exim4 SMTP 配置，测试邮件发送 | 🔄 TC-P1-IMOD-001 | stdin 注入模拟 SMTP 凭据 |
| M-52 | 启用登录邮件通知 | 选 login-mail-on | PAM 集成配置写入 | ★★☆☆☆ | L6 VM |
| M-53 | 禁用登录邮件通知 | 选 login-mail-off | PAM 配置行移除 | ★★☆☆☆ | L6 VM |

### 3.8 系统维护（分类 6）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-60 | 子菜单显示 | 主菜单选 6 | 显示 3 个模块（检查兼容性/检查系统更新/查询服务状态） | ★★☆☆☆ | L6 VM |
| M-61 | 检查兼容性 | 选 sys-check | 输出 Debian 版本/架构/兼容性 | ★★☆☆☆ | L6 VM |
| M-62 | 检查系统更新 | 选 sys-patches | 列出可用更新，可设置定时检查 | ★★☆☆☆ | L6 VM |
| M-63 | 查询服务状态 | 选 service-query | 显示已安装服务运行状态 | ★★☆☆☆ | L6 VM |

### 3.9 系统工具（分类 7）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-64 | 子菜单显示 | 主菜单选 7 | 显示 4 个模块（同步 Hosts/安装 Tailscale/ACL 权限管理/配置 BBR 加速） | ★★☆☆☆ | L6 VM |
| M-65 | 同步 Hosts | 选 hosts-sync | GitHub/hub.docker.com 等域名解析并更新 hosts | ★★☆☆☆ | L6 VM |
| M-66 | 安装 Tailscale | 选 tailscale | Tailscale 安装成功 | ★★☆☆☆ | L6 VM |
| M-67 | ACL 权限管理 | 选 acl-manager | 进入 ACL 交互菜单 | 🔄 TC-P1-IMOD-002 | stdin 注入完整菜单序列 |
| M-68 | 配置 BBR 加速 | 选 bbr | 进入 BBR 交互菜单 | 🔄 TC-P1-IMOD-003 | 参数模式 (`debnas --yes run bbr 2`) |

### 3.10 一键部署（分类 8）

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| M-70 | 子菜单显示 | 主菜单选 8 | 显示 basic/secure 两个部署方案 | ★★☆☆☆ | L6 VM |
| M-71 | 一键基础环境 | 选 basic | 按顺序执行 7 个模块（sources→basic-tools→cockpit→cockpit-net→docker-ce→docker-mirror→service-query） | ★★☆☆☆ | L6 VM |
| M-72 | 一键安全环境 | 选 secure | 按顺序执行 12 个模块（基础+安全+通知全套） | ★★☆☆☆ | L6 VM |
| M-73 | 一键部署跳过已装 | 已有部分模块时执行 | 已安装模块自动跳过 | ★★☆☆☆ | L6 VM |

---

## 四、模块功能测试

### 4.1 L3-L5 自动化覆盖

| TC-ID 范围 | 测试目标 | 自动化等级 | 覆盖现有用例 |
|------------|---------|:---:|------|
| TC-P0-REG-001~016 | 模块注册表（DFS 拓扑排序、循环依赖检测、30 行元数据窗口边界、分类过滤） | ★★★★☆ | —（全新测试） |
| TC-P0-URL-001~008 | URL 探测与镜像（curl/wget 双路径回退、镜像名称映射、代理端点） | ★★★★☆ | —（全新测试） |
| TC-P1-MOD-005~007 | 模块功能测试（sys-check/service-query/hosts-sync） | ★★★☆☆ | F-01~F-21 等 |
| TC-P2-MOD-008~009 | 模块纯函数单元测试（threat-ips IP 验证、docker-ce GPG 重试） | ★★★★★ | F-39, F-47 |

> ⚠️ **已知反模式**：`test-docker-ce.bats` 内联复制了 `extract_mirror_from_sources()` 和 `is_official_debian_source()` 的 awk 逻辑，而非 source 真实函数。修复方案见 TC-P1-MOCKFIX-001~002。
>
> 💀 **死代码警告**：`lib/ui/menu.sh` 中 `get_user_multiple_choice()`、`show_confirm()`、`show_menu_with_description()` 三个函数有实现但从未被任何生产代码调用。相关 BATS 测试（如存在）所测的是永不执行的代码路径。

> **依赖链验证**：以下模块声明了 `@depend_modules`，测试时需验证其依赖状态如果未满足，是否正确报错提示：
> - cockpit-45drives/cockpit-ext-on/off/cockpit-net/vm-components/service-query → 依赖 cockpit
> - fail2ban/threat-ips → 依赖 firewall
> - docker-mirror/docker-apps → 依赖 docker-ce
> - login-mail-on/login-mail-off → 依赖 mail-account

### 4.2 基础系统

| 编号 | 模块 | 测试项 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|------|--------|---------|:---:|------|
| F-01 | sources | 无 wget/curl 环境下执行 | 跳过镜像探测，使用默认镜像站 | ★★☆☆☆ | L6 VM |
| F-02 | sources | DEB822 格式写入 | `/etc/apt/sources.list.d/debian.sources` 格式正确 | ★★☆☆☆ | L6 VM |
| F-03 | sources | apt update 成功 | 软件包列表更新成功 | ★★☆☆☆ | L6 VM |
| F-04 | sources | 幂等性 | 重复执行跳过 | ★★☆☆☆ | L6 VM |
| F-05 | basic-tools | 软件包安装 | curl、sudo、wget、gnupg 等已安装 | ★★☆☆☆ | L6 VM |
| F-06 | basic-tools | 幂等性 | 重复执行跳过 | ★★☆☆☆ | L6 VM |

### 4.3 管理面板

| 编号 | 模块 | 测试项 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|------|--------|---------|:---:|------|
| F-10 | cockpit | Debian 12 安装 | 通过 45Drives 仓库安装 | ★★☆☆☆ | L6 VM |
| F-11 | cockpit | Debian 13 安装 | 通过本地 .deb 安装，包含 cockpit-files | ★★☆☆☆ | L6 VM |
| F-12 | cockpit | 服务运行 | `systemctl is-active cockpit` = active | ★★☆☆☆ | L6 VM |
| F-13 | cockpit | 幂等性 | 重复执行跳过 | ★★☆☆☆ | L6 VM |
| F-14 | cockpit-45drives | 扩展安装 | 45Drives 存储管理扩展安装成功 | ★★☆☆☆ | L6 VM |
| F-15 | cockpit-45drives | Debian 12/13 适配 | 根据版本选择正确安装方式 | ★★☆☆☆ | L6 VM |
| F-16 | cockpit-ext-on | 外网访问启用 | 输入域名后 Web 代理配置成功 | ★★☆☆☆ | L6 VM |
| F-17 | cockpit-ext-off | 外网访问禁用 | 配置清理成功 | ★★☆☆☆ | L6 VM |
| F-18 | cockpit-net | 网络设置 | Cockpit 监听地址配置 | ★★☆☆☆ | L6 VM |
| F-19 | vm-components | 虚拟机组件 | libvirt、qemu-kvm、virt-manager 安装 | ★★☆☆☆ | L6 VM |
| F-20 | wallpaper | 壁纸下载 | Bing API 数据获取 + 壁纸 PNG 下载 | ★★☆☆☆ | L6 VM |
| F-21 | wallpaper | CSS 生成 + cron 注册 | branding.css 生成，cron 定时任务注册成功（`debnas cron list` 可见） | ★★☆☆☆ | L6 VM |

### 4.4 安全防护

| 编号 | 模块 | 测试项 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|------|--------|---------|:---:|------|
| F-30 | security | su 限制 | `/etc/pam.d/su` 配置正确 | ★★★☆☆ | 临时目录 + Function Override（PAM 路径） |
| F-31 | security | 超时登出 | `/etc/profile.d/` 超时配置写入 | ★★★☆☆ | 临时目录 Mock |
| F-32 | firewall | firewalld 安装 | 服务运行，默认区域 = public | ★★☆☆☆ | L6 VM |
| F-33 | firewall | SSH 端口保活 | 22 端口在防火墙规则中保持开放 | ★★☆☆☆ | L6 VM |
| F-34 | firewall | 幂等性 | 重复执行跳过 | ★★☆☆☆ | L6 VM |
| F-35 | fail2ban | 安装运行 | 服务 active，sshd jail 启用 | ★★☆☆☆ | L6 VM |
| F-36 | fail2ban | 邮件通知 | 配置中 banaction 含邮件通知 | ★★☆☆☆ | L6 VM |
| F-37 | threat-ips | 交互菜单 | 显示启用/禁用/查看/返回选项 | ★★★☆☆ | stdin 注入 |
| F-38 | threat-ips | 威胁列表下载 | 列表下载解析成功 | ★★☆☆☆ | L6 VM |
| F-39 | threat-ips | ipset + firewalld | IP 集合创建并绑定到 drop 区域 | ★★☆☆☆ | L6 VM |
| F-40 | threat-ips | cron 定时更新 | 定时任务注册（@cron_schedule） | ★★☆☆☆ | L6 VM |

### 4.5 容器管理

| 编号 | 模块 | 测试项 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|------|--------|---------|:---:|------|
| F-45 | docker-ce | Docker CE 安装 | `docker --version` 输出版本号 | ★★☆☆☆ | L6 VM |
| F-46 | docker-ce | 服务运行 | `systemctl is-active docker` = active | ★★☆☆☆ | L6 VM |
| F-47 | docker-ce | 用户加入 docker 组 | UID 1000 用户在 docker 组中 | ★★☆☆☆ | L6 VM |
| F-48 | docker-ce | 幂等性 | 重复执行跳过 | ★★☆☆☆ | L6 VM |
| F-49 | docker-mirror | daemon.json 配置 | registry-mirrors 写入 `/etc/docker/daemon.json` | ★★☆☆☆ | L6 VM |
| F-50 | docker-mirror | 多源合并去重 | 合并已有 + 新增 registry-mirrors 并去重，写入 daemon.json | ★★☆☆☆ | L6 VM |
| F-51 | docker-mirror | 幂等性 | 重复执行跳过 | ★★☆☆☆ | L6 VM |
| F-52 | docker-apps | 菜单显示 | 显示 Portainer 部署选项 | ★★★☆☆ | stdin 注入 |
| F-53 | docker-apps | 部署 Portainer | `docker compose` 部署成功 | ★★☆☆☆ | L6 VM |
| F-54 | docker-apps | Docker 未安装报错 | 未装 Docker 时执行，报错提示先安装 docker-ce | ★★★☆☆ | Function Override (state_is_installed→fail) |

### 4.6 通知服务

| 编号 | 模块 | 测试项 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|------|--------|---------|:---:|------|
| F-60 | mail-account | QQ 邮箱配置 | Exim4 SMTP 配置成功 | ★★★☆☆ | stdin 注入模拟 SMTP 凭据 |
| F-61 | mail-account | 测试邮件 | 测试邮件发送成功 | ★★☆☆☆ | L6 VM |
| F-62 | login-mail-on | PAM 集成 | `/etc/pam.d/common-session` 含通知脚本 | ★★★☆☆ | 临时目录 Mock |
| F-63 | login-mail-off | PAM 移除 | 配置行被删除，登录不再发送通知 | ★★★☆☆ | 临时目录 Mock |

### 4.7 系统工具

| 编号 | 模块 | 测试项 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|------|--------|---------|:---:|------|
| F-70 | sys-check | 系统检查 | 输出 Debian 版本/架构/磁盘/内存/兼容性 | ★★★☆☆ | PATH Injection（df/free/uname） |
| F-71 | sys-check | Debian 12/13 | 两个版本均正确识别 | ★★★☆☆ | Function Override (os_release) |
| F-72 | sys-check | 非 Debian 拒绝 | Ubuntu 等系统报错退出 | ★★★★☆ | Function Override (verify_debian) |
| F-73 | sys-patches | 更新检查 | 列出可用更新数量 | ★★☆☆☆ | L6 VM |
| F-74 | sys-patches | 邮件通知 | 有更新时通过邮件发送通知 | ★★☆☆☆ | L6 VM |
| F-75 | sys-patches | cron 定时 | 定时检查任务注册 | ★★☆☆☆ | L6 VM |
| F-76 | service-query | 服务列表 | 显示已安装的 DebNAS 管理服务状态 | ★★★☆☆ | 临时目录 + Mock systemctl |
| F-77 | hosts-sync | DNS 解析 | GitHub/Docker Hub 域名解析成功 | ★★★☆☆ | PATH Injection（dig/nslookup） |
| F-78 | hosts-sync | 连通性检测 | TCP ping 检测，三级优先级筛选 | ★★★☆☆ | PATH Injection |
| F-79 | hosts-sync | /etc/hosts 更新 | hosts 文件更新并备份 | ★★★☆☆ | 临时目录 Mock |
| F-79a | hosts-sync | cron 定时更新 | 定时任务注册成功（`debnas cron list` 可见 hosts-sync 条目） | ★★★☆☆ | PATH Injection (MOCK-CRONTAB) |
| F-80 | tailscale | 安装 | Tailscale 安装成功，服务运行 | ★★☆☆☆ | L6 VM |
| F-81 | acl-manager | ACL 设置 | 交互式设置文件/目录 ACL 权限 | ★★★☆☆ | stdin 注入完整菜单序列 + 临时目录 |
| F-82 | acl-manager | ACL 查看 | 显示当前 ACL 配置 | ★★★☆☆ | stdin 注入 |
| F-83 | bbr | 启用 BBR | `tcp_bbr` 模块加载，sysctl 持久化配置 | ★★☆☆☆ | L6 VM（需真实内核模块） |
| F-84 | bbr | 禁用 BBR | 恢复默认拥塞控制算法 | ★★☆☆☆ | L6 VM |
| F-85 | bbr | 查看状态 | 显示当前使用的拥塞控制算法 | ★★★☆☆ | 参数模式 (`debnas --yes run bbr 5`) |

### 4.8 一键部署

| 编号 | 模块 | 测试项 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|------|--------|---------|:---:|------|
| F-90 | basic | 全新执行 | 按顺序执行 7 个模块（sources/basic-tools/cockpit/cockpit-net/docker-ce/docker-mirror/service-query），全部成功 | ★★☆☆☆ | L6 VM |
| F-91 | basic | 部分已安装 | 已安装模块自动跳过，继续执行未装模块 | ★★☆☆☆ | L6 VM |
| F-92 | basic | 中间失败 | 某子模块失败后停止后续执行 | ★★☆☆☆ | L6 VM |
| F-93 | secure | 全新执行 | 按顺序执行 12 个模块（基础+安全+通知全套），全部成功 | ★★☆☆☆ | L6 VM |
| F-94 | secure | 依赖自动解析 | 未装依赖模块自动先安装 | ★★☆☆☆ | L6 VM |

---

## 五、幂等性测试

### 5.1 L3-L5 自动化覆盖

| TC-ID 范围 | 测试目标 | 自动化等级 | 覆盖现有用例 |
|------------|---------|:---:|------|
| TC-P1-AUTO-003 | L6→L5 下沉：I-01~I-04 转为 BATS（状态文件 Mock + 二次执行验证） | ★★★★☆ | I-01~I-04 |

### 5.2 L6 VM 测试

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| I-01 | 全模块二次执行 | 所有已成功模块再执行一次 | 全部提示"已安装，跳过" | 🔄 TC-P1-AUTO-003 | Function Override (state_is_installed) |
| I-02 | 状态文件完整性 | 检查 `/var/lib/debnas/state/` | 每个成功模块有对应 .state 文件 | 🔄 TC-P1-AUTO-003 | 临时目录 Mock（TEMP-STATE-DIR） |
| I-03 | 失败状态不保存 | 模拟模块失败 | `/var/lib/debnas/state/` 无该模块的 success 状态 | 🔄 TC-P1-AUTO-003 | Function Override（模拟模块失败） |
| I-04 | 状态清除后重跑 | 删除某模块 state 文件后重跑 | 模块重新执行（不再跳过） | 🔄 TC-P1-AUTO-003 | 临时目录 Mock |

---

## 六、错误处理测试

### 6.1 L3-L5 自动化覆盖

| TC-ID 范围 | 测试目标 | 自动化等级 | 覆盖现有用例 |
|------------|---------|:---:|------|
| TC-P0-PERM-001~002 | 非 root 拒绝路径（require_root + main 硬退出 ERROR_PERMISSION） | ★★★★☆ | E-01 |
| TC-P1-ERR-001~011 | ERROR_* 常量触发路径、log_fatal/log_fatal_return 层级约束、set -e/pipefail 行为、网络失败模拟 | ★★★★☆ | E-02, E-04~E-05 |
| TC-P1-AUTO-002 | L6→L5 下沉：E-01~E-06 转为 BATS | ★★★★☆ | E-01~E-06 |

### 6.2 L6 VM 测试

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| E-01 | 非 root 执行 | 普通用户执行 `debnas run sources` | 报错提示需要 root 权限 | 🔄 TC-P0-PERM-001~002 | PATH Injection (MOCK-ID-ROOT) |
| E-02 | 网络断开 | 断网后执行需下载的模块 | 报错提示网络不可达 | 🔄 TC-P1-ERR-009~011 | PATH Injection (MOCK-CURL-FAIL) |
| E-03 | 磁盘空间不足 | `/tmp` 满时运行 | 报错提示空间不足 | ⚠️ L6 VM | 需真实磁盘填充，Mock 困难（df 可 Mock 但 write 行为难以精确模拟） |
| E-04 | 无 APT 源时安装依赖 | 最小化系统直接 `debnas run fail2ban` | 提示手动配置 APT 源 | 🔄 TC-P1-DEP-002~004 | Function Override (check_dependencies→fail) |
| E-05 | Ctrl+C 中断 | 模块执行中 Ctrl+C | 清理临时文件，状态不标记成功 | 🔄 TC-P1-REC-001~002 | 子 shell + kill -INT 信号注入 |
| E-06 | 依赖模块未安装 | 未装 Docker 时运行 docker-apps | 报错提示依赖缺失 | 🔄 TC-P0-REG-016 | Function Override (check_module_deps_ready→fail) |

---

## 七、日志与状态测试

### 7.1 L3-L5 自动化覆盖

日志格式验证（时间戳 `[YYYY-MM-DD HH:MM:SS]`、等级标签 `[INFO]/[WARNING]/[ERROR]/[FATAL]`）可通过静态 grep 在 L4 冒烟测试中完成。状态文件格式验证 (`last_result=success`) 同理。

### 7.2 L6 VM 测试

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| L-01 | 日志文件生成 | 执行模块后检查 `/var/log/debnas/` | 有对应 `.log` 文件 | ★★★☆☆ | 临时目录 Mock（TEMP-LOG-DIR） |
| L-02 | 日志时间戳 | 查看日志内容 | 每行含 `[YYYY-MM-DD HH:MM:SS]` | ★★★☆☆ | 临时目录 Mock |
| L-03 | 日志等级标签 | 执行任意模块并查看输出 | 包含 [INFO]/[WARNING]/[ERROR]/[FATAL] 等级标签 | ★★★☆☆ | 临时目录 Mock |
| L-04 | 状态文件格式 | 检查 `.state` 文件 | `last_result=success` 格式正确 | ★★★☆☆ | 临时目录 Mock |
| L-05 | doctor 读取状态 | doctor 输出 | 各模块安装状态正确显示 | ★★★☆☆ | 临时目录 Mock |

---

## 八、兼容性与边界测试

### 8.1 L3-L5 自动化覆盖

| TC-ID 范围 | 测试目标 | 自动化等级 | 覆盖现有用例 |
|------------|---------|:---:|------|
| TC-P1-BND-001~006 | 边界覆盖（timeout 行为、retry 逻辑、空依赖列表、缺失字段默认值） | ★★★★☆ | B-03, B-05~B-06 |
| TC-P2-BND-007~010 | 数值边界（菜单 off-by-one、CIDR 掩码 /32 /0 /33、内存 <1GB、磁盘 <10GB 阈值） | ★★★☆☆ | — |

### 8.2 L6 VM 测试

| 编号 | 测试项 | 操作步骤 | 预期结果 | 自动化等级 | Mock 方案 |
|:----:|--------|---------|---------|:---:|------|
| B-01 | Debian 12 | Debian 12 最小化安装完整测试 | 所有功能正常 | ★★☆☆☆ | L6 VM（需 Debian 12 VM） |
| B-02 | Debian 13 | Debian 13 最小化安装完整测试 | 所有功能正常 | ★★☆☆☆ | L6 VM |
| B-03 | 非 Debian 系统 | Ubuntu 上执行 | 报错提示不支持此系统 | 🔄 TC-P1-ERR-002 | Function Override (verify_debian_12_13_support→fail) |
| B-04 | 最小化安装 | 仅有 wget 的全新系统 | install.sh 正常工作，菜单正常启动 | ★★☆☆☆ | L6 VM |
| B-05 | 已有 Cockpit | 系统已安装 Cockpit 时执行 cockpit 模块 | 幂等跳过 | 🔄 TC-P1-BND-005~006 | Function Override (state_is_installed→true) |
| B-06 | 已有 Docker | 系统已安装 Docker 时执行 docker-ce | 幂等跳过 | 🔄 TC-P1-BND-005~006 | Function Override |
| B-07 | 中文环境 | LANG=zh_CN.UTF-8 执行 | 菜单/日志显示中文 | ★★★☆☆ | LANG 环境变量覆盖 |

---

## 九、新增自动化测试用例 — Phase 4-5 汇总

> 完整 9 字段自动化规格（前置条件、Mock 方案、执行步骤、预期结果等）见 [自动化测试用例文档](../docs/自动化测试用例文档.md)。以下为按批次的 3 字段摘要。
>
> **Phase 8-9 实施状态**：
> - **Phase 8**（2026-07-05）：实施 7 个模块的结构验证 + 纯函数测试 + Mock 功能测试
> - **Phase 9**（2026-07-12）：实施剩余全部 14 个计划文件 + 2 个扩展现有文件（105 新用例），Phase 4-5 设计的 165 个 TC-ID 全部覆盖。详见 [§17 Phase 8 实施成果](#十七phase-8-实施成果2026-07-05)。

### 批次 A：CLI 路由 + Preflight + 权限（P0，32 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P0-CLI-001 | `main()` 无子命令 → `cmd_menu`（exec 到 menu.sh） | ★★★★☆ |
| TC-P0-CLI-002 | `cmd_install` 缺少模块名 → 返回 1 + 列出模块 | ★★★★☆ |
| TC-P0-CLI-003 | `cmd_install` 有效模块 → exec 到 module-runner.sh | ★★★★☆ |
| TC-P0-CLI-004 | `cmd_config` 无参数 → 打印用法帮助 | ★★★★☆ |
| TC-P0-CLI-005 | `cmd_config list` → 列出 region/file_logging | ★★★★☆ |
| TC-P0-CLI-006 | `cmd_config write` → 设置 config key=value | ★★★★☆ |
| TC-P0-CLI-007 | `cmd_config --unset` → 删除 config key（幂等） | ★★★★☆ |
| TC-P0-CLI-008 | `cmd_update` 下载失败（主源+回退） → 返回 1 | ★★★★☆ |
| TC-P0-CLI-009 | `cmd_update` 解压失败 → 返回 1 | ★★★★☆ |
| TC-P0-CLI-010 | `cmd_uninstall` 非 FORCE_YES → 交互确认后执行 | ★★★★☆ |
| TC-P0-CLI-011 | `cmd_cron add` 缺少模块名 → 返回 1 | ★★★★☆ |
| TC-P0-CLI-012 | `cmd_cron remove` 缺少模块名 → 返回 1 | ★★★★☆ |
| TC-P0-CLI-013 | `cmd_cron` 未知子命令 → 返回 1 | ★★★★☆ |
| TC-P0-CLI-014 | `main()` 未知子命令 → 返回 1 + 打印用法 | ★★★★☆ |
| TC-P0-CLI-015 | `--cron` 重写：`debnas mymodule --cron` → `debnas run mymodule` | ★★★★☆ |
| TC-P0-CLI-016 | `main()` 有全局标志但无子命令 → 返回 1 + 错误 | ★★★★☆ |
| TC-P0-PRE-001 | `run_preflight`：dry-run 模式 → 跳过所有检查，返回 2 | ★★★★☆ |
| TC-P0-PRE-002 | `run_preflight`：非 root → `preflight_root` 拒绝，返回 1 | ★★★★☆ |
| TC-P0-PRE-003 | `run_preflight`：Debian 版本不匹配 → 返回 1 | ★★★★☆ |
| TC-P0-PRE-004 | `run_preflight`：架构不匹配 → 返回 1 | ★★★★☆ |
| TC-P0-PRE-005 | `run_preflight`：命令依赖缺失 → 返回 1 | ★★★★☆ |
| TC-P0-PRE-006 | `run_preflight`：模块依赖未就绪 → 返回 1 + 提示 | ★★★★☆ |
| TC-P0-PRE-007 | `run_preflight`：交互模块 → 跳过依赖检查，返回 0 | ★★★★☆ |
| TC-P0-PRE-008 | `run_preflight`：全部 5 阶段通过 → 返回 0 | ★★★★☆ |
| TC-P0-PRE-009 | `execute_module`：子进程 exit 0 → 返回 0 | ★★★★☆ |
| TC-P0-PRE-010 | `execute_module`：子进程 exit 非 0 → 传播退出码 | ★★★★☆ |
| TC-P0-PRE-011 | `run_report`：成功 → `state_mark_success` + SUCCESS 输出 | ★★★★☆ |
| TC-P0-PRE-012 | `run_report`：失败 → `state_mark_fail` + ERROR + 日志路径 | ★★★★☆ |
| TC-P0-PRE-013 | `main()`：模块未找到 → 列出模块 + 返回 1 | ★★★★☆ |
| TC-P0-PRE-014 | `main()`：完整链路 preflight → execute → report（E2E） | ★★★☆☆ |
| TC-P0-PERM-001 | `require_root()`：非 root → `ERROR_PERMISSION` (4) + 错误日志 | ★★★★☆ |
| TC-P0-PERM-002 | `main()`：非 root → `exit ERROR_PERMISSION`（硬退出） | ★★★★☆ |

### 批次 B：Module Registry + URLs + Installer Mock（P0，27 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P0-REG-001 | `discover_modules`：正常发现（单文件 + 目录模块） | ★★★☆☆ |
| TC-P0-REG-002 | `discover_modules`：空模块目录 → 无错误，空列表 | ★★★☆☆ |
| TC-P0-REG-003 | `discover_modules`：模块目录缺失 → 返回 1 | ★★★☆☆ |
| TC-P0-REG-004 | `resolve_module_deps`：无依赖模块 → 仅自身 | ★★★★☆ |
| TC-P0-REG-005 | `resolve_module_deps`：线性链 A→B→C → C B A 顺序 | ★★★★☆ |
| TC-P0-REG-006 | `resolve_module_deps`：钻石依赖 (A→C, B→C) → C 只出现一次 | ★★★★☆ |
| TC-P0-REG-007 | `resolve_module_deps`：直接循环 A→B→A → 检测 + 返回 1 | ★★★★☆ |
| TC-P0-REG-008 | `resolve_module_deps`：间接循环 A→B→C→A → 检测 + 返回 1 | ★★★★☆ |
| TC-P0-REG-009 | `resolve_module_deps`：自依赖 A→A → 检测为循环 | ★★★★☆ |
| TC-P0-REG-010 | `parse_module_metadata`：文件未找到 → 返回 1 | ★★★☆☆ |
| TC-P0-REG-011 | `parse_module_metadata`：30 行窗口边界（第 30 行有效，第 31 行忽略） | ★★★☆☆ |
| TC-P0-REG-012 | `_parse_single_file`：缺少 `@module` 标签 → 警告但继续 | ★★★☆☆ |
| TC-P0-REG-013 | `get_modules_by_category`：指定分类 → 过滤 + 按 order 排序 | ★★★☆☆ |
| TC-P0-REG-014 | `get_modules_by_category`：无参数 → 全部分类按 CATEGORY_ORDER | ★★★☆☆ |
| TC-P0-REG-015 | `check_module_deps_ready`：全部依赖就绪 → 返回 0 | ★★★★☆ |
| TC-P0-REG-016 | `check_module_deps_ready`：任一依赖未就绪 → 返回 1 + 列出名称 | ★★★★☆ |
| TC-P0-URL-001 | `probe_url`：curl 可达 → 返回 0 | ★★★★☆ |
| TC-P0-URL-002 | `probe_url`：curl 不可达 → 返回 1 | ★★★★☆ |
| TC-P0-URL-003 | `probe_url`：curl 缺失 → 回退到 wget | ★★★★☆ |
| TC-P0-URL-004 | `probe_url`：curl 和 wget 均缺失 → 返回 1 | ★★★★☆ |
| TC-P0-URL-005 | `get_mirror_name`：已知 URL → 中文名称 | ★★★★★ |
| TC-P0-URL-006 | `get_mirror_name`：未知 URL → 返回原始 URL | ★★★★★ |
| TC-P0-URL-007 | `get_github_proxy_endpoints`：返回 3 个代理地址 | ★★★★★ |
| TC-P0-URL-008 | `get_docker_registry_mirrors`：返回 3 个镜像地址 | ★★★★★ |
| TC-P0-MOCK-001 | `installer_download`：wget Mock 成功 → tarball 存在 | ★★★★☆ |
| TC-P0-MOCK-002 | `installer_download`：主源失败 + 回退成功 → 返回 0 | ★★★★☆ |
| TC-P0-MOCK-003 | `installer_download`：双源均失败 → 返回 1 | ★★★★☆ |

### 批次 C：菜单系统 + UI + 交互模块（P1，19 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P1-MENU-001 | `auto_menu_loop`：输入 0 → exit 0 | ★★★★☆ |
| TC-P1-MENU-002 | `auto_menu_loop`：非数字输入 → 重试循环 | ★★★★☆ |
| TC-P1-MENU-003 | `auto_menu_loop`：超出范围数字 → 重试循环 | ★★★★☆ |
| TC-P1-MENU-004 | `auto_menu_loop`：EOF/CTRL-D → 优雅退出 | ★★★★☆ |
| TC-P1-MENU-005 | `build_active_categories`：空分类被过滤 | ★★★★☆ |
| TC-P1-MENU-006 | `build_active_categories`：部署分类仅在有方案时出现 | ★★★★☆ |
| TC-P1-UI-001 | `get_user_choice`：有效输入 1 → 输出 1，返回 0 | ★★★★★ |
| TC-P1-UI-002 | `get_user_choice`：选择 0 → 输出 0，返回 0 | ★★★★★ |
| TC-P1-UI-003 | `get_user_choice`：EOF/CTRL-D → 输出 0，返回 0 | ★★★★★ |
| TC-P1-UI-004 | `get_user_choice`：负数输入 → 返回 1 | ★★★★★ |
| TC-P1-UI-005 | `get_user_choice`：超大数字 → 返回 1 | ★★★★★ |
| TC-P1-UI-006 | `get_user_choice`：空输入（Enter） → 返回 1 | ★★★★★ |
| TC-P1-UI-007 | `get_user_choice`：非数字（字母/符号） → 返回 1 | ★★★★★ |
| TC-P1-UI-008 | `run_submenu`：选择 0 → 退出子菜单，返回 0 | ★★★★★ |
| TC-P1-UI-009 | `run_submenu`：有效选择 → 分发到回调（索引偏移验证） | ★★★★★ |
| TC-P1-UI-010 | `run_submenu`：回调失败 → 不退出子菜单 | ★★★★★ |
| TC-P1-IMOD-001 | `mail-account`：管道 SMTP 凭据 → 正确写入配置 | ★★★☆☆ |
| TC-P1-IMOD-002 | `acl-manager`：管道完整菜单序列 → 执行 ACL 操作 | ★★★☆☆ |
| TC-P1-IMOD-003 | `bbr`：参数模式 (`debnas --yes run bbr 2`) → 永久启用 | ★★★☆☆ |

### 批次 D：依赖体系 + 配置优先级 + Shell 关联数组（P1，15 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P1-DEP-001 | `check_dependencies_by_level`：Tier 0 全部存在 → 返回 0 | ★★★★☆ |
| TC-P1-DEP-002 | `check_dependencies_by_level`：Tier 0 缺失 → 返回 1（致命） | ★★★★☆ |
| TC-P1-DEP-003 | `check_dependencies_by_level`：Tier 1 工具 → 触发自动安装 | ★★★★☆ |
| TC-P1-DEP-004 | `check_dependencies_by_level`：Tier 2 服务缺失 → 返回 1 + 提示 | ★★★★☆ |
| TC-P1-DEP-005 | `ensure_module_deps`：组合 cmd + 模块依赖检查 → 全部通过 | ★★★★☆ |
| TC-P1-DEP-006 | `ensure_command`：Tier 2 服务 → 拒绝自动安装，返回 1 | ★★★★☆ |
| TC-P1-CFG-001 | `parse_global_args`：CLI `--region global` 覆盖 env `DEBNAS_REGION=cn` | ★★★★☆ |
| TC-P1-CFG-002 | `parse_global_args`：env 变量覆盖 config 文件值 | ★★★★☆ |
| TC-P1-CFG-003 | `parse_global_args`：config 文件缺失 → 回退到默认值 | ★★★★☆ |
| TC-P1-CFG-004 | `parse_global_args`：`--cron` 标志设置 `DEBNAS_CRON_MODE=1` | ★★★★☆ |
| TC-P1-CFG-005 | `parse_global_args`：非法 `--region` 值 → 返回 1 | ★★★★☆ |
| TC-P1-SH-001 | `get_dependency_level`：未注册 cmd → 默认 "tool" | ★★★★★ |
| TC-P1-SH-002 | `get_dependency_level`：cmd_to_pkg 存在但 cmd_to_level 缺失 → 从 pkg 推断 | ★★★★★ |
| TC-P1-SH-003 | `parse_global_args` grep vs `config_read_global` → 行为一致 | ★★★★☆ |

### 批次 E：Mock 反模式修复 + 安装部署 + APT Pinning（P1+P2，22 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P1-MOCKFIX-001 | docker-ce：source 真实 `extract_mirror_from_sources` 替代内联 awk | ★★★☆☆ |
| TC-P1-MOCKFIX-002 | docker-ce：source 真实 `is_official_debian_source` 替代内联 regex | ★★★☆☆ |
| TC-P1-MOCKFIX-003 | solution：source 真实 `execute_solution`（bin/menu.sh）替代重定义 | ★★★☆☆ |
| TC-P1-MOCKFIX-004 | 提取共享 crontab Mock 到 `tests/helpers/mock-crontab.bash` | ★★★☆☆ |
| TC-P1-INST-001 | `installer_get_url`：region=cn → Gitee URL | ★★★★★ |
| TC-P1-INST-002 | `installer_get_url`：region=global → GitHub URL | ★★★★★ |
| TC-P1-INST-003 | `installer_extract`：正常 tar.gz → strip-components=1 解压 | ★★★★☆ |
| TC-P1-INST-004 | `installer_deploy`：bin/debnas 部署后缺失 → 返回 1 | ★★★★☆ |
| TC-P1-INST-005 | `installer_deploy`：完整 download→extract→deploy E2E 链 | ★★★☆☆ |
| TC-P2-MIG-001 | `migration_run`：首次安装（无版本文件） → 保存版本，返回 0 | ★★★☆☆ |
| TC-P2-MIG-002 | `migration_run`：版本未变 → 跳过，返回 0 | ★★★☆☆ |
| TC-P2-MIG-003 | `migration_run`：版本变更 → 动态分发 `_migrate_<version>` | ★★★☆☆ |
| TC-P2-MIG-004 | `migration_check_compatibility`：config 文件缺失 → 返回 1 | ★★★☆☆ |
| TC-P2-PIN-001 | `write_pinning_file`：正确创建 APT preferences 文件 | ★★★☆☆ |
| TC-P2-PIN-002 | `check_pinning_status`：文件存在/不存在 → 正确判断 | ★★★☆☆ |
| TC-P2-PIN-003 | `cleanup_pinning_config`：删除 pinning 文件 + 幂等 | ★★★☆☆ |
| TC-P2-ATOM-001 | `config_write`：磁盘满时 tmp 写入 → 保留原始文件 | ★★★☆☆ |
| TC-P2-ATOM-002 | `config_write`：mv 失败（权限） → 保留原始文件 + 无 .tmp 残留 | ★★★☆☆ |

> 注：TC-P0-MOCK-001~003 已在上方 [批次 B](#批次-bmodule-registry--urls--installer-mockp027-用例) 中列出。

### 批次 F：异常/错误 + 权限/安全（P1+P2，20 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P1-ERR-001 | `ERROR_PERMISSION` (4)：由 `require_root` 非 root 触发 | ★★★★☆ |
| TC-P1-ERR-002 | `ERROR_UNSUPPORTED_OS` (6)：由 `verify_debian_12_13_support` 触发 | ★★★★☆ |
| TC-P1-ERR-003 | `ERROR_DEPENDENCY` (2)：由 `check_system_deps` 缺失 cmd 触发 | ★★★★☆ |
| TC-P1-ERR-004 | `log_fatal` 在子 shell 中：仅退出子 shell，不终止测试进程 | ★★★★☆ |
| TC-P1-ERR-005 | `log_fatal_return`：返回 1，不退出进程 | ★★★★☆ |
| TC-P1-ERR-006 | `write_file_if_changed` 在 `set -e` 下返回 1 → 验证所有 11 个调用点 | ★★★☆☆ |
| TC-P1-ERR-007 | `((var++))` 0→1 退出码 1 陷阱 → 验证回归修复 | ★★★☆☆ |
| TC-P1-ERR-008 | pipefail：中间管道命令失败 → 退出码传播 | ★★★☆☆ |
| TC-P1-ERR-009 | curl 连接超时 → 非零退出 → 调用方正确处理 | ★★★★☆ |
| TC-P1-ERR-010 | curl DNS 解析失败 → 非零退出 → 调用方正确处理 | ★★★★☆ |
| TC-P1-ERR-011 | HTTP 404 → 识别为不可达（curl `-f` 标志） | ★★★★☆ |
| TC-P1-SEC-001 | `configure_su_restrictions`：幂等添加 `pam_wheel.so` | ★★★☆☆ |
| TC-P1-SEC-002 | `configure_su_restrictions`：损坏的 PAM 文件 → 报错，不写入 | ★★★☆☆ |
| TC-P1-ACL-001 | ACL set：`setfacl -m` 使用正确的用户/权限参数 | ★★★☆☆ |
| TC-P1-ACL-002 | ACL recursive：`-R` 标志确认 → 执行 | ★★★☆☆ |
| TC-P1-ACL-003 | ACL delete：`setfacl -x`（非 -m） | ★★★☆☆ |
| TC-P1-SVC-001 | `service_ensure firewalld enabled`：firewall 模块调用路径 | ★★★★☆ |
| TC-P1-SVC-002 | `service_ensure docker enabled + started`：组合调用序列 | ★★★★☆ |
| TC-P2-CHMOD-001 | `security.sh`：`chmod 1733` 特殊模式（sticky+setgid） | ★★★☆☆ |
| TC-P2-CHMOD-002 | `mail-account.sh`：`chown root:Debian-exim` | ★★★☆☆ |

### 批次 G：恢复/清理 + Shell 特性（P1+P2，8 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P1-REC-001 | Ctrl+C 执行中 → `state_mark_success` 未被调用 | ★★★★☆ |
| TC-P1-REC-002 | Ctrl+C 执行中 → 临时文件通过 trap 清理 | ★★★★☆ |
| TC-P1-REC-003 | install.sh：下载 OK + 解压失败 → 通过 EXIT trap 清理 tarball | ★★★☆☆ |
| TC-P1-REC-004 | install.sh：部署时磁盘满 → 部分清理 + EXIT trap | ★★★☆☆ |
| TC-P2-REC-005 | `apt_wait_for_lock` 超时 → 调用方 (`apt_update_safe`) 正确处理 | ★★★☆☆ |
| TC-P2-SH-003 | 进程替换：子命令失败 → 父进程检测（非静默跳过） | ★★★☆☆ |
| TC-P2-SH-004 | IFS 临时修改：手动赋值形式 → 验证恢复 | ★★★☆☆ |
| TC-P2-SH-005 | `print_colored`：不存在颜色的间接变量引用 → 静默回退 | ★★★★★ |

### 批次 H：边界覆盖 + 模块扩展（P1+P2，15 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P1-BND-001 | curl `--max-time 5` 超时 → 进程终止（非挂起） | ★★★★☆ |
| TC-P1-BND-002 | wget `--timeout=30` 超时 → 返回非零 | ★★★★☆ |
| TC-P1-BND-003 | docker-ce GPG 下载：重试 1 失败，重试 2 成功 → 在第 2 次停止 | ★★★★☆ |
| TC-P1-BND-004 | docker-ce GPG 下载：全部 3 次重试失败 → 返回错误 | ★★★★☆ |
| TC-P1-BND-005 | `preflight_dependencies`：空依赖列表 → 返回 0 | ★★★★☆ |
| TC-P1-BND-006 | `get_module_field`：不存在的字段 → 返回默认值 | ★★★★☆ |
| TC-P2-BND-007 | 菜单输入边界：choice=0 和 choice=max 通过范围检查 | ★★★★★ |
| TC-P2-BND-008 | CIDR 掩码边界：/32 合法，/33 拒绝，/0 合法 | ★★★★☆ |
| TC-P2-BND-009 | sys-check：内存 < 1GB → 触发警告（1023 vs 1025） | ★★★★☆ |
| TC-P2-BND-010 | sys-check：磁盘 < 10GB → 触发警告（9GB vs 11GB） | ★★★★☆ |
| TC-P1-MOD-005 | sys-check：功能测试 → 诊断输出包含预期字段 | ★★★☆☆ |
| TC-P1-MOD-006 | service-query：功能测试 → 列出服务和容器 | ★★★☆☆ |
| TC-P1-MOD-007 | hosts-sync：功能测试 → DNS 解析 + hosts 文件写入 | ★★★☆☆ |
| TC-P2-MOD-008 | threat-ips：`parse_ip_entries`（awk 批量解析）样例列表单元测试 | ★★★★★ |
| TC-P2-MOD-009 | docker-ce：`download_docker_gpg_key` 重试循环功能验证 | ★★★★☆ |

### 批次 I：自动化改进 + UI（P1+P2，5 用例）

| TC-ID | 测试目标 | 自动化等级 |
|--------|---------|:---:|
| TC-P1-AUTO-001 | L6→L5：CLI C-01~C-08 下沉为 BATS（~8 用例） | ★★★★☆ |
| TC-P1-AUTO-002 | L6→L5：Error E-01~E-06 下沉为 BATS（~5 用例） | ★★★★☆ |
| TC-P1-AUTO-003 | L6→L5：Idempotency I-01~I-04 下沉为 BATS（~4 用例） | ★★★★☆ |
| TC-P1-AUTO-004 | check.sh：分层独立执行 + 报告（L1-L5 分别展示） | ★★★★☆ |
| TC-P2-UI-001 | styles.sh：`NO_COLOR=1` → 输出无 ANSI 转义码 | ★★★★★ |

### 批次汇总统计

| 批次 | 优先级 | TC 数 | 主要覆盖集群 | ★★★★★ | ★★★★☆ | ★★★☆☆ | Phase 9 状态 |
|------|:---:|:---:|------|:---:|:---:|:---:|------|
| A | P0 | 32 | CLI + Preflight + 权限 | 0 | 28 | 4 | ✅ 已实施 |
| B | P0 | 27 | Registry + URLs + Installer | 4 | 11 | 12 | ✅ 已实施 |
| C | P1 | 19 | 菜单 + UI + 交互模块 | 11 | 5 | 3 | ✅ 已实施 |
| D | P1 | 15 | 依赖 + 配置 + Shell | 2 | 11 | 2 | ✅ 已实施 |
| E | P1+P2 | 18 | Mock 修复 + 安装 + Pinning | 2 | 2 | 14 | ✅ 已实施 |
| F | P1+P2 | 20 | 错误 + 权限 + 安全 | 0 | 11 | 9 | ✅ 已实施 |
| G | P1+P2 | 8 | 恢复 + Shell 特性 | 1 | 2 | 5 | ✅ 已实施 |
| H | P1+P2 | 19 | 边界 + 模块扩展 | 2 | 10 | 7 | ✅ 已实施 |
| I | P1+P2 | 5 | L6→L5 + UI | 4 | 1 | 0 | ✅ 已实施 |
| **合计** | | **165** | | **26** | **83** | **56** | ✅ 全部完成 |

> 完整 9 字段自动化规格（前置条件、Mock 方案、执行步骤、预期结果、预期日志、清理步骤、自动化方案详述、CI 友好）见 [自动化测试用例文档](../docs/自动化测试用例文档.md) §3-§11。

---

## 十、Mock 策略速查

从 [自动化测试用例文档 §2.2 + §A](../docs/自动化测试用例文档.md) 浓缩。

### 10.1 PATH Injection 模板

| 模板 ID | Mock 命令 | 行为 | 典型用途 |
|---------|----------|------|---------|
| MOCK-ID-ROOT | `id -u` | 返回 1000（非 root） | 权限拒绝测试 |
| MOCK-ID-ROOT-PASS | `id -u` | 返回 0（root） | 权限通过测试 |
| MOCK-CURL-OK | `curl` | 静默成功 | 网络可达模拟 |
| MOCK-CURL-FAIL | `curl` | 连接错误 → stderr，exit 7 | 网络不可达模拟 |
| MOCK-WGET-OK | `wget` | 静默成功 | 下载成功模拟 |
| MOCK-WGET-FAIL | `wget` | 网络失败 → stderr，exit 4 | 下载失败模拟 |
| MOCK-WGET-STAGED | `wget` | 第 1 次失败 (exit 1)，第 2 次成功 | 重试逻辑测试 |
| MOCK-CRONTAB | `crontab` | 状态文件式：支持 `-l`/`-`/`-r` | cron 注册测试 |
| MOCK-FREE-1023 | `free -m` | 返回 total=1023MB（<1GB 阈值） | 内存警告测试 |
| MOCK-FREE-2048 | `free -m` | 返回 total=2048MB（正常） | 内存正常测试 |
| MOCK-DISK-LOW | `df` | 返回 95% 磁盘使用率 | 磁盘警告测试 |

### 10.2 Function Override 模板

| 模板 ID | 覆盖函数 | 行为 |
|---------|---------|------|
| OVERRIDE-REQUIRE-ROOT | `require_root()` | 返回 0（绕过 root 检查） |
| OVERRIDE-VERIFY-DEBIAN-FAIL | `verify_debian_12_13_support()` | 返回 1（版本检查失败） |
| OVERRIDE-VERIFY-DEBIAN-PASS | `verify_debian_12_13_support()` | 返回 0（版本检查通过） |
| OVERRIDE-STATE-INSTALLED | `state_is_installed()` | 根据 `MOCK_INSTALLED_MODULE` 变量返回 0/1 |
| OVERRIDE-DISCOVER-MODULES | `discover_modules()` | No-op，返回 0 |
| OVERRIDE-INSTALLER-DOWNLOAD-FAIL | `installer_download()` | "Mock: download failed" → stderr，返回 1 |

### 10.3 其他 Mock 模式

| 模式 | 方法 | 典型用途 |
|------|------|---------|
| **临时目录隔离** | `mktemp -d` + 重定向 `DEBNAS_CONF_DIR`/`DEBNAS_STATE_DIR`/`DEBNAS_MODULES_DIR`/`DEBNAS_LOG_DIR` | 配置文件、状态文件、模块目录、日志目录的隔离测试 |
| **stdin 注入** | `echo "1" \| func`（单行）、`printf '1\n0\n' \| script`（多行菜单）、`true \| func`（EOF 模拟） | 交互式输入测试 |
| **子 shell 隔离** | `(main ...); echo "EXIT:$?"` | exec/exit 测试（避免终止 BATS 进程） |
| **全局状态注入** | 直接设置 `_MODULE_REGISTRY`、`_DISCOVERED_MODULES` 数组 | 模块注册表测试 |
| **Here Document** | `cat > $dir/stub.sh << 'EOF' ... EOF` | 创建 stub 模块/脚本 |
| **环境变量覆盖** | `DEBNAS_REGION=cn`、`NO_COLOR=1` | 配置优先级、UI 样式测试 |

> ⚠️ **关键约束**：`DEBNAS_MODULES_DIR` 和 `DEBNAS_STATE_DIR` 为 `readonly`，必须在 `source` 对应脚本**之前**通过 `export` 设置，否则测试失败。

---

## 十一、Legacy ID ↔ TC-ID 映射表

| Legacy ID | 用例名称 | 对应 TC-ID | 自动化等级 | 状态 |
|-----------|---------|-----------|:---:|:---:|
| A-03 | --help 参数 | TC-P1-INST-001~005 | ★★★★☆ | 🔄 可自动化 |
| A-09 | SHA256 校验通过 | TC-P0-MOCK-001 | ★★★★☆ | 🔄 已设计 |
| A-10 | SHA256 校验失败 | TC-P0-MOCK-003 | ★★★★☆ | 🔄 已设计 |
| C-01 | 版本号 | TC-P1-AUTO-001 | ★★★★☆ | 🔄 可下沉 |
| C-02 | 帮助信息 | TC-P1-AUTO-001 | ★★★★☆ | 🔄 可下沉 |
| C-03 | 无参数启动菜单 | TC-P0-CLI-001 | ★★★★☆ | 🔄 已设计 |
| C-04 | 未知子命令 | TC-P0-CLI-014 | ★★★★☆ | 🔄 已设计 |
| C-05 | --dry-run 模式 | TC-P0-PRE-001 | ★★★★☆ | 🔄 已设计 |
| C-06 | --yes 模式 | TC-P1-CFG-004 | ★★★★☆ | 🔄 已设计 |
| C-07 | --region 指定 | TC-P1-CFG-001~002 | ★★★★☆ | 🔄 已设计 |
| C-08 | --cron 模式 | TC-P0-CLI-015 | ★★★★☆ | 🔄 已设计 |
| C-11 | 不存在的模块 | TC-P0-PRE-013 | ★★★★☆ | 🔄 已设计 |
| C-12 | run 无参数报错 | TC-P0-CLI-002 | ★★★★☆ | 🔄 已设计 |
| C-13 | 幂等性 | TC-P1-AUTO-003 | ★★★★☆ | 🔄 可下沉 |
| C-14 | 失败后重试 | TC-P1-AUTO-003 | ★★★★☆ | 🔄 可下沉 |
| C-15~C-18 | config 子命令 | — | ★★★★☆ | 可自动化（临时目录 Mock） |
| C-19~C-21 | doctor 子命令 | — | ★★★☆☆ | 可自动化（PATH Injection + 临时目录） |
| C-22~C-28 | cron 子命令 | TC-P0-CLI-011~013 | ★★★★☆ | 🔄 已设计 |
| C-27 | cron 无参数 | TC-P0-CLI-013 | ★★★★☆ | 🔄 已设计 |
| E-01 | 非 root 拒绝 | TC-P0-PERM-001~002 | ★★★★☆ | 🔄 已设计 |
| E-02 | 网络断开 | TC-P1-ERR-009~011 | ★★★★☆ | 🔄 已设计 |
| E-03 | 磁盘空间不足 | — | ⚠️ L6 | Mock 困难，保留 VM |
| E-04 | 无 APT 源 | TC-P1-DEP-002~004 | ★★★★☆ | 🔄 已设计 |
| E-05 | Ctrl+C 中断 | TC-P1-REC-001~002 | ★★★★☆ | 🔄 已设计 |
| E-06 | 依赖未安装 | TC-P0-REG-016 | ★★★★☆ | 🔄 已设计 |
| I-01~I-04 | 幂等性 | TC-P1-AUTO-003 | ★★★★☆ | 🔄 可下沉 |
| L-01~L-05 | 日志与状态 | — | ★★★☆☆ | 可自动化（临时目录 Mock） |
| B-03 | 非 Debian 系统 | TC-P1-ERR-002 | ★★★★☆ | 🔄 已设计 |
| B-05~B-06 | 已有软件幂等 | TC-P1-BND-005~006 | ★★★★☆ | 🔄 已设计 |
| M-01~M-04 | 主菜单基础交互 | TC-P1-MENU-001~006 + TC-P1-UI-001~010 | ★★★★☆ | 🔄 已设计 |
| M-51 | 邮件账户配置 | TC-P1-IMOD-001 | ★★★☆☆ | 🔄 已设计 |
| M-67 | ACL 权限管理 | TC-P1-IMOD-002 | ★★★☆☆ | 🔄 已设计 |
| M-68 | 配置 BBR 加速 | TC-P1-IMOD-003 | ★★★☆☆ | 🔄 已设计 |
| F-30~F-31 | 安全配置 | TC-P1-SEC-001~002 | ★★★☆☆ | 🔄 已设计 |
| F-37 | threat-ips 菜单 | —（人工） | ★★★☆☆ | 🔄 已设计 |
| F-39 | threat-ips ipset | TC-P2-MOD-008~009 | ★★★★★ | 🔄 已设计 |
| F-54 | Docker 未安装报错 | TC-P0-REG-016 | ★★★★☆ | 🔄 已设计 |
| F-60 | 邮件配置 | TC-P1-IMOD-001 | ★★★☆☆ | 🔄 已设计 |
| F-70~F-72 | sys-check | TC-P1-MOD-005 | ★★★☆☆ | 🔄 已设计 |
| F-76 | service-query | TC-P1-MOD-006 | ★★★☆☆ | 🔄 已设计 |
| F-77~F-79a | hosts-sync | TC-P1-MOD-007 | ★★★☆☆ | 🔄 已设计 |
| F-81~F-82 | acl-manager | TC-P1-IMOD-002 | ★★★☆☆ | 🔄 已设计 |
| F-83~F-85 | bbr | TC-P1-IMOD-003 | ★★★☆☆ | 🔄 已设计 |

> **注意**：A-01~A-02, A-04~A-08, A-11~A-13, C-09~C-10, C-29~C-32, M-10~M-73（大部分）, F-01~F-94（大部分）, B-01~B-02, B-04, B-07 为需要真实系统环境（网络/apt/systemd/多版本 VM）的 L6 用例，暂无直接对应的自动化 TC-ID。它们应在 L6 VM 上继续执行，不作为自动化下沉目标。

---

## 十二、已弃用/低价值测试

### 12.1 建议删除（4 项 — Phase 8 已全部完成）

| 编号 | 位置 | 测试项 | 弃用理由 | Phase 8 修复 | 状态 |
|------|------|--------|---------|-------------|:----:|
| — | test-sources.bats | `bash -n` 语法检查 | L1 门禁已全局覆盖所有 .sh 文件，集成测试中重复执行无增量价值 | 已移除，添加注释说明 L1 全局覆盖 | ✅ 已修复 |
| — | test-firewall.bats | `bash -n` 语法检查 | 同上 | 已移除，添加注释说明 L1 全局覆盖 | ✅ 已修复 |
| — | test-docker-ce.bats | `bash -n` 语法检查 | 同上 | 已移除，添加注释说明 L1 全局覆盖 | ✅ 已修复 |
| — | test-cron-mode.bats | `bash -n` 语法检查 | 同上（module.sh 由 L1 覆盖；子脚本 check.sh/cron.sh/notify.sh 的 bash -n 保留在测试中） | 仅移除 module.sh 的重复 bash -n，子脚本检查保留 | ✅ 已修复 |

### 12.2 低价值（6 项 — 1 项已改进，4 项待合并，1 项维持）

| 编号 | 位置 | 测试项 | 理由 | Phase 8 状态 |
|------|------|--------|------|:----------:|
| — | test-logging.bats | 原 9 个用例覆盖 8 个函数 | 日志函数测试粒度不足（`log_status`/`_log_to_file`/`log_action`/`log_to_file` 回退路径未覆盖） | ✅ 已扩展至 14 用例（Phase 8：+5 测试） |
| — | test-constants.bats | 多个独立 `ERROR_*` 值断言 | 建议合并为 1 个循环遍历 `${!ERROR_*}` | 📋 待合并（P3，低优先级） |
| — | test-args.bats | 多个独立 `parse_global_args` 标志测试 | 建议合并为 3 个参数化测试（布尔/值/剩余参数） | 📋 待合并（P3，低优先级） |
| — | test-service.bats | 多个独立 `service_ensure` 幂等测试 | 建议合并为 2 个（需要操作/已满足） | 📋 待合并（P3，低优先级） |
| — | test-apt.bats/test-tempfile.bats | 相同 guard clause 模式测试了 2 次 | `apt_install_safe`/`apt_remove_safe`/`create_temp_file`/`create_temp_dir` 的相同 "缺少参数" 模式重复 | 📋 待合并（P3，低优先级） |
| — | test-dependency.bats | `cmd_to_pkg[grep]="grep"` 断言 | 测试静态数据映射表而非函数行为 | 维持（暂无更好替代方案） |

### 12.3 需重构 — 已知反模式（3 项 — Phase 8 已全部修复）

| 编号 | 文件 | 问题 | 严重程度 | 修复 TC-ID | Phase 8 修复详情 | 状态 |
|------|------|------|:---:|-----------|-----------------|:----:|
| — | test-docker-ce.bats | 内联复制 `extract_mirror_from_sources()` 和 `is_official_debian_source()` 的 awk 逻辑（6 个用例），源码变更时测试不同步更新 → **假阳性** | 🔴 高 | TC-P1-MOCKFIX-001~002 | 移除内联 awk，改为 source 真实函数结构验证（grep 源码中的函数签名和关键代码模式如 `URIs`/`sub(`/`-f`/`deb.*debian.*org`） | ✅ 已修复 |
| — | test-solution.bats | `execute_solution()` 完全重定义（18 行 stub），真实 `bin/menu.sh` 的 fd 3 隔离、module-runner.sh 子进程调用、失败中止逻辑从未被测 → **假阳性** | 🔴 高 | TC-P1-MOCKFIX-003 | 保留 stub 用于受控测试 + 新增真实 bin/menu.sh 函数结构验证（fd 3 隔离 `3<`、module-runner.sh 调用、`break` 中止逻辑、注释/空行过滤） | ✅ 已修复 |
| — | test-cron.bats + test-cron-mode.bats | crontab Mock 逻辑独立实现两次（状态文件读写模式完全一致），修改需双端同步 | 🟡 中 | TC-P1-MOCKFIX-004 | 提取共享 `setup_crontab_mock()`/`teardown_crontab_mock()` 到 `tests/helpers/common-setup.bash`，双端统一引用 | ✅ 已修复 |

> ✅ 全部 3 项反模式已于 Phase 8 修复。验证：L3 354 tests PASS + L5 108 tests PASS。

### 12.4 死代码警告（13 函数 + 2 常量）

以下函数/常量有 BATS 单元测试但**从未被生产代码调用**。测试所覆盖的是永不执行的代码路径：

| 层级 | 符号 | 类型 | BATS 测试 |
|------|------|------|:---:|
| config | `config_write()` | 函数 | ✅ test-config.bats |
| config | `config_delete()` | 函数 | ✅ test-config.bats |
| config | `config_validate()` | 函数 | ✅ test-config.bats |
| config | `config_read_global()` | 函数 | ✅ test-config.bats |
| config | `config_write_global()` | 函数 | ✅ test-config.bats |
| state | `state_is_configured()` | 函数 | ✅ test-state.bats |
| state | `state_clear()` | 函数 | ✅ test-state.bats |
| state | `state_mark_checkpoint()` | 函数 | ✅ test-state.bats |
| state | `state_get_checkpoint()` | 函数 | ✅ test-state.bats |
| menu | `get_user_multiple_choice()` | 函数 | ❌ 无测试 |
| menu | `show_confirm()` | 函数 | ❌ 无测试 |
| menu | `show_menu_with_description()` | 函数 | ❌ 无测试 |
| constants | `ERROR_CONFIG=3` | 常量 | ✅ test-constants.bats |
| constants | `ERROR_PARAMETER=5` | 常量 | ✅ test-constants.bats |

> 💀 **建议**：在后续架构清理阶段决定这些符号的去留——要么集成到模块工作流中使其"复活"，要么删除以减小维护面。Phase 8 未涉及死代码清理。

---

## 十三、AI 自动化执行指南

AI 拥有测试 VM 的完全操作权限（SSH 信息见本文"测试环境"章节），应尽可能自主完成全部测试，包括 VM 上的部署、执行和验证。

### 第 0 阶段：L1-L5 开发机自动化门禁（新增）

**每次代码修改后必须在开发机上首先执行**（具体命令参见 [TESTING_GUIDE.md](../docs/TESTING_GUIDE.md) §八）：

```bash
# 一键完整质量门禁（推荐：L1 语法 + L2 ShellCheck + L3 单元 + L4 冒烟 + L5 集成）
bash tests/check.sh

# 逐层单独执行：
bash tests/run.sh unit          # L3 单元测试（65 文件，1628 用例）
bash tests/run.sh integration   # L5 集成测试（15 文件，258 用例）
bash tests/run.sh all           # L1-L5 全部
```

| 层级 | 工具 | 验证内容 | 文件数 | 用例数 |
|------|------|---------|:---:|:---:|
| L1 语法检查 | `bash -n` | 全部 .sh 文件语法正确 | 80+ | — |
| L2 静态分析 | ShellCheck | error 级别问题 | 4 目录 | — |
| L3 单元测试 | BATS | 库函数逻辑 + 模块结构/纯函数/Mock | 19 | 354 |
| L4 冒烟测试 | grep/awk | 模块元数据完整性 + 依赖引用有效性 | 24 | 2 检查 |
| L5 集成测试 | BATS | 模块结构验证 + Mock 功能测试 + 依赖链检查 | 6 | 108 |

### 第 1-4 层自动化测试（现有，整合）

以下用例可直接在开发机上自动化（已纳入 L1-L5 门禁）：

| 来源编号 | 测试项 | 自动化方式 |
|----------|--------|-----------|
| C-04 | 未知子命令报错 | 运行 `bin/debnas --invalid`，断言退出码非 0 |
| C-11 | 不存在的模块报错 | 运行 `debnas run nonexistent`，断言报错输出 |
| C-12 | run 无参数报错 | 运行 `debnas run`（无参数），断言退出码非 0 |
| C-27 | cron 无参数报错 | 运行 `debnas cron`，断言报错输出 |
| C-28 | cron add 无模块报错 | 运行 `debnas cron add`，断言报错输出 |
| E-01 | 非 root 拒绝 | 以普通用户运行模块，断言退出码 = ERROR_ROOT |
| 全部模块 | 元数据 / 依赖 / 入口点 / 禁止调用 | [TESTING_GUIDE.md](../docs/TESTING_GUIDE.md) §七 冒烟测试脚本 |

### 第 5 层：VM 自动化测试

通过 SSH 部署代码到 VM 并远程执行验证（部署命令见本文"测试模式与代码部署"章节）。

**VM 上执行的用例覆盖：**

| 阶段 | 用例 | 验证方式 |
|------|------|---------|
| 一、安装 | A-01~A-13 | SSH: 检查目录/命令/配置文件是否创建，卸载清理是否完整 |
| 二、CLI | C-01~C-32 | SSH: 执行各子命令，验证输出和退出码 |
| 三、菜单交互 | M-01~M-73 | SSH + 管道模拟输入（`echo` / `expect`），验证菜单输出内容 |
| 四、模块功能 | F-01~F-94 | SSH: `debnas run <module>` + 验证服务/文件/配置状态 |
| 五、幂等性 | I-01~I-04 | SSH: 二次执行模块，检查跳过提示 + state 文件 |
| 六、错误处理 | E-01~E-06 | SSH: 模拟各错误场景（非 root/断网/依赖缺失） |
| 七、日志与状态 | L-01~L-05 | SSH: 检查日志文件生成、时间戳、state 格式 |
| 八、兼容性 | B-01~B-07 | SSH: 在用户提供的所有 VM 环境上执行系统检测 |
| 十四、卸载 | A-11~A-13 + C-31~C-32 | SSH: 执行卸载，检查清理是否完整 |

**VM 上的典型测试流程：**

```
部署代码到 VM（见"测试模式与代码部署"章节）
  ↓
执行目标模块: debnas run <module>
  ↓
验证执行结果:
  - systemctl is-active <service>（如有服务）
  - 检查配置文件内容（如 /etc/apt/sources.list.d/）
  - 检查安装的工具（command -v <tool>）
  - 检查日志输出（cat /var/log/debnas/<module>.log）
  ↓
幂等性验证: debnas run <module>（第二次应跳过）
  ↓
验证 state 文件: cat /var/lib/debnas/state/<module>.state
  ↓
如修改了 lib/ 公共函数: 执行所有依赖该函数的模块
```

**交互式模块自动化测试指南：**

> ⚠️ **核心原则**：不要因为模块有交互式菜单就直接跳过。先读源码理解输入流程，再用管道模拟值测试配置写入流程。模拟值不会影响真实服务（如假 SMTP 凭据不会真的发送邮件），但可以验证配置文件是否正确写入、流程是否跑通。

**SSH 管道注意事项：**

- **必须使用 `printf` 而非 `echo -e`**：SSH 多层引号嵌套中，`echo -e` 的 `\n` 会被外层 shell 吞掉变成字面量 `n`。`printf` 的转义在所有层级都可靠
- **管道格式**：`printf '选项1\n选项2\n...\n' | debnas` 或 `printf 'input1\ninput2\n' | debnas --yes run <模块>`

**模块自动化方法速查表：**

| 模块 | 自动化方法 | 输入序列 | 说明 |
|------|-----------|---------|------|
| mail-account | 管道模拟值 | `printf 'test@qq.com\nfakepass123\nadmin@qq.com\n' \| debnas --yes run mail-account` | 用假邮箱/密码验证配置写入流程。SMTP 发不出去不影响 Exim4 配置文件、passwd.client、notify_email 的写入验证 |
| login-mail-on | `--yes` 直接执行 | `debnas --yes run login-mail-on` | 依赖 mail-account 已完成，读取 notify_email 配置，非交互 |
| login-mail-off | `--yes` 直接执行 | `debnas --yes run login-mail-off` | 依赖 mail-account，直接移除 PAM 配置 |
| hosts-sync | `--yes` 跳过菜单 | `debnas --yes run hosts-sync` | 代码中 `DEBNAS_FORCE_YES=1` 时跳过菜单直接执行单次更新 |
| BBR | 参数模式 | `debnas --yes run bbr 2` | 支持参数 1=临时启用 2=永久启用 3=临时禁用 4=永久禁用 5=状态，非 TTY 自动走参数模式 |
| acl-manager | 管道菜单序列 | `printf '2\n/path\nuser\nrwx\nn\ny\n0\n' \| debnas --yes run acl-manager` | 输入顺序：选项→路径→用户名→权限→递归(n)→确认(y)→返回(0) |
| basic 方案 | 菜单管道 | `printf '8\n1\n0\n' \| debnas` | 主菜单选 8（一键部署）→ 1（基础环境），所有子模块已装则幂等跳过 |
| secure 方案 | 菜单管道 | `printf '8\n2\n0\n' \| debnas` | 主菜单选 8（一键部署）→ 2（安全环境）。需先完成 mail-account 配置（幂等状态下跳过交互） |

**主菜单交互测试模板：**

```bash
# 示例：测试主菜单显示 + 选择分类 + 返回（使用 printf，不要用 echo -e）
SSH_ASKPASS=/tmp/ssh-askpass.sh DISPLAY=:0 \
  ssh -o StrictHostKeyChecking=no -t kekylin@${TEST_VM_IP} "printf '%s\n' '${TEST_VM_PASSWORD:?}' | su -c '
    printf \"1\\n0\\n\" | debnas
  '"
# 验证：输出中包含目标子菜单内容

# 示例：测试无效输入处理
SSH_ASKPASS=/tmp/ssh-askpass.sh DISPLAY=:0 \
  ssh -o StrictHostKeyChecking=no -t kekylin@${TEST_VM_IP} "printf '%s\n' '${TEST_VM_PASSWORD:?}' | su -c '
    printf \"abc\\n99\\n0\\n\" | debnas
  '"
# 验证：输出中包含"无效"或"重新输入"提示
```

**交互模块输入流分析方法：**

测试前先读模块源码，按以下步骤确定输入序列：
1. `grep -n 'print_prompt\|read -r\|safe_read_input' modules/<模块>.sh` 找到所有提示和输入点
2. 按顺序列出每个提示需要的输入值
3. 用模拟值填充（邮箱用 `test@example.com`，密码用 `test123`，路径用 `/tmp/test_dir`）
4. 用 `printf` 拼接输入序列，末尾加 `0` 或 `exit` 确保正常退出

如果管道输入确实无法满足（如需要实时交互的 curses 界面），才标记为 ⏭️ 并说明原因。

### 发布前测试策略

| 时机 | 执行内容 |
|------|---------|
| 每次代码修改后 | L1-L5 门禁（`bash tests/check.sh`） |
| 功能开发完成后 | 相关模块的全部用例（VM 上执行，含菜单模拟） |
| 发布前 | [TESTING_GUIDE.md](../docs/TESTING_GUIDE.md) §四 发布前检查清单 + 本文冒烟测试阶段 + 阻塞项验证 |
| 重大版本发布前 | 完整回归测试（用户提供的所有 VM 环境） |

---

## 十四、执行顺序建议

```
第 0 阶段：L1-L5 自动化门禁（开发机，~30 秒）【新增】
  bash tests/check.sh

第一阶段：安装与基础验证（约 1 分钟）
  A-01 → A-05~A-10 → C-01 → C-02 → C-03

第二阶段：基础系统（约 1 分钟）
  M-11 → M-12 → F-01~F-06

第三阶段：CLI 子命令（约 1 分钟）
  C-04~C-08 → C-09~C-14 → C-15~C-18 → C-19~C-21 → C-22~C-32

第四阶段：管理面板（约 2 分钟）
  M-21 → F-10~F-13 → M-22 → F-14~F-15 → M-23~M-27 → F-16~F-21

第五阶段：安全防护（约 2 分钟）
  M-31 → F-30~F-31 → M-32 → F-32~F-34 → M-33 → F-35~F-36 → M-34 → F-37~F-40

第六阶段：容器管理（约 1 分钟）
  M-41 → F-45~F-48 → M-42 → F-49~F-51 → M-43 → F-52~F-54

第七阶段：通知服务（约 1 分钟）
  M-51 → F-60~F-61 → M-52 → F-62 → M-53 → F-63

第八阶段：系统维护（约 1 分钟）
  M-61~M-63 → F-70~F-76

第九阶段：系统工具（约 1 分钟）
  M-64~M-68 → F-77~F-85

第十阶段：一键部署（约 1 分钟）
  M-71 → F-90~F-92 → M-72 → F-93~F-94

第十一阶段：幂等性与状态（约 1 分钟）
  I-01~I-04 → L-01~L-05

第十二阶段：错误处理（约 1 分钟）
  E-01~E-06

第十三阶段：兼容性（约 2 分钟，需额外 VM）
  B-01~B-07

第十四阶段：卸载（约 1 分钟）
  A-11~A-13 → C-31~C-32
```

### 预估时间

| 测试范围 | 用例数 | 预估时间 |
|----------|:------:|----------|
| L1-L5 自动化门禁（第 0 阶段） | ~462 | ~60 秒 |
| 冒烟测试（★标记项 + 一~四阶段） | ~30 | ~3 分钟 |
| 完整回归（全部阶段） | 170+ | ~10 分钟 |
| 双版本兼容（Debian 12 + 13） | 170+ × 2 | ~20 分钟 |

---

## 十五、测试通过标准

### 15.1 L1-L5 自动化门禁标准（新增）

| 层级 | 命令 | 通过标准 | 阻塞？ |
|------|------|---------|:---:|
| L1 语法 | `find lib/ modules/ bin/ -name '*.sh' -exec bash -n {} \;` | 0 错误 | ✅ 是 |
| L2 ShellCheck | `shellcheck --severity=error -x lib/**/*.sh bin/*.sh modules/*.sh` | 0 error | ✅ 是 |
| L3 单元 | `bash tests/run.sh unit` | 全部 PASS | ✅ 是 |
| L4 冒烟 | `bash tests/check.sh` 内置检查 | 全部 PASS | ✅ 是 |
| L5 集成 | `bash tests/run.sh integration` | 全部 PASS | ✅ 是 |
| 综合门禁 | `bash tests/check.sh` | 退出码 0 | ✅ 是 |

### 15.2 L6 上线交付标准（必须全部 PASS）

- 第一阶段：A-01、A-05、C-01、C-02、C-03
- 第二阶段：F-01、F-03、F-05
- 第三阶段：C-09、C-19、C-22
- 第四阶段：F-12（Cockpit 服务运行）
- 第五阶段：F-33（SSH 端口保持开放）
- 第六阶段：F-45（Docker 正常运行）
- 第十二阶段：E-01（非 root 拒绝）
- 第十四阶段：A-11（卸载干净）
- **第 0 阶段（新增）**：L1-L5 自动化门禁全部通过

### 15.3 阻塞项

以下任何一项失败，禁止发布：

| # | 阻塞项 | 层级 | 理由 |
|:-:|--------|:---:|------|
| 1 | `bash tests/check.sh` 退出码 ≠ 0 | L1-L5 | 自动化门禁不通过，代码质量无保障 |
| 2 | A-01 安装脚本不可用 | L6 | 用户无法安装 |
| 3 | C-01/C-02/C-03 CLI 入口异常 | L6 | 用户无法使用基本功能 |
| 4 | E-01 非 root 未拒绝 | L6 | 安全风险 |
| 5 | F-33 SSH 端口被防火墙阻断 | L6 | 安全事故（用户失联） |
| 6 | A-11 卸载不干净 | L6 | 残留文件污染系统 |

### 15.4 完整通过标准

- L1-L5 自动化门禁全部通过（`check.sh` 退出码 0）
- 全部 170+ L6 VM 用例 PASS
- Debian 12 + Debian 13 双版本验证（重大版本发布前）

---

## 十六、测试报告格式

每轮测试结束后，AI **必须**生成测试报告并保存到本地磁盘。

### 报告保存位置

```
tests/reports/test-report-YYYYMMDD-HHmmss.md
```

目录 `tests/reports/` 不存在时自动创建。

### 设计原则

报告同时服务于**三类读者**，按阅读顺序设计：

| 读者 | 阅读目标 | 需要的信息 | 阅读时间 |
|------|---------|-----------|:--------:|
| **领导/管理者** | 判断是否可以发布 | 总通过率、阻塞项状态、风险摘要 | ≤ 30 秒 |
| **开发者（人类）** | 快速定位问题 | 哪些阶段/模块失败、严重程度 | ≤ 2 分钟 |
| **AI（自动修复）** | 精确修复代码 | 失败用例编号、错误输出、文件路径+行号、根因、修复建议 | 完整读取 |

**核心原则**：
- **一眼定结论**：报告顶部就能看到"通过/失败"判定，无需翻页
- **分层读深度**：总览（30 秒）→ 阶段表（2 分钟）→ 失败详情（AI 精读）
- **符号统一**：✅ PASS / ❌ FAIL / ⏭️ SKIP / ⚠️ WARN / 🔴 阻塞 / 🟡 重要 / 🟢 建议
- **失败可操作**：每个失败用例包含 AI 修复所需的全部信息（编号、错误输出、文件定位、根因、修复方向）

### 报告模板

```markdown
# 🧪 DebNAS 测试报告

> **报告编号**: `#NNN` | **日期**: YYYY-MM-DD HH:mm | **测试模式**: 本地推送 / 远程安装
> **代码版本**: `abc1234` (refactor/debnas-v2) | **测试环境**: Debian 13 (trixie) amd64 | **VM**: 见本地测试环境

---

## 🎯 执行摘要

> 👤 **目标读者：领导/管理者** — 用一段话讲清楚：测了什么、结果怎样、能否发布。

本轮对 DebNAS 的 [完整功能集 / `sources` 模块 / 安全防护分类] 进行了验证。
共执行 **N** 个用例，通过 **N** 个（XX%），失败 **N** 个，跳过 **N** 个。

[选择以下之一作为结语]
✅ 全部阻塞项通过，无遗留问题，**建议进入发布流程**。
⚠️ 存在 N 个阻塞项（P0），**不建议发布**，修复后需重新测试第 X 阶段。
🟡 存在 N 个非阻塞问题（P1/P2），**可以发布但建议修复**，详见建议章节。

---

## 📊 测试仪表盘

> 👤 **目标读者：所有人** — 一页看懂整体健康状况。

```
通过率   ████████████████████░░░░  95.2%  (163/172)
```

| 指标 | 数值 | 指标 | 数值 |
|------|:----:|------|:----:|
| L1-L5 自动化 | ✅ PASS / ❌ FAIL | 总耗时 | ~10 分钟 |
| 总用例 | 170+ | P0 阻塞 | N 个 |
| ✅ 通过 | 149 | P1 重要 | N 个 |
| ❌ 失败 | 4 | P2 建议 | N 个 |
| ⏭️ 跳过 | 3 | 通过率 | **95.2%** |
| ⚠️ 警告 | 0 | 综合判定 | ⚠️ 存在阻塞项 / ✅ 可以发布 |

> **综合判定**：⚠️ 存在阻塞项，不建议发布 / ✅ 全部通过，可以发布

---

## 🗺️ 阶段结果

> 👤 **目标读者：开发者（人类）** — 快速定位问题集中在哪个阶段。

| # | 阶段 | 用例范围 | 通过/总数 | 通过率 | 耗时 | 状态 |
|:-:|------|----------|:--------:|:-----:|:----:|:----:|
| 0 | L1-L5 自动化门禁 | `check.sh` | ✅/✅ | — | 30s | ✅/❌ |
| 1 | 安装与基础验证 | A-01~A-10, C-01~C-03 | 13/13 | 100% | 1m | ✅ |
| 2 | 基础系统 | M-11~M-12, F-01~F-06 | 8/8 | 100% | 1m | ✅ |
| ... | ... | ... | ... | ... | ... | ... |
| **∑** | **合计** | **全部** | **~163/172** | **~95%** | **~10m** | ⚠️ |

> 阶段状态图例：✅ 全部通过 · ⚠️ 部分失败（非阻塞） · ❌ 含阻塞项 · ⏭️ 已跳过

---

## 🔴 失败用例详情

> 👤 **目标读者：AI（自动修复）** — 每个失败用例包含精确的代码定位和修复指引。
> 按优先级排列：🔴 P0（阻塞发布） → 🟡 P1（建议修复） → 🟢 P2（锦上添花）

---

### 🔴 P0-[编号] [测试项名称]

| 维度 | 详情 |
|------|------|
| **用例编号** | 如 F-33 |
| **对应 TC-ID** | 如 TC-P1-AUTO-002（如有自动化覆盖） |
| **所属模块** | 如 `modules/firewall.sh` |
| **严重程度** | 🔴 P0 — 阻塞发布（SSH 端口安全风险） |
| **现象** | （一句话描述：实际发生了什么） |
| **预期** | （一句话描述：应该发生什么） |
| **错误输出** | （粘贴关键错误日志/退出码/输出片段，≤ 10 行） |
| **代码定位** | `文件路径:行号` — 函数名() |
| **根因** | （为什么出错，不是"什么错了"而是"为什么会错"） |
| **影响范围** | （哪些后续用例/模块受此影响） |
| **修复方向** | （具体的修改思路，不是"修复它"而是"在 XX 位置增加 YY 检查"） |

---

### 🟡 P1-[编号] [测试项名称]

| 维度 | 详情 |
|------|------|
| ... | （同上格式） |

---

### 🟢 P2-[编号] [测试项名称]

| 维度 | 详情 |
|------|------|
| ... | （同上格式） |

---

## ⏭️ 跳过用例

> 👤 **目标读者：开发者 + 管理者** — 说明为什么跳过、是否影响发布判断。

| 编号 | 用例名称 | 跳过原因 | 解除条件 | 影响发布？ |
|:----:|---------|---------|---------|:----------:|
| B-01 | Debian 12 完整测试 | 无 Debian 12 虚拟机 | 准备 Debian 12 VM 即可执行 | 否（大版本发布前补测） |
| B-02 | Debian 12 兼容性 | 同上 | 同上 | 否 |

> 上表中的"影响发布"判断标准：该用例是否属于 §十五 阻塞项。非阻塞项跳过不影响发布。

---

## 🏁 发布门禁判定

> 👤 **目标读者：领导/管理者** — 逐项对照 §十五 阻塞项，清晰展示每一项的判定结果。

| # | 阻塞项（§十五） | 要求 | 实际结果 | 判定 |
|:-:|--------|------|---------|:----:|
| 0 | L1-L5 自动化门禁 | `check.sh` exit 0 | ✅ PASS / ❌ FAIL | |
| 1 | A-01 安装脚本可用 | PASS | ✅ PASS | ✅ |
| 2 | C-01/C-02/C-03 CLI 入口正常 | PASS | ✅ PASS | ✅ |
| 3 | E-01 非 root 权限拒绝 | PASS | ✅ PASS | ✅ |
| 4 | F-33 SSH 端口保持开放 | PASS | ❌ FAIL — SSH 22 端口被阻断 | 🔴 |
| 5 | A-11 卸载清理完整 | PASS | ✅ PASS | ✅ |

| 结论 | 判定 |
|------|:----:|
| 阻塞项通过率 | **N / 6** |
| 是否达到上线交付标准 | ❌ / ✅ |
| 是否可以发布 | 🔴 禁止发布 / ✅ 可以发布 |
| 修复后需重测阶段 | [阶段列表] |
| 遗留问题 | [描述] |

---

## 📝 建议与后续行动

> 👤 **目标读者：领导/管理者 + 开发者** — 明确的下一步行动，可直接转化为任务分配。

| 优先级 | 行动 | 关联用例 | 预估工时 | 负责角色 |
|:------:|------|:--------:|:--------:|:--------:|
| P0 | 修复 SSH 端口阻断 | F-33 | 30 min | 开发 |
| P1 | 补充 config set/get 一致性 BATS 测试 | C-15 | 20 min | 测试 |
| P2 | 准备 Debian 12 VM 补充兼容性测试 | B-01~B-02 | 10 min | 运维 |

> 完成全部 P0 + P1 行动后，重新执行受影响阶段的测试并生成新报告。

---

*📅 报告生成时间：YYYY-MM-DD HH:mm:ss*
*📂 报告路径：tests/reports/test-report-YYYYMMDD-HHmmss.md*
*🤖 生成者：DebNAS AI 测试框架*
```

### 报告生成规范

**1. 结果符号（统一使用）**

| 符号 | 含义 | 使用场景 |
|:----:|------|---------|
| ✅ | PASS | 用例通过 |
| ❌ | FAIL | 用例失败 |
| ⏭️ | SKIP | 用例跳过 |
| ⚠️ | WARN | 通过但有非预期行为（如多余日志、性能偏慢） |
| 🔴 | 阻塞 | P0 级别失败，必须修复才能发布 |
| 🟡 | 重要 | P1 级别失败，建议修复 |
| 🟢 | 建议 | P2 级别失败，锦上添花 |

**2. 失败严重程度定义**

| 级别 | 标记 | 定义 | 动作 |
|:----:|:----:|------|------|
| P0 | 🔴 | §十五 阻塞项失败，或导致 SSH 失联/数据丢失/安全漏洞 | 禁止发布，立即修复 |
| P1 | 🟡 | 非阻塞项失败，用户可见的功能异常或体验降级 | 建议修复后可发布 |
| P2 | 🟢 | 边缘场景、UI 文案、非关键日志格式等问题 | 可发布，后续迭代修复 |

**3. 报告生成规则**

- 模板中 `> 👤 **目标读者：...**` 开头的行是 AI 编写指引，**禁止**出现在最终报告中。同理，`[选择以下之一作为结语]`、`（同上格式）` 等占位说明也不得出现在最终报告中。报告应直接呈现数据，不要让读者感觉在被"指导如何阅读"
- 每个执行过的用例必须有明确结果（✅ / ❌ / ⏭️ / ⚠️），不允许遗漏
- ❌ 失败用例必须填写完整的 11 维度详情表（含 **对应 TC-ID** 维度），不得省略任何维度。如某个维度不适用，填写 `—`（不是空白）
- 阶段结果表的"通过/总数"列：被跳过的阶段写 `0/N`，通过率为 `—`
- 跳过用例必须说明"解除条件"（即做什么可以不再跳过）
- 仪表盘新增 "L1-L5 自动化" 行，展示 `check.sh` 门禁结果
- 阶段结果表新增 "第 0 阶段：L1-L5 自动化门禁"
- 仅当存在 P0 失败时，"是否达到上线交付标准"才判定为 ❌；仅 P1/P2 失败时为 🟡（有条件通过）
- 报告生成后 AI 向用户输出：**报告路径 + 执行摘要 + 测试仪表盘 + 发布门禁判定**（四项即可，不输出全部报告内容。但报告文件本身必须包含完整模板所有章节）

**4. 无失败时的模板简化**

当全部用例通过（无 ❌）时：
- `🔴 失败用例详情` 章节替换为：`> ✅ 本轮测试无失败用例。`
- `📝 建议与后续行动` 章节替换为：`> ✅ 无待处理问题。`
- 其他章节照常填写（仪表盘、阶段结果、门禁判定等仍然有价值）

---

## 十七、Phase 8 实施成果（2026-07-05）

> 实施日期：2026-07-05 | 核心原则：零依赖 Mock（PATH Injection + 结构验证 + 纯函数提取）| 详见 [CLAUDE.md](../CLAUDE.md) Phase 8 计划

### 17.1 新增测试文件

| 文件 | 路径 | 测试数 | 测试目标 | 技术 |
|------|------|:---:|------|------|
| test-bbr.bats | tests/unit/modules/ | 25 | 配置 BBR 加速（参数模式1-5、永久/临时启用停用、状态查询、cron_mode 守卫） | PATH Injection (sysctl/modprobe/lsmod/modinfo) + 纯函数 |
| test-service-query.bats | tests/unit/modules/ | 27 | 服务状态查询（已安装服务列表、容器状态、cockpit URL、firewalld/fail2ban 信息） | 结构验证 + grep 断言 |
| test-hosts-sync.bats | tests/unit/modules/ | 31 | Hosts DNS 优化（5 子脚本结构、DNS 提供商常量、START_MARK/END_MARK、--yes 跳过逻辑） | 结构验证 + grep 断言 |
| test-acl-manager.bats | tests/unit/modules/ | 25 | ACL 权限管理（validate_permissions 纯函数、8 函数定义、7 菜单项、cron_mode 守卫） | 纯函数测试 + 菜单结构验证 |
| test-docker-mirror.bats | tests/unit/modules/ | 18 | 配置镜像加速（array_to_json_array 纯函数、DAEMON_JSON 常量、SECURITY 无硬编码 IP 检查） | 纯函数 + 结构验证 |
| test-security.bats | tests/unit/modules/ | 19 | 基础安全配置（configure_su_restrictions pam_wheel、configure_timeout_and_logging TMOUT=900、安全审计 marker） | 结构验证 + 安全逻辑 grep |
| test-sys-check.bats | tests/unit/modules/ | 29 | 系统兼容性检查（check_system_compatibility、内存/磁盘阈值、网络检查 curl --max-time、SSH/Cron 服务检查） | 结构验证 + 检查项覆盖 |
| **合计** | | **174** | | |

### 17.2 修改的现有文件

| 文件 | 修改内容 | 关联 TC-ID | 状态 |
|------|---------|-----------|:----:|
| tests/unit/lib/test-logging.bats | 新增 5 个测试（9→14）：时间戳格式、默认 DEBNAS_LOG_DIR、LOG_TIMESTAMP=0、NO_COLOR=1、连续追加 | — | ✅ |
| tests/integration/test-docker-ce.bats | 移除内联 awk 逻辑，改为 source 真实函数结构验证（`URIs`/`sub(`/`-f`/`deb.*debian.*org`） | TC-P1-MOCKFIX-001~002 | ✅ |
| tests/integration/test-solution.bats | 保留 stub + 新增 bin/menu.sh 真实 execute_solution() 结构验证（fd 3 `3<`、module-runner.sh 调用、`break` 逻辑、注释/空行过滤） | TC-P1-MOCKFIX-003 | ✅ |
| tests/unit/lib/test-cron.bats | crontab Mock 改用共享 `setup_crontab_mock()`（原 25 行内联实现→1 行调用） | TC-P1-MOCKFIX-004 | ✅ |
| tests/integration/test-cron-mode.bats | crontab Mock 改用共享 `setup_crontab_mock()`（原 19 行内联实现→1 行调用） | TC-P1-MOCKFIX-004 | ✅ |
| tests/integration/test-sources.bats | 移除重复 `bash -n "$MODULE_FILE"`，添加注释说明 L1 门禁覆盖 | — | ✅ |
| tests/integration/test-firewall.bats | 移除重复 `bash -n "$MODULE_FILE"`，添加注释说明 L1 门禁覆盖 | — | ✅ |
| tests/helpers/common-setup.bash | 新增共享 `setup_crontab_mock()` / `teardown_crontab_mock()`（状态文件式 Mock，支持 -l/-r/-） | TC-P1-MOCKFIX-004 | ✅ |

### 17.3 覆盖的 TC-ID

| TC-ID | 描述 | 覆盖方式 |
|--------|------|---------|
| TC-P1-MOCKFIX-001 | docker-ce 内联 awk 替换 | test-docker-ce.bats — 改为结构 grep |
| TC-P1-MOCKFIX-002 | docker-ce 内联 regex 替换 | test-docker-ce.bats — 改为结构 grep |
| TC-P1-MOCKFIX-003 | solution 函数重定义修复 | test-solution.bats — stub + 真实函数结构验证 |
| TC-P1-MOCKFIX-004 | crontab Mock DRY | common-setup.bash — 共享 helper |
| TC-P1-MOD-005 | sys-check 功能测试 | test-sys-check.bats — 结构验证 + 检查项断言 |
| TC-P1-MOD-006 | service-query 功能测试 | test-service-query.bats — 结构验证 |
| TC-P1-MOD-007 | hosts-sync 功能测试 | test-hosts-sync.bats — 5 子脚本结构验证 |
| TC-P1-IMOD-002 | acl-manager 交互测试 | test-acl-manager.bats — 纯函数 + 菜单结构 |
| TC-P1-IMOD-003 | bbr 参数模式测试 | test-bbr.bats — PATH Injection Mock |
| TC-P2-BND-009 | sys-check 内存 < 1GB 阈值 | test-sys-check.bats — 检查项覆盖 |
| TC-P2-BND-010 | sys-check 磁盘 < 10GB 阈值 | test-sys-check.bats — 检查项覆盖 |
| L-01~L-05 | 日志格式与行为验证 | test-logging.bats — +5 用例 |

### 17.4 技术债清理汇总

| 类别 | 项数 | 完成 | 延后 | 说明 |
|------|:---:|:---:|:---:|------|
| §12.1 重复 bash -n | 4 | 4 | 0 | 全部移除，保留注释说明 L1 全局覆盖 |
| §12.2 低价值项 | 6 | 1 | 5 | test-logging.bats 扩展至 14 用例；4 项合并延后（P3）；1 项维持 |
| §12.3 反模式 | 3 | 3 | 0 | docker-ce 内联 awk、solution stub、crontab Mock 统一 |
| §12.4 死代码 | 15 | 0 | 15 | 未涉及，建议后续架构清理阶段处理 |

### 17.5 实施前后测试规模对比

| 指标 | Phase 8 前（v3.0.0 记录） | Phase 8 后（实际） | 变化 |
|------|:---:|:---:|:---:|
| L3 unit/lib 文件数 | 12 | 12 | — |
| L3 unit/lib 测试数 | 175 | 180 | +5 |
| L3 unit/modules 文件数 | 0 | 7 | +7 |
| L3 unit/modules 测试数 | 0 | 174 | +174 |
| L3 合计文件数 | 12 | 19 | +7 |
| L3 合计测试数 | 175 | 354 | +179 |
| L5 integration 文件数 | 6 | 6 | — |
| L5 integration 测试数 | 108 | 108 | — |
| BATS 总文件数 | 18 | 25 | +7 |
| BATS 总测试数 | 283 | 462 | +179 |

### 17.6 质量门禁验证

```
L1 (语法):   ✅ PASS — bash -n 全部 .sh 文件
L3 (单元):   ✅ PASS — 354 个测试全部通过（19 文件）
L4 (冒烟):   ✅ PASS — 模块元数据完整性检查
L5 (集成):   ✅ PASS — 108 个测试全部通过（6 文件）
```

---

## 附录 A：新增 BATS 测试文件清单（已实施 + 计划）

### A.1 Phase 8 已交付文件（实际）

| 批次 | 文件路径 | 实际用例数 | 类型 | 状态 |
|------|---------|:---:|------|:---:|
| Phase 8 | `tests/unit/modules/test-bbr.bats` | 25 | 单元（模块） | ✅ 已交付 |
| Phase 8 | `tests/unit/modules/test-service-query.bats` | 27 | 单元（模块） | ✅ 已交付 |
| Phase 8 | `tests/unit/modules/test-hosts-sync.bats` | 31 | 单元（模块） | ✅ 已交付 |
| Phase 8 | `tests/unit/modules/test-acl-manager.bats` | 25 | 单元（模块） | ✅ 已交付 |
| Phase 8 | `tests/unit/modules/test-docker-mirror.bats` | 18 | 单元（模块） | ✅ 已交付 |
| Phase 8 | `tests/unit/modules/test-security.bats` | 19 | 单元（模块） | ✅ 已交付 |
| Phase 8 | `tests/unit/modules/test-sys-check.bats` | 29 | 单元（模块） | ✅ 已交付 |
| Phase 8 | `tests/unit/lib/test-logging.bats`（扩展） | +5 (9→14) | 单元（lib） | ✅ 已扩展 |

### A.2 Phase 4-5 计划文件（全部已实施 — Phase 9）

Phase 4-5 自动化测试用例已全部实施，以下为计划对照：

| 批次 | 新增文件 | 预估 | 实际 | 类型 | 状态 |
|------|---------|:---:|:---:|------|:---:|
| A | `tests/integration/test-cli-routing.bats` | ~16 | 25 | 集成 | ✅ |
| A | `tests/integration/test-preflight.bats` | ~14 | 24 | 集成 | ✅ |
| A | `tests/unit/lib/test-permission.bats` | ~2 | 4 | 单元 | ✅ |
| B | `tests/unit/lib/test-module-registry.bats`（扩充） | ~16 | 34 | 单元 | ✅ |
| B | `tests/unit/lib/test-urls.bats` | ~8 | 12 | 单元 | ✅ |
| B | `tests/unit/lib/test-installer.bats` | ~3 | 11 | 单元 | ✅ |
| C | `tests/integration/test-menu.bats` | ~6 | 7 | 集成 | ✅ |
| C | `tests/unit/ui/test-ui-input.bats` | ~10 | 11 | 单元 | ✅ |
| C | `tests/integration/test-interactive-modules.bats` | ~3 | 4 | 集成 | ✅ |
| D | `tests/unit/lib/test-dependency.bats`（扩充） | ~6 | 24 | 单元 | ✅ |
| D | `tests/unit/lib/test-config-priority.bats` | ~6 | 5 | 单元 | ✅ |
| D | `tests/unit/lib/test-shell-arrays.bats` | ~3 | — | 单元 | 🔀 合并至 test-dependency.bats + test-args.bats |
| E | `tests/unit/lib/test-migration.bats` | ~4 | 12 | 单元 | ✅ |
| E | `tests/unit/lib/test-apt-pinning.bats` | ~5 | 11 | 单元 | ✅ |
| F | `tests/integration/test-error-paths.bats` | ~11 | 14 | 集成 | ✅ |
| F | `tests/integration/test-permission-security.bats` | ~9 | 9 | 集成 | ✅ |
| G | `tests/integration/test-recovery.bats` | ~5 | 9 | 集成 | ✅ |
| G | `tests/unit/lib/test-shell-features.bats` | ~3 | 5 | 单元 | ✅ |
| H | `tests/integration/test-boundary.bats` | ~10 | 10 | 集成 | ✅ |
| I | `tests/unit/ui/test-ui-styles.bats` | ~1 | 2 | 单元 | ✅ |
| **合计** | **22 计划文件** | **~146** | **278** | | ✅ 全部完成 |

> 🔀 `test-shell-arrays.bats` 规划的 TC-ID（SH-001~003）已合并到 `test-dependency.bats`（SH-001~002）和 `test-args.bats`（SH-003），未创建独立文件。

### A.3 需修改的现有文件（全部已完成）

| 文件 | 修改内容 | 关联 TC-ID | 状态 |
|------|---------|-----------|:---:|
| `tests/integration/test-docker-ce.bats` | 移除内联 awk 逻辑，source 真实函数 | TC-P1-MOCKFIX-001~002 | ✅ Phase 8 |
| `tests/integration/test-solution.bats` | 移除函数重定义，source 真实 `bin/menu.sh` | TC-P1-MOCKFIX-003 | ✅ Phase 8 |
| `tests/unit/lib/test-cron.bats` | 提取 crontab Mock 到共享 helper | TC-P1-MOCKFIX-004 | ✅ Phase 8 |
| `tests/integration/test-cron-mode.bats` | 使用共享 crontab Mock | TC-P1-MOCKFIX-004 | ✅ Phase 8 |
| `tests/helpers/common-setup.bash` | 新增共享 Mock 函数（`setup_crontab_mock` 等） | TC-P1-MOCKFIX-004 | ✅ Phase 8 |
| `tests/unit/lib/test-args.bats` | 新增配置优先级链 + 全局配置一致性测试 | TC-P1-CFG-001~006, TC-P1-SH-003 | ✅ Phase 9 |
| `tests/unit/lib/test-dependency.bats` | 新增 Tier 1 自动安装 + ensure_module_deps 测试 | TC-P1-DEP-001~006, TC-P1-SH-001~002 | ✅ Phase 9 |

---

## 附录 B：自动化等级标注符号说明

| 符号 | 含义 | 判定条件 |
|:----:|------|---------|
| ★★★★★ | 全自动零依赖 | 纯函数测试，无需 Mock，无文件系统依赖，可直接 BATS |
| ★★★★☆ | 全自动轻 Mock | 仅需 PATH Injection 或环境变量覆盖，1-2 个 Mock 点 |
| ★★★☆☆ | 全自动中度 Mock | 需要临时文件系统 + 多种 Mock 组合（3+ Mock 点） |
| ★★☆☆☆ | 半自动/L6 VM | 需要真实系统服务（apt/systemd/docker）或真实网络，在 VM 上执行 |
| ★☆☆☆☆ | 人工为主 | 需要硬件/物理交互（USB 插入、OAuth 回调），仅少量步骤可自动化 |
| ☆☆☆☆☆ | 无法自动化 | 物理限制，无可行自动化方案 |
| 🔄 | 已被/可被自动化覆盖 | 有对应的 TC-ID 可在 L3-L5 自动化执行 |
| ⚠️ | 需重构/注意 | 存在反模式（内联逻辑/函数重定义）或 Mock 困难 |
| 💀 | 死代码 | 函数/常量有实现/测试但生产代码从未调用 |

---

## 十三、Mock 编写标准模板（AI 协作参考）

> 本章从现有 41 个 .bats 测试文件中提炼已验证的 Mock 模式，为 AI 编写新测试提供标准模板。
> 所有模式均已在项目中验证可行，新测试应遵循相同模式而非发明新方法。

### 13.1 PATH Injection（系统命令覆盖）

**适用场景**：被测函数依赖外部命令（`curl`, `wget`, `exim`, `chmod`, `apt-get` 等），需要在测试中控制其行为。

**标准模板**：
```bash
@test "example: 使用 PATH Injection mock 外部命令" {
  local mock_bin
  mock_bin=$(mktemp -d)

  # 创建 mock 命令（记录调用参数或返回固定值）
  cat > "$mock_bin/chmod" << 'EOF'
#!/usr/bin/env bash
echo "CHMOD_ARGS=$*" >> /tmp/chmod_log
exit 0
EOF
  chmod +x "$mock_bin/chmod"

  run bash -c '
    export PATH="$1:$PATH"
    # ... 被测函数调用 ...
  ' _ "$mock_bin"

  rm -rf "$mock_bin"
}
```

**项目实例**：[test-security.bats:196-253](tests/unit/modules/test-security.bats#L196) — Mock `chmod` 验证 1733 权限参数

**关键规则**：
- Mock bin 目录使用 `mktemp -d`，测试后 `rm -rf`
- Mock 脚本必须以 `#!/usr/bin/env bash` 开头
- 必须 `chmod +x` mock 脚本
- 在 `run bash -c` 内部 `export PATH="$mock_bin:$PATH"` 确保隔离
- 使用临时日志文件记录调用参数（不要依赖 stdout 解析）

### 13.2 函数覆盖（同名函数替换）

**适用场景**：被测函数调用 lib 函数（`write_file_if_changed`, `log_info`, `config_read` 等），需要拦截调用并验证参数或阻止副作用。

**标准模板**：
```bash
@test "example: 函数覆盖验证调用" {
  run bash -c '
    # 覆盖 lib 函数为 no-op 或记录函数
    write_called=0
    write_content=""

    write_file_if_changed() {
      write_called=1
      write_content="$2"
      return 0
    }

    # 覆盖 log_* 为 no-op（避免输出污染）
    log_info() { :; }; log_success() { :; }
    log_error() { :; }; log_warning() { :; }
    log_fail() { :; }

    # ... 被测函数调用 ...
    echo "WRITE_CALLED=$write_called"
  '
  [[ "$output" == *"WRITE_CALLED=1"* ]]
}
```

**项目实例**：[test-security.bats:147-192](tests/unit/modules/test-security.bats#L147) — Mock `write_file_if_changed` 验证 PAM 配置写入

**关键规则**：
- 覆盖函数必须在 `eval`/source 被测函数**之前**定义（同名覆盖）
- 使用 `write_called=0` + `write_content=""` 模式记录状态
- 用 `echo "KEY=VALUE"` 从子 shell 传递状态到 BATS 断言
- `cat()` 覆盖时注意用 `command cat` 处理非 mock 路径

### 13.3 sed+eval 函数提取（纯函数隔离测试）

**适用场景**：模块文件包含 `source lib/bootstrap.sh` 和 `main "$@"` 调用，不能直接 source。需提取单个函数到测试环境。

**标准模板**：
```bash
@test "example: 提取并测试纯函数" {
  run bash -c '
    # Mock 该函数的所有外部依赖
    log_info() { :; }; log_error() { :; }
    SMTP_MAP_READY=1

    # sed -n "/^func_name()/,/^}/p"：提取函数定义（假设无嵌套花括号）
    eval "$(sed -n "/^[[:space:]]*declare -A SMTP_MAP=/,/^)/p; /^validate_sender_email()/,/^}/p" "$1"/modules/example.sh)"
    validate_sender_email "test@qq.com"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "expected_value" ]]
}
```

**项目实例**：[test-mail-account.bats:152-160](tests/unit/modules/test-mail-account.bats#L152) — 提取 SMTP_MAP + validate_sender_email

**关键规则**：
- sed 范围提取假设函数体无嵌套 `}` 在行首（所有已知函数满足此条件）
- 如果函数依赖文件级变量（关联数组、常量），需同时提取
- 所有 `log_*` 调用必须预先覆盖
- 使用 `"$SRC"/modules/example.sh` 绝对路径

### 13.4 子 shell 隔离（处理 exit/exec）

**适用场景**：被测脚本调用 `exit`、`exec` 或需要 root 权限，直接调用会终止 BATS 进程。

**标准模板**：
```bash
@test "example: 子 shell 隔离测试 exit 行为" {
  run bash -c '
    # 在子 shell 中 source/执行，exit 只终止子 shell
    source /path/to/script.sh
    function_that_calls_exit
  '
  # BATS 捕获子 shell 的 exit code
  [[ "$status" -eq 0 ]]
}
```

**项目实例**：[test-args.bats:53-54](tests/unit/lib/test-args.bats#L53) — `parse_global_args --version` 触发 exit 0

**关键规则**：
- 所有调用 `exit` 或 `exec` 的测试必须用 `run bash -c '...'`
- 子 shell 中需要重新 source 依赖（子 shell 不继承函数定义）
- `run bash -c` 中的 `set -euo pipefail` 按需使用（某些测试需要宽松的错误处理）

### 13.5 临时文件/目录隔离（文件系统 Mock）

**适用场景**：被测函数读写系统路径（`/etc/pam.d/su`, `/etc/profile` 等），需要隔离到临时目录。

**标准模板**：
```bash
@test "example: 临时目录替换系统路径" {
  local pam_dir
  pam_dir=$(mktemp -d)
  echo "existing content" > "$pam_dir/su"

  run bash -c '
    PAM_DIR="$2"
    # 覆盖 cat：将对系统路径的访问重定向到临时目录
    cat() {
      if [[ "$1" == "/etc/pam.d/su" ]]; then
        command cat "$PAM_DIR/su"
      else
        command cat "$@"
      fi
    }
    # ... 被测函数 ...
  ' _ "${DEBNAS_ROOT}" "$pam_dir"

  rm -rf "$pam_dir"
}
```

**项目实例**：[test-security.bats:108-145](tests/unit/modules/test-security.bats#L108) — Mock `/etc/pam.d/su` 到临时目录

**关键规则**：
- 用 `mktemp -d` 创建临时工作目录
- 用 `cat()` 覆盖模式重定向文件访问
- 测试结束时必须 `rm -rf` 清理
- BATS `$BATS_TMPDIR` 可用于长期共享 fixture

### 13.6 模式选择决策树

```
被测函数是否调用 exit/exec？  ──是──→  13.4 子 shell 隔离
      │否
      ▼
被测函数是否读写系统路径？    ──是──→  13.5 临时文件隔离 + 13.2 函数覆盖
      │否
      ▼
被测函数是否调用外部命令？    ──是──→  13.1 PATH Injection
      │否
      ▼
被测函数来自模块文件？        ──是──→  13.3 sed+eval 函数提取 + 13.2 函数覆盖
      │否（来自 lib 库文件）
      ▼
直接 source + 13.2 函数覆盖即可
