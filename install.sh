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
#   # 旧版教程的写法仍可用（-s github@main → --region global，-s gitee@main → --region cn；分支部分忽略）
#   bash <(wget -qO- https://gitee.com/kekylin/debnas/raw/main/install.sh) -s gitee@main
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
readonly DEBNAS_LIB_DIR="/var/lib/debnas"
readonly DEBNAS_STATE_DIR="${DEBNAS_LIB_DIR}/state"

# ⚠️ 以下 URL 与 lib/system/installer.sh 中的定义必须保持同步
# 发布产物（GitHub Release / Gitee Release 附件）：<base>/<tag>/<file>
# Gitee 的 Release 附件下载路径为推测格式，首次发布时需核实，不一致须两处同步修改
readonly RELEASE_GLOBAL_BASE="https://github.com/kekylin/debnas/releases/download"
readonly RELEASE_CN_BASE="https://gitee.com/kekylin/debnas/releases/download"
# 分支归档（仅 --unsigned 模式使用，内容不做任何校验）
readonly BRANCH_GLOBAL_BASE="https://github.com/kekylin/debnas/archive/refs/heads"
readonly BRANCH_CN_BASE="https://gitee.com/kekylin/debnas/repository/archive"

# 默认安装的稳定版本（由 tools/release.sh 更新，勿手改；为空表示尚未发布签名版本）
readonly DEBNAS_RELEASE_TAG="v2026.11.1"

# >>> DEBNAS-RELEASE-PUBKEY-BEGIN（由 tools/release.sh --embed-key 生成，勿手改）
# 发布公钥主密钥指纹（大写十六进制无空格）与 ASCII armor 公钥（与 keys/debnas-release.asc 一致）
# 两者为空 = 维护者尚未配置发布公钥，签名安装不可用
readonly DEBNAS_RELEASE_KEY_FPR="39F90606DED9060CBA5D45A46774EEFB31905EE6"
readonly DEBNAS_RELEASE_PUBKEY='-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEavHOOhYJKwYBBAHaRw8BAQdAqV031sJ0K6M3aZjzJJ8x5L2AxSzNgJAWqTz8
jyouhn+0IERlYk5BUyBSZWxlYXNlIDxjY2t5dW5Ac2luYS5jb20+iJYEExYKAD4W
IQQ5+QYG3tkGDLpdRaRndO77MZBe5gUCavHOOgIbAQUJCWYBgAULCQgHAgYVCgkI
CwIEFgIDAQIeAQIXgAAKCRBndO77MZBe5sYMAP9RpyqVxMGQfwTgaeSpNn3/PBlC
rFNufdxCEjDog2Ju7AD/c1EhyxKUY04jgCVhhTOL3z6K/s4++TP1G5EMb0hD6Aq4
MwRq8c48FgkrBgEEAdpHDwEBB0BaGuJbvSIn4mftvaawCZBY4FZg8+XgNuZ0zjEt
771Luoj1BBgWCgAmFiEEOfkGBt7ZBgy6XUWkZ3Tu+zGQXuYFAmrxzjwCGwIFCQPC
ZwAAgQkQZ3Tu+zGQXuZ2IAQZFgoAHRYhBCy+MgrYgCYUXEyioe7KH1SfRIguBQJq
8c48AAoJEO7KH1SfRIguiO4BAP5j0pwm55cf3gnVy6KeVeAqS+//A9uOkasTSt5u
0eMAAQDCJM5vMYGFUe4bGxvW0jozuCzjdiimnO0bMbRXI0PrCio2AQCs66oaIHBV
sqV60XQcQd1GS5s13ydxgztjUAANkXchywD9Eq4SJnHKKhp6FWK2TotnQ5BO+MZi
tUM59dPb7fx//Qw=
=IyeC
-----END PGP PUBLIC KEY BLOCK-----'
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

# 发布 tag / 分支名校验（实现见下方 DEBNAS-RELEASE-VERIFY 区块）
is_valid_tag() {
  release_valid_tag "$@"
}

