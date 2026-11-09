#!/bin/bash
# @module: tailscale
# @name: 安装 Tailscale
# @category: 系统工具
# @depends: curl
# @version: 1.0.0
# @order: 74
# 功能：安装并配置 Tailscale 内网穿透服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 可覆盖路径（测试时可注入临时目录）
TAILSCALE_KEYRING_FILE="${TAILSCALE_KEYRING_FILE:-/usr/share/keyrings/tailscale-archive-keyring.gpg}"
TAILSCALE_SOURCES_DIR="${TAILSCALE_SOURCES_DIR:-/etc/apt/sources.list.d}"

# 官方 Debian 安装方式（https://pkgs.tailscale.com/stable/ 的 Debian Bookworm/Trixie 小节，2026-11-09 核对）：
#   公钥  https://pkgs.tailscale.com/stable/debian/<codename>.noarmor.gpg → /usr/share/keyrings/tailscale-archive-keyring.gpg
#   源    https://pkgs.tailscale.com/stable/debian/<codename>.tailscale-keyring.list，内容为：
#         deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian <codename> main
# 本模块本地生成等价的 DEB822 源，不写入远程下载的内容；公钥必须匹配下方固定指纹。
# 仓库/公钥地址可在 /etc/debnas/debnas.conf 用 repo_tailscale_url / repo_tailscale_key_url 换成镜像，
# 指纹校验不变，apt 仍用钉死的 keyring 校验 Release 签名，镜像无法篡改软件包。
TAILSCALE_DEFAULT_REPO_URL="https://pkgs.tailscale.com/stable/debian"

# Tailscale 仓库签名主密钥指纹（Tailscale Inc. (Package repository signing key) <info@tailscale.com>，
# rsa4096，2020-02-25 创建）。来源：首次获取固定（TOFU）——官方未在网页公布指纹（见 tailscale/tailscale#15221）；
# 2026-11-09 从 pkgs.tailscale.com 获取（bookworm/trixie 两个 .noarmor.gpg 内容相同），与 keyserver.ubuntu.com、
# keys.openpgp.org 上同指纹公钥一致，且该密钥能验证 bookworm/trixie 的 InRelease 签名。
TAILSCALE_GPG_FINGERPRINT="2596A99EAAB33821893C0A79458CA832957F5868"

# 读取可配置的地址（留空=默认地址）；只接受 http(s):// 且不含空白的单个 URL，去掉末尾 /
# 参数：$1 - 配置键名，$2 - 默认地址
read_tailscale_url() {
  local key="$1" default_url="$2" url
  url=$(config_read "global" "$key" "" 2>/dev/null) || url=""
  [[ -n "$url" ]] || url="$default_url"
  if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
    log_error "debnas.conf 中 ${key} 不是合法的 http(s) 地址：${url}"
    return 1
  fi
  echo "${url%/}"
}

# 校验公钥文件：只允许包含一个主密钥，且指纹等于固定指纹
# 参数：$1 - 公钥文件路径（armored 或二进制均可）
# 返回：0 校验通过，1 失败
verify_tailscale_gpg_fingerprint() {
  local key_file="$1"
  local gpg_home fprs

  gpg_home=$(create_temp_dir "tailscale-gpg") || return 1
  # --with-colons 输出中 pub 行之后的第一条 fpr 为主密钥指纹（跳过子密钥）
  fprs=$(gpg --homedir "$gpg_home" --batch --quiet --show-keys --with-colons "$key_file" 2>/dev/null \
    | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }') || return 1

  if [[ "$fprs" != "$TAILSCALE_GPG_FINGERPRINT" ]]; then
    log_error "Tailscale GPG 公钥指纹不匹配（期望 ${TAILSCALE_GPG_FINGERPRINT}，实际 ${fprs:-无}），拒绝安装"
    return 1
  fi
  return 0
}

