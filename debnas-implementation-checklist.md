# DebNAS 重构施工清单

> 基于 [debnas-optimization-roadmap.md](debnas-optimization-roadmap.md) 生成。
> AI 执行时逐条完成，将 `[ ]` 改为 `[x]` 并填写验证结果。
> 每条任务标注对应路线图章节，确保不遗漏、不跳跃。

---

## Phase 1: 基础设施

> 目标：纯新增文件，不影响现有模块运行。
> 验证点：`bash bin/main.sh` 正常运行（现有功能不受影响）。

### 1.1 创建 lib/system/apt.sh
- [ ] **文件**: `lib/system/apt.sh`
- **函数**: `apt_update_safe()`, `apt_install_safe()`, `apt_remove_safe()`, `apt_wait_for_lock()`, `_apt_lock_available()`
- **参考**: 路线图 §8.2, §8.1 bootstrap.sh source 顺序；编码规范 §2.1, §5, §6
- **验证**: `bash -n lib/system/apt.sh` 零语法错误
- **状态**: ⬜

### 1.2 创建 lib/system/service.sh
- [ ] **文件**: `lib/system/service.sh`
- **函数**: `require_root()`, `service_ensure()`, `sysctl_set()`
- **参考**: 路线图 §8.2；编码规范 §2.1
- **验证**: `bash -n lib/system/service.sh` 零语法错误
- **状态**: ⬜

### 1.3 创建 lib/system/args.sh
- [ ] **文件**: `lib/system/args.sh`
- **函数**: `parse_global_args()`, `print_help()`, `print_usage()`
- **参考**: 路线图 §8.2, §4.2 全局参数列表；编码规范 §2.1
- **验证**: `bash -n lib/system/args.sh` 零语法错误
- **状态**: ⬜

### 1.4 创建 lib/system/state.sh
- [ ] **文件**: `lib/system/state.sh`
- **函数**: `state_get()`, `state_set()`, `state_is_installed()`, `state_is_configured()`, `state_mark_checkpoint()`
- **参考**: 路线图 §10.1, §10.2, §13.1；编码规范 §2.1
- **验证**: `bash -n lib/system/state.sh` 零语法错误
- **状态**: ⬜

### 1.5 创建 lib/system/cron.sh
- [ ] **文件**: `lib/system/cron.sh`
- **函数**: `cron_register()`, `cron_unregister()`, `cron_list()`
- **参考**: 路线图 §11, §8.2；编码规范 §2.1
- **验证**: `bash -n lib/system/cron.sh` 零语法错误
- **状态**: ⬜

### 1.6 创建 lib/system/config.sh
- [ ] **文件**: `lib/system/config.sh`
- **函数**: `config_read()`, `config_write()`, `config_validate()`
- **参考**: 路线图 §16, §8.2；编码规范 §2.1
- **验证**: `bash -n lib/system/config.sh` 零语法错误
- **状态**: ⬜

### 1.7 创建 lib/system/module-registry.sh
- [ ] **文件**: `lib/system/module-registry.sh`
- **函数**: `discover_modules()`, `parse_module_metadata()`, `get_module_list()`, `get_modules_by_category()`, `resolve_module_deps()`
- **参考**: 路线图 §7.1, §7.3；编码规范 §2.1
- **验证**: `bash -n lib/system/module-registry.sh` 零语法错误
- **状态**: ⬜

### 1.8 重写 lib/bootstrap.sh
- [ ] **文件**: `lib/bootstrap.sh`（当前 25 行，重写为完整版）
- **内容**: 见路线图 §8.1 完整代码 — 早期标志解析 + Core/System/UI 分层加载 + cron 检测 + 自动 trap 注册 + module-registry
- **参考**: 路线图 §8.1, §8.2；编码规范 §1.4, §1.5
- **验证**: `bash -n lib/bootstrap.sh` 零语法错误；`source lib/bootstrap.sh` 在 bash 中不报错
- **状态**: ⬜

### 1.9 增强 lib/core/logging.sh
- [ ] **文件**: `lib/core/logging.sh`
- **改动**: 在现有基础上增加文件日志输出支持（`log_to_file()` 或等效机制）
- **参考**: 路线图 §14.2, §8.3
- **验证**: 保留现有所有函数签名不变；`bash -n lib/core/logging.sh` 零语法错误
- **状态**: ⬜