is_valid_branch() {
  release_valid_branch "$@"
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
      -s)
        # 旧版安装命令：bash <(wget -qO- …/install.sh) -s github@main / -s gitee@main
        # 只取平台决定下载源；分支部分忽略（默认安装已签名的发布版本）
        shift
        if [[ $# -eq 0 || ! "$1" =~ ^(github|gitee)@[A-Za-z0-9._/-]+$ ]]; then
          _fail "-s 参数无效: '${1:-}'（旧版格式为 -s github@main 或 -s gitee@main）"
          _fail "新写法: bash install.sh --region global（GitHub 优先）或 --region cn（Gitee 优先）"
          print_usage
          exit 1
        fi
        case "${1%%@*}" in
          gitee) REGION="cn" ;;
          *)     REGION="global" ;;
        esac
        _warn "-s 为旧版参数，已按 --region ${REGION} 处理；新写法见 --help"
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

兼容旧版命令:
  bash install.sh -s github@main    # 等同 --region global（分支部分忽略，安装已签名的发布版本）
  bash install.sh -s gitee@main     # 等同 --region cn

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
    require_tty_or_yes "卸载"
    local confirm=""
    # EOF 时 read 返回非 0，set -e 下会静默退出，按"取消"处理
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
  if [[ "$current_crontab" == *DEBNAS-CRON* ]]; then
    # 只删除 DebNAS 条目：过滤后为空才 crontab -r；crontab - 写入失败不得回退为
    # crontab -r（会删除用户全部定时任务），只告警并保留原内容
    local filtered="" grep_rc=0
    filtered=$(printf '%s\n' "$current_crontab" | grep -v "DEBNAS-CRON") || grep_rc=$?
    if [[ "$grep_rc" -eq 0 ]]; then
      if [[ -z "$filtered" ]]; then
        crontab -r 2>/dev/null || true
      elif ! printf '%s\n' "$filtered" | crontab - 2>/dev/null; then
        _warn "清理 DebNAS 定时任务失败，请手动检查 root crontab"
      fi
      _info "定时任务已清理"
    elif [[ "$grep_rc" -eq 1 ]]; then
      # 全部条目都是 DebNAS 管理：直接移除整份 crontab
      crontab -r 2>/dev/null || true
      _info "定时任务已清理"
    else
      _warn "读取/过滤 crontab 失败，未修改定时任务"
    fi
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

  # 移除状态目录（整个 /var/lib/debnas：状态、文件清单等，与 debnas uninstall 一致）
  if [[ -d "$DEBNAS_LIB_DIR" ]]; then
    rm -rf "$DEBNAS_LIB_DIR"
    _info "状态: ${DEBNAS_LIB_DIR}"
  fi

  # 移除临时文件（root 用 /run/debnas，旧版本用 /tmp/debnas；卸载模式下 DEBNAS_TMP_DIR 未定义）
  local t
  for t in /run/debnas /tmp/debnas; do
    if [[ -d "$t" && ! -L "$t" ]]; then
      rm -rf "$t"
      _info "临时: ${t}"
    fi
  done
  # 被中断的部署残留
  rm -rf "${DEBNAS_INSTALL_DIR%/*}/.${DEBNAS_INSTALL_DIR##*/}.old" "${DEBNAS_INSTALL_DIR%/*}/.${DEBNAS_INSTALL_DIR##*/}.new"

  _success "卸载完成"
  _info "已安装的软件包和系统配置未被修改。如需恢复系统，请手动操作。"
}

# ==================== 完整性校验 ====================
# 下方区块是 lib/system/installer.sh 中同名区块的副本（单一来源在 lib），
# 由 tools/release.sh --embed-key / --bump / --sync-verify 自动同步，勿在此手改；
# tests/unit/lib/test-release-sync.bats 断言两份逐字一致。本脚本仍须单文件可运行。

# >>> DEBNAS-RELEASE-VERIFY-BEGIN（单一来源：lib/system/installer.sh；install.sh 中的同名区块由 tools/release.sh 同步生成，勿手改）
# 发布产物校验：debnas update（lib）与自包含引导脚本 install.sh 共用这一份代码。
# 只依赖 bash、awk、coreutils（base64/sha256sum）与 gpgv；错误经 _release_fail 输出。
# 换钥过渡期：keyring 可含新旧多把公钥，期望指纹为逗号分隔列表，任一把签的产物都能通过。

# 输出校验错误：已加载 lib 日志时用 log_error；install.sh 不加载 lib，按其 [FAIL] 格式写 stderr
_release_fail() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$1"
  else
    printf '[FAIL] %s\n' "$1" >&2
  fi
}

