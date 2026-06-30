# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 格式。

分类：
- `Added` — 新增功能
- `Changed` — 功能变更
- `Deprecated` — 即将废弃
- `Removed` — 已移除
- `Fixed` — Bug 修复
- `Security` — 安全修复

---

## [未发布]

> 当前开发分支：`refactor/debnas-v2`

### Added
- 新增 CLI 调度器 `bin/debnas`，支持子命令路由（`list`、`run`、`menu`、`doctor`、`help` 等）
- 新增 `debnas run <模块>` 子命令，支持直接执行模块
- 新增模块短名称支持（如 `cockpit` 代替 `install-cockpit`）
- 新增模块元数据系统（`@module`、`@order`、`@depends` 等注释标记）
- 新增统一库系统 `lib/`：日志、配置、状态、服务、APT、Cron、依赖检测、临时文件等公共函数
- 新增幂等性基础设施：`write_file_if_changed`、`service_ensure`、`apt_install_packages` 等核心抽象
- 新增统一配置管理（`config_read/write/delete`）
- 新增统一 Cron 管理（`cron_register/cron_unregister`，含表达式校验 + 冲突去重）
- 新增 `doctor` 诊断子命令
- 新增 BATS 测试框架和单元/集成测试
- 新增 `tests/check.sh` 统一质量检查入口（ShellCheck + 语法 + 测试 + 元数据冒烟）
- 新增 `mail-account.sh` SMTP 多提供商支持（QQ/163/126/新浪/阿里云/Gmail/Outlook/Yahoo）
- 新增 `hosts-sync` 域名配置文件支持（`/etc/debnas/conf.d/hosts-sync-domains.conf`）
- 新增 `wallpaper` API 地址配置化支持（`debnas.conf` + 自包含副本兼容）
- 新增 3 个 BATS 单元测试文件（cron/tempfile/utils），覆盖率从 9 个文件提升至 12 个
- 修复 `tests/run.sh` 缺少 `--recursive` 标志导致子目录测试未被发现
- 新增日志等级标签（4 级：INFO/WARN/ERROR/FATAL），全部直接输出不做阈值过滤

### Changed
- 重构测试报告模板（§十二）：新增执行摘要、测试仪表盘、P0/P1/P2 失败分级、9 维度失败详情、发布门禁逐项判定、跳过解除条件、建议与后续行动等章节，支持三类读者（领导/开发者/AI）分层阅读
- 项目结构从单体脚本重构为模块化架构（`modules/` + `lib/` + `bin/`）
- 28 个模块全部重命名为行业标准短名称（如 `install-docker` → `docker-ce`）
- 4 个复杂模块拆分为目录模块：`sys-patches/`、`hosts-sync/`、`threat-ips/`、`wallpaper/`
- `docker-compose/` 目录重命名为 `compose/`
- 模块状态由 `bin/module-runner.sh` 统一管理，模块不再自行调用 `state_mark_success`
- 统一 28 个模块入口点为 `main() { ... }; main "$@"` 模式
- 统一 Bootstrap 加载：15 个模块从 `bootstrap-core.sh` 切换为 `bootstrap.sh`
- 删除全部 28 处模块内冗余 `state_mark_success` 调用
- 重构日志等级系统：消除 `CURRENT_LOG_LEVEL` 快照变量，`should_log` 直接从 `LOG_LEVEL` 环境变量读取（消除双重状态）
- 9 处幂等跳过说明从 `log_debug` 升级为 `log_info`（"服务已在运行"、"配置未变更"等）
- 删除日志过滤模式：移除 `LOG_LEVEL` 变量、`should_log` 门控、`set_log_level`/`get_log_level` 函数，4 级日志全部直接输出
- 8 处内部 `log_debug` 升级为 `log_info`/`log_action`（依赖解析、安装进度），其余 18 处内部细节删除

