#!/usr/bin/env bash
# install.sh — DebNAS 自包含引导脚本
# 无需 git，仅需 wget、gpgv、sha256sum（Debian 最小化安装自带；gpgv 是 apt 的依赖）
#
# 用法:
#   # 国内用户（<tag> 为发布版本号，建议使用 tag 下的 install.sh 而非 main 分支）
#   wget https://gitee.com/kekylin/debnas/raw/<tag>/install.sh && bash install.sh --region cn
#
#   # 国际用户
#   wget https://github.com/kekylin/debnas/raw/<tag>/install.sh && bash install.sh --region global
#
#   # 卸载
#   bash install.sh --uninstall
#
# 完整性校验（默认）:
#   下载发布产物 debnas-<tag>.tar.gz + SHA256SUMS + SHA256SUMS.asc，
#   先用 gpgv + 本文件内嵌的发布公钥验签 SHA256SUMS（并核对签名者主密钥指纹），
#   再 sha256sum -c 校验 tar 包；任一步失败即中止并删除下载物。
#   信任边界：本脚本自身经 HTTPS 从代码托管平台获取，其内嵌公钥/指纹的可信度
#   等同于获取本脚本的渠道；签名只保护之后下载的代码包。

set -euo pipefail
IFS=$'\n\t'

# ==================== 常量 ====================

readonly DEBNAS_INSTALL_DIR="/opt/debnas"
readonly DEBNAS_BIN="/usr/local/bin/debnas"
readonly DEBNAS_CONF_DIR="/etc/debnas"
readonly DEBNAS_LOG_DIR="/var/log/debnas"
readonly DEBNAS_STATE_DIR="/var/lib/debnas/state"

# ⚠️ 以下 URL 与 lib/system/installer.sh 中的定义必须保持同步
# 发布产物（GitHub Release / Gitee Release 附件）：<base>/<tag>/<file>
# Gitee 的 Release 附件下载路径为推测格式，首次发布时需核实，不一致须两处同步修改
readonly RELEASE_GLOBAL_BASE="https://github.com/kekylin/debnas/releases/download"
readonly RELEASE_CN_BASE="https://gitee.com/kekylin/debnas/releases/download"
# 分支归档（仅 --unsigned 模式使用，内容不做任何校验）
readonly BRANCH_GLOBAL_BASE="https://github.com/kekylin/debnas/archive/refs/heads"
readonly BRANCH_CN_BASE="https://gitee.com/kekylin/debnas/repository/archive"

# 默认安装的稳定版本（由 tools/release.sh 更新，勿手改；为空表示尚未发布签名版本）
readonly DEBNAS_RELEASE_TAG=""

# >>> DEBNAS-RELEASE-PUBKEY-BEGIN（由 tools/release.sh --embed-key 生成，勿手改）
# 发布公钥主密钥指纹（大写十六进制无空格）与 ASCII armor 公钥（与 keys/debnas-release.asc 一致）
# 两者为空 = 维护者尚未配置发布公钥，签名安装不可用
readonly DEBNAS_RELEASE_KEY_FPR=""
readonly DEBNAS_RELEASE_PUBKEY=''
# <<< DEBNAS-RELEASE-PUBKEY-END

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
INSTALL_TAG=""
INSTALL_BRANCH=""
UNSIGNED_MODE=0

