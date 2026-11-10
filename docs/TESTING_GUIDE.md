# DebNAS 测试指南

> 版本：1.6.0 | 更新：2026-07-05
> 更新触发：P3-2 新增 3 模块集成测试、P3-5 本地一键门禁闭环、§八命令速查更新

---

## 一、测试体系

DebNAS 项目采用六层自动化测试体系（第 1-5 层自动执行，第 6 层手动/AI 辅助执行）：

1. **语法检查** — `bash -n` 验证全部 .sh 文件
2. **静态分析** — ShellCheck error 级别检测
3. **单元测试** — BATS 库函数逻辑验证
4. **冒烟测试** — 模块元数据完整性 + 依赖引用有效性
5. **集成测试** — BATS 模块结构验证 + Mock 功能测试 + 依赖链检查（6 文件，108 用例）
6. **VM 测试** — SSH 远程部署 + 模块执行 + 幂等性 + 状态验证（170+ 用例，手动/AI 辅助执行）

具体测试实施步骤请按照该文档第七部分执行落地。AI 自动化执行的详细指南（VM 部署流程、用例覆盖映射、菜单模拟方法）参见 [test-plan.md §九](../tests/test-plan.md)。

## 二、测试环境

### 依赖安装

```bash
# Debian 12/13
sudo apt install bats shellcheck

# 或从源码安装 BATS
git clone https://github.com/bats-core/bats-core.git
cd bats-core && sudo ./install.sh /usr/local
```

### 测试目录结构

```
tests/
├── check.sh                  # 一键质量门禁（第 1-5 层）
├── run.sh                    # 测试入口（语法检查 + ShellCheck + 单元/集成测试）
├── test-plan.md              # 测试计划（170+ 用例，AI 通过 SSH 自动执行）
├── reports/                  # 测试报告输出目录
├── helpers/
│   └── common-setup.bash     # BATS 共享设置（加载公共库）
├── integration/              # 集成测试（6 文件，108 用例）
│   ├── test-module-registry.bats
│   ├── test-solution.bats
│   ├── test-cron-mode.bats
│   ├── test-docker-ce.bats
│   ├── test-firewall.bats
│   └── test-sources.bats
└── unit/
    └── lib/                  # 单元测试（按库文件组织，12 文件 175 用例）
        ├── test-apt.bats
        ├── test-args.bats
        ├── test-colors.bats
        ├── test-config.bats
        ├── test-constants.bats
        ├── test-cron.bats
        ├── test-dependency.bats
        ├── test-logging.bats
        ├── test-service.bats
        ├── test-state.bats
        ├── test-tempfile.bats
        └── test-utils.bats
```

## 三、运行测试

### 命令行

```bash
# 单元测试
bash tests/run.sh unit

# 集成测试
bash tests/run.sh integration

# 全部自动化测试（语法检查 + ShellCheck + 单元测试）
bash tests/run.sh all

# 一键完整质量门禁（第 1-5 层，推荐）
bash tests/check.sh

# 直接使用 BATS（递归模式）
bats tests/unit --recursive
bats tests/integration --recursive
```

### 测试计划

参见 [tests/test-plan.md](../tests/test-plan.md) 了解完整的 13 阶段测试计划（170+ 用例，AI 通过 VM 自动执行）。

## 四、发布前检查清单

### 4.1 代码质量

```bash
# ShellCheck（静态分析）
shellcheck --severity=error -x lib/**/*.sh bin/*.sh modules/*.sh

# 语法检查（全部 .sh 文件）
find . -name '*.sh' -exec bash -n {} \;

# BATS 单元测试
bash tests/run.sh unit
```

### 4.2 模块检查

- [ ] 所有模块入口点统一为 `main() { ... }; main "$@"` 模式
- [ ] 模块顶部无顶层可执行代码（`sources.sh` 除外，已知问题）
- [ ] `@depend_modules` 声明完整（使用 `grep -rn '@depend_modules' modules/` 检查）
- [ ] 无直接 `systemctl` 调用（使用 `service_ensure` 替代）
- [ ] 无直接文件写入（使用 `write_file_if_changed` 替代）
- [ ] `wget`/`curl` 设置了 `--timeout` 参数
- [ ] 无 `eval` 使用

### 4.3 全局影响检查

- [ ] CLI 子命令参数未变化（或已更新 CHANGELOG.md）
- [ ] 配置文件格式兼容（`/etc/debnas/debnas.conf`）
- [ ] 状态文件路径未变化（`/var/lib/debnas/state/`）
- [ ] 日志目录路径未变化（`/var/log/debnas/`）

### 4.4 环境验证

- [ ] Debian 12 (bookworm) 上通过测试
- [ ] Debian 13 (trixie) 上通过测试
- [ ] amd64 架构上通过测试
- [ ] 最小化安装环境（无 sudo / 无预装工具）下安装流程正常

### 4.5 文档同步

- [ ] 新功能 → CHANGELOG.md `[未发布]` 章节
- [ ] Bug 修复 → CHANGELOG.md `[未发布]` 章节
- [ ] 新临时方案/已知局限 → TECH_DEBT.md
- [ ] 公共 API 变更 → ARCHITECTURE.md §三
- [ ] 安装流程变更 → `README.md`
- [ ] CLI 变更 → README.md CLI 章节

