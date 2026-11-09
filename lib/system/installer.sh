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
# main 分支的 install.sh：仅用于读取其中的 DEBNAS_RELEASE_TAG（最新稳定版本号）。
# 该文件本身不受签名保护，因此只采信其中的版本号字符串，代码内容仍由签名把关，
# 且 cmd_update 对自动发现的版本做防降级检查。
readonly DEBNAS_INSTALLER_GLOBAL_URL="https://github.com/kekylin/debnas/raw/main/install.sh"
readonly DEBNAS_INSTALLER_CN_URL="https://gitee.com/kekylin/debnas/raw/main/install.sh"
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

# 查询最新稳定版本号：读取 main 分支 install.sh 中的 DEBNAS_RELEASE_TAG
# 参数：$1 - region  $2 - 临时工作目录
# 输出：tag；返回：0 成功，1 失败
installer_latest_tag() {
  local region="$1" workdir="$2"
  local file="${workdir}/install.sh.remote" tag
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

# 版本比较：$1 < $2 时返回 0（sort -V 语义，v3.10.0 > v3.9.0）
installer_version_lt() {
  [[ "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
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
# 参数：$1 - 输出 keyring 文件；stdin - armor 文本
# 返回：0 成功；1 文本中没有恰好一个公钥块或解码失败
release_dearmor() {
  local out="$1" body
  # mawk 不支持 {n} 区间，CRC24 行（= 加 4 个 base64 字符）逐字符匹配
  body=$(awk '
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
release_verify() {
  if _release_verify_steps "$@"; then
    return 0
  fi
  release_discard "${1:-}" "${2:-}"
  return 1
}

_release_verify_steps() {
  local dir="${1:-}" name="${2:-}" keyring="${3:-}" expected="${4:-}"

  expected="${expected//[[:space:]]/}"
  expected="${expected^^}"
  if [[ ! "$expected" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]]; then
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
  if [[ ! -s "$keyring" ]]; then
    _release_fail "发布公钥 keyring 不存在: ${keyring}"
    return 1
  fi
  for f in gpgv sha256sum; do
    if ! command -v "$f" >/dev/null 2>&1; then
      _release_fail "缺少命令 ${f}（apt install gpgv coreutils）"
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
    _release_fail "SHA256SUMS 签名验证失败（gpgv 退出码 ${rc}${bad:+，${bad}}）"
    sed 's/^/    gpgv: /' "${work}/stderr" >&2 || true
    rm -rf -- "${work:?}"
    return 1
  fi
  if [[ "$signer" == MISMATCH:* ]]; then
    _release_fail "签名者指纹不匹配：期望 ${expected}，实际 ${signer#MISMATCH:}"
    rm -rf -- "${work:?}"
    return 1
  fi

  # 第 2 步：只取 tar 包对应的那一行做 sha256sum -c（防止清单里其他条目干扰/路径穿越）
  local hash
  hash=$(awk -v n="$name" 'NF == 2 && ($2 == n || $2 == "*" n) { print $1 }' "${dir}/SHA256SUMS")
  if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    _release_fail "SHA256SUMS 中没有（或有多条）${name} 的校验和"
    rm -rf -- "${work:?}"
    return 1
  fi
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
# 返回：0 成功；1 文件中没有恰好一个公钥块或解码失败
installer_dearmor_key() {
  local armor_file="$1" out="$2"
  [[ -f "$armor_file" ]] || return 1
  release_dearmor "$out" < "$armor_file"
}

# 从安装目录加载发布公钥（已安装的可信副本，不从网络获取）
# 参数：$1 - 安装目录  $2 - 输出 keyring 文件
# 输出：主密钥指纹；返回：0 成功，1 公钥/指纹缺失或无效
installer_load_release_key() {
  local install_dir="$1" out="$2" fpr=""
  if [[ -f "${install_dir}/${DEBNAS_RELEASE_FPR_REL}" ]]; then
    fpr=$(tr -d '[:space:]' < "${install_dir}/${DEBNAS_RELEASE_FPR_REL}") || fpr=""
  fi
  fpr="${fpr^^}"
  if [[ ! "$fpr" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]]; then
    return 1
  fi
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
# 说明：先把各目录完整复制到暂存目录（.<dir>.new），全部成功后再逐个 rename 替换：
#       - 复制中途失败不会留下"半新半旧"的安装；
#       - 上游已删除的旧模块/文件会随旧目录一起移除；
#       - rename 不改写正在执行的 bin/debnas 的 inode（原地覆写会让运行中的 bash 读到错位内容）。
#       config/、compose/（docker-apps、service-query、部署方案依赖）与 keys/（发布公钥）一并部署。
installer_deploy() {
  local src_dir="$1"
  local install_dir="$2"
  local d

  if [[ -z "$src_dir" || -z "$install_dir" ]]; then
    log_error "installer_deploy: 缺少源目录或安装目录参数"
    return 1
  fi

  # 校验更新包完整性（在动现有安装之前）
  if [[ ! -f "${src_dir}/bin/debnas" ]]; then
    log_error "部署后关键文件缺失：${src_dir}/bin/debnas"
    return 1
  fi
  for d in lib modules; do
    if [[ ! -d "${src_dir}/${d}" ]]; then
      log_error "更新包不完整，缺少目录：${d}"
      return 1
    fi
  done

  mkdir -p "$install_dir"

  # 第一阶段：复制到暂存目录
  local -a staged=()
  for d in bin lib modules config compose keys; do
    [[ -d "${src_dir}/${d}" ]] || continue
    rm -rf -- "${install_dir}/.${d}.new"
    if ! cp -R -- "${src_dir}/${d}" "${install_dir}/.${d}.new"; then
      log_error "复制失败：${d}"
      rm -rf -- "${install_dir}/.${d}.new"
      local s
      for s in "${staged[@]+"${staged[@]}"}"; do
        rm -rf -- "${install_dir}/.${s}.new"
      done
      return 1
    fi
    staged+=("$d")
  done

  # 第二阶段：逐目录替换
  for d in "${staged[@]}"; do
    rm -rf -- "${install_dir}/.${d}.old"
    if [[ -e "${install_dir}/${d}" ]] && ! mv -- "${install_dir}/${d}" "${install_dir}/.${d}.old"; then
      log_error "替换失败：${install_dir}/${d}"
      return 1
    fi
    if ! mv -- "${install_dir}/.${d}.new" "${install_dir}/${d}"; then
      # 回滚当前目录
      if [[ -e "${install_dir}/.${d}.old" ]]; then
        mv -- "${install_dir}/.${d}.old" "${install_dir}/${d}" || true
      fi
      log_error "替换失败：${install_dir}/${d}"
      return 1
    fi
    rm -rf -- "${install_dir}/.${d}.old"
  done

  # 验证关键文件
  if [[ ! -f "${install_dir}/bin/debnas" ]]; then
    log_error "部署后关键文件缺失：${install_dir}/bin/debnas"
    return 1
  fi

  # 设置可执行权限
  chmod +x "${install_dir}/bin/"* 2>/dev/null || true

  return 0
}