# 发布 tag 名校验：只允许字母数字开头，后接字母数字 . _ -（不含 / 与空白，防 URL/路径注入）
is_valid_tag() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# 分支名校验：在 tag 规则基础上允许 /，但禁止 .. 与首尾 /
is_valid_branch() {
  local b="${1:-}"
  [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || return 1
  [[ "$b" != *..* && "$b" != */ && "$b" != *//* ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        shift
        if [[ $# -eq 0 ]] || ! is_valid_tag "$1"; then
          _fail "--tag 需要一个合法的发布版本号（如 v3.1.0）"
          exit 1
        fi
        INSTALL_TAG="$1"
        ;;
      --branch)
        shift
        if [[ $# -eq 0 ]] || ! is_valid_branch "$1"; then
          _fail "--branch 需要一个合法的分支名（如 dev）"
          exit 1
        fi
        INSTALL_BRANCH="$1"
        ;;
      --unsigned)
        UNSIGNED_MODE=1
        ;;
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

  if [[ -n "$INSTALL_BRANCH" && "$UNSIGNED_MODE" -ne 1 ]]; then
    _fail "按分支安装不做任何完整性校验，必须显式加 --unsigned（例：--unsigned --branch ${INSTALL_BRANCH}）"
    exit 1
  fi
  if [[ "$UNSIGNED_MODE" -eq 1 && -n "$INSTALL_TAG" ]]; then
    _fail "--tag 与 --unsigned 不能同时使用（指定 tag 时总是校验签名）"
    exit 1
  fi
  if [[ "$UNSIGNED_MODE" -eq 1 && -z "$INSTALL_BRANCH" ]]; then
    INSTALL_BRANCH="main"
  fi
}

print_usage() {
  echo "用法: bash install.sh [--region cn|global] [--tag <版本>] [--yes]"
  echo "      bash install.sh --unsigned [--branch <分支>] [--region cn|global]"
  echo "      bash install.sh --uninstall"
}

print_help() {
  cat <<'EOF'
DebNAS — Debian NAS 自动化部署工具

安装:
  bash install.sh                   # 默认国际源（GitHub/Gitee 自动降级）
  bash install.sh --region cn       # 国内用户优先 Gitee
  bash install.sh --yes             # 自动确认所有提示
  bash install.sh --tag v3.1.0      # 安装指定发布版本（同样校验签名）

调试（不校验，仅限开发者）:
  bash install.sh --unsigned --branch dev   # 按分支安装，需交互输入 yes 确认

卸载:
  bash install.sh --uninstall       # 移除 DebNAS 脚本和配置

说明:
  · --region 可选，默认 global（国际源），cn 使用国内镜像
  · Gitee 和 GitHub 互为备用，任一地址失效自动切换
  · 默认安装本脚本内置的稳定版本，并用内嵌发布公钥验证 GPG 签名与 SHA256
  · --unsigned 不做任何完整性校验，非交互环境下拒绝执行（--yes 不能跳过该确认）
  · 安装到 /opt/debnas/，全局命令 /usr/local/bin/debnas
  · 安装完成后自动启动交互菜单
EOF
}

# ==================== 卸载流程 ====================

do_uninstall() {
  _warn "此操作将移除 DebNAS 所有脚本文件、配置和日志。"
  _warn "不会恢复已安装的软件包或已修改的系统配置。"

  if [[ "$FORCE_YES" -ne 1 ]]; then
    local confirm=""
    # EOF（如管道/无终端）时 read 返回非 0，set -e 下会静默退出，按"取消"处理
    read -rp "确认继续？[y/N]: " confirm || confirm=""
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

  # 登录通知：移除 PAM 中指向 DebNAS 脚本的 pam_exec 行（新旧两种路径），再删辅助脚本
  # （install.sh 不加载 lib，路径与 lib/system/layout.sh 保持一致）
  local pam_session="/etc/pam.d/common-session"
  if [[ -f "$pam_session" ]] && grep -Eq 'pam_exec\.so.*(/usr/local/libexec/debnas|/etc/pam\.d)/login-notify\.sh' "$pam_session"; then
    sed -i -E '\#pam_exec\.so.*(/usr/local/libexec/debnas|/etc/pam\.d)/login-notify\.sh#d' "$pam_session"
    _info "PAM: 已移除登录通知行"
  fi
  rm -f /etc/pam.d/login-notify.sh
  if [[ -d /usr/local/libexec/debnas ]]; then
    rm -rf /usr/local/libexec/debnas
    _info "辅助脚本: /usr/local/libexec/debnas"
  fi
  # 通知邮箱兼容链接（指向即将删除的 /etc/debnas/notify_email）
  [[ -L /etc/exim4/notify_email ]] && rm -f /etc/exim4/notify_email
  # 文件清单随状态目录删除，先留一份到备份目录；备份目录默认保留
  if [[ -f /var/lib/debnas/manifest && -d /var/backups/debnas ]]; then
    cp -p /var/lib/debnas/manifest /var/backups/debnas/manifest.uninstalled 2>/dev/null || true
    _info "系统文件原件保留在 /var/backups/debnas/（确认不需要后可手动删除）"
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

# ==================== 完整性校验 ====================
# ⚠️ dearmor_pubkey / verify_release 与 lib/system/installer.sh 中的
#    installer_dearmor_key / installer_verify_release 逻辑必须保持同步

# 把 ASCII armor 公钥转换为 gpgv 可用的二进制 keyring
# 纯 awk + coreutils base64 实现，不依赖 gpg 完整包（gpgv 不接受 armor 格式的 keyring）
# 参数：$1 - armor 文本  $2 - 输出 keyring 文件
# 返回：0 成功；1 文本中没有恰好一个公钥块或解码失败
dearmor_pubkey() {
  local armor="$1" out="$2" body
  # mawk 不支持 {n} 区间，CRC24 行（= 加 4 个 base64 字符）逐字符匹配
  body=$(printf '%s\n' "$armor" | awk '
    /^-----BEGIN PGP PUBLIC KEY BLOCK-----/ { inblk = 1; n++; next }
    /^-----END PGP PUBLIC KEY BLOCK-----/   { inblk = 0; next }
    !inblk { next }
    { gsub(/[ \t\r]/, "") }
    /^=[A-Za-z0-9+\/][A-Za-z0-9+\/][A-Za-z0-9+\/][A-Za-z0-9+\/]$/ { next }
    /:/ { next }
    NF { print }
    END { if (n != 1) exit 1 }') || return 1
  [[ -n "$body" ]] || return 1
  printf '%s\n' "$body" | base64 -d > "$out" 2>/dev/null || return 1
  [[ -s "$out" ]]
}

# 验证发布产物：先 gpgv 验签 SHA256SUMS 并核对签名者指纹，再 sha256sum -c 校验 tar 包
# 参数：$1 - 产物目录（含 <tar 包>、SHA256SUMS、SHA256SUMS.asc）
#       $2 - tar 包文件名（debnas-<tag>.tar.gz）
#       $3 - 二进制 keyring 文件
#       $4 - 期望的签名者主密钥指纹（40/64 位十六进制，大小写/空格不敏感）
# 返回：0 通过；1 失败（失败时删除三个下载物）
verify_release() {
  local dir="${1:-}" name="${2:-}"
  if _verify_release_steps "$@"; then
    return 0
  fi
  if [[ -n "$dir" && -n "$name" ]]; then
    rm -f -- "${dir:?}/${name:?}" "${dir:?}/SHA256SUMS" "${dir:?}/SHA256SUMS.asc"
  fi
  return 1
}

_verify_release_steps() {
  local dir="${1:-}" name="${2:-}" keyring="${3:-}" expected="${4:-}"

  expected="${expected//[[:space:]]/}"
  expected="${expected^^}"
  if [[ ! "$expected" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]]; then
    _fail "发布公钥指纹无效或未配置"
    return 1
  fi
  if [[ ! "$name" =~ ^debnas-[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz$ ]]; then
    _fail "非法的产物文件名: ${name}"
    return 1
  fi
  local f
  for f in "$name" SHA256SUMS SHA256SUMS.asc; do
    if [[ -z "$dir" || ! -s "${dir}/${f}" ]]; then
      _fail "缺少发布产物: ${f}"
      return 1
    fi
  done
  if [[ ! -s "$keyring" ]]; then
    _fail "发布公钥 keyring 不存在: ${keyring}"
    return 1
  fi
  for f in gpgv sha256sum; do
    if ! command -v "$f" >/dev/null 2>&1; then
      _fail "缺少命令 ${f}（apt install gpgv coreutils）"
      return 1
    fi
  done
  # gpgv 只把含 / 的 --keyring 参数当作路径
  [[ "$keyring" == /* ]] || keyring="${PWD}/${keyring}"

  # 第 1 步：验签 SHA256SUMS（临时 homedir，不读写任何用户 keyring）
  local work rc=0
  work=$(mktemp -d "${dir}/.verify.XXXXXX") || return 1
  gpgv --homedir "$work" --keyring "$keyring" --status-fd 3 \
    "${dir}/SHA256SUMS.asc" "${dir}/SHA256SUMS" \
    3>"${work}/status" 2>"${work}/stderr" || rc=$?

  local bad signer
  bad=$(awk '$1 == "[GNUPG:]" && $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY)$/ { print $2; exit }' "${work}/status")
  # VALIDSIG <签名密钥指纹> ... <主密钥指纹>：任一与期望指纹相同即视为匹配
  signer=$(awk -v want="$expected" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      a = toupper($3); b = toupper($NF)
      if (a == want || b == want) { print want; found = 1; exit }
      last = b
    } END { if (!found && last != "") print "MISMATCH:" last }' "${work}/status")
  if [[ "$rc" -ne 0 || -n "$bad" || -z "$signer" ]]; then
    _fail "SHA256SUMS 签名验证失败（gpgv 退出码 ${rc}${bad:+，${bad}}）"
    sed 's/^/    gpgv: /' "${work}/stderr" >&2 || true
    rm -rf -- "${work:?}"
    return 1
  fi
  if [[ "$signer" == MISMATCH:* ]]; then
    _fail "签名者指纹不匹配：期望 ${expected}，实际 ${signer#MISMATCH:}"
    rm -rf -- "${work:?}"
    return 1
  fi

  # 第 2 步：只取 tar 包对应的那一行做 sha256sum -c（防止清单里其他条目干扰/路径穿越）
  local entries hash
  entries=$(awk -v n="$name" 'NF == 2 && ($2 == n || $2 == "*" n) { print $1 }' "${dir}/SHA256SUMS")
  if [[ ! "$entries" =~ ^[0-9a-f]{64}$ ]]; then
    _fail "SHA256SUMS 中没有（或有多条）${name} 的校验和"
    rm -rf -- "${work:?}"
    return 1
  fi
  hash="$entries"
  printf '%s  %s\n' "$hash" "$name" > "${work}/check"
  if ! (cd "$dir" && sha256sum --check --strict --status "${work}/check"); then
    _fail "SHA256 校验失败：${name} 与已签名的校验和不一致，文件可能被篡改"
    rm -rf -- "${work:?}"
    return 1
  fi
  rm -rf -- "${work:?}"
  return 0
}

# ==================== 安装流程 ====================

# 检查 root 权限
check_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    _fail "此脚本需要 root 权限运行。请使用 sudo 或以 root 身份执行。"
    exit 1
  fi
}

# 安装前检查下载来源：签名模式检查公钥/版本/命令；--unsigned 模式要求交互确认
preflight_source() {
  if [[ "$UNSIGNED_MODE" -eq 1 ]]; then
    confirm_unsigned
    return 0
  fi
  if [[ -z "$DEBNAS_RELEASE_KEY_FPR" || -z "$DEBNAS_RELEASE_PUBKEY" ]]; then
    _fail "维护者尚未配置发布公钥，无法进行签名校验安装。"
    _fail "如确需安装未经校验的代码（风险自负）：bash install.sh --unsigned [--branch main]"
    exit 1
  fi
  if [[ -z "${INSTALL_TAG:-$DEBNAS_RELEASE_TAG}" ]]; then
    _fail "本脚本未内置默认发布版本（维护者尚未发布签名版本），请用 --tag <版本> 指定"
    exit 1
  fi
  local c
  for c in gpgv sha256sum base64; do
    if ! command -v "$c" >/dev/null 2>&1; then
      _fail "缺少命令 ${c}，请先执行：apt install gpgv coreutils"
      exit 1
    fi
  done
}

# --unsigned：醒目警告 + 交互确认；非交互（stdin 非终端）直接拒绝，--yes 不能跳过
confirm_unsigned() {
  _warn "================================================================"
  _warn "  !!! 不校验模式：将直接下载分支 '${INSTALL_BRANCH}' 的源码归档 !!!"
  _warn "  不做 GPG 签名与 SHA256 校验，无法发现传输或托管平台上的篡改；"
  _warn "  该代码将以 root 身份执行。仅供开发调试，请勿用于生产环境。"
  _warn "================================================================"
  if [[ ! -t 0 ]]; then
    _fail "非交互环境下拒绝 --unsigned 安装"
    exit 1
  fi
  local answer=""
  read -rp "确认安装未经校验的代码？请输入 yes 继续: " answer || answer=""
  if [[ "$answer" != "yes" ]]; then
    _info "已取消"
    exit 1
  fi
}

# 依次尝试主源/备用源下载同一 tag 的三个发布产物
# 参数：$1 - tag  $2 - 输出目录
download_release() {
  local tag="$1" outdir="$2"
  local name="debnas-${tag}.tar.gz"
  local -a bases=()
  if [[ "$REGION" == "cn" ]]; then
    bases=("$RELEASE_CN_BASE" "$RELEASE_GLOBAL_BASE")
  else
    bases=("$RELEASE_GLOBAL_BASE" "$RELEASE_CN_BASE")
  fi
  local base f ok
  for base in "${bases[@]}"; do
    ok=1
    for f in "$name" SHA256SUMS SHA256SUMS.asc; do
      # --timeout/--tries：网络不可达时避免无限挂起（项目红线）
      if ! wget -q --timeout=30 --tries=3 -O "${outdir}/${f}" "${base}/${tag}/${f}" 2>/dev/null; then
        ok=0
        break
      fi
    done
    if [[ "$ok" -eq 1 ]]; then
      return 0
    fi
    rm -f -- "${outdir:?}/${name:?}" "${outdir:?}/SHA256SUMS" "${outdir:?}/SHA256SUMS.asc"
    _warn "源 ${base%%/releases/*} 下载失败，切换备用源"
  done
  return 1
}

# 下载代码包到临时目录并完成校验，输出临时目录路径（tar 包为 <tmpdir>/debnas.tar.gz）
download_repo() {
  local tmpdir
  tmpdir=$(mktemp -d "${DEBNAS_TMP_DIR:-/tmp}/install.XXXXXX")
  chmod 700 "$tmpdir"

  local tarball="${tmpdir}/debnas.tar.gz"

  if [[ "$UNSIGNED_MODE" -eq 1 ]]; then
    local primary_url fallback_url
    if [[ "$REGION" == "cn" ]]; then
      primary_url="${BRANCH_CN_BASE}/${INSTALL_BRANCH}.tar.gz"
      fallback_url="${BRANCH_GLOBAL_BASE}/${INSTALL_BRANCH}.tar.gz"
    else
      primary_url="${BRANCH_GLOBAL_BASE}/${INSTALL_BRANCH}.tar.gz"
      fallback_url="${BRANCH_CN_BASE}/${INSTALL_BRANCH}.tar.gz"
    fi
    _action "下载分支 ${INSTALL_BRANCH}（未校验）"
    if ! wget -q --timeout=30 --tries=3 -O "$tarball" "$primary_url" 2>/dev/null; then
      _warn "切换备用源"
      if ! wget -q --timeout=30 --tries=3 -O "$tarball" "$fallback_url" 2>/dev/null; then
        _fail "所有下载源均失败"
        rm -rf -- "${tmpdir:?}"
        exit 1
      fi
    fi
    _warn "已跳过完整性校验（--unsigned）"
    echo "$tmpdir"
    return 0
  fi

  local tag="${INSTALL_TAG:-$DEBNAS_RELEASE_TAG}"
  _action "下载 ${tag}"
  if ! download_release "$tag" "$tmpdir"; then
    _fail "所有下载源均失败（版本 ${tag} 的发布产物不存在或网络不可达）"
    rm -rf -- "${tmpdir:?}"
    exit 1
  fi

  _action "校验"
  local keyring="${tmpdir}/release-keyring.gpg"
  if ! dearmor_pubkey "$DEBNAS_RELEASE_PUBKEY" "$keyring"; then
    _fail "内嵌发布公钥格式无效"
    rm -rf -- "${tmpdir:?}"
    exit 1
  fi
  if ! verify_release "$tmpdir" "debnas-${tag}.tar.gz" "$keyring" "$DEBNAS_RELEASE_KEY_FPR"; then
    _fail "完整性校验未通过，已删除下载文件，安装中止"
    rm -rf -- "${tmpdir:?}"
    exit 1
  fi
  mv -f -- "${tmpdir}/debnas-${tag}.tar.gz" "$tarball"
  _success "校验通过（签名者 ${DEBNAS_RELEASE_KEY_FPR}）"

  echo "$tmpdir"
}

# 记录已安装的版本来源，供 debnas update 判断版本/防降级
write_release_marker() {
  local marker="${DEBNAS_INSTALL_DIR}/RELEASE"
  if [[ "$UNSIGNED_MODE" -eq 1 ]]; then
    printf 'tag=\nbranch=%s\nverified=0\n' "$INSTALL_BRANCH" > "$marker"
  else
    printf 'tag=%s\nbranch=\nverified=1\n' "${INSTALL_TAG:-$DEBNAS_RELEASE_TAG}" > "$marker"
  fi
  chmod 644 "$marker"
}

# 解压到安装目录
extract_repo() {
  local tmpdir="$1"
  local tarball="${tmpdir}/debnas.tar.gz"
  local extract_dir="${tmpdir}/extract"

  mkdir -p "$extract_dir"
  _action "解压"
  # --no-same-owner：root 解压时不沿用归档内的 uid/gid，避免文件归属任意普通用户
  if ! tar -xzf "$tarball" -C "$extract_dir" --strip-components=1 --no-same-owner 2>/dev/null; then
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
  # compose/ 是 docker-apps、service-query 模块的数据目录，缺失会导致模块报错退出
  cp -rf "$extract_dir"/compose "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
  # keys/ 存放发布公钥，debnas update 用它验证后续更新包的签名
  cp -rf "$extract_dir"/keys "$DEBNAS_INSTALL_DIR/" 2>/dev/null || true
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
    local choice=""
    read -rp "请选择 [1/2]: " choice || choice=""
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
  if [[ "$UNSIGNED_MODE" -eq 1 ]]; then
    echo "  安装来源: 分支 ${INSTALL_BRANCH}（未校验）"
  else
    echo "  安装版本: ${INSTALL_TAG:-${DEBNAS_RELEASE_TAG:-（未内置）}}（签名校验）"
  fi
  echo "============================================"
  echo ""

  # 检查下载来源（签名模式：公钥/版本/命令就绪；--unsigned：交互确认）
  preflight_source

  # 检测已安装
  check_existing_install

  # 创建安全临时目录
  # 注意：不能声明为 local —— set -e 在函数内触发退出时局部变量已失效，
  # EXIT trap 读到空值，临时目录会残留
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
  write_release_marker

  # 安装全局命令
  install_debnas_bin

  # 创建运行时目录
  create_runtime_dirs

  # 写入配置
  write_config

  # 旧版文件布局迁移（notify_email、login-notify.sh、firewalld-ipthreat 等；幂等，失败只告警）
  # 直接重跑 install.sh 升级时不经过 debnas update，这里补跑一次
  bash -c 'source "$1/lib/bootstrap.sh" && migration_run_layout' _ "$DEBNAS_INSTALL_DIR" \
    || _warn "旧版文件布局迁移未完成，可稍后运行 debnas doctor 查看"

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

# 被 source 时（单元测试 / tools/release.sh 自检）只加载函数，不执行安装流程；
# 直接执行、bash <(wget …)、wget -O- | bash 均会进入 main
if ! (return 0 2>/dev/null); then
  main "$@"
fi