# 发布 tag 名校验：只允许字母数字开头，后接字母数字 . _ -（不含 / 与空白，防 URL/路径注入）
release_valid_tag() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# 分支名校验：在 tag 规则基础上允许 /，但禁止 .. 与首尾 /
release_valid_branch() {
  local b="${1:-}"
  [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || return 1
  [[ "$b" != *..* && "$b" != */ && "$b" != *//* ]]
}

# 删除某个 tag 的三个下载物
# 参数：$1 - 目录  $2 - tar 包文件名
release_discard() {
  local dir="${1:-}" name="${2:-}"
  if [[ -n "$dir" && -n "$name" ]]; then
    rm -f -- "${dir:?}/${name:?}" "${dir:?}/SHA256SUMS" "${dir:?}/SHA256SUMS.asc"
  fi
}

# 把 ASCII armor 公钥（stdin）转换为 gpgv 可用的二进制 keyring
# 纯 awk + coreutils base64 实现，不依赖 gpg 完整包（gpgv 不接受 armor 格式的 keyring）
# 文本中可以有多个公钥块（换钥过渡期新旧两把并存），逐块解码后依次拼接
# 参数：$1 - 输出 keyring 文件；stdin - armor 文本
# 返回：0 成功；1 文本中没有公钥块、块不完整或解码失败
release_dearmor() {
  local out="$1" body line blk=""
  # mawk 不支持 {n} 区间，CRC24 行（= 加 4 个 base64 字符）逐字符匹配；每块结束输出一行 "-" 作分隔
  body=$(awk '
    /^-----BEGIN PGP PUBLIC KEY BLOCK-----/ { if (inblk) bad = 1; inblk = 1; n++; next }
    /^-----END PGP PUBLIC KEY BLOCK-----/   { if (!inblk) bad = 1; inblk = 0; print "-"; next }
    !inblk { next }
    { gsub(/[ \t\r]/, "") }
    /^=[A-Za-z0-9+\/][A-Za-z0-9+\/][A-Za-z0-9+\/][A-Za-z0-9+\/]$/ { next }
    /:/ { next }
    NF { print }
    END { if (n < 1 || inblk || bad) exit 1 }') || return 1
  [[ -n "$body" ]] || return 1
  : > "$out" || return 1
  while IFS= read -r line; do
    if [[ "$line" != "-" ]]; then
      blk+="${line}"$'\n'
      continue
    fi
    [[ -n "$blk" ]] || return 1
    printf '%s' "$blk" | base64 -d >> "$out" 2>/dev/null || return 1
    blk=""
  done <<<"$body"
  [[ -s "$out" ]]
}

# 规范化期望的签名者指纹（去空白、转大写）并校验格式，结果写入全局 _RELEASE_FPRS
# 参数：$1 - 指纹（40/64 位十六进制；多个用逗号分隔）
_release_norm_fprs() {
  _RELEASE_FPRS="${1:-}"
  _RELEASE_FPRS="${_RELEASE_FPRS//[[:space:]]/}"
  _RELEASE_FPRS="${_RELEASE_FPRS^^}"
  [[ "$_RELEASE_FPRS" =~ ^([0-9A-F]{40}|[0-9A-F]{64})(,([0-9A-F]{40}|[0-9A-F]{64}))*$ ]]
}

# gpgv 验证分离签名并核对签名者指纹（SHA256SUMS 与版本指针 LATEST 共用）
# 参数：$1 - 签名文件（.asc）  $2 - 被签名的文件  $3 - 二进制 keyring（可含多把公钥）
#       $4 - 期望的签名者主密钥指纹（逗号分隔的多个指纹任一匹配即通过）
#       $5 - 错误信息里的文件显示名（默认取 $2 的文件名）
# 返回：0 签名有效且签名者在期望指纹之内；1 其余情况
release_check_sig() {
  local sig="${1:-}" data="${2:-}" keyring="${3:-}" label="${5:-}" expected dir="."
  [[ -n "$label" ]] || label="${data##*/}"
  if ! _release_norm_fprs "${4:-}"; then
    _release_fail "发布公钥指纹无效或未配置"
    return 1
  fi
  expected="$_RELEASE_FPRS"
  if [[ ! -s "$sig" || ! -s "$data" ]]; then
    _release_fail "缺少 ${label} 或其签名文件"
    return 1
  fi
  if [[ ! -s "$keyring" ]]; then
    _release_fail "发布公钥 keyring 不存在: ${keyring}"
    return 1
  fi
  if ! command -v gpgv >/dev/null 2>&1; then
    _release_fail "缺少命令 gpgv（apt install gpgv）"
    return 1
  fi
  # gpgv 只把含 / 的 --keyring 参数当作路径
  [[ "$keyring" == /* ]] || keyring="${PWD}/${keyring}"
  [[ "$data" == */* ]] && dir="${data%/*}"

  # 临时 homedir，不读写任何用户 keyring
  local work rc=0
  work=$(mktemp -d "${dir}/.verify.XXXXXX") || return 1
  gpgv --homedir "$work" --keyring "$keyring" --status-fd 3 "$sig" "$data" \
    3>"${work}/status" 2>"${work}/stderr" || rc=$?

  local bad signer
  bad=$(awk '$1 == "[GNUPG:]" && $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY)$/ { print $2; exit }' "${work}/status")
  # VALIDSIG <签名密钥指纹> ... <主密钥指纹>：任一与期望指纹（之一）相同即视为匹配
  signer=$(awk -v want="$expected" 'BEGIN { n = split(want, w, ","); for (i = 1; i <= n; i++) ok[w[i]] = 1 }
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      a = toupper($3); b = toupper($NF)
      if ((a in ok) || (b in ok)) { print (b in ok) ? b : a; found = 1; exit }
      last = b
    } END { if (!found && last != "") print "MISMATCH:" last }' "${work}/status")
  if [[ "$rc" -ne 0 || -n "$bad" || -z "$signer" ]]; then
    _release_fail "${label} 签名验证失败（gpgv 退出码 ${rc}${bad:+，${bad}}）"
    sed 's/^/    gpgv: /' "${work}/stderr" >&2 || true
    rm -rf -- "${work:?}"
    return 1
  fi
  rm -rf -- "${work:?}"
  if [[ "$signer" == MISMATCH:* ]]; then
    _release_fail "签名者指纹不匹配：期望 ${expected}，实际 ${signer#MISMATCH:}"
    return 1
  fi
  return 0
}

# 验证发布产物：先 gpgv 验签 SHA256SUMS 并核对签名者指纹，再 sha256sum -c 校验 tar 包
# 参数：$1 - 产物目录（含 <tar 包>、SHA256SUMS、SHA256SUMS.asc）
#       $2 - tar 包文件名（debnas-<tag>.tar.gz）
#       $3 - 二进制 keyring 文件
#       $4 - 期望的签名者主密钥指纹（40/64 位十六进制，大小写/空格不敏感；
#            密钥轮换期间可为逗号分隔的多个指纹，任一匹配即通过）
# 返回：0 通过；1 失败（失败时删除三个下载物）
release_verify() {
  if _release_verify_steps "$@"; then
    return 0
  fi
  release_discard "${1:-}" "${2:-}"
  return 1
}

_release_verify_steps() {
  local dir="${1:-}" name="${2:-}" keyring="${3:-}" expected="${4:-}"

  if ! _release_norm_fprs "$expected"; then
    _release_fail "发布公钥指纹无效或未配置"
    return 1
  fi
  if [[ ! "$name" =~ ^debnas-[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz$ ]]; then
    _release_fail "非法的产物文件名: ${name}"
    return 1
  fi
  local f
  for f in "$name" SHA256SUMS SHA256SUMS.asc; do
    if [[ -z "$dir" || ! -s "${dir}/${f}" ]]; then
      _release_fail "缺少发布产物: ${f}"
      return 1
    fi
  done
  if ! command -v sha256sum >/dev/null 2>&1; then
    _release_fail "缺少命令 sha256sum（apt install coreutils）"
    return 1
  fi

  # 第 1 步：验签 SHA256SUMS 并核对签名者指纹
  release_check_sig "${dir}/SHA256SUMS.asc" "${dir}/SHA256SUMS" "$keyring" "$expected" "SHA256SUMS" || return 1

  # 第 2 步：只取 tar 包对应的那一行做 sha256sum -c（防止清单里其他条目干扰/路径穿越）
  local hash work
  hash=$(awk -v n="$name" 'NF == 2 && ($2 == n || $2 == "*" n) { print $1 }' "${dir}/SHA256SUMS")
  if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    _release_fail "SHA256SUMS 中没有（或有多条）${name} 的校验和"
    return 1
  fi
  work=$(mktemp -d "${dir}/.verify.XXXXXX") || return 1
  printf '%s  %s\n' "$hash" "$name" > "${work}/check"
  if ! (cd "$dir" && sha256sum --check --strict --status "${work}/check"); then
    _release_fail "SHA256 校验失败：${name} 与已签名的校验和不一致，文件可能被篡改"
    rm -rf -- "${work:?}"
    return 1
  fi
  rm -rf -- "${work:?}"
  return 0
}
# <<< DEBNAS-RELEASE-VERIFY-END

# 下方区块同样是 lib/system/installer.sh 中同名区块的副本（安装目录整树替换 + 更新锁 + 全局命令包装脚本），勿在此手改。
# >>> DEBNAS-DEPLOY-BEGIN（单一来源：lib/system/installer.sh；install.sh 中的同名区块由 tools/release.sh 同步生成，勿手改）
# 安装目录整树替换：debnas update（lib）与自包含引导脚本 install.sh 共用这一份代码。
# 流程：在安装目录的同级暂存目录 .<名>.new 中组装完整新树（新代码 + 旧安装目录中的非代码条目，
#       如 RELEASE），全部成功后用两次 rename 切换：<安装目录> → .<名>.old，.<名>.new → <安装目录>。
#       - 组装中途失败/中断：旧安装原封不动，暂存目录在失败时或下次启动时清理；
#       - 两次 rename 在忽略 INT/TERM/HUP 的子 shell 中完成（父进程被中断时子 shell 仍会走完）；
#         被 SIGKILL/断电打断在两次 rename 之间时，下次启动由 deploy_recover 把 .<名>.old 改回；
#       - rename 不改写正在执行的 bin/debnas 的 inode（原地覆写会让运行中的 bash 读到错位内容）；
#       - 上游已删除的旧模块/文件随旧树一起移除。
#       并发保护：deploy_lock 对 DEBNAS_UPDATE_LOCK（默认 /run/debnas-update.lock）加 flock。
# 全局命令 /usr/local/bin/debnas 的包装脚本内容也在本区块（deploy_install_wrapper），安装与更新共用。

# 部署输出：已加载 lib 日志时用 log_*；install.sh 不加载 lib，按其 [FAIL]/[WARNING]/[INFO] 格式写 stderr
# 参数：$1 - error|warn|info  $2 - 消息
_deploy_msg() {
  if declare -F log_error >/dev/null 2>&1; then
    case "$1" in
      error) log_error "$2" ;;
      warn)  log_warning "$2" ;;
      *)     log_info "$2" ;;
    esac
  else
    case "$1" in
      error) printf '[FAIL] %s\n' "$2" >&2 ;;
      warn)  printf '[WARNING] %s\n' "$2" >&2 ;;
      *)     printf '[INFO] %s\n' "$2" >&2 ;;
    esac
  fi
}

