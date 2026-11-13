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

### Added
- `debnas check-update`：只读版本检测——用已安装目录的发布公钥验签 main 分支的 `LATEST` 指针，与已安装版本比较；不下载代码包、不持更新锁、不修改安装目录。退出码 `0`=已是最新、`1`=有新版本、`2`=检查失败（公钥缺失 / 指针验签失败 / 网络不可达 / 指针回放）。`debnas update` 与它共用 `release_check_latest`，两处判断不会再分叉
- 一级菜单「关于项目」改为二级菜单：**项目简介**（原「关于项目」的简介内容 + 当前版本）、**检查脚本更新**（检查新版本，确认后调用 `debnas update --tag <最新版本>`；非交互环境只检查不更新）。检查逻辑与 `debnas check-update` 共用 `installer.sh` 的 `release_check_latest` / `release_check_error_text`，与 `debnas update` 的判断口径一致
- 首页 footer 版本号前新增「有新版本」绿色圆点：启动只读本地缓存（`/var/lib/debnas/state/update-check`，默认 6 小时有效），缺失或过期时由后台 detached 进程静默检查已签名 `LATEST` 指针并写回（flock 去重、5 秒超时，不阻塞首屏）；仅一级菜单显示，版本号放不下时只保留圆点。`debnas update` 成功或菜单内更新完成后清除缓存
- 菜单「检查脚本更新」的提示按普通用户收敛为四行以内：`检查更新…` / `当前版本` / `一句话结论`，版本号等状态信息统一带 `[INFO]` 标识、不再裸行展示；未签名指针回退、主备源切换等内部诊断不再显示（`_RELEASE_QUIET`）。`debnas check-update` 仍保留详细原因，便于排查

### Changed
- `modules/ops-report/report.sh` 拆分完成：`report.sh` 改为 loader，按序加载 `report-common.sh`（共享格式化 helper）、`report-collect.sh`（数据采集与状态判定）、`report-render.sh`（HTML/图表渲染）、`report-cli.sh`（报告生成、终端摘要与并发锁）；函数名、全局变量与调用方式不变
- `modules/ops-report/report.sh` 拆分第一步：23 个 `ops_render_*` 渲染/图表函数原样移入 `report-render.sh`，由 `report.sh` 加载；函数名、全局变量与调用方式不变
- 锁实现收敛：`lib/system/tempfile.sh` 新增 `lock_acquire` / `lock_release` 句柄 API（属主/符号链接校验、`--timeout` / `--nonblock` / `--required`），`debnas_locked`、hosts-sync 与 threat-ips 的锁统一走该 API；`deploy_lock` 作为跨 `install.sh` / `update` 的共享锁保留并注明同步要求
- `lib/system/cron.sh` 的交互菜单（启用/禁用定时任务）移入 `lib/ui/cron-menu.sh`，system 层不再反向依赖 UI 层；无调用方的 `cron_show_status` 已删除
- `docs/` 恢复为不入库（开发文档按项目约定只保留在维护者本地）：从仓库移除并重新加入 `.gitignore`；`tests/` 仍入库供 CI 使用
- 一键方案 `basic` / `secure` 改为安装 `cockpit-45drives`（45Drives 官方插件）
- 交互菜单仅保留 debnas-v2 经典样式（居中 DebNAS 标题、`>` 焦点、灰色快捷键栏，无边框）；不再通过 `DEBNAS_UI` 切换界面
- 经典菜单内容栏宽度改为**终端宽度的一半**（最少 20 列），从左侧开始（靠左，不整体居中）：Header 在内容栏内居中，面包屑、菜单项、Footer 在内容栏内左对齐；Footer 放不下版本号时省略版本号，优先保留完整快捷键

