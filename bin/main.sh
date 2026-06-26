#!/bin/bash
# 功能：兼容入口脚本（保留旧接口，转发到新的 CLI 调度器）
# 说明：此文件保留向后兼容性，实际功能已迁移到 bin/debnas 和 bin/menu.sh
#
# 用法：
#   bash bin/main.sh          → 启动交互菜单
#   bash bin/main.sh --tmpdir /path  → 兼容旧版参数
#
# 推荐使用新的 CLI 入口：
#   bash bin/debnas menu      → 启动交互菜单
#   bash bin/debnas --help    → 查看所有命令

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${_DEBNAS_SCRIPT}")/.." && pwd)"

# 转发到新的 CLI 调度器（将 --tmpdir 等旧参数过滤掉）
exec bash "${SCRIPT_DIR}/bin/debnas" menu "$@"