# 加更新锁（非阻塞；同一进程重复调用直接返回）。锁随进程退出自动释放，也可 deploy_unlock 提前释放
# 说明：跨 install.sh / debnas update 的共享锁，本函数位于 DEBNAS-DEPLOY 同步区块，
#       修改需同步 install.sh（tools/release.sh --sync-verify）与 test-release-sync。
# 返回：0 已加锁（或系统无 flock 命令时告警后放行）；1 另一个安装/更新正在进行或锁文件无法打开
deploy_lock() {
  [[ -z "${_DEBNAS_DEPLOY_LOCK_FD:-}" ]] || return 0
  local lock="${DEBNAS_UPDATE_LOCK:-/run/debnas-update.lock}" fd
  if ! command -v flock >/dev/null 2>&1; then
    _deploy_msg warn "缺少 flock 命令（util-linux），跳过并发保护"
    return 0
  fi
  if ! exec {fd}>>"$lock"; then
    _deploy_msg error "无法打开更新锁文件：${lock}"
    return 1
  fi
  if ! flock -n "$fd"; then
    exec {fd}>&-
    _deploy_msg error "另一个 DebNAS 安装/更新正在进行（锁 ${lock}），请稍后再试"
    return 1
  fi
  _DEBNAS_DEPLOY_LOCK_FD="$fd"
  return 0
}

