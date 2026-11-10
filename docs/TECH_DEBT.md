# DebNAS 技术债务

> 版本：2.9.0 | 更新：2026-11-09
> 更新触发：新增 P3-6 模块只读探测契约覆盖不完整；坑 #1 补充守卫机制

---

## 债务分级说明

| 级别 | 含义 | 修复时间 |
|------|------|---------|
| **P0** | 影响功能正确性或安全性，需立即修复 | 当前版本 |
| **P1** | 影响代码可维护性或存在潜在风险，应在下一版本修复 | 下个版本 |
| **P2** | 代码风格不一致、微小优化、非关键重复 | 下下个版本 |
| **P3** | 长期改进方向，不阻塞正常开发 | 未来规划 |

---

## P0 — 紧急修复

（当前无 P0 级别债务）

---

## P1 — 高优先级

- B-20260731-01: `ui_menu` 在非 TTY/模块子菜单调用时 `LINES` 未绑定导致崩溃（✅ 已修复 2026-07-31）
- B-20260731-02: `mail-account` 管道输入 EOF 时无限循环刷“发件邮箱不能为空”（✅ 已修复 2026-07-31）
- B-20260731-03: 非 TTY 管道菜单输入 EOF 后主菜单无限重绘，进程无法退出（✅ 已修复 2026-07-31）

---

## P2 — 中优先级

- B-20260731-04: `wallpaper` 非交互启用时 cron 表达式为 `0 0 * * *`，与 `@cron_schedule: 0 */6 * * *` 不一致（✅ 已修复 2026-07-31）
- B-20260731-05: `acl-manager` 在 `LINES` 错误后仍写入 `success` 状态，错误未传播（✅ 已修复 2026-07-31）

---

## P3 — 长期改进

### P3-6: 模块只读探测契约覆盖不完整（2026-11-09 新增）

- **问题**：仪表盘的状态列与预演依赖模块实现 `module_status` / `module_plan`（ARCHITECTURE §4.5）。目前仅 `firewall`、`docker-ce` 两个样板实现；其余模块状态显示为"? 未知"（有成功执行记录时显示"已应用（按执行记录）"），预演显示"未提供预演"
- **建议**：按 DEVELOPMENT_GUIDE §4.6 逐个改造：末行换守卫 + 补两个只读函数；交互式模块（`@interactive: true`）至少实现 `module_status`
- **注意**：未加守卫的模块加载器绝不 source（安全），但这意味着即便模块写了 `module_status` 也不会被调用，直到末行换成守卫形式

### P3-2: 模块集成测试覆盖不完整 (持续改善)

- **问题**：当前有 lib/ 层单元测试（12 个 BATS 文件，175 用例）和集成测试（6 个文件，108 用例），但关键模块（hosts-sync、threat-ips、login-mail 等）的功能级集成测试覆盖仍不足
- **当前状态**：`tests/integration/` 已扩充至 6 个集成测试文件，2026-07-05 新增 docker-ce（13 用例）、firewall（13 用例）、sources（19 用例）三个模块的集成测试
  - test-module-registry.bats — 模块发现、元数据解析、拓扑排序（15 用例）
  - test-solution.bats — 方案执行流程、故障处理（9 用例）
  - test-cron-mode.bats — Cron 模式模块结构与注册（13 用例）
  - test-docker-ce.bats — Docker CE 结构与 Mock 功能（13 用例）**新增**
  - test-firewall.bats — Firewalld 结构与依赖链（13 用例）**新增**
  - test-sources.bats — APT 软件源结构与 DEB822 格式（19 用例）**新增**
- **建议**：继续为目录模块（hosts-sync、threat-ips、login-mail）添加集成测试

### P3-5: CI 与集成测试闭环 (本地门禁已完成，VM 层待评估)

