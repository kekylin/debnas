---
description: "Use when editing debnas shell scripts. Covers Debian-specific requirements: UI design, logging standards, dependency management, and temp file handling for the debnas project."
applyTo: "**/*.sh"
---

# debnas Bash 开发规范（Debian 项目）

## UI 设计规范

### 视觉一致性

- 同一行内元素颜色统一，禁止不同颜色混用
- 所有颜色使用普通字体（非粗体）：`\e[0;3Xm` 格式
- 支持 `NO_COLOR=1` 环境变量禁用颜色输出
- 使用 `get_ui_color()` 获取语义化颜色

### 样式函数

使用 `print_` 前缀的标准样式函数：

`print_banner_text`、`print_title`、`print_success`、`print_warning`、`print_error`、`print_info`、`print_highlight`、`print_separator`、`print_menu_item`、`print_prompt`

- 优先使用预定义样式函数，避免直接使用颜色变量
- 兼容不同终端，支持优雅降级到黑白显示

## 日志规范

### 统一日志模块（lib/core/logging.sh）

| 级别 | 数值 | 颜色 | 用途 |
|:---|:---|:---|:---|
| DEBUG | 0 | 青色 | 调试信息 |
| INFO | 1 | 绿色 | 正常操作 |
| WARN | 2 | 黄色 | 潜在问题 |
| ERROR | 3 | 红色 | 操作失败 |
| FATAL | 4 | 紫色 | 致命错误 |

**日志格式**：`[级别] 时间戳 文件名:行号 (函数名): 消息内容`

**标准函数**：`log_debug`、`log_info`、`log_warn`、`log_error`、`log_fatal`

**环境变量**：`LOG_LEVEL`（默认 INFO）、`NO_COLOR`、`LOG_TIMESTAMP`

### 使用建议

- 开发阶段：DEBUG 级别
- 生产环境：INFO 或 WARN 级别
- 日志内容使用中文，包含关键参数和状态信息

## 依赖管理

```bash
# 使用关联数组映射命令到包名
declare -A CMD_PKG_MAP=(
    ["curl"]="curl"
    ["jq"]="jq"
    ["wget"]="wget"
)
```

- 以 root 权限执行，禁止 sudo
- 缺失依赖自动通过 apt 安装

## 临时文件处理

- 基目录：`/tmp/debnas/`，权限 `0700`
- 使用 `mktemp` 创建唯一文件名
- 通过 `trap` 在脚本退出时自动清理
- APT 安装场景：临时提升基目录权限 → 创建 `0755` 子目录 → 恢复原权限