# 释放 deploy_lock 加的锁（关闭锁文件描述符）
deploy_unlock() {
  [[ -n "${_DEBNAS_DEPLOY_LOCK_FD:-}" ]] || return 0
  exec {_DEBNAS_DEPLOY_LOCK_FD}>&-
  _DEBNAS_DEPLOY_LOCK_FD=""
  return 0
}

# 处理被中断的部署残留（启动时调用；无残留时不加锁、不 fork）
# 参数：$1 - 安装目录
# 返回：0 无残留或已处理（无写权限、锁被占用时跳过）；1 回滚失败
# 规则：.<名>.old 存在而安装目录缺失 → 切换被打断，改回旧版本；安装目录已存在 → 切换已完成，删除旧树；
#       .<名>.new → 删除未完成的暂存树；旧版逐目录部署遗留的 <安装目录>/.<目录>.old 同理（缺失则改回）
deploy_recover() {
  local install_dir="${1%/}" parent name old new d any=0 rc=0 locked_here=0
  [[ -n "$install_dir" ]] || return 0
  parent="${install_dir%/*}"; [[ -n "$parent" ]] || parent="/"
  name="${install_dir##*/}"
  old="${parent}/.${name}.old"
  new="${parent}/.${name}.new"
  [[ -e "$old" || -L "$old" || -e "$new" || -L "$new" ]] && any=1
  for d in bin lib modules config compose keys; do
    [[ -e "${install_dir}/.${d}.old" || -e "${install_dir}/.${d}.new" ]] && any=1
  done
  (( any )) || return 0
  [[ -w "$parent" ]] || return 0
  if [[ -z "${_DEBNAS_DEPLOY_LOCK_FD:-}" ]]; then
    # 锁被占用说明另一进程正在部署，残留是它的工作目录，不能动
    deploy_lock 2>/dev/null || return 0
    locked_here=1
  fi

  if [[ -e "$old" || -L "$old" ]]; then
    if [[ ! -e "$install_dir" && ! -L "$install_dir" ]]; then
      if mv -T -- "$old" "$install_dir"; then
        _deploy_msg warn "检测到被中断的更新（切换未完成），已回滚到旧版本：${install_dir}"
      else
        _deploy_msg error "回滚失败：请手动执行 mv -T ${old} ${install_dir}"
        rc=1
      fi
    else
      rm -rf -- "${old:?}"
    fi
  fi
  if [[ -e "$new" || -L "$new" ]]; then
    rm -rf -- "${new:?}"
  fi
  for d in bin lib modules config compose keys; do
    if [[ -e "${install_dir}/.${d}.old" ]]; then
      if [[ ! -e "${install_dir}/${d}" ]]; then
        if mv -T -- "${install_dir}/.${d}.old" "${install_dir}/${d}"; then
          _deploy_msg warn "检测到旧版更新残留，已恢复 ${install_dir}/${d}；建议重新运行 install.sh 覆盖安装"
        else
          rc=1
        fi
      else
        rm -rf -- "${install_dir:?}/.${d}.old"
      fi
    fi
    [[ -e "${install_dir}/.${d}.new" ]] && rm -rf -- "${install_dir:?}/.${d}.new"
  done
  (( locked_here )) && deploy_unlock
  return "$rc"
}

