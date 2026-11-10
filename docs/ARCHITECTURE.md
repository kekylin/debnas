# DebNAS 架构文档

> 版本：2.5.0 | 更新：2026-11-10
> 更新触发：§三 公共 API 补充第一阶段收拢的公共函数（keyring/sshd 端口/cron_state/config_get_bool/get_primary_user 等）与 install.sh 校验区块单一来源；§4.5 补充只读工具约定与守卫行识别规则；双引导表加入 keyring.sh；PATH 补全改为只追加缺失目录

---

## 一、目录结构

```
debnas/
├── install.sh                    # 自包含引导安装脚本（零依赖；内嵌发布公钥，校验签名与 SHA256）
├── keys/debnas-release.asc       # 发布公钥（+ .fpr 主密钥指纹），update 验签用的可信副本
├── tools/release.sh              # 维护者发布脚本（embed-key / bump / 构建签名自检，不随安装部署）
├── README.md                     # 项目说明（中文）
├── CHANGELOG.md                  # 变更日志（Keep a Changelog 格式）
├── LICENSE                       # MIT 许可证
│
├── bin/                          # 入口脚本
│   ├── debnas                    # CLI 调度器（全局参数解析 → 子命令路由）
│   ├── menu.sh                   # 交互菜单（模块自动发现 + 部署方案）
│   ├── module-runner.sh          # 模块执行引擎（preflight → execute → report；--probe status|plan 只读探测）
│   └── doctor.sh                 # 系统诊断工具
│
├── lib/                          # 公共库（3 层架构）
│   ├── bootstrap.sh              # 完整加载入口（core + 全部 system + ui + 模块注册）
│   ├── bootstrap-core.sh         # 轻量加载入口（core + 基础 system）
│   ├── core/                     # 零依赖基础层
│   │   ├── constants.sh          # 退出码常量
│   │   ├── colors.sh             # ANSI 颜色（NO_COLOR / 非 tty 检测）
│   │   └── logging.sh            # 4 级日志（info/warning/error/fatal）
│   ├── system/                   # 系统操作封装
│   │   ├── apt.sh                # APT 安全操作（锁等待 + 去重安装）
│   │   ├── apt-pinning.sh        # APT 优先级固定
│   │   ├── args.sh               # 全局参数解析（CLI > 环境变量 > 配置文件）
│   │   ├── backup.sh             # 集中备份（/var/backups/debnas，保留策略）
│   │   ├── config.sh             # 统一配置管理（read/write/delete）
│   │   ├── cron.sh               # 统一 Cron 管理（注册/删除/列表）
│   │   ├── dependency.sh         # 命令→包映射 + 依赖检测
│   │   ├── feature.sh            # 模块功能启用状态管理
│   │   ├── installer.sh          # 安装/更新/卸载逻辑（发布产物下载 + gpgv/SHA256 校验；校验区块是 install.sh 副本的单一来源）
│   │   ├── keyring.sh            # 第三方 APT 源公钥下载 + 主密钥指纹校验 + 原子安装
│   │   ├── layout.sh             # 文件布局常量 + 通知邮箱读写 + 登录通知 PAM 行
│   │   ├── manifest.sh           # 文件清单（/var/lib/debnas/manifest，debnas files）
│   │   ├── migration.sh          # 版本迁移框架 + 文件布局迁移
│   │   ├── module-registry.sh    # 模块自动发现 + 拓扑排序
│   │   ├── module-probe.sh       # 模块只读探测契约加载器（module_status/module_plan）+ 状态缓存
│   │   ├── service.sh            # 幂等服务管理（systemd）
│   │   ├── state.sh              # 模块状态追踪
│   │   ├── tempfile.sh           # 临时文件管理（信号安全清理）
│   │   ├── urls.sh               # URL 探测 + 镜像源常量
│   │   └── utils.sh              # OS 检测 + 工具函数
│   ├── ui/                       # 终端 UI
│   │   ├── styles.sh             # 样式输出（标题/菜单项/提示/分隔线）
│   │   ├── menu.sh               # 旧版菜单工具（ui_menu，非 TTY / DEBNAS_UI=classic 回退路径）
│   │   ├── dashboard.sh          # 方案 A 双栏 TUI 仪表盘（默认交互界面，仅 bin/menu.sh 加载）
│   │   ├── textwidth.sh          # 显示宽度计算/截断/补齐（CJK 双宽）
│   │   └── sysinfo.sh            # 仪表盘系统概况采集（/proc，只读）
├── modules/                      # 功能模块（25 个）
│   ├── *.sh                      # 单文件简单模块（如 sources.sh、firewall.sh）
│   └── */module.sh               # 目录式复杂模块（如 hosts-sync/module.sh）
│       └── *.sh                  # 子模块文件
│   └── cockpit-shares/plugin/     # Cockpit 插件「共享管理」静态文件（HTML/CSS/JS，见 §八）
│
├── tests/                        # 测试
│   ├── run.sh                    # 测试入口
│   ├── test-plan.md              # 手动测试计划
│   ├── helpers/                  # BATS 共享设置
│   └── unit/lib/                 # 单元测试（按库文件组织）
│
└── docs/                         # 项目文档
    ├── PROJECT_OVERVIEW.md       # 项目概览
    ├── ARCHITECTURE.md           # 架构文档（本文件）
    ├── DEVELOPMENT_GUIDE.md      # 开发指南
    ├── TESTING_GUIDE.md          # 测试指南
    └── TECH_DEBT.md              # 技术债务
```