### 1.10 Phase 1 整体验证
- [ ] ShellCheck 对 `lib/` 目录所有文件运行，零 error
- [ ] `bash bin/main.sh` 正常启动交互菜单
- [ ] 现有模块（以 `configure-sources.sh` 为代表）正常执行
- **状态**: ⬜

---

## Phase 2: CLI + 入口

> 目标：`debnas` 命令可用，install.sh 改为自包含引导脚本。
> 依赖：Phase 1 完成。

### 2.1 重写 install.sh
- [ ] **文件**: `install.sh`（重写）
- **功能**: 自包含引导脚本 — root 检查 → `--region` 校验 → wget 下载压缩包 → checksum 校验 → 检测已安装 → 解压到 `/opt/debnas/` → 配置 APT 源 → 安装 `debnas` 到 `/usr/local/bin/` → 创建目录 → 启动菜单
- **支持**: `--region cn|global`（必填）、`--uninstall`（卸载流程）
- **参考**: 路线图 §5.1, §5.3, §9.1, §24.16；编码规范 §1.2, §1.6
- **验证**: `bash -n install.sh`；Dry-run 测试参数解析
- **状态**: ⬜

### 2.2 创建 bin/debnas
- [ ] **文件**: `bin/debnas`
- **功能**: CLI 调度器 — `parse_global_args()` → 路由到 menu/install/update/uninstall/doctor/cron
- **全局参数**: `--debug`, `--dry-run`, `--yes`/`-y`, `--region`, `--lang`, `--version`, `--help`
- **参考**: 路线图 §6, §4.2；编码规范 §1.6
- **验证**: `bash -n bin/debnas`；`./bin/debnas --help` 输出帮助；`./bin/debnas --version` 输出版本
- **状态**: ⬜

### 2.3 创建 bin/module-runner.sh
- [ ] **文件**: `bin/module-runner.sh`
- **功能**: 标准化模块执行引擎 — preflight（root/version/deps/state/dry-run）→ execute → verify → report
- **参考**: 路线图 §6（模块执行标准化流程）；编码规范 §5.4
- **验证**: `bash -n bin/module-runner.sh`
- **状态**: ⬜

### 2.4 重构 bin/main.sh → bin/menu.sh
- [ ] **文件**: `bin/main.sh` → 重构为 `bin/menu.sh`
- **功能**: 交互菜单系统，使用 `discover_modules()` 自动生成菜单；保留原 `bin/main.sh` 作为兼容入口（调用 `bin/debnas menu`）
- **参考**: 路线图 §7.4, §8.3
- **验证**: `bash bin/menu.sh` 正常显示菜单
- **状态**: ⬜

### 2.5 新增 checksum.sha256
- [ ] **文件**: `checksum.sha256`
- **内容**: 仓库压缩包的 SHA256 校验和（install.sh 用于完整性校验）
- **参考**: 路线图 §12, §24.16
- **状态**: ⬜

### 2.6 Phase 2 整体验证
- [ ] `install.sh --region cn` 能完成从下载到安装的全流程
- [ ] `debnas menu` 正常启动菜单
- [ ] `debnas --help` 输出完整帮助
- [ ] `debnas --version` 输出版本信息
- [ ] ShellCheck 零 error
- **状态**: ⬜

---

## Phase 3: 模块标准化

> 目标：30 个模块全部使用 `bootstrap.sh` + 元数据声明 + 自动发现。
> 原则：只改头尾不改逻辑（加元数据头、改 source 语句、加入口守卫）。

### 3.1 模块加元数据（基础系统 + 管理面板）
- [ ] `modules/configure-sources.sh`
- [ ] `modules/install-basic-tools.sh`
- [ ] `modules/install-cockpit.sh`
- [ ] `modules/install-vm-components.sh`
- [ ] `modules/enable-cockpit-external.sh`
- [ ] `modules/disable-cockpit-external.sh`
- [ ] `modules/set-cockpit-network.sh`
- [ ] `modules/cockpit-auto-bing-wallpaper.sh`
- **改动**: 
  - 添加 `@module`/`@name`/`@category`/`@depends`/`@version`/`@order` 元数据头
  - 按路线图 §7.1 的映射表设置 `@order` 值（基础系统: 10-19，管理面板: 30-39）
  - 切换为 `source bootstrap.sh`
  - 加入口守卫