### Fixed
- 2026-11-13 全面审查修复（第一批 P0/P1）：
  - crontab 读取失败不再当成空 crontab：`_get_current_crontab` 仅在 cron 明确报 `no crontab for` 时按空处理，`cron_register`/`cron_register_variant`/`cron_unregister` 读取失败时拒绝写回，避免覆盖用户任务；卸载不再以 `crontab -r` 作为兜底，删除失败会报错并返回非 0
  - `/etc/hosts` 渲染失败时中止写入（此前读错误会用仅含 DebNAS 区块的内容覆盖用户条目）；兼容 CRLF；hosts 锁拒绝符号链接并使用受保护的回退目录
  - firewalld 新建 public 区文件写入失败（rc=2）时中止，不再继续安装/启动 firewalld；fail2ban 配置写入失败或服务未启动时返回失败，并始终确保 `fail2ban started`；security/fail2ban/cockpit/cockpit-net/cockpit-ext/wallpaper/mail-account 的写入失败不再被当作“未变更”
  - threat-ips 禁用时仅在 firewalld 查询成功、且文件确为 DebNAS 生成（含 ipthreat）时删除 drop.xml，删除前集中备份；锁文件不再用 `>` 截断或跟随符号链接
  - 运维报告：RAID 降级检测改为解析 `/proc/mdstat` 的 `[n/m]`、`[U_]`/`[_U]`、`(F)`；更新次数按 120 秒会话统计；移除无数据来源的“意外停电”指标；dpkg 日志不再 `tail -100` 截断；journalctl 加 `-q`；监听端口快照不再截断 30 行；周期重启只统计 Started；`@depends` 去掉不在 PATH 的 sadc
  - `apt_install_packages` 改用只认 installed 的 `pkg_is_installed`；无 fuser 时不再用 flock 误判 APT 锁，apt 调用统一加 `DPkg::Lock::Timeout`；dependency/apt-pinning 统一走 APT 抽象；`ensure_command` 对缺失且无包映射的系统命令返回失败
  - `@debian_min` 在 preflight 中真正生效（支持主版本号与代号）；wallpaper 声明 `@debian_min: 13`，避免在 Debian 12 上必然失败
  - `debnas <模块> --cron` 改写恢复可用；`update`/`check-update`/菜单检查更新优先使用 CLI/环境传入的 region
  - 测试门禁：ShellCheck 覆盖 `tests/`、缺失 shellcheck 视为失败、统计 skip；修复 22 处位于非末行的无效 `!` 否定断言；新增 crontab 读取失败、apt config-files、`@debian_min`、`service_is_installed` 负向用例
  - 其他：security 的 PAM NUL 检测改用 od；login-mail 使用 C.UTF-8；sys-check 的 df 加 -P；fail2ban 声明 mail 依赖（Tier 1）；APT pinning 清理前备份并登记清单
  - 第二批（P2/P3 收敛）：`file_logging=0` 现在真正关闭文件日志（未配置时默认启用）；`@module` 预扫描修复字段顺序/空值丢字段；cron 变体按 5 个调度字段精确匹配（不再前缀误删）；RELEASE 标记与版本状态原子写入；`keyring --label` 参数校验；`config_write` 目录创建失败返回错误；`feature_enabled` 不再 fork cat；`tempfile` 锁 fd 打开失败不再污染全局 stderr；`get_system_name` 不再 source os-release；`sources.sh` 移除加载时命令替换；sys-patches 的 `echo -e` 改 `printf '%b'`；footer 版本默认值改为“未知”；docs/ 同步 ARCHITECTURE/DEV_GUIDE/PROJECT_OVERVIEW/TECH_DEBT 的 API 名、模块/用例数与包装脚本说明
  - 第三批（P2/P3 续）：`ui_input` 非交互输入无末尾换行时不再丢弃内容；确认/提示框支持字面量 `\n` 并保留空行；菜单入口在非 UTF-8 locale 下回退 `C.UTF-8`；`update`/`check-update`/菜单检查更新改用 `DEBNAS_OPT_DIR`，doctor 改用 `DEBNAS_VERSION_STATE`；keyring 拒绝已过期/禁用/无效密钥；日志模块名与 feature 模块名增加路径穿越校验；ops-report 漂移转义补齐引号、事件分类去掉未用参数、网络/磁盘日均按各自采样天数换算；apt 模拟升级失败时待装更新显示“待解析”而不是 0；`config_delete` 失败返回错误；`log_stop_file` 清空路径；module-probe 使用统一临时文件；补 `ERROR_MODULE_NOT_FOUND`；`sources` 在 DEB822 未变时也清理传统 sources.list；wallpaper 校验 `WALLPAPER_API_URL`；login-mail 识别 IPv6 内网；acl-manager 复用 `pkg_is_installed`；threat-ips 去掉未使用的 ipset 依赖；运维报告终端摘要不再输出 `N/A%`；测试 `common-setup` 改为向上查找项目根、`check.sh` 统一 IFS、新增 `ui_input` 无末尾换行回归用例，文档用例数同步
- 交互菜单在终端尺寸变化（SIGWINCH，含启动瞬间触发的情况）后按方向键会在旧帧下方再叠一帧、屏幕上出现重复菜单：`ui_handle_resize` 只清屏并置重绘标志，菜单 `REDRAW` 分支改为整屏重绘（清屏 → Header → 菜单）并重新保存光标位置；循环 wrap / 数字跳转使旧焦点滚出可视区时，先按菜单区整块清除再重绘
- 运维报告磁盘容量快照的"同日"判断改用本地日界：原先按 `epoch/86400`（UTC 日界），东八区早上 8 点前后同一本地日采集的两条样本都会保留，同一天重复生成报告时基线被冲掉
- 经典菜单底部快捷键与版本号粘连（`Q 退出v2026.11.1`）：`printf "%*s"` 的宽度小于版本号长度时不补空格，间距改为单独打印，保证两者之间至少 2 个空格

### Removed
- 删除方案 A 双栏 TUI 仪表盘及 `lib/ui/dashboard.sh`、`lib/ui/textwidth.sh`、`lib/ui/sysinfo.sh`、模块状态批量采集代码与相关测试；`bin/module-runner.sh --probe` 的只读探测契约保留
- 删除自研 Cockpit 共享管理插件 `cockpit-shares`：管理面板只保留「安装 45Drives 官方插件」，不再有 `file_sharing_ui` 二选一开关；模块总数由 27 个减为 26 个

## [v2026.11.1] - 2026-11-10