## 二、库分层架构

```
┌──────────────────────────────────────────────────┐
│                    bin/ 入口层                     │
│  debnas / menu.sh / module-runner.sh / doctor.sh  │
├──────────────────────────────────────────────────┤
│                  lib/ 公共库层                     │
│                                                    │
│  ┌────────────────────────────────────────────┐   │
│  │                lib/ui/                     │   │
│  │             (终端展示)                     │   │
│  └────────────────────┬───────────────────────┘   │
│                       │                           │
│  ┌────────────────────▼───────────────────────┐   │
│  │               lib/system/                  │   │
│  │  apt / service / config / cron /           │   │
│  │  state / tempfile / args / utils /         │   │
│  │  dependency / installer / migration /      │   │
│  │  module-registry / urls / ...              │   │
│  └────────────────────┬───────────────────────┘   │
│                       │                           │
│  ┌────────────────────▼───────────────────────┐   │
│  │               lib/core/                    │   │
│  │  constants / colors / logging              │   │
│  │  (零依赖，纯函数)                          │   │
│  └────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────┤
│               modules/ 模块层                      │
│  功能模块（纯业务逻辑，依赖 lib/ 函数）              │
└──────────────────────────────────────────────────┘
```

### 依赖方向（严格单向）

```
modules/ → lib/bootstrap.sh → lib/bootstrap-core.sh → lib/core/
                │                      │
                ├── lib/system/*.sh ───┘ (全部 20 个)
                ├── lib/ui/*.sh       (仅 bootstrap.sh)
                └── lib/system/module-registry.sh
```

**设计原则：上层依赖下层，下层不感知上层。`lib/core/` 零依赖，不涉及文件 I/O。**

### 双引导策略

| 入口 | 加载内容 | 使用场景 |
|------|---------|---------|
| `bootstrap-core.sh` | core ×3 + system ×11（layout/manifest/backup/utils/dependency/tempfile/urls/apt-pinning/apt/service/keyring） | 轻量模块、定时任务 |
| `bootstrap.sh` | bootstrap-core + system ×8（args/state/cron/config/installer/migration/module-registry/module-probe）+ ui（仪表盘三件 dashboard/textwidth/sysinfo 仅由 bin/menu.sh 加载） | bin/ 入口、交互模块 |

`bootstrap.sh` 在 cron 模式下自动跳过 UI 加载（检测 `DEBNAS_CRON_MODE=1`）。

**PATH 补全**：`bootstrap-core.sh` 只把缺失的 `/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin` 追加到 `PATH` 末尾（逐个检查 `:$PATH:` 是否已含），不再整体前置。权衡：root 的 PATH 由 root 自己控制，追加已能解决 cron（`PATH=/usr/bin:/bin`）下缺 `/usr/sbin` 的原问题；前置会让调用方放在前面的目录失效（测试 mock 被系统 `/usr/sbin/sysctl` 抢先，root 测试机上会真的改内核参数）。

## 三、核心抽象（公共 API）

所有模块应优先复用以下函数，不满足需求时才新增代码（新代码的强制要求见 DEVELOPMENT_GUIDE §3.6）。

| 函数 | 用途 |
|------|------|
| `write_file_if_changed` | 幂等文件写入（比较后写入，避免无谓覆盖；原子替换；修改前自动备份并登记清单）。返回 0 已写入 / 1 未变更 / 2 失败或缺参数；**空内容合法**，写 0 字节空文件（调用方需自行防止误把空串写进关键配置） |
| `debnas_backup_file` | 把文件备份到 `/var/backups/debnas/<运行ID>/<原路径>`（替代同目录 `.bak`） |
| `manifest_add` / `manifest_list` | 登记/列出 DebNAS 改过的系统文件（`debnas files`） |
| `notify_email_get` / `notify_email_set` | 读写系统通知收件邮箱（`/etc/debnas/notify_email`，旧路径回退） |
| `service_ensure` | 幂等服务管理（started/stopped/enabled/disabled/restarted） |
| `apt_install_packages` | 智能包安装（自动过滤已装包 + 防重复 apt update） |
| `apt_remove_safe` | 安全包卸载（含自动清理） |
| `sysctl_persist` / `sysctl_set` | 内核参数持久化（经 `write_file_if_changed`，替换同名旧值）/ 临时设置 |
| `check_dependencies` | 命令→包映射、依赖检测 |
| `ensure_module_deps <模块>` | 命令依赖（分级处理）+ 依赖模块就绪检查；module-runner preflight 与交互式模块共用 |
| `config_read/write/delete` | 统一配置管理 |
| `cron_register / cron_unregister` | Cron 任务管理（含表达式校验 + 冲突去重） |
| `tempfile_create / tempfile_register` | 临时文件管理 + 信号清理 |
| `debnas_locked <锁名> <命令...>`（tempfile.sh） | 在 flock 互斥锁内执行命令（锁文件在临时基目录下，同名锁可重入；无 flock 时直接执行）。`cron_register/cron_register_variant/cron_unregister`（锁 cron）、`config_write/config_delete`（锁 config）、`state_set`（锁 state）内部已使用 |
| `bg_group_begin` / `bg_group_end` / `bg_group_kill`（utils.sh） | 后台探测任务自成进程组（临时 `set -m`），终止时 kill 整个进程组，子 shell 里的 systemctl/apt-get 不会成为孤儿（module-probe、sysinfo 使用） |