- **验证**: 每个文件 `bash -n` 零语法错误
- **状态**: ⬜

### 3.2 模块加元数据（安全防护 + 通知服务）
- [ ] `modules/configure-security.sh`
- [ ] `modules/install-firewall.sh`
- [ ] `modules/install-fail2ban.sh`
- [ ] `modules/block-threat-ips.sh`
- [ ] `modules/setup-mail-account.sh`
- [ ] `modules/enable-login-mail.sh`
- [ ] `modules/disable-login-mail.sh`
- **改动**: 
  - 同上
  - 安全防护模块 `@order` 范围: 40-49
  - 通知服务模块 `@order` 范围: 60-69
- **验证**: 每个文件 `bash -n` 零语法错误
- **状态**: ⬜

### 3.3 模块加元数据（容器管理 + 系统工具）
- [ ] `modules/install-docker-ce.sh`
- [ ] `modules/add-docker-mirror.sh`
- [ ] `modules/install-docker-apps.sh`
- [ ] `modules/backup-restore.sh`
- [ ] `modules/check-system-compatibility.sh`
- [ ] `modules/check-system-updates.sh`
- [ ] `modules/install-service-query.sh`
- [ ] `modules/auto-update-hosts.sh`
- [ ] `modules/install-tunnel.sh`
- [ ] `modules/acl-manager.sh`
- [ ] `modules/bbr-algo-manager.sh`
- **改动**: 
  - 同上
  - 容器管理模块 `@order` 范围: 50-59
  - 系统工具模块 `@order` 范围: 70-79
- **验证**: 每个文件 `bash -n` 零语法错误
- **状态**: ⬜

### 3.4 模块加元数据（一键部署）
- [ ] `modules/setup-homenas-basic.sh`
- [ ] `modules/setup-homenas-secure.sh`
- **改动**: 
  - 同上 + 改为读取 `config/presets/` 配置文件
  - 一键部署模块 `@order` 范围: 80-89
- **参考**: 路线图 §24.1
- **验证**: 每个文件 `bash -n` 零语法错误
- **状态**: ⬜

### 3.5 菜单切换为自动发现
- [ ] 确认 `bin/menu.sh` 中菜单由 `discover_modules()` 生成，不再硬编码 `MODULE_DESC`/`MENU_MAP`
- [ ] 确认 `debnas install <模块名>` 能路由到正确的模块文件
- [ ] 确认菜单排序按 `@order` 值升序排列，与路线图 §7.1 映射表一致
- **验证**: 
  - 运行 `debnas menu`，所有 25 个菜单项正确显示
  - 检查菜单顺序：基础系统(10-19) → 管理面板(30-39) → 安全防护(40-49) → 容器管理(50-59) → 通知服务(60-69) → 系统工具(70-79) → 一键部署(80-89)
- **状态**: ⬜

### 3.6 Phase 3 整体验证
- [ ] `debnas menu` 显示完整的 7 组分类菜单
- [ ] `debnas install configure-sources` 能正确执行模块
- [ ] 所有 30 个模块 `bash -n` 零语法错误
- [ ] ShellCheck 零 error
- **状态**: ⬜

---

## Phase 4: 幂等性 + 配置 + Doctor

> 目标：模块支持重复执行安全，统一配置管理，诊断命令可用。
> 依赖：Phase 3 完成。

### 4.1 核心模块幂等性检查
- [ ] `configure-sources.sh` — 检测 APT 源是否已配置，是则跳过
- [ ] `install-docker-ce.sh` — 检测 Docker 是否已安装，是则跳过或询问接管
- [ ] `install-cockpit.sh` — 检测 Cockpit 是否已安装，是则跳过
- [ ] `install-firewall.sh` — 检测 firewalld 是否已运行，是则跳过
- [ ] `install-fail2ban.sh` — 检测 fail2ban 是否已安装，是则跳过
- [ ] `configure-security.sh` — 检测安全配置是否已应用，是则跳过
- **改动**: 模块 main() 开头调用 `state_is_installed()`；执行成功后调用 `state_set()` + `state_mark_checkpoint()`
- **参考**: 路线图 §10.2, §19.2；编码规范 §1.6
- **状态**: ⬜

