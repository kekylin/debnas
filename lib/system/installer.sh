#!/bin/bash
# 功能：DebNAS 安装/更新公共逻辑
# 说明：提供下载、签名校验、解压、文件部署的统一函数，供 cmd_update 等复用
# 注意：install.sh 引导脚本因自包含需求不加载本库；其中的发布校验区块
#       （DEBNAS-RELEASE-VERIFY）由 tools/release.sh 从本文件同步生成

set -euo pipefail
IFS=$'\n\t'

# ==================== 常量 ====================

# ⚠️ 以下 URL 与 install.sh 中的定义必须保持同步
# 发布产物（GitHub Release / Gitee Release 附件）：<base>/<tag>/<file>
# Gitee 的 Release 附件下载路径为推测格式，首次发布时需核实，不一致须两处同步修改
readonly DEBNAS_RELEASE_GLOBAL_BASE="https://github.com/kekylin/debnas/releases/download"
readonly DEBNAS_RELEASE_CN_BASE="https://gitee.com/kekylin/debnas/releases/download"
# 分支归档（仅 --unsigned 模式使用，内容不做任何校验）
readonly DEBNAS_BRANCH_GLOBAL_BASE="https://github.com/kekylin/debnas/archive/refs/heads"
readonly DEBNAS_BRANCH_CN_BASE="https://gitee.com/kekylin/debnas/repository/archive"
# main 分支 raw 地址：取"最新稳定版本"指针 LATEST（一行 tag）与其分离签名 LATEST.asc
# （由 tools/release.sh --sign-latest 生成，用已安装目录 keys/ 中的发布公钥验签）
readonly DEBNAS_RAW_GLOBAL_BASE="https://github.com/kekylin/debnas/raw/main"
readonly DEBNAS_RAW_CN_BASE="https://gitee.com/kekylin/debnas/raw/main"
# main 分支的 install.sh：LATEST / LATEST.asc 都取不到时（维护者尚未发布已签名指针）的回退来源，
# 只读取其中的 DEBNAS_RELEASE_TAG。该文件不受签名保护，因此只采信版本号字符串，
# 代码内容仍由签名把关，且 cmd_update 对自动发现的版本做防降级检查。
readonly DEBNAS_INSTALLER_GLOBAL_URL="${DEBNAS_RAW_GLOBAL_BASE}/install.sh"
readonly DEBNAS_INSTALLER_CN_URL="${DEBNAS_RAW_CN_BASE}/install.sh"
# 发布公钥与主密钥指纹（安装目录内的可信副本，由 tools/release.sh --embed-key 生成）
readonly DEBNAS_RELEASE_KEY_REL="keys/debnas-release.asc"
readonly DEBNAS_RELEASE_FPR_REL="keys/debnas-release.fpr"

# ==================== 公共函数 ====================

# 发布 tag / 分支名校验（实现在下方 DEBNAS-RELEASE-VERIFY 区块，与 install.sh 共用）
installer_valid_tag() {
  release_valid_tag "$@"
}

installer_valid_branch() {
  release_valid_branch "$@"
}

# 根据 region 获取发布产物下载 URL（主源）
# 参数：$1 - region (cn|global)
#       $2 - tag（可选，省略时只返回 Release 下载根地址）
#       $3 - 文件名（可选）
# 输出：URL
installer_get_url() {
  local region="${1:-global}" tag="${2:-}" file="${3:-}"
  local base="$DEBNAS_RELEASE_GLOBAL_BASE"
  [[ "$region" == "cn" ]] && base="$DEBNAS_RELEASE_CN_BASE"
  if [[ -n "$tag" ]]; then
    echo "${base}/${tag}${file:+/${file}}"
  else
    echo "$base"
  fi
}

# 下载单个文件（主源失败自动切换备用源）
# 参数：$1 - 输出文件  $2 - 主源 URL  $3 - 备用源 URL
# 返回：0 成功，1 失败
installer_fetch() {
  local out="$1" primary_url="$2" fallback_url="$3"
  # --timeout/--tries：网络不可达时避免无限挂起（项目红线）
  if wget -q --timeout=30 --tries=3 -O "$out" "$primary_url" 2>/dev/null; then
    return 0
  fi
  log_warning "主源下载失败，尝试备用源..."
  if wget -q --timeout=30 --tries=3 -O "$out" "$fallback_url" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${out:?}"
  return 1
}