### Security
- `debnas update` 的"最新版本号"改为**已签名的指针**：仓库根新增 `LATEST`（一行 tag）与 `LATEST.asc`（发布密钥的分离签名），update 从 main 分支取这两个文件，用已安装目录 `keys/` 里的公钥与指纹验签（与发布包同一套 `gpgv` 逻辑，抽成公共函数 `release_check_sig`），通过才采用。`LATEST` 取到但验签失败、或缺 `LATEST.asc` → 拒绝自动更新（仍可 `--tag` 指定版本，代码包照常验签）；两个文件都取不到（维护者尚未发布指针）→ 告警并回退读 main 分支 `install.sh` 的版本号。两种来源都保留"只升不降"。此前版本号直接读自未签名的 `install.sh`
- 全局命令 `/usr/local/bin/debnas` 改为同目录临时文件 + rename 写入：旧安装里它是指向 `bin/debnas` 的软链接时，覆盖安装不再顺着链接把 `bin/debnas` 本身写成包装脚本

### Added
- `tools/release.sh --sign-latest <tag> <密钥 ID>`：生成并自检 `LATEST` / `LATEST.asc`；构建正式版本时自动生成（预发布版本、或 `LATEST` 已指向更高版本时不动），并提示在附件上传后提交推送
- `tools/release.sh --embed-key <新公钥> --keep-old`：换发布密钥的过渡版——`keys/debnas-release.asc` 与 `install.sh` 内嵌区块同时包含新旧两把公钥、`keys/debnas-release.fpr` 两行，任一把签的发布包与 `LATEST` 都能通过；下个版本执行不带 `--keep-old` 的 `--embed-key` 移除旧钥。步骤见 `tools/release.sh` 文件头与 docs/MAINTENANCE.md「更换发布密钥」
- `.gitattributes`：`tests/`、`docs/`、`tools/`、`.github/`、`.gitattributes`、`.gitignore`、`LATEST`、`LATEST.asc` 标记 `export-ignore`，不进发布包与平台分支归档（`keys/` 保留）
- 运维报告：磁盘一节新增「磁盘容量预测」表（按近 N 天使用率增速外推到 90% 告警线，基线不足 1 天显示"数据不足"）；容量快照改为每盘每天一条、保留 400 天，同日重复生成报告不再冲掉基线
- threat-ips：firewall-cmd 写出的永久配置（`/etc/firewalld/ipsets/ipthreat_block_ipv{4,6}.xml` 与 `zones/drop.xml`）登记到文件清单，`debnas files` 可见

### Changed
- `tests/`、`docs/` 不再被 `.gitignore` 排除（改为入库，发布包体积由 `export-ignore` 控制）；新增忽略本地测试报告 `tests/reports/`
- 发布公钥文件与 `install.sh` 内嵌公钥允许多个公钥块（`release_dearmor` 逐块解码后拼接）；`tools/release.sh --check-keys` 与构建时检查改为"内嵌指纹集合 = 指纹文件集合 = 公钥文件里实际的主密钥集合"，指纹文件里多出没有对应公钥的指纹不再放行
- 构建发布时检查包内含 `keys/debnas-release.asc`
- 全局命令包装脚本内容收拢为单一来源（`lib/system/installer.sh` DEBNAS-DEPLOY 区块的 `deploy_install_wrapper`），`install.sh` 与 `debnas update` 共用
- 仪表盘：功能栏与"执行计划·预演"框按内容分配行数——预演生成后预演框按条数扩展（80x24 下由固定 2 条提高到最多 13 条），未勾选时预演框保持最小、其余行归功能栏；双栏、单栏均适用，切换分类/窗口尺寸变化时重新计算
- 仪表盘：详情区说明过长时折成两行；单栏功能列表超出时显示 ↑/↓；快捷键行放不下时按优先级省略，80 列下 移动/勾选/执行/预演/退出 始终可见；临时提示 4 秒后自动消失
- 运维报告：Debian 13 默认没有登录记录读取工具，启用或生成报告时若既无 `wtmpdb` 也无 `last`，自动安装 `wtmpdb` 与 `libpam-wtmpdb`（PAM 由包自带的 pam-auth-update 启用，不改 `/etc/pam.d`）；Debian 12 自带 `last`，不安装任何包；安装失败只告警
- firewall / bbr / vm-components：修改已有的 `/etc/firewalld/zones/*.xml`、`/etc/sysctl.conf` 不再用 `sed -i` 原地改，统一经 `write_file_if_changed` 写回（原件备份、原子替换、登记文件清单）