### 4.2 统一配置管理
- [ ] 创建 `config/presets/basic.conf` — 基础环境模块列表
- [ ] 创建 `config/presets/secure.conf` — 安全环境模块列表
- [ ] 创建 `config/debnas.conf.default` — 全局默认配置（region, log_level 等）
- [ ] 确认为 `config_read()`/`config_write()` 编写逻辑，支持模块读写 `/etc/debnas/conf.d/<module>.conf`
- **参考**: 路线图 §16, §24.1, §24.3
- **状态**: ⬜

### 4.3 debnas doctor 诊断命令
- [ ] **文件**: `bin/doctor.sh`（或在 `module-runner.sh` 中实现）
- **功能**: 系统兼容性检查 + 配置一致性检查 + 网络连通性检查 + DebNAS 自身状态
- **原则**: 仅报告，不自动修改（路线图 §15.2）
- **参考**: 路线图 §15
- **验证**: `debnas doctor` 输出诊断报告
- **状态**: ⬜

### 4.4 Phase 4 整体验证
- [ ] 重复执行已安装模块 → 正确跳过
- [ ] 中断后重新执行 → 从 checkpoint 继续
- [ ] `debnas doctor` 输出完整诊断报告
- [ ] ShellCheck 零 error
- **状态**: ⬜

---

## Phase 5a: Cron 统一

> 目标：cron 代码路径统一，所有模块通过框架管理定时任务。
> 依赖：Phase 4 完成。
> 风险：中等（仅改动 cron 相关代码）

### 5a.1 Cron 框架统一
- [ ] 用 `lib/system/cron.sh` 的 API 替换 `block-threat-ips.sh` 中的 cron 逻辑
- [ ] 用 `lib/system/cron.sh` 的 API 替换 `auto-update-hosts.sh` 中的 cron 逻辑（消除数十个 `if CRON_MODE` 守卫）
- [ ] 用 `lib/system/cron.sh` 的 API 替换 `check-system-updates.sh` 中的 cron 逻辑
- [ ] 用 `lib/system/cron.sh` 的 API 替换 `cockpit-auto-bing-wallpaper.sh` 中的 cron 逻辑
- **改动**: 模块移除自行复制脚本、管理 crontab 的代码；元数据声明 `@cron: true` + `@cron_schedule`
- **验证**: `debnas cron list` 能查看已注册任务；`debnas cron add <模块>` 正确写入 crontab；cron 执行后日志正常
- **状态**: ⬜

### 5a.2 Phase 5a 整体验证
- [ ] `debnas cron add` 对 4 个模块均正常工作
- [ ] `debnas cron remove` 能正确移除定时任务
- [ ] ShellCheck 零 error
- **状态**: ⬜

---

## Phase 5b: 大模块拆分

> 目标：5 个大模块拆分为目录结构，提升代码可读性和可维护性。
> 依赖：Phase 5a 完成。
> ⚠️ 最高风险阶段，每个模块拆分后需 Git commit 并验证。

### 5b.1 拆分 block-threat-ips.sh → 目录模块（试点）
- [ ] 创建 `modules/block-threat-ips/module.sh`（入口 + 菜单）
- [ ] 创建 `modules/block-threat-ips/download.sh`（下载 + 解析威胁列表）
- [ ] 创建 `modules/block-threat-ips/ipset.sh`（ipset 管理）
- [ ] 创建 `modules/block-threat-ips/firewall.sh`（firewalld 集成）
- [ ] 创建 `modules/block-threat-ips/cron.sh`（定时更新逻辑）
- [ ] 创建 `modules/block-threat-ips/config/ipthreat.conf.default`
- [ ] 保留旧文件 `modules/block-threat-ips.sh` 作为兼容层（source 新模块入口）
- **参考**: 路线图 §7.2
- **验证**: 旧路径和新路径功能等价；cron 任务正常执行
- **状态**: ⬜