# 整树替换安装目录
# 参数：$1 - 新版本源目录（解压后的仓库根，须含 bin/debnas、lib/、modules/）
#       $2 - 安装目录
# 返回：0 成功；1 失败（旧安装保持不变）
deploy_tree() {
  local src_dir="${1:-}" install_dir="${2:-}"
  local parent name old new d e base rc=0

  if [[ -z "$src_dir" || -z "$install_dir" ]]; then
    _deploy_msg error "deploy_tree: 缺少源目录或安装目录参数"
    return 1
  fi
  install_dir="${install_dir%/}"
  # 校验更新包完整性（在动现有安装之前）
  if [[ ! -f "${src_dir}/bin/debnas" ]]; then
    _deploy_msg error "更新包不完整，关键文件缺失：bin/debnas"
    return 1
  fi
  for d in lib modules; do
    if [[ ! -d "${src_dir}/${d}" ]]; then
      _deploy_msg error "更新包不完整，缺少目录：${d}"
      return 1
    fi
  done

  parent="${install_dir%/*}"; [[ -n "$parent" ]] || parent="/"
  name="${install_dir##*/}"
  old="${parent}/.${name}.old"
  new="${parent}/.${name}.new"
  mkdir -p -- "$parent" || { _deploy_msg error "无法创建目录：${parent}"; return 1; }
  deploy_lock || return 1
  deploy_recover "$install_dir" || return 1
  if [[ -e "$old" || -L "$old" || -e "$new" || -L "$new" ]]; then
    _deploy_msg error "存在无法清理的部署残留：${old} / ${new}"
    return 1
  fi

  # 第一阶段：组装完整新树（失败即删除暂存树，旧安装不动）
  if ! mkdir -m 755 -- "$new"; then
    _deploy_msg error "无法创建暂存目录：${new}"
    return 1
  fi
  for d in bin lib modules config compose keys; do
    [[ -d "${src_dir}/${d}" ]] || continue
    cp -R -- "${src_dir}/${d}" "${new}/${d}" || { rc=1; break; }
  done
  if (( rc == 0 )); then
    for e in install.sh README.md LICENSE; do
      [[ -f "${src_dir}/${e}" ]] || continue
      cp -- "${src_dir}/${e}" "${new}/${e}" || { rc=1; break; }
    done
  fi
  # 旧安装目录中新版本没有提供的条目原样带过去（RELEASE 标记、更新包未包含的目录等）
  if (( rc == 0 )) && [[ -d "$install_dir" ]]; then
    for e in "${install_dir}"/* "${install_dir}"/.[!.]* "${install_dir}"/..?*; do
      [[ -e "$e" || -L "$e" ]] || continue
      base="${e##*/}"
      [[ -e "${new}/${base}" || -L "${new}/${base}" ]] && continue
      case "$base" in .bin.old|.lib.old|.modules.old|.config.old|.compose.old|.keys.old|.*.new) continue ;; esac
      cp -a -- "$e" "${new}/${base}" || { rc=1; break; }
    done
  fi
  if (( rc == 0 )); then
    chmod +x "${new}/bin/"* 2>/dev/null || true
    [[ -f "${new}/bin/debnas" ]] || rc=1
  fi
  if (( rc != 0 )); then
    rm -rf -- "${new:?}"
    _deploy_msg error "组装新版本失败（磁盘空间不足或权限问题？），现有安装未改动"
    return 1
  fi

  # 第二阶段：切换（忽略中断信号；mv -T 防止目标意外存在时把目录移进去）
  (
    trap '' INT TERM HUP
    if [[ -e "$install_dir" || -L "$install_dir" ]]; then
      mv -T -- "$install_dir" "$old" || exit 1
    fi
    if ! mv -T -- "$new" "$install_dir"; then
      if [[ -e "$old" || -L "$old" ]]; then
        mv -T -- "$old" "$install_dir" || exit 3
      fi
      exit 2
    fi
    exit 0
  ) || rc=$?
  if (( rc != 0 )); then
    [[ "$rc" -eq 3 ]] && _deploy_msg error "回滚失败：旧版本在 ${old}，请手动执行 mv -T ${old} ${install_dir}"
    [[ "$rc" -ne 3 ]] && rm -rf -- "${new:?}"
    _deploy_msg error "替换安装目录失败：${install_dir}"
    return 1
  fi
  rm -rf -- "${old:?}"
  return 0
}