# 下载某个 tag 的三个发布产物（同一来源取齐，否则整体切换备用源）
# 参数：$1 - region (cn|global)  $2 - tag  $3 - 输出目录
# 返回：0 成功，1 失败
installer_download_release() {
  local region="$1" tag="$2" outdir="$3"
  local name="debnas-${tag}.tar.gz"
  local -a bases=()

  if ! installer_valid_tag "$tag" || [[ -z "$outdir" ]]; then
    log_error "installer_download_release: 参数无效"
    return 1
  fi
  if [[ "$region" == "cn" ]]; then
    bases=("$DEBNAS_RELEASE_CN_BASE" "$DEBNAS_RELEASE_GLOBAL_BASE")
  else
    bases=("$DEBNAS_RELEASE_GLOBAL_BASE" "$DEBNAS_RELEASE_CN_BASE")
  fi

  log_info "从 ${region} 源下载 ${tag}..."
  local base f ok
  for base in "${bases[@]}"; do
    ok=1
    for f in "$name" SHA256SUMS SHA256SUMS.asc; do
      if ! wget -q --timeout=30 --tries=3 -O "${outdir}/${f}" "${base}/${tag}/${f}" 2>/dev/null; then
        ok=0
        break
      fi
    done
    if [[ "$ok" -eq 1 ]]; then
      return 0
    fi
    release_discard "$outdir" "$name"
    log_warning "源 ${base%%/releases/*} 下载失败，尝试备用源..."
  done
  log_error "所有下载源均失败"
  return 1
}

# 下载分支归档（不校验，仅 --unsigned 模式使用）
# 参数：$1 - region (cn|global)  $2 - 分支名  $3 - 输出 tarball 路径
installer_download_branch() {
  local region="$1" branch="$2" tarball="$3"
  if ! installer_valid_branch "$branch"; then
    log_error "非法的分支名: ${branch}"
    return 1
  fi
  local cn_url="${DEBNAS_BRANCH_CN_BASE}/${branch}.tar.gz"
  local global_url="${DEBNAS_BRANCH_GLOBAL_BASE}/${branch}.tar.gz"
  log_info "从 ${region} 源下载分支 ${branch}（未校验）..."
  if [[ "$region" == "cn" ]]; then
    installer_fetch "$tarball" "$cn_url" "$global_url" || { log_error "所有下载源均失败"; return 1; }
  else
    installer_fetch "$tarball" "$global_url" "$cn_url" || { log_error "所有下载源均失败"; return 1; }
  fi
}

# 校验已下载的"最新稳定版本"指针：LATEST.asc 须是发布密钥对 LATEST 的有效签名，LATEST 须恰为一行合法 tag
# 参数：$1 - 含 LATEST 与 LATEST.asc 的目录  $2 - 二进制 keyring  $3 - 期望的主密钥指纹（逗号分隔）
# 输出：tag；返回：0 通过，1 验签失败或内容无效
installer_verify_latest() {
  local dir="$1" keyring="$2" fprs="$3" tag
  release_check_sig "${dir}/LATEST.asc" "${dir}/LATEST" "$keyring" "$fprs" "LATEST" || return 1
  tag=$(< "${dir}/LATEST")
  tag="${tag%$'\r'}"
  if ! release_valid_tag "$tag"; then
    _release_fail "LATEST 内容无效（应为一行发布版本号）"
    return 1
  fi
  echo "$tag"
}

