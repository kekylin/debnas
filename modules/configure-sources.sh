#!/usr/bin/env bash
# 功能: Debian 软件源配置与切换（支持测速换源、自选镜像、自定义镜像）
# 本脚本自动下载并调用开源工具 chsrc (https://github.com/RubyMetric/chsrc)
# chsrc 由 RubyMetric 开发，遵循 GPL-3.0-or-later 和 MIT 许可协议。
# 本脚本不修改 chsrc，仅调用其功能进行系统软件源更换。
# 感谢 chsrc 项目作者的贡献。


set -euo pipefail
IFS=$'\n\t'

# 加载公共库（日志、依赖、工具）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"

# 受控临时目录（遵循项目规范）
TMP_DIR="/tmp/debian-homenas"
mkdir -p "$TMP_DIR" 2>/dev/null || true
chmod 700 "$TMP_DIR" 2>/dev/null || true

# 依赖项检查（自动安装缺失依赖）
required_cmds=(wget awk grep sed tee)
if ! check_dependencies "${required_cmds[@]}"; then
  log_action "正在安装缺失依赖..."
  if install_missing_dependencies "${required_cmds[@]}"; then
    log_success "依赖安装完成。"
  else
    log_error "依赖安装失败，无法继续。"
    exit 2
  fi
fi

# 日志文件（若存在则追加，不存在则创建）
LOG_FILE="/var/log/chsrc-switch.log"
touch "$LOG_FILE" 2>/dev/null || true

# 标记 chsrc 是否由本脚本安装（供退出时清理）
CHSRC_INSTALLED_BY_SCRIPT=0

# 统一日志适配
log()   { log_info "$*"; echo "$*" >>"$LOG_FILE" 2>/dev/null || true; }
error() { log_error "$*"; echo "$*" >>"$LOG_FILE" 2>/dev/null || true; }

# ---------- 系统检测 ----------
detect_system() {
    if ! verify_system_support; then
        exit 1
    fi
    CODENAME=$(get_system_codename)
    local version_full
    version_full=$(get_system_version)
    local version_major="${version_full%%.*}"
    log "系统版本检测：Debian ${version_major} (${CODENAME})"
}

# ---------- chsrc 安装 ----------
install_chsrc() {
    if command -v chsrc &>/dev/null; then
        log "已检测到 chsrc 工具，跳过安装。"
        return
    fi

    log "未检测到 chsrc，尝试安装..."
    local urls=(
        "https://gitee.com/RubyMetric/chsrc/raw/main/tool/installer.sh"
        "https://chsrc.run/posix"
        "https://raw.githubusercontent.com/RubyMetric/chsrc/main/tool/installer.sh"
    )

    local downloaded=0 tmp_installer
    tmp_installer="$(mktemp "$TMP_DIR/chsrc-installer.XXXXXX" 2>/dev/null || echo "$TMP_DIR/chsrc-installer.$RANDOM")"
    for u in "${urls[@]}"; do
        log "尝试下载安装脚本：$u"
        if wget -q --timeout=15 --tries=2 -O "$tmp_installer" "$u"; then
            # 基本校验：非空 + 以 shebang 开头
            if [[ -s "$tmp_installer" ]] && head -n1 "$tmp_installer" | grep -q "^#!"; then
                downloaded=1
                break
            fi
        fi
    done

    if [[ $downloaded -ne 1 ]]; then
        rm -f "$tmp_installer" 2>/dev/null || true
        error "chsrc 安装脚本下载失败，请检查网络。"
        exit 1
    fi

    if bash "$tmp_installer"; then
        CHSRC_INSTALLED_BY_SCRIPT=1
    else
        rm -f "$tmp_installer" 2>/dev/null || true
        error "chsrc 安装脚本执行失败。"
        exit 1
    fi
    rm -f "$tmp_installer" 2>/dev/null || true

    if ! command -v chsrc &>/dev/null; then
        error "chsrc 安装失败，请检查网络。"
        exit 1
    fi
    log "chsrc 安装成功。"
}