### Fixed
- CI 全部任务失败：`.gitignore` 排除了 `tests/`，而 `ci.yml` 调用 `tests/run.sh`、`tests/check.sh`。`tests/` 入库；`ci.yml` 每个 job 在 `actions/checkout` 之前先安装 git（容器内没有 git 时 checkout 走归档接口，归档受 `export-ignore` 影响会缺 `tests/`）；bats-unit 任务加装 gnupg / jq 让签名校验用例实际执行
- 旧教程里的安装命令 `bash <(wget -qO- …/install.sh) -s github@main` / `-s gitee@main` 报"未知参数: -s"：`install.sh` 兼容 `-s 平台@分支`（github → `--region global`，gitee → `--region cn`，分支部分忽略，仍安装已签名的发布版本），并提示新写法；格式非法时报错并给出新用法
- `debnas update` 不刷新 `/usr/local/bin/debnas` 包装脚本：更新成功后由新版本代码重新生成；`debnas` 启动时发现包装脚本过期或仍是旧版软链接也会换成当前版本（从 v2026.11.0 升上来时执行更新的是旧代码，靠这一步补上）
- cockpit / cockpit-net：netplan / systemd-networkd 管理网络的系统（云镜像等）安装 Cockpit 后，随包带入的 NetworkManager 会给同一网卡再配一个 DHCP 地址。现在检测到网卡已由 systemd-networkd 管理时写入 `/etc/NetworkManager/conf.d/10-debnas-unmanaged.conf`，让 NetworkManager 不接管这些网卡；已出现双地址的系统重新执行 cockpit 或 cockpit-net 模块即可修复。ifupdown 的常规安装不受影响。如以后改由 NetworkManager 管理网络，需先删除该文件并 `systemctl reload NetworkManager`
- firewall：放行规则改为写入 firewalld 实际的默认区（原先固定写 public 区，默认区改成 home / internal 等时规则不生效）；默认区为 trusted 时不写规则并提示
- firewall：firewalld 已在运行时，写入区文件后同步把新增项补进 firewalld 的永久配置（`firewall-cmd --permanent`，不 reload）。此前之后任何 `--permanent` 操作都会重写区文件并丢掉 DebNAS 放行的条目
- 定时任务：没有 cron 的系统（如 Debian 12 云镜像）注册定时任务时自动安装并启用 cron；无法安装或服务启动失败时明确报错。此前条目写不进去，或写入了但 cron 未运行
- threat-ips：未安装 cron 的系统启用威胁 IP 封禁时不再因"启动 cron 失败"而中止
- 运维报告：服务清单"说明"列同时有周期错误与周期重启时，错误次数被覆盖
- 运维报告：登录记录在 Cockpit "web console" 会话、终端为空的记录上列错位；"… begins" 行不再计为登录；数据源缺失或周期内无登录时给出明确说明（原来是空表）
- 运维报告：内核版本改查 `linux-image-$(uname -r)`（原包名查不到），查不到时回退 `uname -v`；"上一版本"取升级前版本

## [v2026.11.0] - 2026-11-10

> 当前开发分支：`refactor/debnas-v2`

### Security（2026-11-09 全面审查修复，分支 fix/review-20261109）
- 临时目录 `/tmp/debnas` 及日志回退目录增加属主/符号链接校验，防止普通用户预建目录后替换 root 写入的文件（fail-closed）
- `write_file_if_changed` 改为同目录临时文件 + 原子 rename，保留原文件权限/属主；写入失败返回 2 并记录错误
- `config.sh` 键名/模块名校验，修复 GNU sed `e` 命令注入与 `../` 路径穿越；`cron.sh` 模块名/variant 校验
- `NO_COLOR` 算术求值命令注入；tar 解压加 `--no-same-owner`；wget 加超时
- hosts-sync：/etc/hosts 不再被改成 0600、保留用户空行；连通性校验改为带 SNI 并校验证书；过滤回环/私网/fake-ip 结果
- security：su 限制此前在 Debian 默认配置下从未生效（注释行误判为已配置）；现插在 pam_rootok 之后并加 use_uid，管理员不在 sudo 组时跳过防锁死；/var/log/history 防抢建
- threat-ips：剔除保留网段/本机/当前 SSH 来源/白名单/过宽前缀；改为差量同步不再先清空；reload 后重启 fail2ban 恢复其规则；flock 互斥
- firewall / fail2ban：按实际 SSH 端口放行与监控；按已安装服务放行 samba/nfs；jail.local 不覆盖用户自定义文件；局域网网段加入 ignoreip
- docker-ce：固定校验 Docker 官方公钥指纹；docker-mirror：只合并 registry-mirrors，JSON 非法时拒绝覆盖
- cockpit：转发头仅在 `cockpit_behind_proxy=1` 时写入，不再整文件覆盖用户配置；45drives 安装脚本失败不再被吞
- cockpit-45drives：不再下载并以 root 执行 `repo.45drives.com/setup`，改为模块自写 DEB822 源（`45drives.sources`，Signed-By `/usr/share/keyrings/45drives-archive-keyring.gpg`），公钥须匹配固定主密钥指纹 `3FBD7E03…731C472B` 才原子写入；旧 `45drives-enterprise-<代号>.list` / `45drives.list` 集中备份到 `/var/backups/debnas` 后移除
- tailscale：公钥下载后校验固定主密钥指纹 `2596A99E…957F5868`，不符拒绝安装；keyring 改为同目录临时文件原子替换（不截断已有文件）；源改为本地生成 DEB822 `tailscale.sources`，旧 `tailscale.list` 集中备份到 `/var/backups/debnas` 后移除
- 45Drives / Tailscale 仓库与公钥地址可在 `debnas.conf` 配置镜像（`repo_45drives_url` `repo_45drives_key_url` `repo_tailscale_url` `repo_tailscale_key_url`，留空=官方），指纹校验不变；公钥下载失败重试 1 次并提示可配置镜像
- login-mail：通知改为后台执行不阻塞登录，ip-api 明文地理查询默认关闭（`login_mail_geoip=1` 开启）
- ops-report：HTML 报告转义所有系统来源数据（进程名/主机名/登录信息等）防 XSS；邮件主题 RFC 2047 编码并防头注入；报告文件 600 创建
- 安装/更新包改为**发布 tag + SHA256 + GPG 签名**校验：`install.sh` 与 `debnas update` 不再拉取 main 分支归档，改为下载 Release 附件 `debnas-<tag>.tar.gz` / `SHA256SUMS` / `SHA256SUMS.asc`，用 `gpgv` + 内嵌（install.sh）或已安装（`keys/debnas-release.asc`）的发布公钥验签并核对主密钥指纹，再 `sha256sum -c`；任一步失败中止并删除下载物。`update` 自动发现新版本时拒绝降级。按分支安装须显式 `--unsigned`（醒目警告 + 交互确认，非交互拒绝）。新增 `tools/release.sh`（`--embed-key` / `--bump` / 构建签名自检）。⚠️ 维护者尚未配置发布公钥前，默认安装/更新会报错，需先完成 docs/MAINTENANCE.md「发布流程」