### 3.1 第一阶段收拢的公共函数（2026-11-09）

以下函数替代各模块里的自写实现（替换清单见第二阶段计划）；签名与语义：

| 函数（文件） | 签名 | 语义 |
|------|------|------|
| `gpg_key_fingerprint_verify`（keyring.sh） | `<keyfile> <expected_fpr> [显示名]` | 临时 GNUPGHOME 解析公钥（armored/二进制均可）；要求**恰好一把主密钥**且**主密钥**指纹等于期望值（大小写/空格不敏感，子密钥指纹不算）；含私钥、已吊销、无 gpg 均返回 1 |
| `keyring_install_verified`（keyring.sh） | `<url> <expected_fpr> <dest_keyring> [--dearmor] [--label 名称]` | curl 带超时（30s/10s）、只允许 http(s)、≤1MB、失败重试 1 次 → 校验 → `--dearmor` 时转二进制（已是二进制原样）、否则原样存放（目标 `.asc` 要求 armored）→ 再校验 → 内容相同跳过（`cmp`）→ 同目录临时文件 `mv -fT` 原子替换（不截断已有文件，替换前集中备份、写入后登记清单）。缺 curl/gpg 时报错返回，不自动安装 |
| `sshd_listen_ports` / `sshd_listen_ports_csv`（service.sh） | `[--no-session]` | sshd 实际监听端口：`sshd -T` → `sshd_config` + `sshd_config.d/*.conf` 的 Port → 默认 22；`ListenAddress` 自带的端口（`a.b.c.d:port`、`[v6]:port`）同样计入，两条路径都解析；只输出 1..65535；另追加当前 SSH 会话端口（`SSH_CONNECTION` 第 4 字段，`--no-session` 不追加；注意 sudo 默认不保留该变量）。升序去重，每行一个 / 逗号分隔 |
| `cron_state`（cron.sh） | `<模块> [变体参数]` | 输出 `on`/`off`/`unknown`：非 root 读不到 root crontab → unknown；无 crontab 命令 → off；变体参数即 `cron_register_variant` 的第 3 个参数，按行尾精确匹配 |
| `config_get_bool`（config.sh） | `<键> <默认值>` | 读 debnas.conf 布尔开关，不输出只返回：0 开（1/true/yes/on）、1 关（0/false/no/off）；未设置/无法识别按默认值；默认值传空串时返回 2（三态开关，如 `file_sharing_nfs`） |
| `get_primary_user`（utils.sh） | 无 | 首个 UID ≥ 1000 的普通用户（排除 nobody/65534），纯 bash 解析 passwd；找不到输出空，始终返回 0。`get_first_regular_user` 为 deprecated 薄包装 |
| `get_system_codename`（utils.sh） | 无 | 优先读 os-release 的 `VERSION_CODENAME`（逐行解析，不 source、不污染变量、不 fork）；为空时回退 `lsb_release -cs`（Debian 12 上是 Python，慢）。`_get_os_id` 同理优先 os-release 的 `ID`。路径可由 `DEBNAS_OS_RELEASE` 覆盖 |
| `config_get_url`（config.sh） | `<键> <默认地址>` | 读 debnas.conf 中可换镜像的地址（留空=默认），只接受不含空白的单个 http(s) 地址、去掉末尾 `/`；非法时 log_error 返回 1（替代 `read_45drives_url` / `read_tailscale_url`） |
| `pkg_is_installed`（apt.sh） | `<包名>` | 只读查询 dpkg 状态是否为 `installed`（仅剩配置文件不算），不打日志（替代各模块 `_xx_pkg_installed`） |
| `get_module_field_var`（module-registry.sh） | `<变量名> <模块> <字段> [默认值]` | `get_module_field` 的无子 shell 版本（`printf -v` 写变量），热路径使用 |
| `pinning_render` / `pinning_file_exists`（apt-pinning.sh） | `<代号> <包模式...>` / `<文件>` | 生成 backports 优先级文件内容（无时间戳，可与现有文件比较做预演）/ 只读判断文件存在、不打日志。`write_pinning_file` 改经 `write_file_if_changed` 写入（幂等、可备份可登记清单）；`check_pinning_status`（带日志）为 deprecated |
| `release_verify` / `release_dearmor` / `release_valid_tag` / `release_valid_branch` / `release_discard`（installer.sh 的 DEBNAS-RELEASE-VERIFY 区块） | 同旧 `verify_release` 等 | 发布产物校验的**唯一实现**。install.sh 中的同名区块由 `tools/release.sh`（`--embed-key` / `--bump` / `--sync-verify`）从 lib 同步生成，构建发布时检查 tag 内两份一致，`tests/unit/lib/test-release-sync.bats` 断言逐字一致；`installer_verify_release` / `installer_dearmor_key` / `installer_valid_*` 与 install.sh 的 `verify_release` / `dearmor_pubkey` / `is_valid_*` 保留为薄包装 |
| `deploy_tree` / `deploy_recover` / `deploy_lock` / `deploy_unlock`（installer.sh 的 DEBNAS-DEPLOY 区块） | `<源目录> <安装目录>` / `<安装目录>` / 无 / 无 | 安装目录整树替换的**唯一实现**（`installer_deploy` 为薄包装，install.sh 中的副本由 `tools/release.sh` 同步）：在同级 `.<名>.new` 组装完整新树（新代码 + 旧目录中的非代码条目如 RELEASE），再在忽略 INT/TERM/HUP 的子 shell 中两次 `mv -T` 切换（`<安装目录>`→`.<名>.old`、`.<名>.new`→`<安装目录>`）；组装失败旧安装不动；被 SIGKILL 打断在两次 rename 之间时，`deploy_recover`（bin/debnas 启动、update、install.sh 调用；/usr/local/bin/debnas 包装脚本在安装目录缺失时同样回滚）把 `.old` 改回，并清理暂存树与旧版逐目录部署留下的 `.X.old`。`deploy_lock` 对更新锁加 flock（非阻塞，锁被占用即报错；`deploy_recover` 遇锁被占用不碰残留） |
| `installer_version_lt`（installer.sh） | `<a> <b>` | 先按 `sort -V` 比数字部分；数字相同时预发布（`-rc1`/`rc1`/`~beta`）低于正式版。`debnas update` 缺少 RELEASE 标记时用 `DEBNAS_VERSION` 做防降级基准，`tools/release.sh --bump` 同步改 `lib/system/args.sh` 的 `DEBNAS_VERSION` |
| `installer_load_release_key`（installer.sh） | `<安装目录> <输出 keyring>` | `keys/debnas-release.fpr` 每行一个主密钥指纹（空行/# 注释跳过），输出逗号分隔；`release_verify` 的期望指纹可为逗号分隔列表，任一匹配即通过（为换钥留口子） |

