# DebNAS 项目概览

> 版本：2.1.0 | 更新：2026-07-05
> 更新触发：补全CHANGELOG导航、新增文档阅读顺序说明

---

## 项目简介

**DebNAS**（**Deb**ian **NAS**）是一个基于 Debian 的 NAS 自动化配置工具。

目标：将 Debian 最小化安装（无桌面环境、无预装服务）快速转变为功能完整的家庭/小型企业 NAS 系统。

## 项目定位

| 维度 | 定位 |
|------|------|
| **目标用户** | NAS 爱好者、家庭用户、小型企业 IT 管理员。不要求专业 Linux 运维背景 |
| **技术门槛** | 用户只需安装 Debian 12+ 系统并联网，后续通过交互菜单完成配置 |
| **核心理念** | 所有操作可重复执行（幂等），用户无需担心误操作导致系统损坏 |
| **技术约束** | 纯 Bash 实现，不引入 Python/Node.js/Ruby 等解释器依赖 |

## 使用场景

1. **新手入门** — 用户刚装好 Debian 系统，需要快速搭建 NAS 环境。通过交互菜单一键部署基础方案（APT 源 + Cockpit 面板 + Docker CE + 防火墙）
2. **选择性配置** — 用户已有部分服务运行，只需要添加特定功能（如 Tailscale 内网穿透、Fail2ban 入侵防御、邮件通知）
3. **定时维护** — 通过 Cron 模式自动执行 Hosts 更新、系统补丁检查、威胁 IP 封禁更新
4. **系统诊断** — 使用 `debnas doctor` 检查系统兼容性、服务状态、APT 源配置
5. **国内网络优化** — 针对国内用户自动检测可用镜像站，支持 Gitee 下载和国内 Docker 镜像加速

## 核心功能模块（25 个）

| 分类 | 模块 | 说明 |
|------|------|------|
| **基础系统** | sources | 配置 APT 软件源（DEB822 格式） |
| | basic-tools | 安装基础工具 |
| **管理面板** | cockpit | 安装 Cockpit 面板 |
| | cockpit-ext-on/off | Cockpit 扩展启用/禁用 |
| | cockpit-net | Cockpit 网络管理器 |
| | cockpit-45drives | 安装 45Drives 扩展 |
| | service-query | 查询服务状态 |
| | vm-components | 安装虚拟机组件 |
| | wallpaper | Bing 每日壁纸 |
| **安全防护** | security | 配置安全加固 |
| | firewall | 配置防火墙 |
| | fail2ban | 配置 Fail2ban |
| | threat-ips | 威胁 IP 自动封禁 |
| | login-mail-on/off | 登录邮件通知开关 |
| | mail-account | 配置邮件账户 |
| **容器管理** | docker-ce | 安装 Docker CE |
| | docker-mirror | 配置镜像加速 |
| | docker-apps | 部署容器应用 |
| **系统维护** | sys-check | 检查兼容性 |
| | sys-patches | 检查系统更新 |
| | service-query | 查询服务状态 |
| | timer-manager | 定时任务概览 |
| **系统工具** | hosts-sync | 同步 Hosts |
| | tailscale | 安装 Tailscale |
| | acl-manager | ACL 权限管理 |
| | bbr | 配置 BBR 加速 |

## 技术特性

- **幂等操作** — 所有系统操作可重复执行，已配置项自动跳过
- **智能依赖** — 自动检测缺失命令并安装对应包，APT 更新去重
- **模块元数据驱动** — 通过 `# @key: value` 注释自动发现模块、解析依赖
- **拓扑排序** — 模块依赖关系自动解析，循环依赖检测
- **双引导策略** — 轻量引导（模块用）+ 完整引导（入口用），按需加载
- **版本迁移** — `_migrate_<version>` 命名约定，升级时自动执行迁移
- **信号安全** — 临时文件自动跟踪，EXIT/INT/TERM 信号下安全清理

## 项目规模

| 指标 | 数值 |
|------|------|
| 总代码行数 | ~11,300 行 Bash |
| 文件总数 | 80+ |
| 功能模块 | 25 个 |
| 公共库文件 | 21 个（core ×3 + system ×14 + ui ×2 + root ×2） |
| CLI 子命令 | 7 个（install/run/config/update/uninstall/doctor/cron） |
| BATS 测试文件 | 15 个（unit ×12 + integration ×3） |
| 手动测试用例 | 170+ |

---

## 文档导航

> 如果你是新加入的开发者或 AI 协作者，按以下顺序阅读文档。

### 必读文档（按顺序）

| 顺序 | 文档 | 用途 | 适用场景 |
|------|------|------|---------|
| 1 | [CLAUDE.md](../CLAUDE.md) | AI 协作规范、开发流程、禁止事项 | 每次开发前必读 |
| 2 | [ARCHITECTURE.md](ARCHITECTURE.md) | 项目结构、库分层、模块系统、核心 API | 理解代码组织方式 |
| 3 | [TECH_DEBT.md](TECH_DEBT.md) | 已知 Bug、隐式依赖、应避免的坑 | 避免踩已知的坑 |
| 4 | [DEVELOPMENT_GUIDE.md](DEVELOPMENT_GUIDE.md) | 代码风格、模块模板、Git 规范 | 写代码时参考 |
| 5 | [TESTING_GUIDE.md](TESTING_GUIDE.md) | 测试命令、发布前检查清单 | 修改代码后执行 |

> **阅读顺序说明**：CLAUDE.md §1 将 TECH_DEBT 排在 DEV_GUIDE 之后（面向 AI，先熟悉开发规范再识别债务），本文档将 TECH_DEBT 排在 DEV_GUIDE 之前（面向人类，先避开已知坑再写代码）。两种顺序各有侧重，按实际需要选择。

### 按需参考

| 文档 | 用途 | 何时需要 |
|------|------|---------|
| [CHANGELOG.md](../CHANGELOG.md) | 版本变更记录（Keep a Changelog 格式） | 查看发布历史、同步更新 |
| [MAINTENANCE.md](MAINTENANCE.md) | 版本号规则、分支策略、发布流程 | 准备发布新版本时 |
| [tests/test-plan.md](../tests/test-plan.md) | 170+ 手动测试用例（13 阶段） | 发布前完整回归测试时 |