# 生成全局命令包装脚本（/usr/local/bin/debnas）的内容，写入全局变量 _DEPLOY_WRAPPER（不含末尾换行）
# install.sh 与 debnas update 都经 deploy_install_wrapper 使用这一份内容
# 参数：$1 - 安装目录
_deploy_wrapper_build() {
  local dir="${1%/}" q_dir q_old
  printf -v q_dir '%q' "$dir"
  printf -v q_old '%q' "${dir%/*}/.${dir##*/}.old"
  printf -v _DEPLOY_WRAPPER '%s\n' \
    '#!/bin/bash' \
    '# DebNAS 全局命令入口（由 install.sh / debnas update 生成，勿手改）' \
    '# 更新在两次 rename 之间被 SIGKILL/断电打断时安装目录会缺失：持锁把旧版本改回后再启动' \
    "if [[ ! -e ${q_dir} && -d ${q_old} ]] && command -v flock >/dev/null 2>&1; then" \
    "  flock -n \"\${DEBNAS_UPDATE_LOCK:-/run/debnas-update.lock}\" mv -T ${q_old} ${q_dir} \\" \
    '    && echo "[WARNING] 检测到被中断的更新，已回滚到旧版本" >&2' \
    'fi' \
    "exec bash ${q_dir}/bin/debnas \"\$@\""
  _DEPLOY_WRAPPER="${_DEPLOY_WRAPPER%$'\n'}"
}