### 5b.2 拆分 auto-update-hosts.sh → 目录模块
- [ ] 创建 `modules/auto-update-hosts/module.sh`（入口 + 菜单）
- [ ] 创建 `modules/auto-update-hosts/dns-resolve.sh`（多 DNS 并行解析）
- [ ] 创建 `modules/auto-update-hosts/connectivity.sh`（三级连通性检测）
- [ ] 创建 `modules/auto-update-hosts/hosts-manager.sh`（/etc/hosts 读写）
- [ ] 创建 `modules/auto-update-hosts/cron.sh`（定时更新逻辑）
- [ ] 保留旧文件作为兼容层
- **参考**: 路线图 §7.2, §24.5（CPU 自适应并发）
- **验证**: 旧路径和新路径功能等价
- **状态**: ⬜

### 5b.3 拆分 backup-restore.sh → 目录模块
- [ ] 创建 `modules/backup-restore/module.sh`（入口 + 菜单）
- [ ] 创建 `modules/backup-restore/backup.sh`（备份逻辑）
- [ ] 创建 `modules/backup-restore/restore.sh`（恢复逻辑）
- [ ] 创建 `modules/backup-restore/verify.sh`（完整性校验）
- [ ] 保留旧文件作为兼容层
- **参考**: 路线图 §7.2
- **验证**: 旧路径和新路径功能等价
- **状态**: ⬜

### 5b.4 拆分 cockpit-auto-bing-wallpaper.sh → 目录模块
- [ ] 创建 `modules/cockpit-auto-bing-wallpaper/module.sh`（入口 + 菜单）
- [ ] 创建 `modules/cockpit-auto-bing-wallpaper/download.sh`（壁纸下载）
- [ ] 创建 `modules/cockpit-auto-bing-wallpaper/configure.sh`（Cockpit 集成）
- [ ] 创建 `modules/cockpit-auto-bing-wallpaper/cron.sh`（定时更新）
- [ ] 保留旧文件作为兼容层
- **参考**: 路线图 §7.2
- **验证**: 旧路径和新路径功能等价
- **状态**: ⬜

### 5b.5 拆分 check-system-updates.sh → 目录模块
- [ ] 创建 `modules/check-system-updates/module.sh`（入口 + 菜单）
- [ ] 创建 `modules/check-system-updates/check.sh`（更新检查逻辑）
- [ ] 创建 `modules/check-system-updates/notify.sh`（邮件通知逻辑）
- [ ] 创建 `modules/check-system-updates/cron.sh`（定时检查逻辑）
- [ ] 保留旧文件作为兼容层
- **参考**: 路线图 §7.2
- **验证**: 旧路径和新路径功能等价
- **状态**: ⬜

### 5b.6 Phase 5b 整体验证
- [ ] 5 个目录模块在菜单和 CLI 中均能正常访问
- [ ] 旧文件兼容层可用
- [ ] 所有模块的 cron 任务正常执行
- [ ] ShellCheck 零 error
- **状态**: ⬜

---

## Phase 6: CI/CD + 测试

> 目标：每次 push 自动运行 ShellCheck，基础库有单元测试。
> 依赖：Phase 1-5 完成。

### 6.1 搭建 BATS 测试框架
- [ ] 安装 BATS（`git submodule add` 或系统包）
- [ ] 创建 `tests/run.sh`（测试入口脚本）
- [ ] 创建 `tests/helpers/common-setup.bash`（共享测试工具函数）
- **状态**: ⬜

### 6.2 基础库单元测试
- [ ] `tests/unit/lib/test-constants.bats` — 错误码定义
- [ ] `tests/unit/lib/test-colors.bats` — NO_COLOR, 终端检测
- [ ] `tests/unit/lib/test-logging.bats` — 日志级别、输出格式
- [ ] `tests/unit/lib/test-args.bats` — 参数解析
- [ ] `tests/unit/lib/test-config.bats` — 配置读写
- [ ] `tests/unit/lib/test-state.bats` — 状态追踪
- [ ] `tests/unit/lib/test-dependency.bats` — cmd 到 pkg 映射
- [ ] `tests/unit/lib/test-apt.bats` — apt_update_safe, apt_install_safe
- [ ] `tests/unit/lib/test-service.bats` — require_root, service_ensure
- **状态**: ⬜