# ---------- DEB822 源文件准备 ----------
prepare_sources_env() {
    # 延迟系统检测：仅在需要时执行
    if [[ -z "${CODENAME:-}" ]]; then
        detect_system
    fi

    if [[ -f /etc/apt/sources.list ]]; then
        log "检测到旧版 sources.list，执行备份..."
        mv /etc/apt/sources.list /etc/apt/sources.list.bak
    fi

    mkdir -p /etc/apt/sources.list.d
    local src_file="/etc/apt/sources.list.d/debian.sources"

    log "写入官方 DEB822 格式源模板"

    tee "$src_file" > /dev/null <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $CODENAME ${CODENAME}-updates ${CODENAME}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: ${CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

# ---------- 功能函数 ----------
switch_fastest() {
    prepare_sources_env
    log "开始测速并切换至最快镜像..."
    command -v chsrc >/dev/null 2>&1 || install_chsrc
    chsrc set debian
    log "测速换源完成。"
}

switch_first() {
    prepare_sources_env
    log "切换至维护团队测速第一的镜像源..."
    command -v chsrc >/dev/null 2>&1 || install_chsrc
    chsrc set debian first
    log "镜像源切换完成。"
}

switch_list() {
    log "获取可用镜像源列表..."

    local mirrors
    command -v chsrc >/dev/null 2>&1 || install_chsrc
    mirrors=$(chsrc list debian | awk '/^[[:space:]]*[a-z0-9]+[[:space:]]+[A-Za-z]/ && $1 != "code" {print $1, substr($0, index($0,$2))}')

    if [[ -z "$mirrors" ]]; then
        error "未获取到镜像列表，请检查网络或 chsrc 状态。"
        return
    fi

    echo
    print_separator "-"
    print_title "可用镜像源列表"
    print_separator "-"
    local index=1
    while read -r code name; do
        printf "%2d) %-10s %s\n" "$index" "$code" "$name"
        ((index++))
    done <<< "$mirrors"
    echo " 0) 返回"
    print_separator "-"

    print_prompt "请选择编号："
    read -r choice
    if [[ "$choice" == "0" ]]; then
        log "已选择退出，返回上级菜单。"
        return
    fi

    local selected
    selected=$(echo "$mirrors" | sed -n "${choice}p" | awk '{print $1}')

    if [[ -z "$selected" ]]; then
        error "输入无效，未选择任何镜像源。"
        return
    fi

    log "切换至镜像源：$selected"
    prepare_sources_env
    chsrc set debian "$selected"
    log "自选镜像切换完成。"
}

switch_custom() {
    echo
    echo "示例格式： https://mirrors.tuna.tsinghua.edu.cn/debian"
    print_prompt "请输入自定义镜像源 URL（必须包含 /debian）："
    read -r custom_url

    if [[ -z "$custom_url" ]]; then
        error "未输入任何 URL，操作已取消。"
        return
    fi

    # 严格验证输入格式
    if [[ ! "$custom_url" =~ ^https?://.+/debian/?$ ]]; then
        error "输入格式错误！请按以下格式输入："
        echo "  https://镜像域名/debian"
        echo "示例： https://mirrors.tuna.tsinghua.edu.cn/debian"
        return
    fi

    log "正在使用自定义镜像源：$custom_url"
    prepare_sources_env
    command -v chsrc >/dev/null 2>&1 || install_chsrc
    chsrc set debian "$custom_url"
    log "自定义镜像源配置完成。"
}

# ---------- 清理与卸载 ----------
cleanup() {
    if command -v chsrc &>/dev/null; then
        local path
        path=$(command -v chsrc)
        if [[ $CHSRC_INSTALLED_BY_SCRIPT -eq 1 ]]; then
            log "卸载由本脚本安装的 chsrc..."
            if [[ "$path" == "/usr/local/bin/chsrc" ]]; then
                rm -f /usr/local/bin/chsrc || true
                rm -rf ~/.chsrc /usr/local/share/chsrc* /usr/local/etc/chsrc* 2>/dev/null || true
                log "已卸载 chsrc 工具（路径：$path）"
            else
                # 安装方式异常，避免误删系统包
                log "检测到非预期安装路径，跳过自动卸载（$path）。"
            fi
        else
            log "检测到系统已有 chsrc，按约定不卸载。"
        fi
    fi
    log "清理完成。"
}

# ---------- 菜单 ----------
menu() {
    while true; do
        echo
        print_separator "-"
        print_title "Debian 软件源管理工具"
        print_separator "-"
        print_menu_item 1 " 测速换源"
        print_menu_item 2 " 自选镜像源"
        print_menu_item 3 " 自定义镜像源"
        print_menu_item 0 " 返回" true
        print_separator "-"
        print_prompt "请选择编号："
        read -r opt

        case "$opt" in
            1) switch_fastest ;;
            2) switch_list ;;
            3) switch_custom ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新输入。" ;;
        esac
    done
}

# ---------- 主程序 ----------
main() {
    if [[ "$1" == "--auto" ]]; then
        # 无人值守模式：立即执行系统检测和换源操作
        detect_system
        log "无人值守模式：使用维护团队测速第一的镜像源..."
        command -v chsrc >/dev/null 2>&1 || install_chsrc
        switch_first
        exit 0
    fi

    # 交互模式：延迟所有操作，仅显示菜单
    menu
}

trap cleanup EXIT
main "${@:-}"