# 查询最新稳定版本号
# 优先取 main 分支的 LATEST + LATEST.asc（同一来源取齐）并用已安装的发布公钥验签，通过才采用；
# 两个文件都取不到时回退读取 main 分支 install.sh 中的 DEBNAS_RELEASE_TAG（未签名，告警）。
# 两种来源的结果都只是"候选版本号"：调用方仍须做防降级检查，代码包仍须通过发布签名校验。
# 参数：$1 - region  $2 - 临时工作目录
#       $3 - 二进制 keyring  $4 - 期望的主密钥指纹（逗号分隔）；$3/$4 省略时只走回退办法
# 输出：tag；返回：0 成功，1 取不到，2 已签名指针存在但校验未通过（调用方应拒绝自动更新）
installer_latest_tag() {
  local region="$1" workdir="$2" keyring="${3:-}" fprs="${4:-}"
  local file="${workdir}/install.sh.remote" tag
  if [[ -n "$keyring" && -n "$fprs" ]]; then
    local -a bases=("$DEBNAS_RAW_GLOBAL_BASE" "$DEBNAS_RAW_CN_BASE")
    [[ "$region" == "cn" ]] && bases=("$DEBNAS_RAW_CN_BASE" "$DEBNAS_RAW_GLOBAL_BASE")
    local base got=0 ptr="${workdir}/latest.d"
    mkdir -p -- "$ptr" || return 1
    for base in "${bases[@]}"; do
      rm -f -- "${ptr:?}/LATEST" "${ptr:?}/LATEST.asc"
      if wget -q --timeout=30 --tries=3 -O "${ptr}/LATEST" "${base}/LATEST" 2>/dev/null; then
        if wget -q --timeout=30 --tries=3 -O "${ptr}/LATEST.asc" "${base}/LATEST.asc" 2>/dev/null; then
          got=2
          break
        fi
        got=1
      fi
    done
    if (( got == 2 )); then
      if tag=$(installer_verify_latest "$ptr" "$keyring" "$fprs"); then
        rm -rf -- "${ptr:?}"
        echo "$tag"
        return 0
      fi
      rm -rf -- "${ptr:?}"
      log_error "版本指针 LATEST 的签名校验未通过（文件可能被篡改）"
      return 2
    fi
    rm -rf -- "${ptr:?}"
    if (( got == 1 )); then
      log_error "取到了版本指针 LATEST，但取不到它的签名 LATEST.asc，不予采用"
      return 2
    fi
    log_warning "未取到已签名的版本指针（LATEST / LATEST.asc），回退读取 main 分支 install.sh 中的版本号（该来源未签名，只用于升级）"
  fi
  if [[ "$region" == "cn" ]]; then
    installer_fetch "$file" "$DEBNAS_INSTALLER_CN_URL" "$DEBNAS_INSTALLER_GLOBAL_URL" || return 1
  else
    installer_fetch "$file" "$DEBNAS_INSTALLER_GLOBAL_URL" "$DEBNAS_INSTALLER_CN_URL" || return 1
  fi
  tag=$(sed -n 's/^readonly DEBNAS_RELEASE_TAG="\([^"]*\)"$/\1/p' "$file" | head -n 1)
  rm -f -- "${file:?}"
  installer_valid_tag "$tag" || return 1
  echo "$tag"
}

# 版本比较：$1 < $2 时返回 0（数字部分按 sort -V 语义，v3.10.0 > v3.9.0）
# 预发布版本（v3.1.0-rc1、v3.1.0rc1、v3.1.0~beta）低于同号正式版：sort -V 会把 v3.1.0-rc1 排在
# v3.1.0 之后（误判 rc 更新，导致正式版被当成降级拒绝），因此先比数字部分，相同时再看预发布后缀
installer_version_lt() {
  local a="${1#[vV]}" b="${2#[vV]}" a_base b_base a_pre b_pre
  [[ "$a" != "$b" ]] || return 1
  [[ "$a" =~ ^([0-9][0-9.]*)(.*)$ ]] && { a_base="${BASH_REMATCH[1]%.}"; a_pre="${BASH_REMATCH[2]}"; } || { a_base="$a"; a_pre=""; }
  [[ "$b" =~ ^([0-9][0-9.]*)(.*)$ ]] && { b_base="${BASH_REMATCH[1]%.}"; b_pre="${BASH_REMATCH[2]}"; } || { b_base="$b"; b_pre=""; }
  a_pre="${a_pre#[-~._]}"; b_pre="${b_pre#[-~._]}"
  if [[ "$a_base" != "$b_base" ]]; then
    [[ "$(printf '%s\n%s\n' "$a_base" "$b_base" | sort -V | head -n 1)" == "$a_base" ]]
    return
  fi
  # 数字部分相同：正式版（无后缀）最大
  [[ -n "$a_pre" ]] || return 1
  [[ -n "$b_pre" ]] || return 0
  [[ "$a_pre" != "$b_pre" && "$(printf '%s\n%s\n' "$a_pre" "$b_pre" | sort -V | head -n 1)" == "$a_pre" ]]
}

