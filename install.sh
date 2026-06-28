#!/usr/bin/env bash
# install.sh — DebNAS 自包含引导脚本
# 无需 git，仅需 wget（Debian 最小化安装自带）
#
# 用法:
#   # 国内用户
#   wget https://gitee.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region cn
#
#   # 国际用户
#   wget https://github.com/kekylin/debnas/raw/main/install.sh && bash install.sh --region global
#
#   # 卸载
#   bash install.sh --uninstall

set -eo pipefail

# ==================== 常量 ====================

readonly DEBNAS_INSTALL_DIR="/opt/debnas"
readonly DEBNAS_BIN="/usr/local/bin/debnas"
readonly DEBNAS_CONF_DIR="/etc/debnas"
readonly DEBNAS_LOG_DIR="/var/log/debnas"
readonly DEBNAS_STATE_DIR="/var/lib/debnas/state"

# ⚠️ 此 URL 与 lib/system/installer.sh 中的定义必须保持同步
readonly REPO_CN_URL="https://gitee.com/kekylin/debnas/repository/archive/main.tar.gz"
readonly REPO_GLOBAL_URL="https://github.com/kekylin/debnas/archive/refs/heads/main.tar.gz"

# SHA256 校验和（更新版本时同步更新此值）
# 如果为空则跳过校验（开发阶段）
readonly EXPECTED_SHA256=""

# ==================== 输出函数 ====================

_msg() { printf "[%s] %s\n" "$1" "$2" >&2; }
_info()    { _msg "INFO" "$1"; }
_success() { _msg "SUCCESS" "$1"; }
_warn()    { _msg "WARNING" "$1"; }
_fail()    { _msg "FAIL" "$1"; }
_action()  { _msg "ACTION" "$1"; }

# ==================== 参数解析 ====================

REGION="global"
UNINSTALL_MODE=0
FORCE_YES=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region)
        shift
        if [[ $# -eq 0 ]]; then
          _fail "--region 需要参数 (cn 或 global)"
          exit 1
        fi
        case "$1" in
          cn|global) REGION="$1" ;;
          *)
            _fail "--region 参数无效: '$1'（仅支持 cn 或 global）"
            exit 1
            ;;
        esac
        ;;
      --uninstall)
        UNINSTALL_MODE=1
        ;;
      --yes|-y)
        FORCE_YES=1
        ;;
      --help|-h)
        print_help
        exit 0
        ;;
      *)
        _fail "未知参数: $1"
        print_usage
        exit 1
        ;;
    esac
    shift
  done
}

print_usage() {
  echo "用法: bash install.sh [--region cn|global] [--yes]"
  echo "      bash install.sh --uninstall"
}

print_help() {
  cat <<'EOF'
DebNAS — Debian NAS 自动化部署工具

安装:
  bash install.sh                   # 默认国际源（GitHub/Gitee 自动降级）
  bash install.sh --region cn       # 国内用户优先 Gitee
  bash install.sh --yes             # 自动确认所有提示

卸载:
  bash install.sh --uninstall       # 移除 DebNAS 脚本和配置

说明:
  · --region 可选，默认 global（国际源），cn 使用国内镜像
  · Gitee 和 GitHub 互为备用，任一地址失效自动切换
  · 安装到 /opt/debnas/，全局命令 /usr/local/bin/debnas
  · 安装完成后自动启动交互菜单
EOF
}

# ==================== 卸载流程 ====================

