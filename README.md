# Debian-HomeNAS 自动化脚本项目

---

## 项目简介

Debian-HomeNAS 是面向 Debian 12+ 家庭/小型办公 NAS 场景的模块化 Bash 自动化脚本集，覆盖系统初始化、Web 管理、安全加固、容器平台、邮件通知、ACL 权限、备份恢复等一站式运维功能。所有脚本严格遵循行业标准和自定义开发规范，支持远程一键拉取与本地开发调试，适配纯中文终端环境。

---

## 主要特性

- **模块化设计**：25 个独立功能模块，主入口自动调度，支持组合批量执行
- **远程执行保障**：正式环境强制远程拉取最新脚本，开发者可本地调试
- **行业标准日志**：五级日志、彩色输出、统一前缀，支持 LOG_LEVEL/NO_COLOR 环境变量
- **UI 体验一致**：等宽字体、统一菜单、语义化颜色、交互友好
- **临时文件规范**：所有临时文件集中于 `/tmp/debian-homenas/`，自动清理
- **依赖自动检测**：缺失依赖自动安装，兼容最小化 Debian 环境
- **纯中文交互**：所有提示、日志、注释均为简体中文
- **无敏感信息存储**：所有敏感信息仅在交互时输入，脚本本身不存储

---

## 目录结构

```
Debian-HomeNAS/
├── bin/           # 主入口脚本
├── lib/           # 公共库
├── modules/       # 功能模块（25个）
├── README.md      # 项目说明
└── LICENSE        # 开源协议
```

---

## 功能模块一览

详见 [docs/scripts-intro.md](docs/scripts-intro.md)  
**主要类别与代表模块如下：**

- **系统初始化**：软件源配置、基础工具安装
- **Web管理**：Cockpit 面板、虚拟机支持、外网访问管理、网络配置
- **邮件服务**：邮件账户配置、登录通知管理
- **安全加固**：SSH/账户加固、防火墙、fail2ban、恶意IP封禁
- **容器平台**：Docker 安装、镜像加速、常用容器应用、备份恢复
- **系统工具**：兼容性检查、系统更新、服务查询、hosts 自动更新、内网穿透、ACL 权限管理
- **一键部署**：基础环境配置、安全环境配置

---

## 快速开始

- 推荐一键安装命令（以 Github 主分支为例）：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/kekylin/Debian-HomeNAS/main/install.sh) -s github@main
```

- Gitee 主分支（适用于中国大陆网络环境）：

```bash
bash <(wget -qO- https://gitee.com/kekylin/Debian-HomeNAS/raw/main/install.sh) -s gitee@main
```

- `-s` 参数格式：**平台@分支名**，如 `-s github@main`、`-s gitee@dev`
- 未指定分支名时，脚本将拒绝执行

---

## 系统要求

- **操作系统**：Debian 12 及以上
- **Shell**：Bash 5.1+
- **权限**：root 用户直接运行（禁止 sudo）
- **网络**：需外网访问能力（用于拉取脚本和安装软件）

---

## 贡献与反馈

欢迎提交 issue 和 PR，建议先阅读开发规范与现有模块说明。所有贡献需遵循统一风格和行业标准。

---

## 开源协议

采用 [GNU GPL v3.0](https://www.gnu.org/licenses/gpl-3.0.html) 开源协议。 