# DebNAS 项目优化路线图（最终版）

> 基于 2026-06-24 对 `dev` 分支的全面技术评审，结合用户需求讨论后生成的最终架构方案与实施计划。
> 当前阶段：**审查与规划阶段** — 未获明确指令前不修改代码。

---

## 1. 当前项目评估总结

### 1.1 项目定位

DebNAS 是面向中文用户的 **Debian NAS 自动化部署工具**，将 Debian 最小化安装快速配置为可用的 HomeNAS 系统。通过 Cockpit WebUI + Docker 实现可视化管理。

### 1.2 项目等级

**小型开源项目（偏高质量个人项目）**

比个人脚本级有明显提升（模块化架构、公共库分层、统一的日志/依赖/tempfile 管理），但距离成熟开源自动化部署工具仍有差距。

### 1.3 核心优势

| 优势 | 说明 |
|------|------|
| 模块化架构 | lib (core/system/ui) → modules，层次分明 |
| 运维基础设施 | 统一的日志框架、依赖管理、临时文件生命周期、URL 配置 |
| 双模式运行 | 交互菜单 + cron 定时任务 |
| 中文用户友好 | 针对国内网络环境优化（镜像源、GitHub 代理） |
| 功能完整 | 30 个模块覆盖从系统初始化到 Docker 应用部署的全流程 |

### 1.4 核心短板

| 短板 | 说明 |
|------|------|
| 稳定性不足 | 幂等性差（重复执行行为不可预测） |
| 安全性有隐患 | curl-pipe-bash 供应链风险、外部脚本直接执行 |
| 缺乏工程化 | 无 CI/CD、无测试、无 `--help`/`--debug`/`--dry-run` |
| 代码质量不均 | 3 个模块 1000+ 行，存在重复代码，trap 管理不一致 |
| 架构不统一 | `install.sh` 与 `main.sh` 功能重叠，`bootstrap.sh` 从未使用，模块注册需硬编码 |

---

## 2. 当前主要问题

### 2.1 安全问题 (P0)