### Fixed（2026-11-09 全面审查修复）
- `bootstrap-core.sh` 把系统目录整体前置到 PATH，导致调用方/测试放在前面的命令被 `/usr/sbin` 同名命令抢先（bbr 单测因此读到真机拥塞算法，root 测试机上会真的改内核参数）；改为只追加缺失目录，cron 环境下 `/usr/sbin` 仍可用
- cockpit-net：先检查 NetworkManager；检测到静态 IP 配置时拒绝执行并给出 nmcli 迁移提示，避免失联
- mail-account：Exim smarthost 端口改为 `host::port`（原写法实际走 25 端口）；465 支持 smtps
- sources：重复运行不再覆盖原始 .bak；sid/testing 不再生成不存在的套件
- sys-patches：去掉 gawk 专有 `match()`（mawk 下明细为空）；apt update 失败时在报告中标注
- service-query 不再启动 cockpit；wallpaper 仅样式变化时重启 cockpit；bbr/vm-components sysctl 覆盖问题
- ops-report：Debian 12 可用率恒为 0%、CST 时区偏差、端口仅减少时报告崩溃、.xz 历史 sar 数据不可读、多 jail 封禁数为 0、全量扫 journal
- lib/bin：installer_deploy 原子替换并部署 config/compose；install.sh 补复制 compose/；migration 使用新版本代码执行；module-runner 透传退出码；菜单 `08`/Y/N 快捷键/缩放错位；state/doctor/apt 多处 pipefail 中途退出

### Added
- 新增 Cockpit 插件「共享管理」（`cockpit-shares` 模块，2026-11-09）：替代 45Drives cockpit-file-sharing 作为默认共享界面，管理 Samba 共享（注册表）、Samba 服务与全局项、NFS 导出（`/etc/exports.d/cockpit-file-sharing.exports`）与 Samba 用户密码；与 45Drives 共用后端，切换不丢共享；`debnas.conf` 新增 `file_sharing_ui=debnas|45drives`（二选一，一键方案改为安装 `cockpit-shares`，选 45drives 时转交 `cockpit-45drives`）与 `file_sharing_nfs`；`cockpit-45drives` 安装前检测并移除自研插件（`modules/cockpit-shares/`、`config/solutions/*.list`、`modules/cockpit-45drives.sh`）
- 交互界面改为“方案 A：双栏 TUI 仪表盘”（2026-11-09）：顶部系统信息框（版本/架构/主机名/IP + CPU/内存/根分区条形仪表、运行时长、待更新包数，只读 apt 缓存不 apt update）、左栏分类（含“⚡ 一键部署”与完成度）、右栏功能列表（勾选框 + 当前状态 + 说明）、执行计划·预演框（d 预演 / 回车执行，执行前显示完整预演并确认）、快捷键行；差量重绘无闪烁、SIGWINCH 自适应、窄终端（<100 列或 <28 行）退化为单栏、`/` 搜索、`l` 日志、`?` 帮助；非 TTY 或 `DEBNAS_UI=classic` 回退旧版菜单（`lib/ui/dashboard.sh`、`lib/ui/textwidth.sh`、`lib/ui/sysinfo.sh`、`bin/menu.sh`）
- 模块只读探测契约：可选 `module_status`（`状态码|说明`）与 `module_plan`（`类型|目标|备注`），模块末尾 main 调用改为 `DEBNAS_MODULE_ACTION` 守卫形式；新增 `lib/system/module-probe.sh`（加载器 + 超时 + 异步状态缓存）与 `module-runner.sh --probe status|plan <模块>`；firewall、docker-ce 为首批样板
- 新增 `ops-report` 运维报告模块：支持 7/30/180/365 天终端摘要、本地 HTML 报告、Markdown 邮件通知与固定周报/年报定时任务
- 新增统一“定时任务”管理模块（位于系统维护二级菜单），支持选择模块后启用/禁用/查看定时任务
- 新增 `lib/system/feature.sh` 模块功能状态管理
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
- ops-report 事件脉冲图支持长周期聚合：月报（30 天）按天、年报（365 天）按周分桶，异常事件时间戳回填为 CPU/内存/磁盘 I/O 峰值出现日期
- ops-report 异常进程检测：静态启发式扫描 `/proc`（异常启动路径 / 已删除二进制 / 隐藏进程名 / 下载并执行），替代原 Top5 展示
- 新增 `cron_register_variant()`：支持同一模块注册多条 cron 定时条目（主调度 + 变体调度），并扩展 `cron_describe` 可读描述，用于 ops-report 周报（周一 01:00）+ 年报（每年 1 月 1 日 02:00）双定时
- 新增 ops-report 依赖命令映射：`sar`/`sadc`/`smartctl`/`sensors`/`wtmpdb`（工具级自动安装）与 `virsh`（服务级提示），依赖检测自动识别 sysstat、smartmontools 等
- `write_file_if_changed` 新增第 4 参数 `quiet` 静默模式，内容未变更时抑制日志输出

