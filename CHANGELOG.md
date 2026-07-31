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
- 一级菜单新增“关于项目”入口，进入后展示本项目概况
- Phase 1 UI 基础层：新增 `COLOR_DIM`（亮黑/灰色）ANSI 颜色变量
- Phase 1 UI 基础层：新增 `print_dim()` / `print_accent()` 辅助输出函数
- Phase 1 UI 基础层：新增 `log_debug()` 调试日志（DEBNAS_DEBUG=1 时输出）
- Phase 1 UI 基础层：新增 `lib/ui/footer.sh` — `ui_footer()` 底栏组件
- Phase 2 菜单交互：新增 `lib/ui/header.sh` — `ui_header()` 居中标题组件
- Phase 2 菜单交互：新增 `lib/ui/layout.sh` — `ui_screen_init()`/`ui_screen_clear()`/`ui_cursor_show()` 布局管理
- Phase 2 菜单交互：新增 `read_key()` 方向键单键捕获（ANSI/应用模式/Vim jk 兼容/数字 1-9）
- Phase 2 菜单交互：新增 `ui_menu()` 交互式菜单（方向键导航 + `>` 光标指示 + 局部刷新）
- 新增 3 个模块集成测试文件（test-docker-ce.bats、test-firewall.bats、test-sources.bats），集成测试从 3 文件 35 用例扩展至 6 文件 108 用例（P3-2）
- 扩展 Docker Compose 元数据系统：新增 `@description`、`@category`、`@require` 字段，支持递归依赖解析与循环依赖检测
- 新增 `run_submenu()` 统一交互式子菜单循环，消除 4 个模块中的重复菜单逻辑
- 新增模块注册表架构检测（`arch` 字段），自动跳过不兼容当前 CPU 架构的模块
- 新增 GitHub Actions CI：Debian 版本矩阵（12/13）、集成测试、Smoke 质量门禁
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
- 新增依赖分级检查函数 `check_dependencies_by_level()` / `get_dependency_level()` / `check_system_deps()` / `check_and_install_tool_deps()` / `check_service_deps()`
- 新增模块依赖就绪检查函数 `check_module_deps_ready()`（检查依赖模块是否已完成，不自动执行）
- 新增 `ensure_module_deps()` 组合依赖检查函数（供模块在操作时调用，合并命令依赖+模块依赖检查）
- 新增 `@interactive: true` 模块元数据标记（区分交互式/非交互式模块）
- 新增部署方案集成测试 `tests/integration/test-solution.bats`（8 个用例：方案解析、模块排序、stdin 隔离、失败中断、空格 trim）

### Changed
- 关于项目改为直接打印概况后返回一级菜单，并优化终端排版
- Phase 1 UI 基础层：日志标签统一为 7 字符宽度（`[SUCCESS]→[OK]`、`[FAIL]→[ERROR]`、`[WARNING]→[WARN]`、`[ACTION]→[INFO]`）
- Phase 1 UI 基础层：`get_ui_color highlight` 从 COLOR_MAGENTA 迁移为 COLOR_CYAN
- Phase 1 UI 基础层：`log_fatal` / `log_fatal_return` 颜色从 COLOR_MAGENTA 改为 COLOR_RED
- Phase 1 UI 基础层：`bin/menu.sh` 横幅精简（移除 QQ/作者/GitHub/温馨提示）
- Phase 2 菜单交互：`bin/menu.sh` 主循环重写为方向键导航（`main_menu_loop` 替代 `auto_menu_loop`）
- Phase 2 菜单交互：`lib/bootstrap.sh` 增加 `header.sh`/`footer.sh`/`layout.sh` 加载
- 质量门禁 check.sh 整合第 5 层集成测试，实现本地一键完整质量闭环（P3-5）
- `install.sh` 编码规范对齐主工程：`set -eo pipefail` → `set -euo pipefail` + `IFS=$'\n\t'`
- `hosts-sync` 依赖检查统一为 `install_missing_dependencies` 单次调用，移除最后的手动 `command -v` 循环
- `cockpit-ext`、`login-mail` 从单文件模块迁移为目录模块（`actions.sh` 拆分交互逻辑）
- `docker-apps`、`service-query` 自动发现 `compose/` 目录，消除硬编码容器列表与 URL 映射
- `threat-ips` 移除 `log_message()` 过度封装，直接使用 `log_*` 标准函数
- 模块菜单分类排序统一为单一数据源（`CATEGORY_ORDER` 数组）
- CLAUDE.md 深度精简，收缩职责范围，减少与架构文档的事实重复
- 依赖安装改为三级分类处理：Tier 0 系统命令仅检查、Tier 1 工具依赖自动安装、Tier 2 服务依赖提示用户（不再自动安装 firewalld/docker.io/exim4 等）
- 模块依赖（`@depend_modules`）改为检查+提示模式：依赖模块未就绪时报错提示用户先运行，不再自动递归执行
- 交互式模块依赖检查改为延迟模式：进入菜单时不再显示依赖检查信息，仅在用户选择具体操作时才执行检查（threat-ips、hosts-sync、sys-patches、bbr）
- threat-ips `check_services()` 服务未运行时改为自动启动（firewalld / cron），而非仅提示用户手动处理
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
- `bin/doctor.sh`：`state_list_installed` 替代内联 glob 循环
- `lib/system/args.sh`：`config_read` 替代直接 `grep` 配置文件

