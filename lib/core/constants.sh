#!/bin/bash
# 功能：统一错误码定义模块
# shellcheck disable=SC2034  # 错误码由 modules/、bin/、lib/system/*.sh 在 source 后引用

set -euo pipefail
IFS=$'\n\t'

# 标准错误码定义
SUCCESS=0                    # 成功
ERROR_GENERAL=1             # 通用错误
ERROR_DEPENDENCY=2          # 依赖缺失
ERROR_PERMISSION=4          # 权限不足
ERROR_UNSUPPORTED_OS=6      # 不支持的操作系统
