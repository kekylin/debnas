# Changelog

本项目的所有重要更改都记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循日期版本号 `vYYYY.MM`。

## [v2026.06] - 2026-06-26

### Added
- **统一库加载入口** `lib/bootstrap.sh`：所有模块只需 source 一行
- **APT 操作封装** `lib/system/apt.sh`：apt_update_safe/install/remove + 锁等待
- **服务管理** `lib/system/service.sh`：require_root/service_ensure/sysctl_set
- **全局参数解析** `lib/system/args.sh`：--debug/--dry-run/--yes/--region/--lang
- **模块状态追踪** `lib/system/state.sh`：幂等性基础（/var/lib/debnas/state/）
- **Cron 统一管理** `lib/system/cron.sh`：cron_register/unregister/list
- **配置读写** `lib/system/config.sh`：/etc/debnas/conf.d/ key=value 格式
- **模块自动发现** `lib/system/module-registry.sh`：@metadata 解析 + 依赖拓扑排序
- **CLI 调度器** `bin/debnas`：menu/install/update/uninstall/doctor/cron 子命令
- **标准化执行引擎** `bin/module-runner.sh`：preflight → execute → verify → report
- **交互菜单** `bin/menu.sh`：基于 discover_modules() 自动生成
- **系统诊断** `bin/doctor.sh`：系统/APT/网络/状态/服务检查（仅报告）
- **文件日志** `lib/core/logging.sh`：log_to_file/log_stop_file
- **i18n 框架** `lib/i18n/`：中英双语消息
- **BATS 测试** `tests/`：9 个单元测试文件，79 个用例
- **GitHub Actions CI**：ShellCheck + 语法检查 + BATS 测试
- **自包含安装脚本** `install.sh`：--region cn|global + --uninstall

### Changed
- **28 个模块**：添加 @module/@name/@category/@order 元数据头
- **25 个模块**：source 块切换为 bootstrap.sh
- **6 个核心模块**：幂等性改造（state_is_installed + state_mark_success）
- **4 个 cron 模块**：统一使用 cron.sh API
- **5 个大模块**：拆分为目录结构（保留旧文件兼容层）
- **bin/main.sh**：保留为兼容入口（转发到 bin/debnas menu）

### Fixed
- log_* 函数在 set -e 下返回非零导致脚本异常退出
- bootstrap.sh 防重复加载守卫通过 exec 传递导致子进程跳过加载