do_uninstall() {
  _warn "此操作将移除 DebNAS 所有脚本文件、配置和日志。"
  _warn "不会恢复已安装的软件包或已修改的系统配置。"

  if [[ "$FORCE_YES" -ne 1 ]]; then
    read -rp "确认继续？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      _info "已取消卸载"
      exit 0
    fi
  fi

  _action "卸载"

  # 移除全局命令
  if [[ -f "$DEBNAS_BIN" ]]; then
    rm -f "$DEBNAS_BIN"
    _info "命令: ${DEBNAS_BIN}"
  fi

  # 移除脚本代码
  if [[ -d "$DEBNAS_INSTALL_DIR" ]]; then
    rm -rf "$DEBNAS_INSTALL_DIR"
    _info "脚本: ${DEBNAS_INSTALL_DIR}"
  fi

  # 移除 cron 定时任务
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || true)
  if echo "$current_crontab" | grep -q "DEBNAS-CRON" 2>/dev/null; then
    echo "$current_crontab" | grep -v "DEBNAS-CRON" | crontab - 2>/dev/null || crontab -r 2>/dev/null || true
    _info "定时任务已清理"
  fi

  # 移除配置目录
  if [[ -d "$DEBNAS_CONF_DIR" ]]; then
    rm -rf "$DEBNAS_CONF_DIR"
    _info "配置: ${DEBNAS_CONF_DIR}"
  fi

  # 移除日志目录
  if [[ -d "$DEBNAS_LOG_DIR" ]]; then
    rm -rf "$DEBNAS_LOG_DIR"
    _info "日志: ${DEBNAS_LOG_DIR}"
  fi

  # 移除状态目录
  if [[ -d "$DEBNAS_STATE_DIR" ]]; then
    rm -rf "$DEBNAS_STATE_DIR"
    _info "状态: ${DEBNAS_STATE_DIR}"
  fi

  # 移除临时文件（使用固定路径，卸载模式下 DEBNAS_TMP_DIR 未定义）
  if [[ -d "/tmp/debnas" ]]; then
    rm -rf "/tmp/debnas"
    _info "临时: /tmp/debnas"
  fi

  _success "卸载完成"
  _info "已安装的软件包和系统配置未被修改。如需恢复系统，请手动操作。"
}

# ==================== 安装流程 ====================

# 检查 root 权限
check_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    _fail "此脚本需要 root 权限运行。请使用 sudo 或以 root 身份执行。"
    exit 1
  fi
}

# 下载仓库压缩包（自动降级：主源失败自动切换备用源）
download_repo() {
  local primary_url fallback_url
  if [[ "$REGION" == "cn" ]]; then
    primary_url="$REPO_CN_URL"
    fallback_url="$REPO_GLOBAL_URL"
    _info "源: Gitee"
  else
    primary_url="$REPO_GLOBAL_URL"
    fallback_url="$REPO_CN_URL"
    _info "源: GitHub"
  fi

  local tmpdir
  tmpdir=$(mktemp -d "${DEBNAS_TMP_DIR}/install.XXXXXX")
  chmod 700 "$tmpdir"

  local tarball="${tmpdir}/debnas.tar.gz"

  _action "下载代码"
  if ! wget -q -O "$tarball" "$primary_url" 2>/dev/null; then
    _warn "切换备用源"
    if ! wget -q -O "$tarball" "$fallback_url" 2>/dev/null; then
      _fail "所有下载源均失败"
      rm -rf "$tmpdir"
      exit 1
    fi
  fi

  # SHA256 校验
  if [[ -n "$EXPECTED_SHA256" ]]; then
    _action "校验"
    local actual_sha256
    actual_sha256=$(sha256sum "$tarball" | awk '{print $1}')
    if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
      _fail "SHA256 校验失败！文件可能被篡改"
      _fail "  期望: ${EXPECTED_SHA256}"
      _fail "  实际: ${actual_sha256}"
      rm -rf "$tmpdir"
      exit 1
    fi
    _success "校验通过"
  fi

  echo "$tmpdir"
}

# 解压到安装目录
extract_repo() {
  local tmpdir="$1"
  local tarball="${tmpdir}/debnas.tar.gz"
  local extract_dir="${tmpdir}/extract"

  mkdir -p "$extract_dir"
  _action "解压"
  if ! tar -xzf "$tarball" -C "$extract_dir" --strip-components=1 2>/dev/null; then
    _fail "解压失败"
    rm -rf "$tmpdir"
    exit 1
  fi

  # 创建安装目录
  mkdir -p "$DEBNAS_INSTALL_DIR"

  # 复制文件到安装目录
  _action "部署"
  cp -rf "$extract_dir"/bin "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
  cp -rf "$extract_dir"/lib "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
  cp -rf "$extract_dir"/modules "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
  cp -rf "$extract_dir"/config "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
  cp -f "$extract_dir"/install.sh "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
  cp -f "$extract_dir"/README.md "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
  cp -f "$extract_dir"/LICENSE "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true

  # 设置权限
  chmod +x "$DEBNAS_INSTALL_DIR/bin/"* 2>/dev/null || true
  chmod +x "$DEBNAS_INSTALL_DIR/lib/"*.sh 2>/dev/null || true

  _success "文件安装完成"
}