- **来源**：[docs/audit/project-roadmap-review.md](docs/audit/project-roadmap-review.md) RR-2、[docs/audit/optimization-planning.md](docs/audit/optimization-planning.md) OP-11
- **发现时间**：2026-07-04 审计
- **当前状态**：
  - ✅ **本地一键门禁已完成**：`tests/check.sh` 已整合第 1-5 层（语法检查 + ShellCheck + 单元测试 + 模块元数据冒烟 + 集成测试），单命令 `bash tests/check.sh` 即可完成本地完整质量闭环
  - ✅ **远程 CI 已覆盖**：`.github/workflows/ci.yml` 在 Debian bookworm/trixie 上自动执行全部 5 层测试
  - ⏳ **第 6 层（VM 端到端功能验证）仍依赖手动执行**：需 Debian VM + SSH + root 权限，当前通过 AI 远程执行 `tests/test-plan.md`（170+ 用例）
- **影响**：本地开发已实现一键门禁，VM 级功能验证仍需在真实 Debian 环境中手动执行
- **建议**：长期评估 VM 测试自动化方案（自托管 GitHub Actions Runner 或 QEMU 容器化 VM），短期保持当前 AI 辅助手动执行模式
- **依赖**：[[P3-2]]（部分满足，仍有模块级集成测试缺口）

---

## 已知的隐式依赖

### 命令→包映射维护

`lib/system/dependency.sh` 中的 `cmd_to_pkg` 和 `cmd_to_level` 关联数组是手动维护的。新增模块使用新命令时需同步更新。

### 依赖分级体系

`lib/system/dependency.sh` 中 `cmd_to_level` 定义了三级依赖：

| 级别 | 名称 | 判断依据 | 处理策略 |
|------|------|---------|---------|
| Tier 0 (`system`) | 系统命令 | Debian 最小化安装自带 | 仅检查，缺失报致命错误 |
| Tier 1 (`tool`) | 工具依赖 | 轻量级软件包，无服务 | 检查 + 自动安装 |
| Tier 2 (`service`) | 服务依赖 | 安装后产生 daemon | 检查 + 提示用户先运行对应模块 |

新增命令映射时必须在 `cmd_to_level` 中声明级别，否则默认按 `tool` 处理。

### 模块元数据解析范围

`lib/system/module-registry.sh` 仅在文件前 30 行扫描 `# @key:`。元数据注释必须放在文件头部，放在 30 行之后会被忽略。

### APT 源格式

项目优先使用 DEB822 格式（`.sources`），兼容传统格式（`.list`）。`sources.sh` 自动迁移传统格式到 DEB822。

---

## 应避免的坑