### Deprecated
- Phase 1 UI 基础层：`print_highlight()` 弃用（MAGENTA 已禁用，改用 `print_accent`）
- Phase 1 UI 基础层：`print_separator()` 弃用（设计规范：用空行呼吸感替代分隔线）
- Phase 1 UI 基础层：`print_submenu_title()` 弃用（Phase 2 由 `ui_header` + 面包屑替代）
- Phase 1 UI 基础层：`print_menu_item()` / `print_main_menu_item()` 弃用（Phase 2 由 `ui_menu` 替代）
- Phase 1 UI 基础层：`print_banner_text()` 弃用（Phase 2 由 `ui_header` 替代）
- Phase 2 菜单交互：`show_menu()` / `show_menu_with_border()` / `get_user_choice()` / `run_submenu()` 弃用（由 `ui_menu` 替代，旧函数保留向后兼容）

### Removed
- 移除多语言（i18n）支持：删除 `lib/i18n/`、`--lang` 参数与 `lang` 配置项，界面固定为中文
- 移除无引用的错误码常量（`ERROR_CONFIG`、`ERROR_PARAMETER`）及兼容别名（`GENERAL`/`DEPENDENCY`/`CONFIG`/`PERMISSION`/`PARAMETER`/`UNSUPPORTED_OS`）
- 移除死函数 `config_validate`、`config_read_global`、`config_write_global`
- 移除死函数 `get_user_multiple_choice`、`show_confirm`、`show_menu_with_description`
- 删除 `--debug` 和 `--quiet` CLI 全局参数
- 删除 `--xtrace` 执行跟踪模式
- 删除 `docker-backup` 模块（高风险恢复操作，含 18 个已知 Bug）
- 删除 `dockge` 应用（简化为 Portainer 单方案）
- 删除 DEBUG 日志等级和 `log_debug` 函数