# 读取安装目录 RELEASE 标记文件中的字段（文件不存在时输出空）
# 参数：$1 - 安装目录  $2 - 字段名（tag|branch|verified）
installer_marker_get() {
  local file="${1}/RELEASE"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${2}=//p" "$file" | head -n 1
}

# 写入 RELEASE 标记文件（格式与 install.sh write_release_marker 一致）
# 参数：$1 - 安装目录  $2 - tag  $3 - branch  $4 - verified(0|1)
installer_marker_write() {
  local file="${1}/RELEASE"
  printf 'tag=%s\nbranch=%s\nverified=%s\n' "$2" "$3" "$4" > "$file"
  chmod 644 "$file"
}

# ==================== 签名校验 ====================
# 校验逻辑的唯一实现在下方 DEBNAS-RELEASE-VERIFY 区块；install.sh 内的副本由
# tools/release.sh（--embed-key / --bump / --sync-verify）从这里同步生成，
# tests/unit/lib/test-release-sync.bats 断言两份区块逐字一致。

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

# 把 ASCII armor 公钥文件转换为 gpgv 可用的二进制 keyring（不依赖 gpg 完整包）
# 参数：$1 - armor 公钥文件  $2 - 输出 keyring 文件
# 返回：0 成功；1 文件中没有公钥块或解码失败（多个公钥块依次拼接，见 release_dearmor）
installer_dearmor_key() {
  local armor_file="$1" out="$2"
  [[ -f "$armor_file" ]] || return 1
  release_dearmor "$out" < "$armor_file"
}

# 从安装目录加载发布公钥（已安装的可信副本，不从网络获取）
# 参数：$1 - 安装目录  $2 - 输出 keyring 文件
# 输出：主密钥指纹；返回：0 成功，1 公钥/指纹缺失或无效
# 指纹文件每行一个主密钥指纹（行内空格忽略，空行与 # 注释跳过）；多行用于密钥轮换，输出逗号分隔；
# 公钥文件相应含多个公钥块（tools/release.sh --embed-key <新公钥> --keep-old 生成）
installer_load_release_key() {
  local install_dir="$1" out="$2" fpr="" line
  if [[ -f "${install_dir}/${DEBNAS_RELEASE_FPR_REL}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ -n "$line" ]] || continue
      line="${line^^}"
      [[ "$line" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || return 1
      fpr="${fpr:+${fpr},}${line}"
    done < "${install_dir}/${DEBNAS_RELEASE_FPR_REL}"
  fi
  [[ -n "$fpr" ]] || return 1
  installer_dearmor_key "${install_dir}/${DEBNAS_RELEASE_KEY_REL}" "$out" || return 1
  echo "$fpr"
}

# 验证发布产物（参数与返回值见 release_verify）
installer_verify_release() {
  release_verify "$@"
}

# 解压仓库压缩包
# 参数：$1 - tarball 路径
#       $2 - 解压目标目录
# 返回：0 成功，1 失败
installer_extract() {
  local tarball="$1"
  local extract_dir="$2"

  mkdir -p "$extract_dir"
  # --no-same-owner：以 root 解压时不沿用归档内记录的 uid/gid（否则文件可能归属任意普通用户，
  # 该用户即可改写之后由 root 执行的脚本）
  if ! tar -xzf "$tarball" -C "$extract_dir" --strip-components=1 --no-same-owner 2>/dev/null; then
    log_error "解压失败"
    return 1
  fi
  return 0
}

# 部署文件到安装目录（覆盖代码文件，保留配置和状态）
# 参数：$1 - 解压源目录
#       $2 - 安装目标目录
# 返回：0 成功，1 失败
# 说明：实现见下方 DEBNAS-DEPLOY 区块的 deploy_tree（与 install.sh 共用，整树替换、可回滚）
installer_deploy() {
  deploy_tree "$@"
}

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