## 五、测试开发

### 5.1 AI 编写 BATS 测试的时机

以下场景**必须**编写或更新 BATS 测试：
- 新增 `lib/` 公共函数 → 在 `tests/unit/lib/test-<库名>.bats` 中新增测试
- 修改已有 `lib/` 函数的行为 → 更新对应测试，确保新行为被覆盖
- 修复 `lib/` 函数的 Bug → 新增一个测试用例验证该 Bug 场景（防止回归）

以下场景**不需要**编写 BATS 测试：
- 仅修改模块内部逻辑（模块级测试通过 VM 测试计划覆盖）
- 仅修改文档、注释、日志消息
- 仅调整变量命名或代码格式

### 5.2 BATS 测试模板

```bash
#!/usr/bin/env bats

load 'helpers/common-setup'

setup() {
  setup_debnas_lib  # 加载 core/ 库（如需 system/ 层用 setup_debnas_system）
}

@test "函数名: 正常场景描述" {
  run 被测试函数 参数1 参数2
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"期望内容"* ]]
}

@test "函数名: 空输入应安全处理" {
  run 被测试函数 ""
  [[ "$status" -ne 0 ]]  # 或 == 0，取决于函数设计
}

@test "函数名: 幂等性 — 第二次调用不应重复操作" {
  run 被测试函数 参数
  [[ "$status" -eq 0 ]]
  run 被测试函数 参数  # 第二次
  [[ "$status" -eq 0 ]]
  # 验证无副作用
}
```

### 5.3 测试命名约定

- 测试文件：`test-<库名>.bats`（如 `test-apt.bats`）
- 测试用例：`"<函数名>: <场景描述>"`（如 `"apt_install_packages: 已安装包应跳过"`）

### 5.4 测试注意事项

- 单元测试不应依赖真实系统状态（不操作 `/etc/`、不调用 `systemctl`）
- 集成测试需要 root 权限时应在测试开头检查并跳过
- 使用 `BATS_TMPDIR` 或 `mktemp` 创建测试临时文件
- 测试结束后在 `teardown()` 中清理
- 测试函数返回值用 `run` 命令（不要用 `$()`），通过 `$status` 和 `$output` 断言
- 需要 mock 外部命令时，在 `setup()` 中创建临时脚本覆盖 PATH

## 六、已知测试覆盖缺口

当前测试覆盖的库文件（12/17，BATS 单元测试 175 用例）：

### 已覆盖

| 文件 | 测试文件 | 状态 |
|------|---------|------|
| constants.sh | test-constants.bats | ✅ |
| colors.sh | test-colors.bats | ✅ |
| logging.sh | test-logging.bats | ✅ |
| apt.sh | test-apt.bats | ✅ |
| args.sh | test-args.bats | ✅ |
| config.sh | test-config.bats | ✅ |
| dependency.sh | test-dependency.bats | ✅ |
| service.sh | test-service.bats | ✅ |
| state.sh | test-state.bats | ✅ |
| utils.sh | test-utils.bats | ✅ |
| tempfile.sh | test-tempfile.bats | ✅ |
| cron.sh | test-cron.bats | ✅ |

### 未覆盖（按优先级排序）

AI 在修改以下文件时，应顺便补充对应的 BATS 测试：

| 优先级 | 文件 | 行数 | 理由 |
|--------|------|------|------|
| 中 | module-registry.sh | 446 | 拓扑排序 + 循环依赖检测是核心逻辑，但测试需要 mock 文件系统 |
| 中 | urls.sh | 119 | URL 探测逻辑，涉及网络操作需 mock |
| 低 | apt-pinning.sh | 122 | 功能相对独立，使用频率低 |
| 低 | installer.sh | 97 | 涉及网络下载，测试需大量 mock |
| 低 | migration.sh | 145 | 版本迁移框架，当前无实际迁移函数 |

## 七、交互式模块测试规范

> ⚠️ **核心原则**：禁止因为模块有交互式菜单就直接跳过。必须先用模拟值跑通配置写入流程，确认无法自动化后才标记 ⏭️。

### 7.1 强制执行流程（不可跳过）

遇到包含 `read -r`、`safe_read_input`、菜单循环（`while ... case`）的模块时，AI 必须按以下顺序尝试，**每步都尝试后才能进入下一步**：

```
第一步：查找非交互分支
  ├── grep -n 'DEBNAS_FORCE_YES\|--yes\|\[\[ ! -t 0 \]\].*return\|CRON_MODE' <模块>
  ├── 如果模块内置非交互模式 → 直接用该模式测试 ✅
  └── 如果没有 → 进入第二步

第二步：管道模拟值
  ├── grep -n 'print_prompt\|read -r\|safe_read_input' <模块>  # 列出所有输入点
  ├── 按顺序编写输入序列表，用模拟值填充
  ├── printf 'val1\nval2\n...\n0\n' | debnas --yes run <模块>
  └── 验证配置文件/状态文件是否正确写入 ✅

第三步：菜单管道
  ├── 如果是主菜单中的方案（如一键部署）→ printf 菜单选项序列
  └── 如果以上全部失败 → 标记 ⏭️ 并说明具体原因
```