### Changed
- lib 代码质量第一阶段（2026-11-09，只改 lib/、bin/、install.sh、tools/，模块输出不变）：
  - 收拢公共函数供模块统一调用：`keyring_install_verified` / `gpg_key_fingerprint_verify`（新增 `lib/system/keyring.sh`，合并 docker-ce / cockpit-45drives / tailscale 三份公钥下载与指纹校验，取最严格行为：恰好一把主密钥、拒绝私钥/吊销、超时+重试 1 次、同目录临时文件原子替换）、`sshd_listen_ports(_csv)`、`cron_state`、`config_get_bool`、`get_primary_user`（`get_first_regular_user` 保留为 deprecated 包装）、`config_get_url`、`pkg_is_installed`、`get_module_field_var`、`pinning_render` / `pinning_file_exists`
  - `get_system_codename` / OS ID 优先读 `/etc/os-release`（逐行解析，不 source、不 fork），`lsb_release`（Debian 12 上为 Python，慢）仅作回退；路径可由 `DEBNAS_OS_RELEASE` 覆盖
  - 发布校验逻辑单一来源：`lib/system/installer.sh` 的 DEBNAS-RELEASE-VERIFY 区块为唯一实现，install.sh 内副本由 `tools/release.sh --embed-key / --bump / --sync-verify` 同步生成，构建发布时检查 tag 内两份一致（新增 `tests/unit/lib/test-release-sync.bats`）；install.sh 仍单文件可运行
  - `write_pinning_file` 改经 `write_file_if_changed` 写入并去掉时间戳（幂等、可备份、登记清单）；`sysctl_persist` 改为读出→计算→`write_file_if_changed` 写入（不再 `sed -i` / `>>`）
  - 模块探测：只认行首的真正守卫行（注释中出现守卫文字的未改造模块不再被 source）；`module_status` 返回 `unknown|只读工具…` 的只读工具不再被执行记录改写为"已应用"
  - module-runner preflight 的依赖检查改用 `ensure_module_deps`（与交互式模块共用）；dependency.sh 合并重复的缺失检测/安装/列表逻辑
  - 性能：模块发现 ~210ms→~30ms（不再每模块 fork head/basename，不再扫描整个注册表）；`--probe status` ~290ms→~110ms；仪表盘单帧 ~60ms→~9ms（宽度/截断结果缓存、去掉每帧的子 shell 与 tr）、初始化 ~300ms→~75ms；state_get / manifest / write_file_if_changed 去掉 grep|cut、basename/dirname、date 等子进程