### Removed
- 删除 `--debug` 和 `--quiet` CLI 全局参数
- 删除 `--xtrace` 执行跟踪模式
- 删除 `docker-backup` 模块（高风险恢复操作，含 18 个已知 Bug）
- 删除 `dockge` 应用（简化为 Portainer 单方案）
- 删除 DEBUG 日志等级和 `log_debug` 函数

### Fixed
- 修复 `bootstrap.sh` 重复加载导致 `_DEBNAS_BOOTSTRAPPED` 变量泄漏
- 修复菜单清理陷阱中 `tmp_dir` 未绑定变量
- 修复 `doctor` 脚本在 `set -e` 下的算术退出错误
- 修复 `module-runner` 递归依赖调用时的环境变量污染
- 修复 CLI 参数序列化问题（IFS 分隔符与参数拼接）
- 修复 `bin/debnas` 符号链接路径解析
- 修复最小化 Debian 安装兼容性（无 APT 源、无 wget）
- 修复 `install.sh` 和 `README.md` 中过时的路径引用
- 修复 `wallpaper` 模块中残留的死代码
- 修复 `tailscale.sh`、`firewall.sh`、`wallpaper/module.sh` 中 `write_file_if_changed` 裸调用未处理返回值（内容不变时 `set -e` 导致脚本退出）
- 修复 `sys-patches` 和 `hosts-sync` 交互菜单不支持 `--yes` 模式（`DEBNAS_FORCE_YES` 已定义但无模块消费）
- 实际创建 `tests/check.sh` 统一质量检查入口（此前仅记录在 CHANGELOG 中，文件未创建）
- 修复 `threat-ips/cron.sh` 中 `update_threat_ips` 函数重复定义（B1）
- 修复 `tailscale.sh` 函数名错误：`tempfile_create` → `create_temp_file`（F-80）
- 修复 `threat-ips/module.sh` 中与 `ipset.sh` 重复的 6 个函数定义（B2）
- 修复 `threat-ips` 未声明 `@depend_modules: firewall` 依赖（D1）
- 修复 4 个交互模块缺少 `DEBNAS_CRON_MODE` 守卫的问题（C3）
- 修复 `install.sh` 与 `installer.sh` REPO URL 双处定义缺少同步注释
- 修复 `verify_architecture_support` 因 `IFS=$'\n\t'` 导致空格分隔参数无法正确分词
- 修复 `cron_register` 未传递 `DEBNAS_CRON_MODE=1` 导致 cron 执行与交互模式无法区分
- 清理 wallpaper 自包含副本设计（项目永久安装于 /opt/，不再需要 /etc/cockpit/branding/ 副本）
- 清理 sys-patches 独立脚本生成（`~/.system-update-checker.sh`）和旧版 `/etc/cron.d/` 机制
- 清理 threat-ips cron 模式下重复的 tempfile 函数定义（统一使用 lib/system/tempfile.sh）
- 修复 `docker-ce.sh` 幂等性失败：`write_file_if_changed` 返回值未处理，文件内容不变时 `set -e` 下脚本异常退出
- 修复配置文件 `log_level=` 不生效的问题（`CURRENT_LOG_LEVEL` 初始化早于配置读取，导致快照不同步）
- 修复 `log_fatal` 仅打印消息不退出程序的问题
- 统一 `systemctl` 直接调用 → `service_ensure`（bbr/wallpaper/docker-mirror/firewall 共 5 处，P1-1）
- 统一 `tee` 写入 → `write_file_if_changed` 幂等文件写入（docker-ce/tailscale 共 3 处，P1-2）
- 补充 `wget`/`curl` 超时参数，防止网络不可达时脚本卡死（installer/threat-ips/cockpit-45drives/wallpaper 共 6 处，P1-3）
- 补全模块依赖声明 `login-mail-on/off` → `mail-account`，防止依赖链断裂（P1-4）
- 重构 `docker-ce.sh` 内联逻辑为 5 个独立函数（install_prerequisites/download_gpg/write_source/install_packages/add_user），提升可读性和可测试性（P2-1）/
- 清理 `threat-ips` 模块：`log_message` 改用全局日志通道 + 移除重复章节标题 + 简化 init 函数（P2-2）
- 简化 `hosts-sync` 临时目录管理，复用 `tempfile.sh` 的 `init_temp_dir`（P2-3）
- 修正 `acl-manager.sh` 旧项目名残留 `homenas` → `debnas`（P2-4）
- 修复 3 处残缺/模糊的 `log_debug` 消息（cron.sh、cockpit-net.sh、state.sh）
- 补全 `service-query.sh` 和 `vm-components.sh` 模块依赖声明 `@depend_modules: cockpit`，防止依赖链断裂（P1-5/P1-6）
- 统一 `acl-manager.sh` 和 `docker-ce.sh` 直接 `apt install` 调用为 `apt_install_packages`/`apt_install_safe`，去掉 `2>/dev/null || true` 吞错（P2-5/P2-6）
- 统一 `service-query.sh` 直接 `systemctl start` 调用为 `service_ensure`，去掉 `|| true` 吞错（P2-7）
- 清理 4 处旧项目名 `HomeNAS` 残留（cockpit.sh ×2、wallpaper/module.sh ×2），统一为 `DebNAS`（P2-8）
- 统一 `wallpaper/module.sh` 中 2 处 `echo >`/`printf >` 直接文件写入为 `write_file_if_changed` 幂等写入（P2-9）