# 下载 Tailscale 公钥 → 校验指纹 → 原子替换 keyring（任一步失败都不动已有 keyring）
# 参数：$1 - 公钥下载地址
install_tailscale_keyring() {
  local key_url="$1"
  local keyring_tmp key_bin gpg_home keyring_dir tmp_dst attempt downloaded=0

  command -v gpg >/dev/null 2>&1 || apt_install_packages gnupg || {
    log_error "gnupg 安装失败，无法校验 Tailscale 公钥"
    return 1
  }

  keyring_tmp=$(create_temp_file "tailscale-keyring" ".gpg") || return 1
  key_bin=$(create_temp_file "tailscale-keyring" ".bin") || return 1
  # 下载失败重试 1 次
  for attempt in 1 2; do
    if curl -fsSL --max-time 30 --connect-timeout 10 "$key_url" -o "$keyring_tmp" && [[ -s "$keyring_tmp" ]]; then
      downloaded=1
      break
    fi
    [[ $attempt -eq 2 ]] || { log_warning "Tailscale GPG 密钥下载失败，重试中..."; sleep 2; }
  done
  if [[ $downloaded -ne 1 ]]; then
    log_error "Tailscale GPG 密钥下载失败：${key_url}"
    log_error "网络不通时可在 /etc/debnas/debnas.conf 配置 repo_tailscale_key_url / repo_tailscale_url 镜像地址（指纹校验不变）"
    return 1
  fi

  # 官方 .noarmor.gpg 已是二进制 keyring；镜像若提供 ASCII armored 则转为二进制
  if grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$keyring_tmp" 2>/dev/null; then
    gpg_home=$(create_temp_dir "tailscale-gpg") || return 1
    gpg --homedir "$gpg_home" --batch --yes --dearmor -o "$key_bin" "$keyring_tmp" 2>/dev/null || key_bin=""
  else
    cp -- "$keyring_tmp" "$key_bin" || key_bin=""
  fi
  if [[ -z "$key_bin" || ! -s "$key_bin" ]] || ! verify_tailscale_gpg_fingerprint "$key_bin"; then
    log_error "Tailscale GPG 公钥校验失败，拒绝安装"
    return 1
  fi

  if [[ -f "$TAILSCALE_KEYRING_FILE" ]] && cmp -s "$key_bin" "$TAILSCALE_KEYRING_FILE" 2>/dev/null; then
    log_info "Tailscale GPG 密钥未变更，跳过"
    return 0
  fi
  # 同目录临时文件 + rename 原子替换，不截断已有 keyring
  keyring_dir=$(dirname -- "$TAILSCALE_KEYRING_FILE")
  install -m 0755 -d "$keyring_dir"
  tmp_dst=$(mktemp -- "${keyring_dir}/.tailscale-keyring.debnas.XXXXXX") || return 1
  if ! cat -- "$key_bin" > "$tmp_dst" || ! chmod 644 "$tmp_dst" \
    || ! mv -fT -- "$tmp_dst" "$TAILSCALE_KEYRING_FILE"; then
    [[ -n "$tmp_dst" ]] && rm -f -- "$tmp_dst"
    log_error "Tailscale GPG 密钥写入失败：${TAILSCALE_KEYRING_FILE}"
    return 1
  fi
  log_info "Tailscale GPG 密钥已更新（指纹 ${TAILSCALE_GPG_FINGERPRINT}）"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

_ts_pkg_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# tailscaled 后端状态（Running/NeedsLogin/Stopped/...；读不到输出空）
# 说明：tailscale status 只走本机 tailscaled 套接字，不联网；加 timeout 防挂起
_ts_backend_state() {
  command -v tailscale >/dev/null 2>&1 || return 0
  timeout 2 tailscale status --json 2>/dev/null \
    | sed -nE 's/^[[:space:]]*"BackendState":[[:space:]]*"([^"]*)".*/\1/p' | head -n1 || true
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local state ip=""
  if ! _ts_pkg_installed tailscale; then
    echo "absent|未安装 Tailscale"
    return 0
  fi
  if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    echo "warn|已安装，tailscaled 未运行"
    return 0
  fi
  state=$(_ts_backend_state)
  case "$state" in
    Running)
      ip=$(timeout 2 tailscale ip -4 2>/dev/null | head -n1 || true)
      echo "running|已登录运行中${ip:+ · ${ip}}"
      ;;
    NeedsLogin|NoState) echo "partial|tailscaled 运行中，尚未登录（执行 tailscale up）" ;;
    NeedsMachineAuth)   echo "partial|已登录，等待管理员在控制台批准本机" ;;
    Stopped)            echo "warn|tailscaled 运行中，连接已断开（执行 tailscale up）" ;;
    Starting)           echo "running|tailscaled 运行中，正在连接" ;;
    "")                 echo "running|tailscaled 运行中，登录状态未知（无法读取 tailscale status）" ;;
    *)                  echo "warn|tailscaled 运行中，状态 ${state}" ;;
  esac
}