### Fixed
- 修复模块内使用 `$(ui_menu)` 捕获菜单渲染导致选择失效，统一改用 `UI_MENU_RESULT_FILE`（sys-patches/wallpaper/hosts-sync/login-mail/bbr/threat-ips/cockpit-ext/acl-manager）
- 修复非 TTY 菜单 EOF 死循环：`read_key` 返回 EOF，`ui_menu` 收到后统一退出
- 修复 `ui_menu` 在非 TTY/模块子菜单中 `LINES` 未绑定导致崩溃
- 修复 `ui_input` 非交互模式忽略管道输入，导致 `mail-account`、`acl-manager` 等模块自动化输入失效
- 修复 `mail-account` 输入无效/EOF 时无限循环，增加重试上限并返回错误
- 修复 `wallpaper` 非交互启用时 cron 表达式未使用 `@cron_schedule` 默认值
- 修复 `acl-manager` 操作失败未传播，模块退出码与 state 误标记为成功
- 修复菜单底部版本号显示为 `vv2026.06` 的问题：`DEBNAS_VERSION` 已含 `v` 前缀，footer/快照不再重复拼接
- 修复快捷键语义：返回统一为 ESC，退出仅限一级菜单（子菜单按 Q 静默忽略，不再返回上级或直接退出）
- 修复退出时重复打印菜单快照：当前菜单已保留在屏幕，退出时不再额外打印快照
- 修复菜单切换时顶部间隙逐次增大：光标保存位置在菜单底行下一行，清除菜单区需上移完整菜单高度
- 修复菜单切换时旧菜单未原位清除导致时间线反复产生菜单记录，切换菜单改为整块清除后重绘
- 修复菜单循环每次模块执行后固定等待约 2 秒的问题：移除模块返回后的 `sleep 1`，并去掉 DSR 光标查询（改为使用已保存光标位置清除菜单区）
- 修复 Phase 2 `ui_menu` 调用方式缺陷：`$()` 命令替换捕获所有 stdout 导致菜单渲染不可见，改为 `UI_MENU_RESULT_FILE` 临时文件传递选中索引
- 修复 `build_active_categories` 最后一分类无项时返回非零导致 `set -e` 下脚本退出，添加 `return 0` 保护
- 修复 `main_menu_loop` 空分类无限重绘 Header 问题，添加空分类检查和提前退出
- 修复 `read_key` 直接按 Enter 键无效：`read -n 1` 在遇到分隔符 `\n` 前无普通字符时设 key 为空串（退出码 0），但原代码未处理空 key，导致"OTHER:"穿透菜单循环无响应
- 修复 `ui_menu` 底部快捷键标签与重构计划不符：`Q 退出`/`← 返回上级` 替换为 `ui_footer` 渲染的 `↑↓ 选择  Enter 确认  Q/Esc 退出/返回` + 版本号
- 修复 P1-4（login-mail 依赖声明补全）、P2-8（旧项目名 HomeNAS→DebNAS 残留）、P2-10（代码风格统一）、P2-12（重复函数定义清理）、P2-18（缺失依赖声明补全）
- 修复 `print_prompt` 输出到 stderr + `mail-account` 幂等性检查
- 修复 `sources.sh` 顶层 `verify_debian_12_13_support` 调用导致 source 时副作用，移入 `main()` 函数
- 修复一键部署方案 `execute_solution()` stdin 污染：`while read` 使用 fd 3 读取方案文件，避免交互式模块（如 mail-account）的 `read` 读到方案文件的下一行模块名
- 修复 `bootstrap.sh` 重复加载导致 `_DEBNAS_BOOTSTRAPPED` 变量泄漏
- 修复菜单清理陷阱中 `tmp_dir` 未绑定变量
- 修复 `doctor` 脚本在 `set -e` 下的算术退出错误
- 修复 `module-runner` 递归依赖调用时的环境变量污染
- 修复非 root 用户执行 `debnas` 时显示 `mktemp` 权限错误而非 root 权限提示
- 统一 root 权限提示文案：引导用户使用 `su -` 切换而非 `sudo`（与项目文档一致）
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
- 修复 `docker-ce.sh`、`docker-apps.sh`、`bin/menu.sh`、`lib/ui/menu.sh` 中裸 `((var++))` 触发 `set -e` 退出（变量为 0 时表达式值为 0 即 falsy，返回退出码 1）
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
- 修复 `tempfile.sh` 权限注释与代码不一致：`chmod 700` → `755`，匹配注释中的 0755 声明；`init_temp_dir` 新增幂等权限修正（目录已存在时也确保 755），移除 `hosts-sync/module.sh` 中的 workaround `chmod 755`
- 修复 `/tmp/.debnas_signal_handled` 哨兵文件泄漏：`_debnas_cleanup_on_exit` 退出时自动清理，避免残留文件抑制后续运行的异常退出警告
- 统一临时文件管理：`menu.sh` 移除自建 EXIT/INT trap，改用 `create_temp_dir` 纳入集中跟踪；`hosts-sync` 子模块 5 处手动 `mktemp` → `create_temp_file`；`login-mail-on.sh` 裸 `mktemp` → `create_temp_file`；`cockpit-45drives.sh` 移除双重清理
- 修复 `modules/wallpaper/module.sh` 中 `config_read` 缺少 `"global"` 命名空间参数
- 修复临时文件追踪失效问题：`create_temp_file`/`create_temp_dir` 通过命令替换 `$()` 调用时在子 shell 中运行，内存数组 `_DEBNAS_TEMP_FILES` 的修改在子 shell 退出后丢失，导致 EXIT trap 无法清理临时文件。重构为进程 PID 目录隔离方案（`/tmp/debnas/pid-$$/`），退出时 `rm -rf` 整个 PID 目录，无需依赖内存数组追踪，天然免疫子 shell 问题

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