## 四、模块系统

### 4.1 元数据标记

每个模块文件头部包含 `# @key: value` 格式的元数据注释：

```bash
# @module: docker-ce           # 模块唯一标识（文件名或显式声明）
# @name: 安装 Docker CE       # 显示名称
# @category: 容器管理           # 分类
# @depends: wget,curl          # 依赖的系统命令
# @depend_modules: firewall    # 依赖的其他模块
# @version: 1.0.0              # 版本号
# @order: 50                   # 菜单排序权重
# @cron: true                  # 是否支持定时执行
# @cron_schedule: 0 0 * * *   # 默认 cron 表达式（每天 00:00）
# @debian_min: 12              # 最低 Debian 版本
# @kind: config                # 可选：install（安装类）| config（配置类），仅影响仪表盘 absent 的显示文案（§4.5.1）
```

### 4.2 模块发现与依赖解析

`lib/system/module-registry.sh` 负责：

1. **自动发现** — 扫描 `modules/*.sh`（文件模块）和 `modules/*/module.sh`（目录模块）
2. **元数据解析** — 读取文件前 30 行的 `# @key: value`，存入 `_MODULE_REGISTRY[]` 关联数组
3. **拓扑排序** — `resolve_module_deps()` 使用递归 DFS 解析 `@depend_modules` 依赖链，检测循环依赖
4. **依赖状态检查** — `module-runner.sh` 在运行目标模块前，检查所有依赖模块的状态；若未安装，则提示用户先执行依赖模块。
5. **交互式标记** — `@interactive: true` 标记（6 个模块使用）通知菜单系统该模块有交互式 UI，避免在非交互环境中误触。

### 4.3 模块执行流程

```
module-runner.sh 调用 run_module()
  │
  ├── preflight_dry_run       → 检查 --dry-run 标志
  ├── preflight_root          → 检查 root 权限
  ├── preflight_debian_version → 检查 Debian 版本（@debian_min）
  ├── preflight_dependencies  → 检查命令依赖（@depends）
  ├── resolve_module_deps     → 递归 DFS 解析 @depend_modules 依赖图
  │
  ├── execute_module          → bash 子进程执行模块 main()
  │
  └── run_report              → 写入 state + 日志
```

### 4.4 模块文件组织

| 类型 | 结构 | 示例 |
|------|------|------|
| 单文件模块 | `modules/<name>.sh` 包含全部逻辑 | `firewall.sh`, `docker-ce.sh`, `sources.sh` |
| 目录模块 | `modules/<name>/module.sh` 入口 + 子模块文件 | `hosts-sync/`, `sys-patches/`, `threat-ips/` |

目录模块入口必须 `source` 所有子模块，必要时使用 `export -f` 导出函数。

### 4.5 模块只读探测契约（module_status / module_plan）

> 2026-11-09 引入，服务于方案 A 仪表盘的"状态列"与"执行计划·预演"。两个函数均**可选**；未实现的模块照常可执行，界面显示"? 未知 / 未提供预演"。

#### 4.5.1 函数契约

