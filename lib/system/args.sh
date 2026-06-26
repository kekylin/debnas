#!/bin/bash
# 功能：全局参数解析模块
# 说明：统一解析 CLI 全局参数，设置对应环境变量供后续模块使用

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ==================== 常量定义 ====================

# DebNAS 版本（日期版本号）
readonly DEBNAS_VERSION="${DEBNAS_VERSION:-v2026.06}"

# ==================== 公共接口 ====================

# 打印简短用法说明
# 参数：无
# 输出：单行用法格式
print_usage() {
  echo "用法: debnas [全局参数] <子命令> [子命令参数]"
}

# 打印完整帮助信息
# 参数：无
# 输出：格式化的帮助文本
print_help() {
  cat <<'EOF'
DebNAS — Debian NAS 自动化部署工具

用法: debnas [全局参数] <子命令> [子命令参数]

子命令:
  menu                 启动交互菜单（无参数时的默认命令）
  install <模块>       安装指定模块
  update               更新 DebNAS 到最新版本（保留配置和状态）
  uninstall            卸载 DebNAS
  doctor               系统状态诊断
  cron add|remove|list 管理定时任务

全局参数:
  --debug              启用调试日志
  --dry-run            仅预览操作，不实际执行
  --yes, -y            自动确认所有提示
  --region cn|global   指定网络环境（cn=国内镜像，global=国际镜像）
  --lang zh|en         指定界面语言
  --version            打印版本号并退出
  --help               打印此帮助信息并退出

示例:
  debnas                               # 启动交互菜单
  debnas install configure-sources     # 配置软件源
  debnas --debug install docker-ce     # 调试模式安装 Docker
  debnas --dry-run install firewall    # 预览防火墙安装（不执行）
  debnas doctor                        # 运行系统诊断
  debnas cron list                     # 查看定时任务

项目主页: https://github.com/kekylin/debnas
QQ 群: 339169752
EOF
}

# 解析全局参数
# 参数：$@ - 命令行参数列表
# 输出：设置全局环境变量，剩余参数通过 DEBNAS_REMAINING_ARGS 返回
# 返回：0 成功，1 参数错误
#
# 全局参数设置的环境变量：
#   LOG_LEVEL         - 日志级别（--debug 设为 DEBUG）
#   DEBNAS_DRY_RUN    - 预览模式（--dry-run 设为 1）
#   DEBNAS_FORCE_YES  - 自动确认（--yes/-y 设为 1）
#   DEBNAS_REGION     - 网络环境（--region 设为 cn 或 global）
#   DEBNAS_LANG       - 界面语言（--lang 设为 zh 或 en）
#   DEBNAS_REMAINING_ARGS - 去除全局参数后的剩余参数
parse_global_args() {
  local -a remaining_args=()

  # 初始化默认值
  export LOG_LEVEL="${LOG_LEVEL:-INFO}"
  export DEBNAS_DRY_RUN="${DEBNAS_DRY_RUN:-0}"
  export DEBNAS_FORCE_YES="${DEBNAS_FORCE_YES:-0}"
  export DEBNAS_REGION="${DEBNAS_REGION:-}"
  export DEBNAS_LANG="${DEBNAS_LANG:-zh}"
  export DEBNAS_CRON_MODE="${DEBNAS_CRON_MODE:-0}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug)
        export LOG_LEVEL="DEBUG"
        shift
        ;;

      --dry-run)
        export DEBNAS_DRY_RUN=1
        shift
        ;;

      --yes|-y)
        export DEBNAS_FORCE_YES=1
        shift
        ;;

      --region)
        shift
        if [[ $# -eq 0 ]]; then
          echo "错误: --region 需要参数 (cn 或 global)" >&2
          return 1
        fi
        case "$1" in
          cn|global)
            export DEBNAS_REGION="$1"
            ;;
          *)
            echo "错误: --region 参数无效: '$1'（仅支持 cn 或 global）" >&2
            return 1
            ;;
        esac
        shift
        ;;

      --lang)
        shift
        if [[ $# -eq 0 ]]; then
          echo "错误: --lang 需要参数 (zh 或 en)" >&2
          return 1
        fi
        case "$1" in
          zh|en)
            export DEBNAS_LANG="$1"
            ;;
          *)
            echo "错误: --lang 参数无效: '$1'（仅支持 zh 或 en）" >&2
            return 1
            ;;
        esac
        shift
        ;;

      --version)
        echo "DebNAS ${DEBNAS_VERSION}"
        exit 0
        ;;

      --help|-h)
        print_help
        exit 0
        ;;

      --cron)
        export DEBNAS_CRON_MODE=1
        shift
        ;;

      --)
        shift
        # -- 后面的全部作为剩余参数
        remaining_args+=("$@")
        break
        ;;

      *)
        remaining_args+=("$1")
        shift
        ;;
    esac
  done

  # 将剩余参数存入全局变量供调用方使用（用空格连接，不受 IFS 影响）
  export DEBNAS_REMAINING_ARGS
  DEBNAS_REMAINING_ARGS="$(IFS=' '; echo "${remaining_args[*]:-}")"
  return 0
}

# 获取剩余参数为数组
# 参数：无
# 输出：将 DEBNAS_REMAINING_ARGS 解析到调用方的数组中
# 用法：
#   parse_global_args "$@"
#   get_remaining_args
#   set -- "${REMAINING[@]}"
get_remaining_args() {
  local -a REMAINING=()
  if [[ -n "${DEBNAS_REMAINING_ARGS:-}" ]]; then
    read -ra REMAINING <<< "$DEBNAS_REMAINING_ARGS"
  fi
  # 通过全局变量返回（bash 函数无法直接返回数组）
  eval "REMAINING=(\"\${REMAINING[@]:-}\")"
}