# 预演：每行 "类型|目标|备注"
module_plan() {
  local IFS=$' \n\t'
  local repo_url
  repo_url=$(config_read "global" "repo_tailscale_url" "" 2>/dev/null) || repo_url=""
  repo_url="${repo_url:-$TAILSCALE_DEFAULT_REPO_URL}"

  command -v gpg >/dev/null 2>&1 || echo "pkg|gnupg|校验 Tailscale 公钥指纹需要"
  echo "info|Tailscale 公钥|执行时联网下载并校验固定指纹 ${TAILSCALE_GPG_FINGERPRINT}"
  echo "write|${TAILSCALE_KEYRING_FILE}|指纹校验通过后原子替换（内容未变则跳过，不另做备份）"
  if [[ -f "${TAILSCALE_SOURCES_DIR}/tailscale.list" ]]; then
    echo "write|${TAILSCALE_SOURCES_DIR}/tailscale.list|旧格式源备份到 /var/backups/debnas/ 后移除"
  fi
  echo "write|${TAILSCALE_SOURCES_DIR}/tailscale.sources|DEB822 源（${repo_url}）；内容未变则跳过，旧文件备份到 /var/backups/debnas/"
  if _ts_pkg_installed tailscale; then
    echo "info|tailscale|已安装，跳过安装"
  else
    echo "pkg|tailscale|apt 安装（先 apt update）"
    echo "service|tailscaled|随软件包启用并启动"
  fi
  echo "info|tailscale up|模块不自动登录，安装后需手动执行 tailscale up 完成身份验证"
  echo "risk|第三方软件源|新增 APT 源 ${repo_url}（apt 用固定指纹的 keyring 校验签名）"
  return 0
}

main() {
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查 curl、apt、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(curl apt systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 curl、apt 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性，防止在不支持的平台运行# 动态获取系统代号，避免硬编码导致跨版本不兼容
CODENAME=$(get_system_codename)
if [[ -z "${CODENAME}" ]]; then
  log_error "无法获取系统版本代号。"
  exit "${ERROR_GENERAL}"
fi

log_info "安装 Tailscale..."

# 添加 Tailscale 的包签名密钥和存储库，确保软件源可信
log_info "配置 Tailscale 源..."
local repo_url key_url
repo_url=$(read_tailscale_url "repo_tailscale_url" "$TAILSCALE_DEFAULT_REPO_URL") || exit "${ERROR_GENERAL}"
key_url=$(read_tailscale_url "repo_tailscale_key_url" "${TAILSCALE_DEFAULT_REPO_URL}/${CODENAME}.noarmor.gpg") \
  || exit "${ERROR_GENERAL}"
# GPG 密钥：下载到临时文件 → 校验固定指纹 → 比较后原子写入（幂等）
if ! install_tailscale_keyring "$key_url"; then
  exit "${ERROR_DEPENDENCY}"
fi

# APT 源：本地生成 DEB822（与官方 ${CODENAME}.tailscale-keyring.list 等价），
# 不把远程下载的内容原样写入 sources.list.d；旧 tailscale.list（DebNAS 旧版/官方脚本写入）备份停用，避免重复源
if [[ -f "${TAILSCALE_SOURCES_DIR}/tailscale.list" ]]; then
  # 集中备份到 /var/backups/debnas 后移除；备份失败则改名为 APT 会忽略的 .bak
  if debnas_backup_file "${TAILSCALE_SOURCES_DIR}/tailscale.list"; then
    rm -f -- "${TAILSCALE_SOURCES_DIR}/tailscale.list"
    log_info "旧 Tailscale 源已移除（原件在 ${DEBNAS_BACKUP_ROOT}/）"
  else
    mv -f -- "${TAILSCALE_SOURCES_DIR}/tailscale.list" "${TAILSCALE_SOURCES_DIR}/tailscale.list.$(date +%Y%m%d%H%M%S).bak"
    log_info "旧 Tailscale 源已改名备份：tailscale.list.*.bak"
  fi
fi
local sources_content rc=0
sources_content="Types: deb
URIs: ${repo_url}
Suites: ${CODENAME}
Components: main
Signed-By: ${TAILSCALE_KEYRING_FILE}"
write_file_if_changed "${TAILSCALE_SOURCES_DIR}/tailscale.sources" "$sources_content" "644" || rc=$?
if [[ $rc -eq 2 ]]; then
  log_error "Tailscale 软件源写入失败。"
  exit "${ERROR_GENERAL}"
fi

# 安装 Tailscale
log_info "安装 Tailscale 组件..."
apt_install_packages tailscale

# 提示用户启动 Tailscale 并进行身份验证
log_info "请运行以下命令启动 Tailscale 并完成身份验证："
echo ""
log_info "  tailscale up"
echo ""



}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