| 函数 | 输出 | 取值 | 硬性要求 |
|------|------|------|---------|
| `module_status` | **一行** `状态码\|简短说明` | 状态码 ∈ `applied`（已应用）`running`（运行中）`partial`（部分完成）`absent`（未安装/未配置）`warn`（需注意）`error`（异常）`unknown` | 只读；< 300ms；不联网、不 `apt update`、不读 stdin、不写文件 |
| `module_plan` | **多行** `类型\|目标\|备注` | 类型 ∈ `pkg`（要装的包，目标可空格分隔多个）`write`（会改的文件，备注写明备份位置或"原地修改无备份"）`service`（服务启停/自启）`port`（放行端口/服务）`cron`（定时任务）`user`（用户/组变更）`risk`（断开 SSH、需重启、权限放大等风险）`info`（其他说明） | 无副作用；可读文件、查询 `dpkg-query` / `systemctl is-active` / `config_read`；已满足的项不列（如已安装的包）；不联网 |

- 说明文字不得包含换行或 ANSI 转义；加载器会清除控制字符，非法状态码归为 `unknown`、非法类型归为 `info`。
- 仪表盘把 `applied` / `running` 计入分类完成度（如 `2/4`）；模块未提供 `module_status`（或返回 `unknown`）时，用 `module-runner` 写入的 state 文件补充（成功记录 → `applied`，失败记录 → `error`）。
- **只读工具约定**：没有"已应用"概念的只读工具（sys-check、service-query 等）在 `module_status` 中返回 `unknown|只读工具 …`（说明以"只读工具"开头，常量 `MODULE_STATUS_READONLY_PREFIX`）；这类结果**不合并执行记录**，不会因执行过一次就显示为"已应用"。
- **`absent` 的显示文案**：仪表盘显示"○ 未安装"或"○ 未配置"。模块声明了 `@kind: install|config` 时按声明；未声明时按说明文字判断——以"未安装"开头（或说明为空）显示"未安装"，否则显示"未配置"。因此配置类模块的说明应写"未配置 …/未启用 …"；若配置类模块因前置软件缺失而说明以"未安装 X"开头（如壁纸"未安装 Cockpit"），应声明 `@kind: config`。
- 预演中多个模块的 `pkg` 合并去重为一行；`risk` 统一排在最后；依赖模块未完成且未一起勾选时，仪表盘自动追加一条 `risk`。
- **同批执行的依赖**：仪表盘探测 `module_plan` 时导出 `DEBNAS_PLAN_WITH=<本次执行的模块列表，空格分隔，依赖在前>`，模块可据此判断依赖是否会先执行（可选）。模块未处理时由仪表盘兜底：若某模块的 `@depend_modules` 也在本次列表中（必然排在前面），其 plan 里**以"<依赖模块名> 模块"或"「<依赖显示名>」"提到该依赖的 `risk`/`info` 行**视为"依赖缺失"提示，合并为一条 `info|<模块显示名>|将先执行依赖「<依赖显示名>」（<依赖模块名>）`。因此模块输出依赖缺失提示时应按此写法点名依赖（如"请先执行 docker-ce 模块"）。

#### 4.5.2 加载机制（守卫）

模块末尾的 main 调用改为受守卫形式（**唯一需要改动的一行**）：

```bash
# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
```

探测流程（`lib/system/module-probe.sh`）：

```
module_probe <模块> status|plan
  ├── 模块入口文件没有行首守卫行 if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]（注释/字符串中出现不算）
  │      → 绝不 source，直接返回回退结果
  │      status → unknown|未提供状态检测      plan → info|<模块>|未提供预演；将直接执行模块
  └── 含守卫 → 后台子 shell：export DEBNAS_MODULE_ACTION=<动作>; _DEBNAS_BOOTSTRAPPED=1（库不重复加载）
         source 模块（stdin=/dev/null，stdout/stderr 丢弃）→ 调用 module_status / module_plan
         超时（status 3s / plan 8s，可由 MODULE_PROBE_*_TIMEOUT 覆盖）→ 终止并返回 unknown / 超时说明
         输出经 module_status_normalize / module_plan_normalize 规范化
```

| 入口 | 用途 |
|------|------|
| `module_probe <模块> status\|plan` | 同步探测（带超时），预演使用 |
| `module_status_collect_start <缓存目录> <模块...>` / `module_status_collect_poll` | 仪表盘进入时并行异步采集全部模块状态；执行后只对执行过的模块重新采集；超时/失败不影响界面 |
| `module_status_get <模块>` | 读缓存（`_MODULE_STATUS`） |
| `bash bin/module-runner.sh --probe status\|plan <模块>` | CLI 入口：不做 preflight（无需 root）、不写 state 与日志、不执行 main |

安全约束：
- `module-runner.sh` 执行模块时 `unset DEBNAS_MODULE_ACTION`，防止该变量从环境泄漏导致受守卫模块静默跳过 main。
- 守卫只阻止 main；模块顶层（main 之外）的代码在探测时仍会执行，**顶层只允许变量/函数定义与 source**（与 TECH_DEBT"应避免的坑 #1"一致）。目录模块被 source 的子文件同样适用。
- 模板与改造清单见 [DEVELOPMENT_GUIDE.md §4.6](DEVELOPMENT_GUIDE.md)。

### 4.6 交互界面（方案 A 仪表盘）

`bin/menu.sh` 在 `ui_dashboard_available`（stdin/stdout 为 TTY、`TERM` 非 dumb、可获得 UTF-8 字符语义、未设 `DEBNAS_UI=classic`）为真时调用 `ui_dashboard_main`，否则走旧版 `main_menu_loop`（`lib/ui/menu.sh` 的 `ui_menu`，代码保留）。