1. **`curl ... | bash` 供应链风险**：[install-cockpit.sh:267](modules/install-cockpit.sh#L267) 直接执行远程未验证脚本
2. 下载的 .deb 包无 SHA256/GPG 校验
3. README 引导用户 `bash <(wget -qO- ...)` 无安全提醒

### 2.2 稳定性和可靠性 (P0/P1)

1. **幂等性缺失**：重复执行模块时行为不可预测（有的跳过、有的重复执行）
2. **apt 锁未检测**：并发 apt 操作直接失败退出
3. **版本号硬编码**：`install-cockpit.sh` 中 cockpit-file-sharing 版本 `v4.6.0` 硬编码

### 2.3 代码工程化问题 (P1/P2)

1. **脚本过大**：3 个模块超过 1000 行
2. **代码重复**：cron 模式下 tempfile 逻辑被复制在 `block-threat-ips.sh` 中
3. **cron 模式双路径**：`auto-update-hosts.sh` 在 cron 路径中用 `if CRON_MODE` 守卫每个 `log_*` 调用，else 分支用 `printf >&2` 替代。整个文件散布数十个 `if [[ $CRON_MODE -eq 0 ]]` 分支，维护脆弱
4. **trap 管理冲突**：各模块各自注册 trap，可能与 `tempfile.sh` 冲突
5. **模块注册耦合**：添加模块必须修改 `bin/main.sh` 中的 `MODULE_DESC`/`MENU_MAP`
6. **入口重叠**：`install.sh`（远程下载）和 `main.sh`（菜单）功能界限模糊

### 2.4 开源规范缺失 (P2)

- 无 SECURITY.md、CONTRIBUTING.md、Issue/PR 模板
- 无 CI/CD pipeline
- 无测试框架
- 无 changelog
- 中文 only 文档

---

## 3. 优化目标

- 建立扎实的基础框架，为长期维护和扩展奠定基础
- 达到成熟开源 Bash 自动化部署工具的工程水平
- 支持 CLI 子命令 + 交互菜单双模式
- 新手友好（菜单 ≤3 级）+ 专家高效（CLI 自动化）
- 适配国内和国际两种网络环境
- UI 中英双语

---

## 4. 全局架构设计

### 4.1 使用流程

```
用户首次使用（Debian 最小化安装，仅有 wget）：
  # 国内用户
  wget https://gitee.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region cn

  # 国际用户
  wget https://github.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region global

  install.sh 做的事（自包含引导脚本，无需 git）：
    ├─ 检查 root 权限
    ├─ --region 参数必填（cn 或 global），无效则报错退出
    ├─ 通过 wget 下载仓库压缩包（根据 region 选择 Gitee/GitHub 源）
    ├─ 校验压缩包 checksum（与脚本内置值对比，不匹配则拒绝）
    ├─ 解压到 /opt/debnas/（永久目录，重启不丢失）
    ├─ 检测 /opt/debnas/ 是否已存在 → 存在则询问"覆盖更新"还是"退出"
    ├─ 安装 debnas 封装脚本到 /usr/local/bin/debnas（薄封装，exec 到 /opt/debnas/bin/debnas）
    ├─ 配置 APT 镜像源（调用 configure-sources，使后续 apt 可用）
    ├─ 创建必要目录（/var/log/debnas, /var/lib/debnas/state, /etc/debnas/conf.d）
    └─ 启动交互菜单

用户后续使用：
  debnas menu                     # 交互菜单（默认命令）
  debnas update                   # 更新 DebNAS（下载新版覆盖 /opt/debnas/，保留配置）
  debnas install cockpit          # 直接安装指定模块
  debnas doctor                   # 系统诊断
  debnas cron add|remove|list     # 管理定时任务
  debnas --region global install cockpit  # 临时切换网络环境
  debnas --lang en menu           # 英文界面
  debnas --debug install firewall # 调试模式
  debnas --dry-run install docker # 预览变更
  debnas --yes install basic-tools # 跳过所有确认
  debnas uninstall                # 卸载清理

用户退出后的清理：
  debnas uninstall
  # 或
  bash install.sh --uninstall     # 备选方式（deb包被误删时可用）
```

### 4.2 CLI 命令体系

```
debnas [全局参数] <子命令> [子命令参数]

全局参数（所有子命令通用）：
  --debug              启用调试日志 (LOG_LEVEL=DEBUG)
  --dry-run            仅预览，不实际执行
  --yes / -y           自动确认所有提示
  --region cn|global   覆盖网络环境设置
  --lang zh|en         覆盖语言设置
  --version            打印版本并退出
  --help               打印帮助

子命令：
  menu                 启动交互菜单（无参数时的默认命令）
  install <模块>       安装指定模块
  update               更新 DebNAS 到最新版本（保留配置和状态）
  uninstall            卸载 DebNAS（清理脚本文件和配置，不恢复系统变更）
  doctor               系统状态诊断
  cron add|remove|list 管理定时任务
```

说明：模块内部的子功能（如 block-threat-ips 的启用/禁用/查看）
不暴露为 CLI 子命令，用户通过菜单或 debnas install <模块> 进入模块后选择。

---

## 5. 入口设计

### 5.1 install.sh — 自包含引导脚本

**设计原则**：`install.sh` 是一个**自包含**的引导脚本。它不依赖仓库中的任何其他文件，也不依赖 `git`。Debian 最小化安装仅有 `wget`，这足够了。

```shell
# 用户执行：
wget https://gitee.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region cn

# install.sh 的职责：
# 1. 检查 root
# 2. 校验 --region 参数（必填，cn 或 global），无效则报错退出
# 3. 通过 wget 下载仓库压缩包（cn→Gitee, global→GitHub）
# 4. 校验压缩包 checksum（脚本内置 SHA256，不匹配则拒绝执行）
# 5. 检测 /opt/debnas/ 是否已存在 → 已存在则询问"覆盖更新"或"退出"
# 6. 解压到 /opt/debnas/（永久目录，重启不丢失；更新时覆盖现有文件）
# 7. 安装 debnas 封装脚本到 /usr/local/bin/debnas（薄封装，指向 /opt/debnas/bin/debnas）
# 8. 调用 configure-sources 配置 APT 镜像源（此后 apt 可用；更新时跳过）
# 9. 写入 /etc/debnas/debnas.conf（含 region 配置；更新时保留）
# 10. 创建目录: /var/log/debnas/ /var/lib/debnas/state/ /etc/debnas/conf.d/（更新时跳过已存在的）
# 11. 启动交互菜单（更新完成后询问是否启动菜单）
```

**与前版的关键区别**：
- 不再要求 `git clone`（Debian 最小化安装无 git）
- 不使用 `bash <(wget -qO- ...)` 模式（避免 pipe-to-bash 风险）
- 代码安装到 `/opt/debnas/`（永久目录），而非 `/tmp/`（重启丢失）
- `install.sh` 通过 wget 下载仓库压缩包，内置 checksum 校验完整性
- 首次安装和后续更新走**同一套流程**（下载→校验→解压→覆盖）
- APT 源配置在安装流程早期完成，确保后续 `apt` 操作可用

**两种运行方式**：全局命令 `debnas`（生产）和项目目录 `./bin/debnas`（开发调试）均保留。

### 5.2 卸载设计

#### 设计原则

卸载脚本**只清理 DebNAS 自身的文件和配置**，不恢复脚本运行所产生的系统变更：

```
清理范围（DebNAS 自身产物）:
  ✅ /usr/local/bin/debnas          ← 全局命令
  ✅ /opt/debnas/                   ← 脚本代码目录
  ✅ /etc/debnas/                   ← 配置文件目录
  ✅ /var/log/debnas/               ← 日志目录
  ✅ /var/lib/debnas/state/         ← 状态文件目录
  ✅ /tmp/debnas/                   ← 临时文件目录
  ✅ crontab 中 # DebNAS 标记的定时任务

不触碰范围（系统级变更）:
  ❌ 已安装的软件包（Docker、Cockpit、Fail2ban 等）
  ❌ 已修改的系统配置（软件源、防火墙规则、sysctl 等）
  ❌ 已启动/启用的系统服务
  ❌ 已创建的 Docker 容器、数据卷、网络
  ❌ 已添加的系统用户/组
```

#### 两种调用方式

```shell
# 方式一：全局命令（推荐）
debnas uninstall

# 方式二：项目目录（deb包被误删时的备选方案）
bash install.sh --uninstall
```

#### 卸载流程

```
debnas uninstall
  │
  ├─ [1] 确认提示:
  │      "此操作将移除 DebNAS 所有脚本文件、配置和日志。
  │       不会恢复已安装的软件包或已修改的系统配置。
  │       确认继续？[y/N]: "
  │      → 输入 N 或直接回车 → 退出
  │
  ├─ [2] 移除全局命令:
  │      rm -f /usr/local/bin/debnas
  │
  ├─ [3] 移除脚本代码:
  │      rm -rf /opt/debnas/
  │
  ├─ [4] 移除 cron 定时任务:
  │      crontab -l 2>/dev/null | grep -v '# DebNAS' | crontab - || true
  │
  ├─ [5] 移除配置目录:
  │      rm -rf /etc/debnas/
  │
  ├─ [6] 移除日志目录:
  │      rm -rf /var/log/debnas/
  │
  ├─ [7] 移除状态目录:
  │      rm -rf /var/lib/debnas/
  │
  ├─ [8] 移除临时文件:
  │      rm -rf /tmp/debnas/
  │
  └─ [9] 输出清理摘要:
         "DebNAS 已卸载。
          已安装的软件包和系统配置未被修改。
          如需恢复系统，请手动操作。"
```

### 5.3 更新机制

两种更新方式，底层逻辑相同（下载→校验→覆盖），入口不同：

#### 方式一：`debnas update`（推荐，便捷）

```shell
debnas update
```

内部流程：
1. 读取 `/etc/debnas/debnas.conf` 中的 `region` 配置
2. 根据 region 选择下载源（cn→Gitee, global→GitHub）
3. 下载最新仓库压缩包到 `/tmp/debnas/`
4. 校验 checksum
5. 解压覆盖 `/opt/debnas/`（脚本代码）
6. **保留** `/etc/debnas/`（配置）
7. **保留** `/var/lib/debnas/state/`（状态）
8. **保留** `/var/log/debnas/`（日志）
9. 输出更新摘要（旧版本 → 新版本）

#### 方式二：重新运行 `install.sh`（适合大版本升级）

```shell
wget https://gitee.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region cn
```

`install.sh` 检测到 `/opt/debnas/` 已存在时：
```
检测到 DebNAS 已安装。
  [1] 覆盖更新（保留配置和状态）
  [2] 退出
请选择 [1/2]:
```

#### 更新原则

| 操作 | 行为 |
|------|------|
| `/opt/debnas/` | **全覆盖**（新版替换所有脚本） |
| `/etc/debnas/` | **保留**（用户配置不丢失） |
| `/var/lib/debnas/state/` | **保留**（模块状态不丢失，更新后幂等性继续生效） |
| `/var/log/debnas/` | **保留**（历史日志不丢失） |
| `/usr/local/bin/debnas` | **覆盖**（确保入口脚本也更新） |
| crontab 条目 | **保留**（定时任务不丢失） |

---

## 6. CLI 调度器

```
debnas (入口) → parse_global_args()
  │
  ├─ 无参数    → debnas menu → 交互菜单
  ├─ menu      → 交互菜单
  ├─ install <模块名> → module-runner.sh 执行模块
  ├─ update    → 下载新版覆盖 /opt/debnas/，保留配置
  ├─ uninstall → 卸载清理
  ├─ doctor    → 系统诊断
  └─ cron add|remove|list → 定时任务管理
```

### 模块执行标准化流程

```
module-runner.sh <module> [subcommand]
  │
  ├─ preflight（框架自动执行）:
  │   ├─ require_root
  │   ├─ check_debian_version (>= bookworm)
  │   ├─ check_dependencies (模块声明的依赖，缺失则自动安装)
  │   ├─ resolve_module_deps (@depend_modules 自动解析执行顺序)
  │   ├─ state_is_installed → 已安装则提示并询问是否跳过
  │   └─ --dry-run → 打印执行计划，退出
  │
  ├─ execute（模块逻辑）:
  │   ├─ 调用 module_main() 或 module_<subcommand>()
  │   └─ 框架提供: apt_update_safe(), register_temp_cleanup() 等
  │
  ├─ verify（模块自检）:
  │   └─ 检查关键后置条件（服务是否启动、配置是否生效）
  │
  └─ report（框架自动记录）:
      ├─ 写入 /var/lib/debnas/state/<module>.state
      └─ 写入 /var/log/debnas/<module>.log
```

---

## 7. 模块系统

### 7.1 元数据声明（自动发现）

模块不再需要在 `main.sh` 中硬编码注册。通过文件头部的注释声明元数据。

解析方式：`grep` + `sed` 提取 `# @key: value` 行，构建关联数组。解析逻辑在 `module-registry.sh` 中实现。缺少元数据的模块 → 使用默认值（文件名作为模块名，"未分类"），打印警告提醒开发者补全。

```bash
#!/bin/bash
# @module: install-cockpit
# @name: 安装 Cockpit
# @category: 管理面板
# @description: 安装 Cockpit Web 管理面板及 45Drives 组件
# @depends: curl,apt,systemctl
# @depend_modules: configure-sources,install-basic-tools
# @version: 3.0.0
# @debian_min: bookworm
# @order: 30
```

框架扫描 `modules/` 目录，自动解析元数据生成菜单和命令路由。

#### 菜单排序机制

**排序规则**：
1. **按 `@order` 数字升序排列**（数字越小越靠前）
2. **相同 `@order` 的模块按字母顺序排列**
3. **未声明 `@order` 的模块默认值为 999**（排在最后）

**分类顺序**：`@category` 决定模块属于哪个分类，分类本身的顺序由 `bin/menu.sh` 中的硬编码列表决定：

```bash
# bin/menu.sh 中的分类顺序（硬编码）
CATEGORY_ORDER=(
  "基础系统"      # 最先显示
  "管理面板"
  "安全防护"
  "容器管理"
  "通知服务"
  "系统工具"
  "一键部署"
  "系统维护"      # 最后显示
)
```

**当前顺序映射**：为保持与现有项目一致的菜单顺序，各模块的 `@order` 值如下：

```
基础系统 (分类 @order 范围: 10-19)
  configure-sources.sh              @order: 10
  install-basic-tools.sh            @order: 11

管理面板 (分类 @order 范围: 30-39)
  install-cockpit.sh                @order: 30
  set-cockpit-network.sh            @order: 31
  enable-cockpit-external.sh        @order: 32
  disable-cockpit-external.sh       @order: 33
  cockpit-auto-bing-wallpaper.sh    @order: 34

安全防护 (分类 @order 范围: 40-49)
  configure-security.sh             @order: 40
  install-firewall.sh               @order: 41
  install-fail2ban.sh               @order: 42
  block-threat-ips/                 @order: 43

容器管理 (分类 @order 范围: 50-59)
  install-docker-ce.sh              @order: 50
  add-docker-mirror.sh              @order: 51
  install-docker-apps.sh            @order: 52
  backup-restore/                   @order: 53

通知服务 (分类 @order 范围: 60-69)
  setup-mail-account.sh             @order: 60
  enable-login-mail.sh              @order: 61
  disable-login-mail.sh             @order: 62

系统工具 (分类 @order 范围: 70-79)
  auto-update-hosts/                @order: 70
  install-tunnel.sh                 @order: 71
  acl-manager.sh                    @order: 72
  bbr-algo-manager.sh               @order: 73
  check-system-updates/             @order: 74
  install-service-query.sh          @order: 75

一键部署 (分类 @order 范围: 80-89)
  setup-homenas-basic.sh            @order: 80
  setup-homenas-secure.sh           @order: 81

系统维护 (分类 @order 范围: 90-99)
  debnas uninstall                  @order: 90（内置命令）
```

**实现细节**：`module-registry.sh` 的 `discover_modules()` 函数执行以下步骤：
1. 扫描 `modules/` 目录
2. 解析每个模块的元数据（`@category`, `@order`）
3. 按分类分组
4. 每个分类内按 `@order` 升序排列
5. 按 `CATEGORY_ORDER` 的顺序输出分类

**灵活性**：如果未来要调整顺序，只需修改模块头部的 `@order` 值，不需要改动 `bin/menu.sh` 或 `module-registry.sh`。

### 7.2 模块目录结构

```
modules/
  # 简单模块（单文件，< ~300 行）
  install-cockpit.sh
  install-firewall.sh
  configure-sources.sh
  ...（共 22 个）

  # 复杂模块（目录式，> ~300 行）
  block-threat-ips/
    module.sh         # 入口 + 元数据
    download.sh       # 下载+解析威胁列表
    ipset.sh          # ipset 管理
    firewall.sh       # firewalld 集成
    cron.sh           # 定时任务逻辑
    config/
      ipthreat.conf.default

  auto-update-hosts/
    module.sh
    dns-resolve.sh    # 多 DNS 并行解析
    connectivity.sh   # 三级连通性检测
    hosts-manager.sh  # /etc/hosts 读写
    cron.sh

  backup-restore/
    module.sh
    backup.sh
    restore.sh
    verify.sh
    config/
      docker_backup.conf.default

  cockpit-auto-bing-wallpaper/
    module.sh
    download.sh
    configure.sh
    cron.sh

  check-system-updates/
    module.sh
    check.sh
    notify.sh
    cron.sh
```

### 7.3 模块依赖自动处理

框架解析 `@depend_modules` 声明，构建依赖图，按拓扑序执行。

```bash
# 模块声明依赖：
# @depend_modules: install-docker-ce

# 框架自动解析：
# debnas install docker-apps
#   → 检测依赖 install-docker-ce
#     → 检测依赖 configure-sources
#       → 执行: configure-sources → install-docker-ce → install-docker-apps
```

**循环依赖**：框架构建依赖图时检测循环引用（A→B→C→A），检测到则报错退出并列出循环路径。

**依赖失败**：被依赖的模块执行失败时，当前模块不执行，直接报告"依赖模块 xxx 执行失败，当前模块已跳过"。

### 7.4 扁平化菜单（≤3 级）

不再有 4-5 级深层嵌套。开关型功能（如 `enable-cockpit-external.sh` / `disable-cockpit-external.sh`）**保留两个文件**，但从单一菜单入口分发调用，菜单中显示为"外网访问（当前：已开启）"或类似状态提示。

同样处理 `enable-login-mail.sh` / `disable-login-mail.sh`。

```
===== DebNAS =====

  [基础系统]
    1. 配置软件源
    2. 安装基础工具

  [管理面板]
    3. 安装 Cockpit
    4. Cockpit 网络管理
    5. Cockpit 外网访问（开启/关闭）
    6. Cockpit 必应壁纸

  [安全防护]
    7. 基础安全配置
    8. 安装防火墙
    9. 安装 Fail2ban
   10. IP 封禁工具

  [容器管理]
   11. 安装 Docker CE
   12. Docker 镜像加速
   13. 安装管理面板（Portainer/Dockge）
   14. 备份恢复

  [通知服务]
   15. 配置邮件账户
   16. 登录通知（开启/关闭）

  [系统工具]
   17. 更新 Hosts 文件
   18. 安装 Tailscale
   19. ACL 权限管理
   20. BBR 算法管理
   21. 系统更新检查
   22. 服务状态查询

  （原"检查兼容性"模块移除，功能并入 preflight 自动检查 + debnas doctor）

  [一键部署]
   23. 基础环境一键部署
   24. 安全环境一键部署

  [系统维护]
   25. 卸载 DebNAS

  0. 退出
```

---

## 8. 基础库体系

### 8.1 bootstrap.sh — 统一加载入口

当前 `bootstrap.sh` 已定义但从未被使用。修复后成为所有模块和 CLI 的唯一库加载入口：

```bash
#!/bin/bash
# bootstrap.sh — DebNAS 统一库加载入口
# 所有模块只需 source 这一行

set -euo pipefail
IFS=$'\n\t'

_DEBNAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 解析早期标志（--cron 影响 UI 库是否加载）
_parse_early_flags() {
  for arg in "$@"; do
    case "$arg" in
      --cron) export DEBNAS_CRON_MODE=1 ;;
      --debug) export LOG_LEVEL=DEBUG ;;
      --dry-run) export DEBNAS_DRY_RUN=1 ;;
      --yes|-y) export DEBNAS_FORCE_YES=1 ;;
    esac
  done
}
_parse_early_flags "$@"
unset _parse_early_flags

# Core layer（零依赖）
source "${_DEBNAS_ROOT}/lib/core/constants.sh"
source "${_DEBNAS_ROOT}/lib/core/colors.sh"
source "${_DEBNAS_ROOT}/lib/core/logging.sh"

# System layer
source "${_DEBNAS_ROOT}/lib/system/utils.sh"
source "${_DEBNAS_ROOT}/lib/system/dependency.sh"
source "${_DEBNAS_ROOT}/lib/system/tempfile.sh"
source "${_DEBNAS_ROOT}/lib/system/urls.sh"
source "${_DEBNAS_ROOT}/lib/system/apt-pinning.sh"
source "${_DEBNAS_ROOT}/lib/system/apt.sh"          # [新]
source "${_DEBNAS_ROOT}/lib/system/args.sh"          # [新]
source "${_DEBNAS_ROOT}/lib/system/state.sh"         # [新]
source "${_DEBNAS_ROOT}/lib/system/cron.sh"          # [新]
source "${_DEBNAS_ROOT}/lib/system/config.sh"        # [新]
source "${_DEBNAS_ROOT}/lib/system/service.sh"       # [新]

# UI layer（cron 模式下跳过，避免颜色输出）
if [[ "${DEBNAS_CRON_MODE:-0}" -eq 0 ]]; then
  source "${_DEBNAS_ROOT}/lib/ui/styles.sh"
  source "${_DEBNAS_ROOT}/lib/ui/menu.sh"
fi

# Module Registry
source "${_DEBNAS_ROOT}/lib/system/module-registry.sh"  # [新]

# 自动注册临时文件清理
register_temp_cleanup

export _DEBNAS_BOOTSTRAPPED=1
```

### 8.2 新建 6 个库文件

| 文件 | 核心函数 | 来源 |
|------|---------|------|
| `apt.sh` | `apt_update_safe()` (防重复 + 锁等待), `apt_install_safe()`, `apt_remove_safe()` | 6 个模块中散落的 `_DEBNAS_APT_UPDATED` 逻辑 |
| `args.sh` | `parse_global_args()`, `print_help()`, `print_usage()` | 各模块手写的 case 参数解析 |
| `state.sh` | `state_get()`, `state_set()`, `state_is_installed()` | 全新（幂等性基础） |
| `cron.sh` | `cron_register()`, `cron_unregister()`, `cron_list()` | 4 个模块各自实现的 crontab 操作 |
| `config.sh` | `config_read()`, `config_write()` | 各模块手写的配置文件解析 |
| `service.sh` | `require_root()`, `service_ensure()`, `sysctl_set()` | 各模块重复的 systemctl/sysctl 代码 |

### 8.3 需要改造的现有文件

| 文件 | 改造内容 |
|------|---------|
| `install.sh` | 重写：git-clone 安装器，整合当前与 main.sh 重叠的功能 |
| `bin/main.sh` | 重构为 `bin/menu.sh`，使用模块注册表生成菜单 |
| `lib/bootstrap.sh` | 重写：当前 25 行基础版扩展为含 cron 检测、早期标志解析、自动 trap 注册的完整入口 |
| `lib/core/logging.sh` | 增强：支持文件日志输出 |
| `lib/system/urls.sh` | 增强：根据 region 返回不同 URL 列表 |

---

## 9. 网络环境自适应

### 9.1 启动参数指定（首次安装）

```shell
# 国内用户
wget https://gitee.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region cn

# 国际用户
wget https://github.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region global
```

`--region` 参数**必填**，限 `cn` 或 `global`。在 README 中分别为国内和国际用户提供各自的安装命令，用户复制粘贴即可，无需额外交互。

安装后 `apt` 源已配置，用户如需 git 可自行 `apt install git`。

### 9.2 配置存储

安装后写入 `/etc/debnas/debnas.conf`：
```ini
[global]
region = cn
```

安装完成后，用户可随时通过全局参数临时覆盖：
```shell
debnas --region global install cockpit   # 国内挂代理时切换
debnas --region cn install docker        # 海外华人用国内镜像
```

### 9.3 URL 注册中心改造

`lib/system/urls.sh` 是网络资源的**唯一真相来源**。所有模块通过统一的 API 获取 URL，不感知 region 细节。

#### 核心设计：函数根据 region 返回不同列表

```bash
# lib/system/urls.sh 提供的统一 API

# 获取 Debian APT 镜像站列表
get_apt_mirrors()
#   cn → ("https://mirrors.tuna.tsinghua.edu.cn" "https://mirrors.ustc.edu.cn" ...)
#   global → ("https://deb.debian.org")   ← 只有官方源

# 获取 Docker CE 安装源列表
get_docker_ce_mirrors()
#   cn → ("https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian" ...)
#   global → ("https://download.docker.com/linux/debian")

# 获取 Docker Registry 镜像加速地址
get_docker_registry_mirrors()
#   cn → ("https://docker.m.ixdev.cn" "https://docker.1ms.run" ...)
#   global → ()   ← 空列表，不配置镜像加速

# 获取 GitHub 代理端点列表
get_github_proxies()
#   cn → ("https://ghfast.top" "https://hubproxy.jiaozi.live" ...)
#   global → ()   ← 空列表，直连 GitHub

# 获取 DNS 服务器列表（用于 hosts 更新）
get_dns_servers()
#   cn → ("223.5.5.5" "119.29.29.29" "180.76.76.76" "114.114.114.114")
#   global → ("8.8.8.8" "1.1.1.1" "9.9.9.9")

# 获取仓库压缩包下载地址
get_repo_tarball_url()
#   cn → "https://gitee.com/kekylin/debnas/repository/archive/main.tar.gz"
#   global → "https://github.com/kekylin/debnas/archive/refs/heads/main.tar.gz"
```

#### 模块如何使用

模块调用这些函数获取列表，然后执行探测/选择逻辑。模块代码完全不需要 `if cn else global` 分支：

```bash
# 以 configure-sources.sh 为例：
selected_mirror=""
for mirror in $(get_apt_mirrors); do     # ← 函数内部已根据 region 返回正确列表
  if probe_url "${mirror}"; then
    selected_mirror="${mirror}"
    break
  fi
done
```

#### 改造清单

| 影响范围 | 当前状态 | 改造方式 |
|---------|---------|---------|
| `urls.sh` | 硬编码仅中国的镜像/代理列表 | 改为函数式 API，内部根据 `DEBNAS_REGION` 返回不同列表 |
| `configure-sources.sh` | 遍历 `APT_MIRRORS`（仅中国） | 改为调用 `get_apt_mirrors()` |
| `install-docker-ce.sh` | 遍历 `DOCKER_FALLBACK_MIRRORS`（仅中国） | 改为调用 `get_docker_ce_mirrors()` |
| `add-docker-mirror.sh` | 直接读取 `DOCKER_REGISTRY_MIRRORS` | 改为调用 `get_docker_registry_mirrors()`；global 返回空则跳过 |
| `install-cockpit.sh` | 遍历 `GITHUB_PROXY_ENDPOINTS` | 改为调用 `get_github_proxies()` |
| `check-system-compatibility.sh` | 硬编码探测中国镜像 | 改为调用 `get_apt_mirrors()` |
| `auto-update-hosts.sh` | 硬编码中国 DNS 服务器 | DNS 列表从模块移至 `urls.sh`（urls.sh 目前无 DNS 相关内容，需从零新增 `get_dns_servers()` 函数），模块调用之 |
| `install.sh` | `-s github@分支` / `-s gitee@分支` | 改为 `--region cn|global`，内部自动选源 |

### 9.4 不受 region 影响的第三方 URL

以下 URL 属于**外部服务**，不根据 region 变化（服务自身可能在特定区域不可用，但这是用户网络环境的限制，不能由脚本控制）：

| URL | 用途 | 备注 |
|-----|------|------|
| `https://lists.ipthreat.net/` | 威胁 IP 列表 | 国内可能受限，建议文档提示 |
| `https://repo.45drives.com/setup` | 45Drives 仓库脚本 | 仅 Debian 12 使用，考虑下载后校验 |
| `https://pkgs.tailscale.com/` | Tailscale 安装源 | Tailscale 在国内可用性不确定 |
| `http://ip-api.com/` | IP 地理定位 | 国内可能不可用，留 TODO 标记 |
| `https://www.bing.com/` | 必应壁纸 | 国内可访问 |

### 9.5 各模块受 region 影响的完整映射

```
Region = cn                                   Region = global
─────────────                                ─────────────────
configure-sources:                           configure-sources:
  APT → 清华/中科大/阿里云镜像                    APT → deb.debian.org 官方源
  
install-docker-ce:                           install-docker-ce:
  Docker CE → 国内镜像站优先                    Docker CE → download.docker.com
  GPG Key  → 同上                              GPG Key  → 同上

add-docker-mirror:                           add-docker-mirror:
  配置 registry-mirrors (国内加速)              跳过（不配置镜像加速）

install-cockpit:                             install-cockpit:
  GitHub .deb → 通过 ghfast.top 代理            GitHub .deb → 直连 GitHub

auto-update-hosts:                           auto-update-hosts:
  DNS → 223.5.5.5, 119.29.29.29, ...         DNS → 8.8.8.8, 1.1.1.1, ...
  针对 GitHub 域名优化 (国内 DNS 污染)           可能不再需要此功能

install.sh:                                  install.sh:
  下载源 → Gitee 压缩包                         下载源 → GitHub 压缩包

其他模块:                                    其他模块:
  APT 操作 → 使用已配置的国内源                   APT 操作 → 使用官方源
  Docker 拉取 → 通过国内镜像加速                  Docker 拉取 → 直连 Docker Hub
```

---

## 10. 幂等性设计

### 10.1 状态追踪

```
/var/lib/debnas/state/
  install-cockpit.state
  install-docker-ce.state
  configure-security.state
```

状态文件格式（key=value）：
```
installed_version=3.0.0
installed_at=2026-06-24T15:30:00+08:00
last_result=success
```

### 10.2 幂等行为

**简单策略：已安装则跳过，失败则重跑**

```
用户再次执行已安装且成功的模块：
  → 检测到 state 文件存在且 last_result=success
  → 提示："Cockpit 已安装（版本 3.0.0），跳过。"
  → 退出

用户再次执行上次失败的模块：
  → 检测到 state 文件不存在或 last_result=fail
  → 从头重新执行整个模块
```

**为什么不需要断点续传**：
- 这些是自动化脚本，不是复杂平台
- 模块执行失败时，用户手动修复问题后重跑即可
- 大多数模块是原子操作（要么全成功，要么全失败）
- 少数多步骤模块（如 install-docker-ce）即使中途失败，重跑时已完成的步骤会自然跳过（如 apt 源已配置、包已安装）

---

## 11. Cron 定时任务统一

不再每个模块自己操作 crontab 或复制脚本。统一通过框架：

```shell
debnas cron add block-threat-ips     # 注册定时任务
debnas cron remove block-threat-ips  # 移除
debnas cron list                     # 查看所有
```

模块只需声明元数据，**不自行复制脚本文件**。框架管理 cron 脚本的存储和路径：
```bash
# @cron: true
# @cron_schedule: "0 */6 * * *"
```
框架自动将模块入口注册到 crontab，cron 执行时调用 `debnas <module> --cron`。

---

## 12. 项目最终目录结构

```
debnas/
  install.sh                     # 自包含引导脚本（重写，无外部依赖）
  checksum.sha256                # 仓库压缩包校验和（install.sh 用于完整性校验）
  README.md
  LICENSE
  CHANGELOG.md
  CONTRIBUTING.md
  SECURITY.md
  CODE_OF_CONDUCT.md
  .editorconfig
  .shellcheckrc

  bin/
    debnas                       # CLI 调度器
    menu.sh                      # 交互菜单（从 main.sh 提取）
    module-runner.sh             # 标准化模块执行引擎

  lib/
    bootstrap.sh                 # 统一库入口（修复）
    core/
      constants.sh               # 错误码
      colors.sh                  # ANSI 颜色 + NO_COLOR
      logging.sh                 # 日志框架（终端 + 文件）
    system/
      utils.sh                   # OS 检测
      dependency.sh              # 依赖检测 + 自动安装
      tempfile.sh                # 临时文件管理 + trap
      urls.sh                    # URL 注册中心（region 感知）
      apt-pinning.sh             # APT pinning
      apt.sh                     # [新] APT 操作封装
      args.sh                    # [新] 参数解析
      state.sh                   # [新] 状态追踪
      cron.sh                    # [新] 定时任务管理
      config.sh                  # [新] 配置读写
      service.sh                 # [新] 系统服务操作
      module-registry.sh         # [新] 模块自动发现
    ui/
      styles.sh                  # 样式
      menu.sh                    # 菜单组件

  modules/
    # 简单模块（单文件，22 个）
    configure-sources.sh
    install-basic-tools.sh
    install-cockpit.sh
    install-vm-components.sh
    enable-cockpit-external.sh
    disable-cockpit-external.sh
    set-cockpit-network.sh
    setup-mail-account.sh
    enable-login-mail.sh
    disable-login-mail.sh
    configure-security.sh
    install-firewall.sh
    install-fail2ban.sh
    install-docker-ce.sh
    add-docker-mirror.sh
    install-docker-apps.sh
    install-service-query.sh
    install-tunnel.sh
    acl-manager.sh
    bbr-algo-manager.sh
    setup-homenas-basic.sh
    setup-homenas-secure.sh

    # 复杂模块（目录式，5 个）
    cockpit-auto-bing-wallpaper/
    block-threat-ips/
    auto-update-hosts/
    backup-restore/
    check-system-updates/

  config/
    debnas.conf.default
    presets/                      # 一键部署套餐定义
      basic.conf                  # 基础环境模块列表
      secure.conf                 # 安全环境模块列表

  lib/i18n/                       # 国际化语言文件
    zh.sh                         # 中文消息
    en.sh                         # 英文消息

  /opt/debnas/                    # 运行时脚本代码目录（永久存放，更新时覆盖）
    bin/
    lib/
    modules/
    config/
  /usr/local/bin/debnas           # 全局 CLI 入口（薄封装，exec 到 /opt/debnas/bin/debnas）
  /etc/debnas/                    # 运行时配置目录
    debnas.conf
    conf.d/
  /var/lock/debnas.lock           # 运行时文件锁（防并发）
  /var/log/debnas/                # 运行时日志目录
  /var/lib/debnas/state/          # 运行时状态目录

  docker-compose/
    portainer.yaml
    dockge.yaml

  tests/
    bats/
    unit/
      lib/
      modules/
    integration/
    fixtures/
    helpers/
    run.sh

  docs/
    zh/
    en/

  .github/
    workflows/
      ci.yml
    ISSUE_TEMPLATE/
    PULL_REQUEST_TEMPLATE.md
```

---

## 13. 错误处理策略

**简单原则：失败则退出，用户修复后重跑**

### 13.1 单模块错误处理

- 模块执行失败 → 立即退出，返回非零状态码
- 不尝试自动修复或回滚
- 用户查看日志（`/var/log/debnas/<module>.log`）找到问题原因
- 用户手动修复问题后，重新运行模块

**为什么不需要复杂错误处理**：
- 脚本逻辑简单，错误通常是网络问题或权限问题
- 大多数操作是幂等的（重跑时已完成的步骤自然跳过）
- 用户是 NAS 爱好者，有能力查看日志和修复简单问题

### 13.2 一键部署失败策略

一键部署（`setup-homenas-basic`）按序执行多个独立模块。中间某个模块失败 → **立即停止**，不继续执行后续模块。已完成的模块状态已记录，用户修复问题后重新运行一键部署，已完成的模块自动跳过。

---

## 14. 日志体系

> **迁移说明**：当前 `block-threat-ips.sh` 有独立的文件日志路径（`/var/log/firewalld-ipthreat.log`）。
> Phase 5 拆分该模块时，统一迁移至 `/var/log/debnas/block-threat-ips-<timestamp>.log`。
> Phase 1-4 期间两套日志路径并存，互不冲突。

### 14.1 日志保留策略

每个模块每次执行生成独立日志文件：
```
/var/log/debnas/
  install-cockpit-2026-06-25-143025.log
  install-cockpit-2026-06-25-170312.log
  configure-sources-2026-06-25-143010.log
```

按时间戳命名，全部保留，由用户自行清理。

### 14.2 日志详细程度

| 模式 | 输出内容 |
|------|---------|
| 正常模式 | 关键操作节点（开始、步骤完成、成功、失败） |
| `--debug` 模式 | 完整 shell trace（`set -x`）+ 命令输出 |

---

## 15. Doctor 诊断命令

### 15.1 诊断范围

`debnas doctor` 检查：

| 类别 | 检查项 |
|------|--------|
| 系统兼容性 | Debian 版本、CPU 架构、磁盘空间、内存 |
| 配置一致性 | APT 源是否有效、Docker daemon.json 格式是否正确 |
| 网络连通性 | 能否访问当前配置的 APT 源 / Docker Hub / GitHub |
| DebNAS 状态 | 已安装模块列表、版本信息、各模块上次执行结果 |

不检查服务状态（服务状态查询由 `service-query` 模块单独处理）。

### 15.2 诊断行为

Doctor **仅报告问题**，不做任何自动修改。如需修复，提示用户执行对应模块或手动操作。例如"检测到 Cockpit 服务未运行 → 建议执行 `systemctl restart cockpit` 或 `debnas install cockpit`"。

---

## 16. 配置管理

### 16.1 敏感信息处理

密码/密钥等敏感信息（如邮件密码）明文存储在 `/etc/debnas/conf.d/<module>.conf`，文件权限设为 `600`：

```bash
config_write "mail" "password" "${user_input}"
chmod 600 "/etc/debnas/conf.d/mail.conf"
```

### 16.2 配置校验

用户手动编辑配置文件后格式有误 → **报错退出，明确指出哪一行有问题**：

```
[FAIL] 配置文件格式错误: /etc/debnas/conf.d/mail.conf 第 12 行
       期望值类型: true/false，实际值: "ture"
```

---

## 17. 代码与版本规范

### 17.1 代码风格

遵循 [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)。

### 17.2 版本号管理

采用日期版本号：`v2026.06`。

### 17.3 硬编码版本提取

模块中硬编码的第三方组件版本号（如 `cockpit-file-sharing v4.6.0`、`cockpit-identities v0.1.12`）提取到 `lib/system/urls.sh` 集中管理：

```bash
# lib/system/urls.sh
get_cockpit_components() {
  # 返回组件下载 URL 列表，版本号集中维护
  echo "https://github.com/45Drives/cockpit-file-sharing/releases/download/v4.6.0/..."
  echo "https://github.com/45Drives/cockpit-identities/releases/download/v0.1.12/..."
}
```

---

## 18. 测试策略

### 18.1 测试环境

维护一台固定测试 VM（Debian 12/13），模拟真实用户环境运行测试。不在 Docker 容器中测试（需要真实的 systemd、firewalld、Docker 等系统服务）。

### 18.2 测试范围

| 层级 | 内容 | 运行方式 |
|------|------|---------|
| 单元测试 | 纯逻辑函数（日志、配置解析、参数解析、状态管理） | BATS，可在 CI 中直接运行 |
| 集成测试 | 涉及系统修改的模块（apt install、systemctl 操作） | 在测试 VM 中真实运行 |

集成测试直接在测试 VM 中执行，不 mock 命令输出。

---

## 19. 兼容性与边界处理

### 19.1 Debian 版本检查

Debian 11 (bullseye) 及以下 → **立即报错退出**，提示需要 Debian 12 及以上，不尝试部分兼容。

### 19.2 预装软件的接管

如果系统上已手动安装过 Docker（或其他 DebNAS 管理的软件），再次执行对应模块时：

```
检测到 Docker 已安装（非 DebNAS 安装）。
是否由 DebNAS 接管管理？[y/N]:
```

用户确认后覆盖配置为 DebNAS 标准。拒绝则跳过。

---

## 20. 长时间操作的用户反馈

`apt update`、下载大文件等耗时操作 → **实时显示命令输出**，让用户看到进度和速度。不使用旋转动画或模糊的"请等待"提示。

---

## 21. i18n 国际化框架

### 21.1 消息存储

使用独立的语言文件：

```
lib/i18n/
  zh.sh       # 中文消息（默认）
  en.sh       # 英文消息
```

每个文件定义同名函数，返回对应语言的消息字符串。通过 `--lang` 参数选择加载。

### 21.2 缺失翻译处理

如果选了 `--lang en` 但某条消息尚无英文翻译 → 显示中文 + `[未翻译]` 标记：

```
Installing packages... [未翻译: 正在安装软件包]
```

---

## 22. CI/CD 与发布流程

### 22.1 CI 触发策略

每次 push 和 PR 都触发。

### 22.2 ShellCheck 严格程度

仅检查 error 级别（`--severity=error`）。

### 22.3 CHANGELOG

基于 conventional commits 自动生成（使用 `git-cliff` 等工具）。

### 22.4 发布流程

1. 打日期版本 tag（`v2026.06`）
2. 在 GitHub Release 页面编写 release notes
3. 不额外通知 QQ 群（Release 页面即为公告）

---

## 23. 安全功能交互

安全模块（SSH 加固、防火墙等）提供"推荐配置"一键应用，同时展示每项配置的细节和当前值，用户可以选择一键应用或逐项调整。不静默修改任何配置。

---

## 24. 补充设计决策

### 24.1 一键部署套餐

套餐定义不硬编码在脚本中，改用配置文件：

```
config/presets/
  basic.conf        # 基础环境：每行一个模块名
  secure.conf       # 安全环境：基础 + 安全模块
```

套餐脚本读取配置文件按序执行。预留扩展能力（未来可增加影音套餐等）。

### 24.2 Docker 应用策略

只提供 Docker 管理面板（Portainer/Dockge 二选一，未来精简为仅 Portainer），不提供应用商店。具体 Docker 应用由用户通过管理面板自行部署。Compose 模板中数据目录硬编码（如 `/opt/docker/portainer`），用户不可在部署时修改。

### 24.3 模块间信息共享

模块通过 `/etc/debnas/` 下的配置文件共享信息。如 `setup-mail-account` 写入 `/etc/debnas/conf.d/mail.conf`，后续 `enable-login-mail` 读取相同文件。避免模块间隐式依赖。

### 24.4 下载安全策略

第三方 .deb 包（45Drives 组件等）：下载失败 → 重试一次 → 仍失败则报错退出，拒绝安装。

### 24.5 并行操作自适应

`auto-update-hosts.sh` 等需要并行操作的模块，自动检测 CPU 核心数动态调整并发上限，避免低功耗 NAS 卡死。

### 24.6 离线能力

系统配置类模块（安全配置、BBR、ACL 等）无需网络即可运行。需网络的模块（apt 相关、Docker 相关）在文档中标注。不做离线打包。

### 24.7 --help 内容标准

每个模块的 `--help` 输出需包含：模块描述、依赖列表、支持的参数、使用示例。

### 24.8 文档站点

保持独立文档站点 `kekylin.github.io/debnas-docs/`。README 做概述和快速入口，详细说明放在文档站点。

### 24.9 Git 分支策略

保持 `main`（稳定）+ `dev`（开发）双分支。PR 合并到 dev，测试通过后合并到 main。

### 24.10 代码审查标准

PR 合并前需通过：代码风格符合 Google Shell Style Guide。ShellCheck 和 BATS 在 CI 中自动检查。

### 24.11 不显示预估耗时

网络环境差异太大，不显示模块预估耗时。

### 24.12 CODE_OF_CONDUCT

项目包含 `CODE_OF_CONDUCT.md`，使用 Contributor Covenant 模板。

### 24.13 命令行自动补全

暂不实现，后期视社区需求添加。

### 24.14 用户输入校验

所有用户输入做**基础校验 + 转义**：校验格式（如邮箱含 `@`、cron 表达式含 5 个字段），通过 `printf '%q'` 或变量引号转义防止命令注入。

### 24.15 第三方脚本处理

`install-cockpit.sh` 中 45Drives 仓库的 `curl | bash` 保持不变，45Drives 视为可信来源。

### 24.16 仓库完整性校验

`install.sh` 安装时自检文件完整性：与代码仓库内置的 checksum 文件对比，不匹配则警告。

### 24.17 磁盘空间检查

不检查。让 `apt` 等命令在空间不足时自然报错。

### 24.18 失败后变更处理

不尝试回滚。模块执行失败时立即退出，用户查看日志找到问题原因，手动修复后重新运行模块。大多数操作是幂等的，重跑时已完成的步骤自然跳过（如 apt 源已配置、包已安装）。

### 24.19 并发执行防护

使用文件锁（`/var/lock/debnas.lock`）防止同时运行多个 `debnas` 实例。检测到锁文件时提示"另一个 debnas 实例正在运行"并退出。

### 24.20 库加载策略

`bootstrap.sh` 全量加载所有库文件。启动耗时预期 <100ms（需在实际低功耗硬件如 J3455/N100 上验证）。如实测超过 500ms，再考虑按需加载。当前全量加载优先，保持简单可靠。

### 24.21 一键部署并行

串行执行，不引入并行逻辑。

### 24.22 钩子机制

不提供。高级用户可直接修改源码。

### 24.23 preflight 不可跳过

Debian 版本检查、root 权限检查为硬性要求，不提供跳过选项。

### 24.24 错误提示简洁化

错误提示仅报告原因，不附带解决建议。

### 24.25 安装完成后无"下一步"指引

不显示关联操作建议。

### 24.26 无新手引导模式

菜单结构已足够清晰，不额外添加引导。

---

## 25. 实施阶段

### Phase 1: 基础设施（纯新增，零风险）
1. 创建 6 个新库文件（apt.sh, args.sh, state.sh, cron.sh, config.sh, service.sh）
2. **重写** `lib/bootstrap.sh` — 从当前 25 行基础版扩展为带 cron 检测的完整版
3. 增强 `lib/core/logging.sh` — 增加文件日志输出
4. 创建 `lib/system/module-registry.sh` — 模块自动发现
5. ShellCheck 全量通过
> **Phase 1 结束时**：现有项目功能完整可用。新库已存在但未被调用（模块仍用旧方式 source）。可独立验证：`bash bin/main.sh` 正常运行。

### Phase 2: CLI + 入口（中等风险）
6. 重写 `install.sh` — git-clone 安装器
7. 创建 `bin/debnas` — CLI 调度器
8. 创建 `bin/module-runner.sh` — 标准化模块执行引擎
9. 重构 `bin/main.sh` → `bin/menu.sh` — 使用模块注册表
> **Phase 2 结束时**：`debnas` 命令可用，但菜单仍依赖硬编码的 MODULE_DESC（模块注册表已就绪但尚未被所有模块使用）。

### Phase 3: 模块标准化（中等风险，大量文件但逻辑不变）
10. 给 30 个模块添加 `@module:` 元数据头
11. 模块切换使用 `bootstrap.sh`（替代手动 source 3-6 行）
12. 菜单切换为自动发现
> **Phase 3 结束时**：模块注册完全自动化。`debnas menu` 和 `debnas install <module>` 均正常工作。

### Phase 4: 幂等性 + 配置（中等风险）
13. 核心模块幂等性检查
14. 统一配置管理
15. `debnas doctor` 诊断命令
> **Phase 4 结束时**：模块支持重复执行安全。doctor 命令可诊断系统状态。

### Phase 5a: Cron 统一（中等风险）
16. 用 `lib/system/cron.sh` 统一 4 个模块的 cron 实现，消除 `auto-update-hosts.sh` 中数十个 `if CRON_MODE` 守卫分支
> **Phase 5a 结束时**：cron 模式代码路径统一，所有模块通过框架管理定时任务。

### Phase 5b: 大模块拆分（中高风险）
17. 拆分 5 个大模块为目录式结构（先做 `block-threat-ips.sh` 验证模式，再批量拆分其余 4 个）
> **Phase 5b 结束时**：目录模块替代旧单文件，代码可读性显著提升。

### Phase 6: CI/CD（低风险）
18. 搭建 BATS 测试框架
19. 编写基础库单元测试（最高 ROI）
20. 配置 GitHub Actions：ShellCheck + BATS
21. 关键模块集成测试
> **Phase 6 结束时**：每次 push 自动运行测试。

### Phase 7: 文档与社区（低风险）
22. 创建 CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md
23. 创建 Issue/PR 模板
24. i18n 框架 + 英文文档
> **Phase 7 结束时**：项目达到成熟开源标准。

---

## 26. 风险评估

### 26.1 低风险优化

| 优化 | 原因 |
|------|------|
| Phase 1 全部内容 | 纯新增文件，不影响现有模块运行 |
| Phase 5a（cron 统一） | 仅改动 cron 相关代码，不影响模块核心逻辑 |
| Phase 7 CI/CD | 不影响运行时代码 |
| Phase 7 文档 | 不涉及代码 |
| 添加 `.editorconfig` / `.shellcheckrc` | 仅影响开发工具 |

### 26.2 需要测试环境验证的修改

| 优化 | 原因 |
|------|------|
| install.sh 重写 | 入口变化，需确认所有调用路径正常 |
| apt 锁检测 | 改变了软件安装时序 |
| trap 管理统一 | 影响所有模块的错误处理 |
| 幂等性检查 | 改变了模块执行流程 |
| cron 基础库提取 | cron 模式行为改变 |
| 大模块拆分 | 函数重新组织，调用方式变化 |

### 26.3 可能影响现有用户的调整

| 优化 | 影响 | 缓解措施 |
|------|------|---------|
| install.sh 改为 wget 引导 | 用户安装命令变化（从 pipe-to-bash 改为两步） | README 提供清晰的新命令 |
| 安装命令变化 | 老用户习惯 `bash <(wget ...)` 模式 | 两步命令 `wget ... && bash install.sh` 更安全，README 重点说明 |
| 模块拆分 | 大模块文件名可能变化 | 保留旧文件作为兼容层 |
| 参数接口标准化 | 模块命令行参数可能变化 | `--help` 文档说明新接口 |
| 网络环境询问 | 首次运行多一步交互 | 只问一次，之后记住 |

---

## 27. 设计原则

1. **模块独立性** — 每个模块可以单独执行，也可以被一键部署调用
2. **不替用户做决定** — 提供默认值但允许覆盖，不强制安装不需要的东西
3. **新手友好 + 专家可用** — 菜单给新手（≤3 级），子命令给专家（自动化）
4. **零运行时依赖** — Bash 5.x + Debian 基础工具，无 Python/Perl/Node
5. **每个文件有明确边界** — 库只提供通用功能，业务逻辑在模块中
6. **简洁高效的入口** — 一行命令完成安装，后续 `debnas` 全局可用

---

## 附录

### A. 文件统计

| 分类 | 当前数量 | 重构后数量 |
|------|---------|----------|
| 入口脚本 | 2 (install.sh + main.sh) | 4 (install.sh + debnas + menu.sh + module-runner.sh) |
| lib/core | 3 | 3 |
| lib/system | 5 | 12 (+7) |
| lib/ui | 2 | 2 |
| modules | 30 个单文件 | 22 个单文件 + 5 个目录模块 |
| config | 2 | 1 (+ 模块自带 config/) |
| 合计 | ~46 文件 | ~55+ 文件 |

### B. 最大/最复杂模块（优先重构）

| 模块 | 行数 | 重构方式 |
|------|------|---------|
| `block-threat-ips.sh` | 1,197 | 拆分为 download + ipset + firewall + cron |
| `auto-update-hosts.sh` | 1,126 | 拆分为 dns-resolve + connectivity + hosts-manager + cron |
| `backup-restore.sh` | 1,055 | 拆分为 backup + restore + verify |
| `cockpit-auto-bing-wallpaper.sh` | 358 | 拆分为 download + configure + cron |
| `check-system-updates.sh` | 447 | 拆分为 check + notify + cron |

### C. 对标的成熟开源项目

| 项目 | 借鉴点 |
|------|--------|
| **Pi-hole** | 一键安装、Web 管理、自动更新、社区活跃 |
| **DietPi** | 模块化系统优化、软件商店模式 |
| **angristan/openvpn-install** | 小而美的交互式部署、幂等性设计 |