- 文件布局收敛到 FHS 同名目录（2026-11-09）：威胁 IP 数据 `/var/lib/firewalld-ipthreat` → `/var/lib/debnas/threat-ips`、日志 `/var/log/firewalld-ipthreat.log` → `/var/log/debnas/threat-ips.log`；通知收件邮箱 `/etc/exim4/notify_email` → `/etc/debnas/notify_email`（640 root，统一由 `notify_email_get/notify_email_set` 读写，旧路径回退一个版本并改为符号链接）；登录通知脚本 `/etc/pam.d/login-notify.sh` → `/usr/local/libexec/debnas/login-notify.sh`（`common-session` 的 pam_exec 行原位替换，不留两条）。`migration_run_layout` 幂等迁移旧文件，每次 `debnas update` 均执行。新增集中备份：`write_file_if_changed` 修改已有文件前备份到 `/var/backups/debnas/<时间戳-pid>/<原路径>`（首次原件另存 `original/`，默认保留最近 20 次运行，`backup_enabled`/`backup_keep` 可配），sources 等模块的同目录 `.bak` 改为统一备份；新增文件清单 `/var/lib/debnas/manifest` 与 `manifest_list`（供 `debnas files`）
- 运维报告按 PRD 0.22.33 更新：改版为 Apple 极简浅色样式，页眉仅保留报告周期，页脚使用数据覆盖/生成时间/上一期/下一期四栏
- 运维报告按 0.22 结构重排：新增“本周概览”事件脉冲与重点跟进，安全与入侵研判合并为单张明细表，服务与应用状态改为统一服务清单，磁盘容量与 I/O 合并为周期明细表
- 运维报告按 PRD 0.20.0 将二级菜单改为数据生命周期状态模型：未启用只显示启用数据采集，数据不足不展示生成入口，暂停/恢复定时报告与停用运维报告分离
- 运维报告定时任务在数据不足时自动跳过，不发送不完整报告
- 运维报告按 PRD 0.21.1 简化二级菜单为固定六项，生成报告时自动初始化依赖与数据采集，邮件附带 HTML 详细报告附件
- 运维报告按 PRD 0.19.0 升级为赛博朋克/SOC 视觉：暗黑网格背景、玻璃拟态卡片、发光状态点、荧光图表和风险胶囊标签
- 运维报告按 PRD 0.18.0 与新版模拟报告更新：摘要风险摘要与最终安全结论、安全与入侵研判独立章节、Swap 摘要、网络独立章节、重启需求与 Journal 错误摘要
- 运维报告实际生成内容按模拟报告样式渲染：使用真实采集数据，移除资源占用大户、原始登录明细、文件系统明细等多余板块
- 运维报告 HTML 按模拟报告样式重构：深色英雄区、马卡龙色带、悬浮摘要卡片、面板化图表、指标卡与分区表格
- 运维报告按模拟报告审计结论完善：失败登录来源与安全事件总数闭环、移动端宽表改为横向滚动、事件脉冲轴语义固定为事件影响等级、安全更新低风险补充判定依据
- 运维报告第 2 章合并风险摘要与异常研判为单张明细表，消除同一事项重复展示
- 运维报告资源章节合并磁盘容量与 I/O 为单张明细表，删除容量预测模块，不再展示挂载点列
- 运维报告 I/O 图直接标注读写量，磁盘已用改具体容量值，存储健康按物理硬盘逐行展示
- 运维报告服务与应用状态改为指标卡 + 统一服务清单，补齐 cron 与 Docker 停止容器汇总
- 运维报告删除服务稳定性图表，四个服务概览指标固定单行展示
- 运维报告全表格列序按行业通用惯例调整：实体/标识列先行、状态/等级次之、指标居中、备注/时间靠后；时间线类表格以时间列开头
- 运维报告事件脉冲曲线约束在横轴基线上方，不再越出绘图区
- 运维报告磁盘明细“健康 / 结论”列不再混入温度，只展示健康结论
- 运维报告删除独立“安全事件”模块，登录来源 IP 统计整宽展示，来源合计与 Fail2ban 封禁结果并入该表
- 运维报告磁盘明细“健康 / 结论”列移至设备之后、容量之前
- 运维报告登录来源 IP 统计补全年份，来源合计行同时汇总成功与失败次数
- 运维报告登录来源 IP 统计不再识别或展示 IP 归属地，公网来源统一显示“公网”
- 运维报告页尾“上一期报告”展示从历史报告归档读取的具体生成时间
- 运维报告页眉只保留报告周期，数据覆盖移到页脚，页脚不再重复展示报告周期
- 运维报告页脚四项按数据覆盖、生成时间、上一期报告、下一期预计排序
- 运维报告默认直接发送邮件，未配置通知邮箱时自动跳过，不再交互询问
- 45Drives 扩展不再安装 `cockpit-navigator`，改用 Cockpit 官方文件管理组件
- 45Drives 扩展在 Debian 13 上改为通过官方仓库安装，移除 GitHub 手动下载 `.deb` 逻辑
- 调整不同层级菜单的时间线间距：下一级菜单标题前增加空行，标题与菜单项之间不再空行
- 统一模块显示名与子菜单标题为动作化表述（安装/配置/检查/查询/部署等）
- 成功日志标签统一为 `[DONE]`
- CLI 定时任务新增 `cron enable/disable` 命令，保留 `add/remove` 兼容
- 定时任务回归模块内管理：每个模块菜单新增“定时设置”，集中入口改为只读概览
- 定时任务启用流程调整为先询问定时时间，再自动补齐功能并注册定时
- 依赖检查统一延迟到交互模块具体动作时执行，进入菜单不再检查/安装依赖（wallpaper、acl-manager、sys-patches、hosts-sync）
- 定时任务默认调度统一为每天 00:00（`0 0 * * *`）
- 四个定时模块菜单统一为启用/禁用，功能开关与定时任务分离管理
- cron 表达式增加字段值范围校验，新增可读描述与状态查询
- 关于项目改为直接打印概况后返回一级菜单，并优化终端排版
- Phase 1 UI 基础层：日志标签统一为 7 字符宽度（`[SUCCESS]→[DONE]`、`[FAIL]→[ERROR]`、`[WARNING]→[WARN]`、`[ACTION]→[INFO]`）
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
- 定时任务概览新增 ops-report 模块
- `install_missing_dependencies` 日志去噪：无缺失不再输出提示，缺失时按系统/服务/工具级别分别提示
- ops-report 报告渲染重构：删除 report.sh 内 4 代历史渲染函数死代码（legacy/017/无后缀/v022，约 2000 行），统一渲染函数命名去除版本号后缀并合并 network_metrics 薄包装

### Deprecated
- `get_first_regular_user` → `get_primary_user`；`check_pinning_status`（带日志）→ `pinning_file_exists`（2026-11-09，旧名保留为薄包装）
- Phase 1 UI 基础层：`print_highlight()` 弃用（MAGENTA 已禁用，改用 `print_accent`）
- Phase 1 UI 基础层：`print_separator()` 弃用（设计规范：用空行呼吸感替代分隔线）
- Phase 1 UI 基础层：`print_submenu_title()` 弃用（Phase 2 由 `ui_header` + 面包屑替代）
- Phase 1 UI 基础层：`print_menu_item()` / `print_main_menu_item()` 弃用（Phase 2 由 `ui_menu` 替代）
- Phase 1 UI 基础层：`print_banner_text()` 弃用（Phase 2 由 `ui_header` 替代）
- Phase 2 菜单交互：`show_menu()` / `show_menu_with_border()` / `get_user_choice()` / `run_submenu()` 弃用（由 `ui_menu` 替代，旧函数保留向后兼容）

