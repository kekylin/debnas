#!/bin/bash
# 功能：全局参数解析模块
# 说明：统一解析 CLI 全局参数，启动时从配置文件读取默认值，CLI 参数可临时覆盖
# 依赖: 无（纯函数库，由 bootstrap.sh 加载）

set -euo pipefail
IFS=$'\n\t'

# ==================== 常量定义 ====================

# DebNAS 版本（日期版本号）
readonly DEBNAS_VERSION="${DEBNAS_VERSION:-v2026.11.1}"

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
  install <模块>          安装模块
  run <模块>              执行模块
  config                   显示配置用法帮助
  config list              列出所有配置
  config <key>             查询配置值
  config <key> <value>     设置配置
  update [--tag <版本>]   更新 DebNAS（校验 GPG 签名与 SHA256，默认最新稳定版）
  update --unsigned [--branch <分支>]  按分支更新，不校验（仅调试，需交互确认）
  uninstall               卸载 DebNAS
  doctor                  系统状态诊断
  files                   列出 DebNAS 文件布局与修改过的系统文件
  cron enable|disable|list   管理定时任务

全局参数（临时生效，需配合子命令）:
  --dry-run               仅预览，不实际操作
  --yes, -y               自动确认所有提示
  --region cn|global      指定网络环境

示例:
  debnas                                    # 启动交互菜单
  debnas install sources                    # 配置软件源
  debnas install cockpit                    # 安装 Cockpit
  debnas run sys-check                      # 运行系统检查
  debnas config                             # 查看配置用法
  debnas config list                        # 列出全部配置
  debnas config region                      # 查询 region 值
  debnas config region cn                   # 设置: 国内镜像
  debnas --dry-run install docker-ce        # 预览安装计划
  debnas doctor                             # 系统诊断
  debnas cron list                          # 查看全部定时任务
  debnas cron enable sys-patches            # 启用定时（默认每天 00:00）
  debnas cron disable sys-patches           # 禁用定时
  debnas --help                             # 显示帮助

项目主页: https://github.com/kekylin/debnas
QQ 群: 339169752
EOF
}

# 解析全局参数
# 参数：$@ - 命令行参数列表
# 输出：设置全局环境变量，剩余参数通过 DEBNAS_REMAINING_ARGS_ARRAY 返回
# 返回：0 成功，1 参数错误
#
# 说明：
#   启动时优先从 /etc/debnas/debnas.conf 读取持久化配置
#   CLI 参数可临时覆盖配置文件值（仅本次执行有效）
#   通过 debnas config <key> <value> 可持久化设置
parse_global_args() {
	local -a remaining_args=()

	# 第1步：从配置文件读取持久化设置
	local _cfg_region _cfg_file_logging
	_cfg_region=$(config_read "global" "region" "" 2>/dev/null || true)
	_cfg_file_logging=$(config_read "global" "file_logging" "" 2>/dev/null || true)

	# 第2步：初始化环境变量（配置文件 > 环境变量 > 默认值）
	export DEBNAS_DRY_RUN="${DEBNAS_DRY_RUN:-0}"
	export DEBNAS_FORCE_YES="${DEBNAS_FORCE_YES:-0}"
	export DEBNAS_REGION="${DEBNAS_REGION:-${_cfg_region:-}}"
	export DEBNAS_FILE_LOGGING="${DEBNAS_FILE_LOGGING:-${_cfg_file_logging:-0}}"
	export DEBNAS_CRON_MODE="${DEBNAS_CRON_MODE:-0}"

	# 标记：是否有 CLI 显式传递的全局参数（与配置文件区分）
	_DEBNAS_CLI_FLAGS=0

	# 第3步：解析 CLI 参数（临时覆盖，仅本次生效）
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--dry-run)
				export DEBNAS_DRY_RUN=1
				_DEBNAS_CLI_FLAGS=1
				shift
				;;

			--yes|-y)
				export DEBNAS_FORCE_YES=1
				_DEBNAS_CLI_FLAGS=1
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
				_DEBNAS_CLI_FLAGS=1
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
				_DEBNAS_CLI_FLAGS=1
				shift
				;;

			--)
				shift
				remaining_args+=("$@")
				break
				;;

			*)
				remaining_args+=("$1")
				shift
				;;
		esac
	done

	# 将剩余参数存入全局数组（避免 eval 反序列化，安全传递含空格/特殊字符的参数）
	# shellcheck disable=SC2034  # 被 bin/debnas、bin/module-runner.sh 读取
	DEBNAS_REMAINING_ARGS_ARRAY=("${remaining_args[@]+"${remaining_args[@]}"}")
	return 0
}