# 写入/刷新全局命令包装脚本（内容已是最新时不写）
# 同目录临时文件 + rename：目标是旧版本留下的软链接（指向 bin/debnas）时替换链接本身，
# 不会顺着链接把 bin/debnas 改写成包装脚本
# 参数：$1 - 包装脚本路径（/usr/local/bin/debnas）  $2 - 安装目录
# 返回：0 已是最新或写入成功；1 失败
deploy_install_wrapper() {
  local bin="${1:-}" install_dir="${2:-}" tmp
  [[ -n "$bin" && -n "$install_dir" ]] || return 1
  _deploy_wrapper_build "$install_dir"
  if [[ -f "$bin" && ! -L "$bin" && -x "$bin" && "$(< "$bin")" == "$_DEPLOY_WRAPPER" ]]; then
    return 0
  fi
  if ! tmp=$(mktemp "${bin%/*}/.debnas-wrapper.XXXXXX" 2>/dev/null); then
    _deploy_msg error "无法写入全局命令：${bin}"
    return 1
  fi
  if printf '%s\n' "$_DEPLOY_WRAPPER" > "$tmp" && chmod 755 "$tmp" && mv -fT -- "$tmp" "$bin"; then
    return 0
  fi
  rm -f -- "${tmp:?}"
  _deploy_msg error "无法写入全局命令：${bin}"
  return 1
}
# <<< DEBNAS-DEPLOY-END

# 把 ASCII armor 公钥文本转换为 gpgv 可用的二进制 keyring
# 参数：$1 - armor 文本  $2 - 输出 keyring 文件
# 返回：0 成功；1 文本中没有公钥块或解码失败（换钥过渡期可含新旧多个公钥块）
dearmor_pubkey() {
  printf '%s\n' "${1:-}" | release_dearmor "$2"
}

# 验证发布产物（参数与返回值见 release_verify；失败时删除三个下载物）
verify_release() {
  release_verify "$@"
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
  for c in wget gpgv sha256sum base64; do
    if ! command -v "$c" >/dev/null 2>&1; then
      _fail "缺少命令 ${c}，请先执行：apt install wget gpgv coreutils"
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
    release_discard "$outdir" "$name"
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

  # 整树替换（与 debnas update 共用 DEBNAS-DEPLOY 区块）：先在暂存目录组装完整新树再一次性切换，
  # 失败即中止且旧安装不变；新版本已删除的旧模块不会残留
  _action "部署"
  if ! deploy_tree "$extract_dir" "$DEBNAS_INSTALL_DIR"; then
    _fail "部署失败，已中止（原有安装未改动）"
    rm -rf "$tmpdir"
    exit 1
  fi

  _success "文件安装完成"
}

# 安装全局命令（包装脚本内容与写入方式见 DEBNAS-DEPLOY 区块的 deploy_install_wrapper，与 debnas update 共用）
install_debnas_bin() {
  if ! deploy_install_wrapper "$DEBNAS_BIN" "$DEBNAS_INSTALL_DIR"; then
    _fail "全局命令安装失败: ${DEBNAS_BIN}"
    exit 1
  fi
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

# 需要确认的操作：stdin 不是终端（如 wget -O- | bash）且未加 --yes 时无法确认，以非 0 退出并提示
# 参数：$1 - 操作名
require_tty_or_yes() {
  if [[ ! -t 0 ]]; then
    _fail "非交互环境（如管道方式运行）无法确认${1}，请加 --yes 重新运行（例：bash install.sh --yes）"
    exit 1
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
    require_tty_or_yes "覆盖更新"

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

  # 并发保护：与 debnas update 共用更新锁（DEBNAS-DEPLOY 区块）；处理上次被中断的部署残留
  deploy_lock || exit 1
  deploy_recover "$DEBNAS_INSTALL_DIR" || exit 1

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
  # 释放更新锁：下面 exec 的菜单会继承锁文件描述符，不释放会挡住之后的 debnas update
  deploy_unlock

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