# 安装全局命令
install_debnas_bin() {
  cat > "$DEBNAS_BIN" <<WRAPPER
#!/bin/bash
# DebNAS 全局命令入口（由 install.sh 生成）
exec bash ${DEBNAS_INSTALL_DIR}/bin/debnas "\$@"
WRAPPER
  chmod +x "$DEBNAS_BIN"
  _success "命令: ${DEBNAS_BIN}"
}

# 创建运行时目录
create_runtime_dirs() {
  mkdir -p "$DEBNAS_CONF_DIR/conf.d" "$DEBNAS_LOG_DIR" "$DEBNAS_STATE_DIR"
  chmod 755 "$DEBNAS_CONF_DIR" "$DEBNAS_LOG_DIR" "$DEBNAS_STATE_DIR"
  chmod 755 "$DEBNAS_CONF_DIR/conf.d"
  _info "运行时目录已就绪"
}

# 写入全局配置
write_config() {
  local conf_file="${DEBNAS_CONF_DIR}/debnas.conf"

  # 首次安装：创建新配置
  if [[ ! -f "$conf_file" ]]; then
    cat > "$conf_file" <<EOF
# DebNAS 全局配置
# 创建时间: $(date '+%Y-%m-%d %H:%M:%S')
region=${REGION}
lang=zh
file_logging=1
EOF
    _success "配置: ${conf_file}"
  else
    # 更新模式：仅更新 region（如果未设置）
    if ! grep -q "^region=" "$conf_file" 2>/dev/null; then
      echo "region=${REGION}" >> "$conf_file"
    fi
    _info "已保留现有配置"
  fi
}

# 检测已安装状态
check_existing_install() {
  if [[ -d "$DEBNAS_INSTALL_DIR" ]] && [[ -f "${DEBNAS_INSTALL_DIR}/bin/debnas" ]]; then
    _info "检测到 DebNAS 已安装"

    if [[ "$FORCE_YES" -eq 1 ]]; then
      _info "--yes 模式：自动执行覆盖更新"
      return 0
    fi

    echo ""
    echo "  [1] 覆盖更新（保留配置和状态）"
    echo "  [2] 退出"
    echo ""
    read -rp "请选择 [1/2]: " choice
    case "$choice" in
      1) _info "执行覆盖更新..." ;;
      *) _info "已取消"; exit 0 ;;
    esac
  fi
}

# ==================== 主流程 ====================

main() {
  parse_args "$@"

  # 卸载模式
  if [[ "$UNINSTALL_MODE" -eq 1 ]]; then
    check_root
    do_uninstall
    exit 0
  fi

  # 安装模式
  check_root

  echo ""
  echo "============================================"
  echo "  DebNAS 安装程序"
  echo "  网络环境: ${REGION}"
  echo "============================================"
  echo ""

  # 检测已安装
  check_existing_install

  # 创建安全临时目录
  local _install_tmpdir
  _install_tmpdir=$(mktemp -d /tmp/debnas-install.XXXXXX)
  chmod 700 "$_install_tmpdir"
  trap 'rm -rf "${_install_tmpdir:-}"' EXIT

  # 临时覆盖全局 TMP 变量供 download_repo 使用
  export DEBNAS_TMP_DIR="$_install_tmpdir"

  # 下载
  local tmpdir
  tmpdir=$(download_repo)

  # 解压安装
  extract_repo "$tmpdir"

  # 安装全局命令
  install_debnas_bin

  # 创建运行时目录
  create_runtime_dirs

  # 写入配置
  write_config

  # 清理临时文件
  rm -rf "$tmpdir"
  rm -rf "$_install_tmpdir"
  trap - EXIT
  _info "临时文件已清理"

  echo ""
  _success "DebNAS 安装完成！"
  echo ""
  echo "  使用方法："
  echo "    debnas           # 启动交互菜单"
  echo "    debnas --help    # 查看所有命令"
  echo ""

  # 自动启动交互菜单
  exec bash "${DEBNAS_INSTALL_DIR}/bin/debnas"
}

main "$@"