| 文件 | 职责 |
|------|------|
| `lib/ui/dashboard.sh` | 模型（分类/条目/勾选）、布局（宽屏双栏 / 窄屏单栏 / 过小提示）、整帧合成 + 逐行差量刷新、按键处理、预演汇总、执行编排 |
| `lib/ui/textwidth.sh` | `ui_str_width` / `ui_str_fit` / `ui_str_wrap`：按码点区分 CJK 双宽、零宽字符，保证边框对齐 |
| `lib/ui/sysinfo.sh` | `/proc` 采集 CPU（两次采样差值）/内存/运行时长、`df` 根分区、启动时取 IP；待更新包数后台 `apt-get -s upgrade`（只读缓存，结果按 apt 列表 mtime 跨会话缓存） |

执行流程：离开备用屏幕 → 打印完整模块列表与预演 → `[y/N]` 确认（`--yes` 跳过）→ 依赖排序后逐个 `bash bin/module-runner.sh <模块>` 流式输出（依赖模块失败则跳过下游）→ 汇总 → 按键返回仪表盘并只刷新执行过的模块状态。设计规范见 [DESIGN_SPEC_UI.md §8](DESIGN_SPEC_UI.md)。

## 五、CLI 调度器

### 5.1 子命令路由

`bin/debnas` 作为统一 CLI 入口（通过软链接安装到 `/usr/local/bin/debnas`）：

```
debnas                          → cmd_menu()     → bin/menu.sh
debnas install <module>         → cmd_install()  → bin/module-runner.sh
debnas run <module>             → cmd_install()  → bin/module-runner.sh (同)
debnas config <key> [value]     → cmd_config()   → 直接操作
debnas update                   → cmd_update()   → installer.sh
debnas uninstall                → cmd_uninstall() → 直接操作
debnas doctor                   → cmd_doctor()   → bin/doctor.sh
debnas cron add|remove|list     → cmd_cron()     → cron.sh
debnas --help                   → 打印帮助
```

### 5.2 全局参数解析

`lib/system/args.sh` 中的 `parse_global_args()` 按优先级解析：

```
CLI 标志 > 环境变量 > /etc/debnas/debnas.conf
```

支持的全局参数：`--region`、`--dry-run`、`--yes`、`--cron`。

## 六、运行时环境

| 项目 | 说明 |
|------|------|
| 代码目录 | `/opt/debnas/` |
| 全局命令 | `/usr/local/bin/debnas`（→ `/opt/debnas/bin/debnas` 软链接） |
| 配置文件 | `/etc/debnas/debnas.conf` + `/etc/debnas/conf.d/` |
| 日志目录 | `/var/log/debnas/` |
| 状态目录 | `/var/lib/debnas/state/` |
| 临时目录 | root：`/run/debnas/`（0700，普通用户无法抢先创建）；非 root：`/tmp/debnas/`（属主/符号链接校验）。会话级 PID 子目录，退出自动清理；`debnas_locked` 的锁文件也在此 |
| 更新锁 | `/run/debnas-update.lock`（`DEBNAS_UPDATE_LOCK` 可覆盖），install.sh 与 `debnas update` 共用 |
| 备份目录 | `/var/backups/debnas/`（见 §七） |

## 七、文件布局

> 2026-11-09 起收敛到 FHS 同名目录：DebNAS 自有文件只出现在下表目录中；系统程序必须从固定位置读取的配置原地修改，修改前统一备份并登记清单。常量定义在 `lib/system/layout.sh`（均为 `${VAR:-默认}` 形式，测试可覆盖）。

### 7.1 DebNAS 自有目录

| 目录 | 常量 | 内容 |
|------|------|------|
| `/etc/debnas/` | `DEBNAS_ETC_DIR` | 配置：`debnas.conf`、`conf.d/*.conf`、`notify_email`（通知收件邮箱，640 root） |
| `/var/lib/debnas/` | `DEBNAS_VAR_DIR` | 状态/数据/报告：`state/`、`ops-report/`、`threat-ips/`（威胁 IP 配置与数据）、`manifest`（文件清单） |
| `/var/log/debnas/` | `DEBNAS_LOG_ROOT` | 日志：`<模块>-<时间>.log`、`threat-ips.log` |
| `/opt/debnas/` | `DEBNAS_OPT_DIR` | 程序代码 |
| `/var/backups/debnas/` | `DEBNAS_BACKUP_ROOT` | 集中备份（700 root，见 7.3） |
| `/usr/local/libexec/debnas/` | `DEBNAS_LIBEXEC_DIR` | 供系统程序回调的辅助脚本：`login-notify.sh`（目录 755、脚本 750 root，由 pam_exec 调用） |

旧路径对照（由 `migration_run_layout` 迁移，`debnas update` 每次执行，幂等，失败只告警；`debnas doctor` 会报告残留）：