### Removed
- 删除无调用方的库函数：`get_remaining_args`（args.sh）、`list_missing_dependencies`（dependency.sh）、`show_menu_with_border`（ui/menu.sh）、`show_all_pinning_status`（apt-pinning.sh）（2026-11-09）
- 删除 sys-patches、hosts-sync 旧 cron 子模块及模块内定时设置菜单
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
- 修复运维报告风险等级换行、风险说明重复、CPU/内存趋势图、网络柱状图和 24 小时登录柱状图错误
- 修复 `sar -r` 将 `kbmemused` 误当内存百分比、24 小时登录时段使用错误字段导致柱状图全零的问题；图表按模拟报告补齐渐变面积、接收/发送双柱与次数轴
- 修复运维报告数据覆盖被 `ops_determine_status` 重置为“无数据”的问题，报告头部与图表图例现在显示覆盖天数和有效采样天数
- 修复 `sadc` 位于 `/usr/lib/sysstat/sadc` 不在 PATH 导致每次运行都误报依赖缺失的问题；可自动安装的工具不再输出误导性 WARN
- 补齐磁盘 I/O、Top 进程、服务稳定性、系统版本、Journal 错误、SSL 证书、systemd 定时器等报告数据，减少大量“无数据”区块
- 修复 24 小时登录柱状图“次数”单位标签与 y 轴数字重叠的问题
- 合并 sysstat 配置重复写入提示，未变更配置不再逐键输出“跳过写入”
- 修复 `ops_collect_resources` 在网络采样天数与 CPU/内存采样天数相同时返回非 0，导致菜单生成 7 天报告直接失败的问题，并新增回归测试
- 统一报告数据口径：周期统计、周期估算、当前状态、待周期数据、待基线明确区分；移除当前进程 Top 5 与瞬时系统负载展示
- 网络接口明细改为 sysstat 周期估算，磁盘 I/O 读/写量改为周期估算，服务重启次数改为周期 journal 统计，不再用 `/proc` 累计值或 `NRestarts` 冒充周期值
- Fail2ban 封禁数改为真实采集，周期可用性、停机统计、安全配置漂移、最近更新检查、重启需求不再使用硬编码默认值
- 事件脉冲图按模拟报告复刻：使用同一 SVG 坐标系、语义色节点、短引线与日期标签，并避免同日事件重叠
- 文件系统与内核日志错误拆分为独立结论：报告明确输出“文件系统错误”或“内核错误”，不再使用“文件系统或内核日志错误”模糊表述；忽略 `/boot/efi` 等正常只读挂载的误报
- CPU/内存趋势图改为模拟报告同款平滑曲线 path；磁盘容量图与设备 I/O 图补齐右侧数据标注，并按模拟报告修正“容量 / 已用”顺序
- 服务与应用清单改为动态核心服务：按实际安装/运行的 systemd 核心服务、失败服务和 Docker 容器生成，不再固定列出 ssh/nginx/docker/jellyfin/radarr
- 登录“最常用时段”改为范围值或维护窗口/每小时服务登录；登录来源 IP 统计修复失败列格式、补充最后活动与来源合计
- 报告内登录、服务、异常登录、来源 IP、SSL 等时间统一转为 `YYYY-MM-DD HH:MM` 格式，与模拟报告一致
- 24 小时登录分布纵轴按实际最大次数动态计算，设备 I/O 图横轴按实际数据量动态调整，不再使用固定档位
- 运维报告生成后校验 HTML 文件存在且完整，并创建 `latest.html` 固定入口便于定位
- 无 sysstat 历史时网络统计回退到 `/proc/net/dev` 累计数据，避免报告显示 `0.0 B`
- 修复登录来源解析：无主机名和 IPv4 映射地址未归一化时误将星期/月份当作来源 IP
- 修复交互式模块仅浏览菜单时仍输出执行包装日志并被标记成功的问题：未执行真实动作不记录状态，也不输出 `→ 模块名` / `[DONE] 模块名`
- 修复成功日志标签被误改为 `[OK]`，恢复为 `[DONE]`
- 修复菜单交互期间终端回显未关闭，连发方向键时 `^[[A` 等 ESC 序列被原样打印
- 修复连发下方向键被误判为 ESC 序列，导致二级菜单意外返回一级菜单
- 修复质量门禁第 3/5 层遗留失败：同步 `log_fail` 旧 API 测试、`ui_confirm`/`ui_log` 断言及 `execute_solution` 失败中断用例
- 修复 threat-ips 菜单缺少“定时设置”入口
- 修复 wallpaper 菜单标题与模块名不一致，并修复 Cockpit 运行状态误判（兼容 `cockpit.socket` 激活）
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
- 修复 ops-report 安全配置漂移 `ops_collect_security_drift` 内 `port_lines` 管道缺失 `|| true`，无监听端口时 `grep -v` 返回非零在 `set -o pipefail` 下触发异常退出

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