---

## [v3.0.3] — 2025-03-28

### Added
- 新增备份/恢复模块
- 新增登录邮件通知开关（启用/禁用）
- 新增邮件账户设置模块

### Changed
- 备份/恢复模块依赖检测统一调用公共库
- Fail2ban 模块邮件通知逻辑优化
- Cockpit SMB 文件共享集成（cockpit-file-sharing v4.6.0）

### Fixed
- 威胁 IP 封禁模块多项关键 Bug 修复（IP 提取逻辑、防火墙重载机制）
- Debian 13 下 Cockpit 文件管理器兼容性调整
- 批量修复已知问题，提升整体健壮性

---

## [v3.0.2] — 2025-03-01

### Added
- 统一入口脚本 `homenas.sh`（合并 Debian 和 Ubuntu 两个版本）

### Changed
- Cockpit 安装脚本更新（navigator、file-sharing 插件）
- 网络管理器设置脚本重构
- 容器部署脚本优化

### Removed
- 删除独立的 `debian-homenas.sh` 和 `ubuntu-homenas.sh`（合并为 `homenas.sh`）

---

## [v3.0.1] — 2025-02-17

### Added
- 新增 Hosts 自动更新脚本（基于下载 hosts 文件方式）

### Changed
- Docker 镜像加速地址更新

### Fixed
- 服务状态检查脚本修复

---

## [v3.0.0] — 2024-12-02

### Added
- 新增统一启动器 `start.sh`
- 新增 Tailscale 内网穿透模块
- 新增 Fail2ban 入侵防御模块
- 新增 Docker Hub 镜像加速模块
- 新增服务状态检查工具
- 新增邮件配置模块
- 新增登录通知模块

### Changed
- 软件源配置脚本重构
- Docker 安装脚本重构

---

## [v2.0.0] — 2024-10-30

### Added
- 新增 Ubuntu 系统支持（`ubuntu-homenas.sh`）
- 新增软件源自动配置脚本
- 新增必要软件安装脚本
- 新增网络管理器设置脚本
- 新增容器部署脚本（Docker Compose 应用）
- 新增服务状态检查脚本

### Changed
- 项目从单文件 `debian-homenas.sh` 拆分为多个独立脚本

---

## [v1.0.0] — 2024-09-23

### Added
- 初次发布：Debian 12 家庭 NAS 一键配置脚本
- 系统初始化（软件源、基础工具、系统安全）
- Cockpit Web 管理面板安装
- Docker CE 安装
- 系统安全加固脚本