### 7.2 SSH 管道规范

**必须使用 `printf`，禁止使用 `echo -e`**。`echo -e` 在 SSH 多层引号嵌套中 `\n` 会被外层 shell 吞掉变成字面量 `n`，`printf` 在所有层级都可靠。

```bash
# ❌ 错误 — \n 被外层 shell 吞掉
ssh ... "su -c 'echo -e \"1\n0\n\" | debnas'"

# ✅ 正确 — printf 转义始终可靠
ssh ... "su -c 'printf \"1\\n0\\n\" | debnas'"
```

### 7.3 模拟值规范

测试配置写入流程时，使用以下模拟值。假凭据不会影响真实服务（如假 SMTP 密码不会真的发送邮件），但可验证配置文件和代码流程是否正确：

| 输入类型 | 模拟值 | 用途 |
|----------|--------|------|
| 邮箱地址 | `test@qq.com`、`admin@test.com` | mail-account 发件/收件邮箱 |
| 授权密码 | `fakepass123` | mail-account SMTP 密码 |
| 文件路径 | `/tmp/test_xxx` | acl-manager 等（先 `mkdir -p` 创建） |
| 用户名 | `testuser` 或已存在的系统用户 | ACL 设置 |
| 权限 | `rwx` | ACL 权限值 |
| 确认/递归 | `y` + `n` | 各模块的确认提示 |

### 7.4 已知模块的非交互模式速查

以下模块已确认支持非交互模式，**禁止标记为 ⏭️**：

| 模块 | 自动化方法 | 命令 |
|------|-----------|------|
| hosts-sync | `--yes` 跳过菜单，直接执行单次更新 | `debnas --yes run hosts-sync` |
| BBR | 参数模式：1=临时启用 2=永久启用 3=临时停用 4=永久停用 5=查看状态 | `debnas --yes run bbr 2` |
| login-mail-on | `--yes` 直接执行（需 mail-account 先完成） | `debnas --yes run login-mail-on` |
| login-mail-off | `--yes` 直接执行 | `debnas --yes run login-mail-off` |
| mail-account | 管道模拟 SMTP 凭据 | `printf 'test@qq.com\nfakepass123\nadmin@qq.com\n' \| debnas --yes run mail-account` |
| acl-manager | 管道输入完整菜单序列 | `printf '2\n/tmp/dir\nuser\nrwx\nn\ny\n0\n' \| debnas --yes run acl-manager` |
| basic 方案 | 菜单管道选 7→1 | `printf '7\n1\n0\n' \| debnas` |
| secure 方案 | 菜单管道选 7→2（需 mail-account 已完成） | `printf '7\n2\n0\n' \| debnas` |
| threat-ips | `--yes` + 管道选子菜单 | `echo '1' \| debnas --yes run threat-ips` |

### 7.5 新模块交互输入分析法

遇到尚未在速查表中的交互模块时，按以下步骤分析：

1. **找输入点**：`grep -n 'print_prompt\|read -r\|safe_read_input' modules/<模块>.sh`
2. **列输入序列表**：按代码行号顺序列出每个提示和它期望的输入值
3. **检查非交互分支**：搜索 `DEBNAS_FORCE_YES`、`[[ ! -t 0 ]]`、参数模式等
4. **编写测试命令**：用 `printf` 拼接模拟值，末尾加 `0` 确保正常退出
5. **验证**：检查配置文件、状态文件是否正确写入
6. **记录**：将结果更新到本节的速查表

### 7.6 允许跳过的情形

仅在以下情况允许标记 ⏭️：

- 模块需要实时 curses/TUI 界面（如 `dialog`、`whiptail`）
- 需要真实硬件交互（如插入 U 盘）
- 需要外部服务实时回调（如 OAuth 授权码）
- 模拟值会导致不可逆的系统配置损坏

跳过时必须在报告中注明具体原因、尝试过的方法和解除条件。


## 八、测试命令速查（移自 CLAUDE.md 旧版约定）

> 本节为 §三 的命令速查卡，方便开发时快速复制执行。

本地代码交付验证需执行以下各层门禁命令查验：

```bash
# ===== 开发机测试（第 1-5 层）=====

# 一键完整质量门禁（推荐：语法 + ShellCheck + 单元 + 冒烟 + 集成）
bash tests/check.sh

# 逐层单独执行：
# 1. 语法检查（涉及的全部 .sh 文件）
find lib/ modules/ bin/ -name '*.sh' -exec bash -n {} \;

# 2. ShellCheck 静态分析
shellcheck --severity=error -x lib/**/*.sh bin/*.sh modules/*.sh

# 3. BATS 单元测试
bash tests/run.sh unit

# 4. 冒烟测试（模块元数据完整性）+ 语法 + ShellCheck + 单元
bash tests/check.sh  # 已整合第 5 层

# 5. 集成测试
bash tests/run.sh integration
```

**VM 环境第 6 层测试执行规范参阅 `tests/test-plan.md` 的代码部署以及测试环境执行要求指示。**