1. **不要直接 `source` 模块文件** — 部分模块有顶层可执行代码，应在子 shell 中执行或通过 module-runner 调用。注意：`sources.sh` 的顶层检查已于 OP-08 移至 `main()` 函数内，但此原则对未审计模块仍有效。**例外**：已加 `DEBNAS_MODULE_ACTION` 守卫的模块可由 `lib/system/module-probe.sh` 在子 shell 中以 status/plan 动作 source（不执行 main），但守卫只挡住 main，顶层代码仍会执行（ARCHITECTURE §4.5）
2. **不要在模块中自行管理状态** — `module-runner.sh` 自动管理，模块内 `state_mark_success` 是冗余的
3. **不要直接调用 `systemctl`** — 使用 `service_ensure`，它处理了服务不存在、权限不足等边界情况
4. **不要直接写文件** — 使用 `write_file_if_changed`，避免无谓的磁盘写入和服务重启。**注意：** 必须处理其返回值（`|| true`），否则 `set -e` 下内容未变时返回 1 会致命退出
5. **不要在 `rm` 中使用未校验变量** — 必须先 `[[ -n "$var" ]]`
6. **不要忘记 `wget --timeout` / `curl --max-time`** — 防止网络不可达时脚本卡死
7. **不要在 `@depend_modules` 中遗漏依赖** — 使用 `grep -rn '@depend_modules' modules/` 检查依赖链完整性
8. **`@depend_modules` 依赖不会自动执行** — 模块声明依赖其他模块时，只会检查依赖模块是否已完成。若未完成，系统报错提示用户先运行依赖模块，而非自动执行。**此语义已在 OP-02 中与文档同步**
9. **新增 `@depends` 命令时需同步更新 `cmd_to_level`** — 未分级的命令默认视为 `tool`，可能不符合实际（如新增服务级命令会被错误地自动安装）
10. **调用 `log_fatal` 前需确认能否接受进程退出** — 该函数会直接 `exit 1`，在库函数中调用会终止整个脚本。库层应使用 `log_fatal_return`（返回 1 而不退出），由入口层（bin/）决定是否 exit
11. **不要在原目录留 `.bak` / 自定义项目文件位置** — 修改或移走系统文件前用 `debnas_backup_file`（集中到 `/var/backups/debnas`，`write_file_if_changed` 已自动调用）；项目自有文件只放 `lib/system/layout.sh` 定义的 FHS 同名目录（`/etc/debnas`、`/var/lib/debnas`、`/var/log/debnas`、`/usr/local/libexec/debnas`），读通知邮箱用 `notify_email_get`。详见 ARCHITECTURE §七
12. **不要写 `exec {fd}>file 2>/dev/null`** — 不带命令的 `exec` 会把**所有**重定向永久作用于当前 shell：`2>/dev/null` 让之后的日志、报错、`bash -x` 输出全部消失（2026-11-10 `debnas_locked` 初版因此导致 threat-ips disable 等"静默成功"，`_module_probe_wait` 也有同样问题）。要抑制打开失败的报错写 `{ exec {fd}>file; } 2>/dev/null`，或先判断可写
13. **`write_file_if_changed` 的空内容会写成空文件** — 2026-11-10 起空内容合法（旧版 `${2:?}` 会直接结束进程）。调用方若内容可能因上游失败而为空（如 hosts、sources），须自行判断后再调用
14. **并发读改写用 `debnas_locked`** — crontab、debnas.conf、state 的读改写已在 `cron_register*`/`cron_unregister`、`config_write`/`config_delete`、`state_set` 内部持锁；新增同类读改写（共用 `.tmp` 文件 + mv）时同样包一层，同名锁可重入
15. **后台探测要自成进程组** — 仪表盘/探测的 `( … ) &` 用 `bg_group_begin` / `bg_group_end` 包住、用 `bg_group_kill` 终止，否则只杀掉子 shell，其中的 systemctl/apt-get 会成为孤儿持续累积
16. **sudo 不保留 `SSH_CONNECTION`** — `sshd_listen_ports` 的"当前会话端口"兜底在 `sudo debnas` 下通常不生效，自定义端口必须靠 `sshd -T` / 配置文件解析（Port 与 ListenAddress 带端口两种写法都已覆盖）

---

## OP 优化进度总览

以下对照 [docs/audit/optimization-planning.md](docs/audit/optimization-planning.md) 12 项优化主题，标注当前状态。

| 编号 | 优化主题 | 状态 | 说明 |
|------|---------|------|------|
| OP-01 | systemctl 调用统一 | ✅ 完成 | 已通过 P1-1 统一为 `service_ensure` |
| OP-02 | 模块依赖语义同步 | ✅ 完成 | 文档与代码已对齐：依赖不自动执行 |
| OP-03 | 临时文件管理统一 | ✅ 完成 | PID 目录隔离方案，已消除子 shell 泄漏 |
| OP-04 | `write_file_if_changed` 返回值处理 | ✅ 完成 | 全仓库检查 + 修复（11 处） |
| OP-05 | `((var++))` set -e 兼容 | ✅ 完成 | 全仓库检查 + 修复（4 处） |
| OP-06 | 旧项目名 HomeNAS 残留清理 | ✅ 完成 | P2-8 统一为 DebNAS |
| OP-07 | `log_fatal` 行为修复 | ✅ 完成 | 新增 `log_fatal_return`，库层不退出 |
| OP-08 | `sources.sh` 顶层副作用 | ✅ 完成 | `verify_debian_12_13_support` 移入 `main()` |
| OP-09 | CLI 参数校验增强 | ❌ 关闭 | 经评估收益低，不实施 |
| OP-11 | CI 与集成测试闭环 | ✅ 完成 | 转 P3-5，本地一键门禁已闭环（check.sh 整合第 1-5 层），VM 层评估结论已记录 |
| OP-12 | 模块安装顺序文档 | ❌ 关闭 | 模块依赖由拓扑排序自动处理，无需手动文档 |

> **注意**：OP-11 的剩余工作已转入 [P3-5](#p3-5-ci-与集成测试闭环缺失-新增)，以 P3 级别持续追踪，此处不再重复。