| 旧路径 | 新路径 | 旧位置处理 |
|------|------|------|
| `/var/lib/firewalld-ipthreat/` | `/var/lib/debnas/threat-ips/` | 整目录搬迁；新目录已存在时逐文件补齐后删除空的旧目录；crontab 仍引用旧目录时不迁移并告警 |
| `/var/log/firewalld-ipthreat.log` | `/var/log/debnas/threat-ips.log` | 移动 |
| `/etc/exim4/notify_email` | `/etc/debnas/notify_email` | 改为指向新路径的符号链接（兼容一个版本）；`notify_email_get` 新路径不存在时回退旧路径 |
| `/etc/pam.d/login-notify.sh` | `/usr/local/libexec/debnas/login-notify.sh` | 先复制、再把 `common-session` 的 pam_exec 行原位替换为新路径（只保留一条），最后备份并删除旧脚本 |

### 7.2 原地修改的系统文件（不搬迁）

系统程序只从固定位置读取，DebNAS 原地修改，写入前自动备份（7.3）：

| 类别 | 文件 |
|------|------|
| 网络/主机 | `/etc/hosts`、`/etc/network/interfaces`、`/etc/NetworkManager/NetworkManager.conf`、`/etc/sysctl.d/11-debnas-bbr.conf`、`/etc/sysctl.conf` |
| 防火墙/防护 | `/etc/firewalld/zones/*.xml`、`/etc/firewalld/ipsets/*.xml`、`/etc/fail2ban/jail.local`、`/etc/fail2ban/action.d/mail-whois.local` |
| 登录/审计 | `/etc/ssh/sshd_config(.d)`、`/etc/pam.d/su`、`/etc/pam.d/common-session`（pam_exec 行）、`/etc/profile`（history 审计）、`/var/log/history/`（审计目录） |
| APT | `/etc/apt/sources.list.d/*.sources`、`/etc/apt/sources.list`（迁移为 DEB822 后备份并移除）、`/etc/apt/preferences.d/*.pref`、`/etc/apt/keyrings/`、`/usr/share/keyrings/` |
| 邮件 | `/etc/exim4/update-exim4.conf.conf`、`/etc/exim4/exim4.conf.localmacros`、`/etc/exim4/passwd.client`、`/etc/email-addresses` |
| 应用 | `/etc/cockpit/cockpit.conf`、`/etc/samba/smb.conf`（仅追加 `include = registry`）、`/etc/cockpit/issue.cockpit`、`/etc/cockpit/branding/`、`/etc/motd`、`/etc/docker/daemon.json`、`/etc/default/sysstat`、`/etc/sysstat/sysstat`、`/etc/logrotate.d/` |
| 定时任务 | root crontab 中以 `# DEBNAS-CRON: <模块>` 结尾的条目 |

### 7.3 集中备份（`lib/system/backup.sh`）

- `write_file_if_changed` 在**内容确实变化且原文件存在**时调用 `debnas_backup_file`，把原件 `cp -a` 到 `/var/backups/debnas/<YYYYmmdd-HHMMSS-pid>/<原绝对路径>`（保留权限属主）；模块需要删除/移走文件时也应先调用 `debnas_backup_file`，不再在原目录留 `.bak`
- 运行 ID 在首次加载库时生成并 `export DEBNAS_BACKUP_RUN_ID`，同一次 debnas 运行（含 module-runner 派生的子进程）共用一个目录；同一次运行内同一文件只备份第一次（即运行前状态）
- 每个文件首次被改前的原件另存 `/var/backups/debnas/original/<原路径>`，不参与轮转（避免高频定时任务把最初配置轮转掉）
- 保留策略 `debnas_backup_prune`：只保留最近 N 次运行目录（按目录名排序，日期/时间字典序 + pid 数值序），只删除名称严格匹配运行 ID 格式且位于备份根目录下的子目录，从不删除当前运行目录
- 开关：`DEBNAS_BACKUP_ENABLED` / `DEBNAS_BACKUP_KEEP`（环境变量）> `debnas.conf` 中 `backup_enabled` / `backup_keep` > 默认 `1` / `20`
- **备份失败只告警、继续写入**：备份是辅助恢复手段，许多调用方以 `|| true` 忽略写入返回值，若因备份盘满/只读而拒绝写入，安全加固等必要变更会被静默跳过。需要"无备份不删除"语义的调用方（如 sources 移除 `sources.list`）检查返回值，失败时回退为同目录 `.<时间戳>.bak` 改名（APT 忽略 `.bak` 后缀）
- 备份含敏感文件（如 `passwd.client`），因此根目录与运行目录均为 700 root

### 7.4 文件清单（`lib/system/manifest.sh`）

- `write_file_if_changed` 写入成功、`debnas_backup_file` 备份成功、布局迁移改动旧文件时调用 `manifest_add <路径>`，登记到 `/var/lib/debnas/manifest`：每行 `路径<TAB>首次登记时间<TAB>来源模块`，同一路径只登记一次；DebNAS 自有目录下的文件不登记；登记失败不影响调用方
- 来源模块：`DEBNAS_MANIFEST_SOURCE` 环境变量优先，否则从入口脚本路径推断（`modules/<名>.sh` / `modules/<名>/module.sh`）
- `manifest_list`（`debnas files`）分组输出：DebNAS 自有目录、修改过的系统文件（是否仍存在、备份份数）、root crontab 的 DEBNAS-CRON 条目、审计目录 `/var/log/history`（原地保留）
- 清单只覆盖经 `write_file_if_changed` / `debnas_backup_file` 的写入；`sed -i`、`firewall-cmd`、`crontab` 等直接改动不会自动登记

