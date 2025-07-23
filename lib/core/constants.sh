#!/bin/bash
# 功能：统一错误码定义模块

set -euo pipefail
IFS=$'\n\t'

# 获取脚本目录
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 标准错误码定义
SUCCESS=0                    # 成功
ERROR_GENERAL=1             # 通用错误
ERROR_DEPENDENCY=2          # 依赖缺失
ERROR_CONFIG=3              # 配置错误
ERROR_PERMISSION=4          # 权限不足
ERROR_PARAMETER=5           # 参数错误
ERROR_UNSUPPORTED_OS=6      # 不支持的操作系统

# 兼容性错误码（保持向后兼容）
GENERAL="${ERROR_GENERAL}"
DEPENDENCY="${ERROR_DEPENDENCY}"
CONFIG="${ERROR_CONFIG}"
PERMISSION="${ERROR_PERMISSION}"
PARAMETER="${ERROR_PARAMETER}"
UNSUPPORTED_OS="${ERROR_UNSUPPORTED_OS}" 