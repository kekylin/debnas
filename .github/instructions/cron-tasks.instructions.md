---
description: "Use when developing scripts that support cron scheduled tasks, implementing --cron mode, or working with init_cron/init_manual functions. Covers run mode detection, cron logging, data directory layout, and crontab management."
---

# debnas 定时任务（Cron 模式）开发规范

## 运行模式检测

```bash
declare RUN_MODE="manual"
if [[ "${1:-}" == "--cron" ]]; then
    RUN_MODE="cron"
fi
```

- 统一使用 `--cron` 参数标识定时任务模式
- 检测位于 `set -euo pipefail` 之后
- 交互模式（manual）：支持用户交互
- 定时任务模式（cron）：无交互，仅执行核心功能

## PATH 环境变量

所有支持 cron 的脚本必须在开头设置标准 PATH：

```bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
```

## 日志处理

### 交互模式

加载公共库 `lib/core/logging.sh`，保持日志风格统一。

### 定时任务模式

使用最小化日志函数，无颜色输出，格式一致：

```bash
log_status() {
    local status="$1" message="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] %s %s\n" "$status" "$ts" "$message" >&2
}
log_info()    { log_status "INFO" "$1"; }
log_error()   { log_status "FAIL" "$1"; }
log_warning() { log_status "WARNING" "$1"; }
log_success() { log_status "SUCCESS" "$1"; }
```

## 文件存放规范

### 数据目录

统一存放在 `/var/lib/<模块名>/`，权限 `755`：

```bash
DATA_DIR="/var/lib/firewalld-ipthreat"
CONFIG_FILE="${DATA_DIR}/ipthreat.conf"
CRON_SCRIPT_PATH="${DATA_DIR}/firewalld_ipthreat.sh"
```

### 文件权限

- 脚本文件：`755`
- 配置文件：`644`
- 日志文件：`644`，存放于 `/var/log/<模块名>.log`

## Crontab 管理

### 任务格式

```bash
# 绝对路径 + --cron 参数 + 模块标识注释
cron_schedule /bin/bash $CRON_SCRIPT_PATH --cron # IPThreat Firewalld Update
```

### 安全更新 crontab

使用临时文件方式安全增删任务，通过 `sed` 和模块标识注释定位任务行。

## 初始化函数

### init_manual()

- 初始化日志文件
- 设置默认配置值
- 不创建数据目录（由用户确认后创建）

### init_cron()

- 检查日志文件存在且可写
- 初始化数据目录
- 安全加载配置文件（`while IFS='=' read`，禁止 `source`）
- 验证配置参数有效性

## 脚本独立性要求

- Cron 模式脚本不得 `source` 项目公共库（`lib/` 下文件）
- 必须包含所有必要的函数定义
- 使用绝对路径，不依赖项目目录结构
- 临时目录基目录：`DEBNAS_TMP_BASE="${DEBNAS_TMP_BASE:-/tmp/debnas}"`
- `cleanup_temp_files` 默认 no-op，仅清理私有子目录

## 开发检查清单

- [ ] 使用统一的 `--cron` 参数检测运行模式
- [ ] 设置标准 PATH 环境变量
- [ ] 交互模式用公共日志库，cron 模式用简化日志
- [ ] 数据目录遵循 `/var/lib/<模块名>/` 格式
- [ ] 文件权限正确（脚本 755，配置 644，日志 644）
- [ ] 实现 `init_cron()` 安全加载配置
- [ ] 禁用时正确清理所有相关文件
- [ ] 脚本可独立运行，无需项目库环境