### 6.3 配置 GitHub Actions
- [ ] 创建 `.github/workflows/ci.yml`
- [ ] **Job 1: ShellCheck** — `--severity=error` 检查全部 .sh 文件
- [ ] **Job 2: BATS Unit** — 运行单元测试
- [ ] **Job 3: BATS Integration** — 在 Debian 容器中运行集成测试（如已有测试 VM）
- **参考**: 路线图 §22
- **验证**: push 后 Actions 正常触发并通过
- **状态**: ⬜

### 6.4 关键模块集成测试
- [ ] `tests/integration/test-install-basic-tools.bats`
- [ ] `tests/integration/test-configure-sources.bats`
- [ ] `tests/integration/test-install-firewall.bats`
- [ ] `tests/integration/test-block-threat-ips-download.bats`
- [ ] 集成测试仅在测试 VM 中运行（路线图 §18.1）
- **状态**: ⬜

### 6.5 Phase 6 整体验证
- [ ] `tests/run.sh` 全部通过
- [ ] GitHub Actions CI 绿灯
- **状态**: ⬜

---

## Phase 7: 文档与社区

> 目标：达到成熟开源项目标准。
> 依赖：Phase 1-6 完成。

### 7.1 项目元文件
- [ ] 创建 `CHANGELOG.md`（基于 conventional commits，使用 git-cliff 自动生成）
- [ ] 创建 `CONTRIBUTING.md`（代码贡献指南，引用编码规范）
- [ ] 创建 `SECURITY.md`（安全漏洞报告流程）
- [ ] 创建 `CODE_OF_CONDUCT.md`（Contributor Covenant 模板）
- **参考**: 路线图 §24.12, §22, §24.9, §24.10
- **状态**: ⬜

### 7.2 GitHub 社区配置
- [ ] 创建 `.github/ISSUE_TEMPLATE/bug_report.md`
- [ ] 创建 `.github/ISSUE_TEMPLATE/feature_request.md`
- [ ] 创建 `.github/PULL_REQUEST_TEMPLATE.md`
- **状态**: ⬜

### 7.3 i18n 框架
- [ ] 创建 `lib/i18n/zh.sh`（中文消息，当前内容的提取和整理）
- [ ] 创建 `lib/i18n/en.sh`（英文消息，至少覆盖菜单和核心日志）
- [ ] `bootstrap.sh` 根据 `--lang` 参数加载对应语言文件
- [ ] 缺失翻译 → 显示中文 + `[未翻译]` 标记
- **参考**: 路线图 §21
- **状态**: ⬜

### 7.4 英文文档
- [ ] 创建 `docs/en/README.md`（英文项目概述 + 快速开始）
- [ ] 创建 `docs/en/installation.md`（详细安装指南）
- [ ] 创建 `docs/en/modules/`（各模块英文说明）
- **参考**: 路线图 §24.8
- **状态**: ⬜

### 7.5 工程配置文件
- [ ] 创建 `.editorconfig`（统一缩进、换行符、字符集）
- [ ] 创建 `.shellcheckrc`（ShellCheck 项目级配置）
- **状态**: ⬜

### 7.6 Phase 7 整体验证
- [ ] `debnas --lang en menu` 英文菜单正常显示
- [ ] `debnas --lang zh menu` 中文菜单正常显示
- [ ] 所有 `.md` 文件无死链
- [ ] GitHub 仓库设置中启用 Issue/PR 模板
- **状态**: ⬜

---

## 执行记录

| Phase | 开始时间 | 完成时间 | 状态 | 备注 |
|-------|---------|---------|------|------|
| Phase 1 | | | ⬜ | |
| Phase 2 | | | ⬜ | |
| Phase 3 | | | ⬜ | |
| Phase 4 | | | ⬜ | |
| Phase 5 | | | ⬜ | |
| Phase 6 | | | ⬜ | |
| Phase 7 | | | ⬜ | |

---

## 每个 Phase 开始前的检查

- [ ] 确认当前 `dev` 分支已 commit 所有改动
- [ ] 确认前一 Phase 验证全部通过
- [ ] 创建备份分支 `backup/pre-phase-N`

## 每个 Phase 完成后的检查

- [ ] `bash -n` 对所有改动文件零语法错误
- [ ] ShellCheck `--severity=error` 零问题
- [ ] `debnas menu` 正常显示（Phase 2+）
- [ ] Git commit 消息遵循 conventional commits 格式