## 八、Cockpit 插件「共享管理」（cockpit-shares）

> 2026-11-09 新增，替代 45Drives cockpit-file-sharing 作为默认共享管理界面；两者二选一，不同时安装。

### 8.1 文件与部署

| 项目 | 说明 |
|------|------|
| 源码 | `modules/cockpit-shares/plugin/`：`manifest.json`、`index.html`、`shares.js`、`shares.css`（纯静态，无构建步骤、无第三方依赖、不引用 CDN） |
| 安装位置 | `/usr/share/cockpit/debnas-shares/`（目录 755、文件 644、root 属主，`install` 命令部署，内容相同跳过，删除源中已不存在的文件） |
| 菜单 | Cockpit 左侧系统菜单「共享管理」（`manifest.json` menu，order 75，紧随「账户」） |
| 随安装器分发 | 插件位于模块目录内，`installer_deploy` / `install.sh` 复制 `modules/` 时一并带上，无需改部署列表 |

### 8.2 样式来源

Cockpit 2xx 起不再提供 `base1/patternfly.css`：Debian 12 backports（337）与 Debian 13（337 / backports 371）的 `cockpit-bridge` 中 `base1/` 只有 `cockpit.js` 与翻译文件，各页面把 PatternFly 6 打包进自己的 CSS。插件因此引用 Cockpit 自带「账户」页的 `../users/users.css`（`cockpit-system` 包，PatternFly 6 组件 + 设计令牌 + 字体 + 深色主题）与 `../../static/branding.css`，`shares.css` 补充自绘标签页等布局；该 CSS 只打包了账户页用到的组件（无 tabs / description-list），因此本插件只使用其中存在的组件类。检测不到 PatternFly 6（如 Debian 12 主仓 cockpit 287 为 PatternFly 5）时给 `<html>` 加 `ds-nopf`，启用 `shares.css` 末尾的兜底样式。深色主题沿用 Cockpit 约定（`localStorage["shell:style"]` → `pf-v6-theme-dark`）。

### 8.3 与 45Drives 共用后端

| 数据 | 读写方式 |
|------|---------|
| Samba 共享 | Samba 注册表：`net conf listshares/showshare/addshare/setparm/delparm/delshare`；编辑时以注册表当前值为基准逐项 setparm/delparm |
| Samba 全局项 | 注册表 `[global]`（workgroup、server string、map to guest、server min protocol），生效值用 `testparm -s --parameter-name=` 读取，被 smb.conf 覆盖时提示 |
| 注册表开关 | `smb.conf` `[global]` 需 `include = registry`：模块安装时自动追加（`write_file_if_changed`，集中备份）；插件内缺失时提示并可一键追加（先写 `smb.conf.debnas-<时间>.bak`，带 tag 写入，`testparm` 失败自动恢复） |
| 手写共享 | smb.conf 中不在注册表的共享只读展示；可选 `net conf import smb.conf <名称>` 导入，勾选后才从 smb.conf 删除对应段（先备份） |
| NFS 导出 | `/etc/exports.d/cockpit-file-sharing.exports`（语法同 `/etc/exports`，保留注释与无法解析的行），不碰 `/etc/exports`；保存前重新读取并与加载时内容比较，`cockpit.file().replace(内容, tag)` 原子替换，`exportfs -ra` 失败自动回滚 |
| Samba 用户 | `pdbedit -L` 列表；`smbpasswd -s -a <用户>` 密码经 stdin 传入；`smbpasswd -x` 删除；系统用户/组增删交给 Cockpit「账户」页 |

安全约定：命令一律 `cockpit.spawn([参数数组], { superuser: "require" })`，不使用 `cockpit.script`/shell；共享名、路径（拒绝 `/`、`/etc`、`/usr`、`/boot`、`/proc`、`/sys` 等系统目录，`realpath` 解析后再校验并确认是目录）、用户名、参数键值白名单校验；参数值禁止控制字符且不得以 `-` 开头；界面一律 `textContent`，不用 `innerHTML`。未获管理员权限时显示提示，引导点击 Cockpit 顶栏「受限访问/管理员访问」。

### 8.4 二选一逻辑

- `debnas.conf`：`file_sharing_ui=debnas`（默认）| `45drives`；`file_sharing_nfs=1|0|留空`（留空：已装保持、交互询问、非交互不装）
- 一键方案（`config/solutions/*.list`）只列 `cockpit-shares`：`file_sharing_ui=45drives` 时该模块 `exec` 执行 `modules/cockpit-45drives.sh`
- `cockpit-shares`（debnas）检测到 `cockpit-file-sharing` 已安装：交互模式确认后 `apt remove`（先 `apt-mark manual` samba/nfs 防 autoremove 连带卸载）；非交互 / `--yes` 按配置执行；拒绝则中止。`cockpit-identities` 不安装也不卸载
- `cockpit-45drives` 检测到 `/usr/share/cockpit/debnas-shares`：交互确认后删除（`rm -rf` 前校验路径非空且严格等于固定常量）；非交互仅当配置为 `45drives` 才删除，否则中止；安装成功后写入 `file_sharing_ui=45drives`
