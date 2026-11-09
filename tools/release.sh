#!/usr/bin/env bash
# tools/release.sh — DebNAS 发布脚本（维护者使用，不随安装部署）
#
# 用法:
#   bash tools/release.sh --embed-key <公钥文件>   # 配置/轮换发布公钥（写 keys/ 与 install.sh 内嵌区块）
#   bash tools/release.sh --bump <tag>             # 仅把 install.sh 默认版本与 README 安装命令改为 <tag>
#   bash tools/release.sh --sync-verify            # 把 lib/system/installer.sh 的发布校验区块同步到 install.sh
#   bash tools/release.sh <tag> <GPG 密钥 ID>       # 生成发布产物到 dist/<tag>/、签名并自检
#
# 发布校验逻辑单一来源：lib/system/installer.sh 中 DEBNAS-RELEASE-VERIFY 区块；
#   --embed-key / --bump 会顺带同步到 install.sh，构建发布时检查 tag 内两份是否一致。
#
# 推荐顺序（详见 docs/MAINTENANCE.md「发布流程」）:
#   --bump vX.Y.Z → 提交 → git tag -a vX.Y.Z → release.sh vX.Y.Z <key> → 上传 Release
#   先 bump 再打 tag，tag 内的 install.sh 默认安装的就是它自己这个版本。
#
# 发布产物（每个 tag）:
#   debnas-<tag>.tar.gz   git archive --prefix=debnas/ <tag>（内容与 tag 一致）
#   install.sh            tag 内的 install.sh（供谨慎用户手动核验引导脚本）
#   SHA256SUMS            以上两个文件的 sha256
#   SHA256SUMS.asc        对 SHA256SUMS 的 GPG 分离签名（ASCII armor）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
README_MD="${REPO_ROOT}/README.md"
KEY_ASC="${REPO_ROOT}/keys/debnas-release.asc"
KEY_FPR="${REPO_ROOT}/keys/debnas-release.fpr"
MARK_BEGIN="# >>> DEBNAS-RELEASE-PUBKEY-BEGIN"
MARK_END="# <<< DEBNAS-RELEASE-PUBKEY-END"
LIB_INSTALLER="${REPO_ROOT}/lib/system/installer.sh"
VERIFY_BEGIN="# >>> DEBNAS-RELEASE-VERIFY-BEGIN"
VERIFY_END="# <<< DEBNAS-RELEASE-VERIFY-END"

_msg()  { printf "[%s] %s\n" "$1" "$2" >&2; }
info()  { _msg "INFO" "$1"; }
ok()    { _msg "OK" "$1"; }
warn()  { _msg "WARNING" "$1"; }
die()   { _msg "FAIL" "$1"; exit 1; }

_TMP=""
cleanup() {
  if [[ -n "$_TMP" && -d "$_TMP" ]]; then
    rm -rf -- "${_TMP:?}"
  fi
}
trap cleanup EXIT

make_tmp() {
  _TMP=$(mktemp -d "${TMPDIR:-/tmp}/debnas-release.XXXXXX")
  chmod 700 "$_TMP"
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
}

valid_tag() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

usage() {
  sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ==================== 发布校验区块同步（--sync-verify） ====================

# 输出文件中 DEBNAS-RELEASE-VERIFY 区块（含起止标记行；标记行之后的说明文字不计入比较）
# 参数：$1 - 文件
extract_verify_block() {
  awk -v mb="$VERIFY_BEGIN" -v me="$VERIFY_END" '
    index($0, mb) == 1 { p = 1; print mb; next }
    index($0, me) == 1 { if (p) print me; p = 0; next }
    p { print }' "$1"
}

# 检查文件中起止标记各恰好一个
# 参数：$1 - 文件  $2 - 显示名
check_verify_marks() {
  local n_begin n_end
  n_begin=$(grep -c "^${VERIFY_BEGIN}" "$1" || true)
  n_end=$(grep -c "^${VERIFY_END}" "$1" || true)
  [[ "$n_begin" -eq 1 && "$n_end" -eq 1 ]] || die "$2 中发布校验区块标记应各有 1 个（起 ${n_begin}，止 ${n_end}）"
}

# 用 lib/system/installer.sh 的区块替换 install.sh 的区块（内容相同则不写）
sync_verify_block() {
  [[ -f "$LIB_INSTALLER" ]] || die "找不到 ${LIB_INSTALLER}（发布校验逻辑的单一来源）"
  check_verify_marks "$LIB_INSTALLER" "lib/system/installer.sh"
  check_verify_marks "$INSTALL_SH" "install.sh"
  local tmpd block new_install
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/debnas-sync.XXXXXX")
  block="${tmpd}/block"
  new_install="${tmpd}/install.sh"
  # lib 中的起始标记行带说明文字，install.sh 中保持同一行（整行复制）
  awk -v mb="$VERIFY_BEGIN" -v me="$VERIFY_END" '
    index($0, mb) == 1 { p = 1 }
    p { print }
    index($0, me) == 1 { p = 0 }' "$LIB_INSTALLER" > "$block"
  awk -v bf="$block" -v mb="$VERIFY_BEGIN" -v me="$VERIFY_END" '
    index($0, mb) == 1 { while ((getline l < bf) > 0) print l; skip = 1; next }
    index($0, me) == 1 && skip { skip = 0; next }
    !skip { print }' "$INSTALL_SH" > "$new_install"
  if ! bash -n "$new_install"; then
    rm -rf -- "${tmpd:?}"
    die "同步后的 install.sh 语法错误，未写入"
  fi
  if cmp -s "$new_install" "$INSTALL_SH"; then
    rm -rf -- "${tmpd:?}"
    info "install.sh 发布校验区块已与 lib/system/installer.sh 一致"
    return 0
  fi
  cat "$new_install" > "$INSTALL_SH"
  rm -rf -- "${tmpd:?}"
  ok "已把 lib/system/installer.sh 的发布校验区块同步到 install.sh"
}

# ==================== --embed-key ====================

embed_key() {
  local keyfile="${1:-}"
  [[ -n "$keyfile" && -f "$keyfile" ]] || die "公钥文件不存在: ${keyfile}"
  need_cmd gpg awk base64 cmp
  sync_verify_block
  make_tmp
  local home="${_TMP}/gnupg"
  mkdir -m 700 "$home"

  # 用临时 homedir 解析与规范化，不读写维护者自己的 keyring
  local colons
  colons=$(gpg --homedir "$home" --batch --with-colons --show-keys "$keyfile" 2>/dev/null) \
    || die "无法解析公钥文件: ${keyfile}"
  if grep -q '^sec:' <<<"$colons"; then
    die "该文件包含私钥！请导出公钥：gpg --armor --export-options export-minimal --export <指纹>"
  fi
  local npub
  npub=$(grep -c '^pub:' <<<"$colons" || true)
  [[ "$npub" -eq 1 ]] || die "公钥文件必须恰好包含一把主密钥（实际 ${npub} 把）"

  local validity caps fpr
  validity=$(awk -F: '$1 == "pub" { print $2; exit }' <<<"$colons")
  caps=$(awk -F: '$1 == "pub" { print $12; exit }' <<<"$colons")
  fpr=$(awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; exit }' <<<"$colons")
  fpr="${fpr^^}"
  [[ "$fpr" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || die "无法取得主密钥指纹"
  case "$validity" in
    r) die "该密钥已吊销" ;;
    e) die "该密钥已过期" ;;
  esac
  [[ "$caps" == *S* ]] || die "该密钥（含子密钥）没有可用的签名能力"

  gpg --homedir "$home" --batch --quiet --import "$keyfile" 2>/dev/null || die "导入公钥失败"
  local norm="${_TMP}/norm.asc" bin="${_TMP}/norm.gpg"
  gpg --homedir "$home" --batch --armor --export-options export-minimal --export "$fpr" > "$norm"
  gpg --homedir "$home" --batch --export-options export-minimal --export "$fpr" > "$bin"
  [[ -s "$norm" && -s "$bin" ]] || die "导出规范化公钥失败"
  if grep -q "'" "$norm"; then
    die "规范化公钥中含单引号，无法内嵌（异常的 armor 头）"
  fi

  # 写 keys/
  mkdir -p "$(dirname "$KEY_ASC")"
  cat "$norm" > "$KEY_ASC"
  printf '%s\n' "$fpr" > "$KEY_FPR"

  # 写 install.sh 内嵌区块（只替换两个标记之间的内容）
  grep -q "^${MARK_BEGIN}" "$INSTALL_SH" || die "install.sh 中找不到内嵌公钥起始标记"
  grep -q "^${MARK_END}" "$INSTALL_SH" || die "install.sh 中找不到内嵌公钥结束标记"
  local block="${_TMP}/block"
  {
    echo "# 发布公钥主密钥指纹（大写十六进制无空格）与 ASCII armor 公钥（与 keys/debnas-release.asc 一致）"
    echo "# 两者为空 = 维护者尚未配置发布公钥，签名安装不可用"
    printf 'readonly DEBNAS_RELEASE_KEY_FPR="%s"\n' "$fpr"
    printf "readonly DEBNAS_RELEASE_PUBKEY='"
    # 去掉末尾换行后接右引号
    printf '%s' "$(cat "$norm")"
    printf "'\n"
  } > "$block"
  local new_install="${_TMP}/install.sh"
  awk -v bf="$block" -v mb="$MARK_BEGIN" -v me="$MARK_END" '
    index($0, mb) == 1 { print; while ((getline l < bf) > 0) print l; skip = 1; next }
    index($0, me) == 1 { skip = 0 }
    !skip { print }' "$INSTALL_SH" > "$new_install"
  bash -n "$new_install" || die "生成的 install.sh 语法错误，未写入"
  cat "$new_install" > "$INSTALL_SH"

  # 自检：install.sh 内嵌公钥解码结果须与 gpg 导出的二进制完全一致
  bash -c 'source "$1" && dearmor_pubkey "$DEBNAS_RELEASE_PUBKEY" "$2" && [[ "$DEBNAS_RELEASE_KEY_FPR" == "$3" ]]' \
    _ "$INSTALL_SH" "${_TMP}/embedded.gpg" "$fpr" || die "自检失败：install.sh 内嵌公钥无法解码或指纹不符"
  cmp -s "${_TMP}/embedded.gpg" "$bin" || die "自检失败：内嵌公钥解码结果与原公钥不一致"

  ok "已写入 keys/debnas-release.asc、keys/debnas-release.fpr 与 install.sh 内嵌区块"
  ok "主密钥指纹: ${fpr}"
  info "请核对指纹无误后提交：git add keys/ install.sh && git commit -m 'chore(release): 配置发布公钥'"
}

# ==================== --bump ====================

bump_tag() {
  local tag="${1:-}"
  valid_tag "$tag" || die "非法的 tag: ${tag}"
  sync_verify_block
  grep -q '^readonly DEBNAS_RELEASE_TAG="[^"]*"$' "$INSTALL_SH" || die "install.sh 中找不到 DEBNAS_RELEASE_TAG 常量"
  sed -i "s/^readonly DEBNAS_RELEASE_TAG=\"[^\"]*\"$/readonly DEBNAS_RELEASE_TAG=\"${tag}\"/" "$INSTALL_SH"
  grep -q "^readonly DEBNAS_RELEASE_TAG=\"${tag}\"$" "$INSTALL_SH" || die "更新 DEBNAS_RELEASE_TAG 失败"
  if [[ -f "$README_MD" ]]; then
    sed -i -E "s#((gitee|github)\.com/kekylin/debnas/raw/)[^/ ]+/install\.sh#\1${tag}/install.sh#g" "$README_MD"
  fi
  ok "install.sh 默认版本与 README 安装命令已改为 ${tag}"
}

# ==================== 构建发布 ====================

build_release() {
  local tag="${1:-}" keyid="${2:-}"
  valid_tag "$tag" || die "非法的 tag: ${tag}"
  [[ -n "$keyid" ]] || die "缺少 GPG 密钥 ID"
  need_cmd git gpg gpgv sha256sum awk base64
  cd "$REPO_ROOT"
  git rev-parse --git-dir >/dev/null 2>&1 || die "${REPO_ROOT} 不是 git 仓库"

  [[ -z "$(git status --porcelain)" ]] || die "工作区不干净，请先提交或暂存修改（git status）"
  git rev-parse -q --verify "refs/tags/${tag}" >/dev/null || die "tag 不存在: ${tag}"
  [[ "$(git cat-file -t "refs/tags/${tag}")" == "tag" ]] || die "${tag} 不是附注 tag（请用 git tag -a ${tag}）"

  make_tmp
  local tag_install="${_TMP}/install.sh"
  git show "${tag}:install.sh" > "$tag_install" || die "tag 中没有 install.sh"

  # 发布校验区块：tag 内 install.sh 必须与 tag 内 lib/system/installer.sh 一致（单一来源）
  local tag_lib="${_TMP}/installer.sh"
  git show "${tag}:lib/system/installer.sh" > "$tag_lib" || die "tag 中没有 lib/system/installer.sh"
  check_verify_marks "$tag_lib" "tag 内 lib/system/installer.sh"
  check_verify_marks "$tag_install" "tag 内 install.sh"
  if ! cmp -s <(extract_verify_block "$tag_lib") <(extract_verify_block "$tag_install"); then
    die "tag ${tag} 中 install.sh 的发布校验区块与 lib/system/installer.sh 不一致：先 --sync-verify 并提交，再重新打 tag"
  fi

  # tag 内 install.sh 的内嵌公钥就是用户实际用来验证的公钥
  local emb_fpr tag_default tag_fpr
  emb_fpr=$(sed -n 's/^readonly DEBNAS_RELEASE_KEY_FPR="\([^"]*\)"$/\1/p' "$tag_install" | head -n 1)
  [[ -n "$emb_fpr" ]] || die "tag ${tag} 中的 install.sh 未内嵌发布公钥：先 --embed-key 并提交，再重新打 tag"
  tag_fpr=$(git show "${tag}:keys/debnas-release.fpr" 2>/dev/null | tr -d '[:space:]') || tag_fpr=""
  [[ "${tag_fpr^^}" == "$emb_fpr" ]] || die "tag 中 keys/debnas-release.fpr 与 install.sh 内嵌指纹不一致"

  # 签名密钥必须就是内嵌公钥（主密钥指纹比对）
  local sign_fpr
  sign_fpr=$(gpg --batch --with-colons --list-secret-keys -- "$keyid" 2>/dev/null \
    | awk -F: '$1 == "sec" { p = 1; next } p && $1 == "fpr" { print toupper($10); exit }') || sign_fpr=""
  [[ -n "$sign_fpr" ]] || die "本机 keyring 中找不到密钥 ${keyid} 的私钥"
  [[ "$sign_fpr" == "$emb_fpr" ]] || die "签名密钥 ${sign_fpr} 与 install.sh 内嵌公钥 ${emb_fpr} 不一致"

  tag_default=$(sed -n 's/^readonly DEBNAS_RELEASE_TAG="\([^"]*\)"$/\1/p' "$tag_install" | head -n 1)
  if [[ "$tag_default" != "$tag" ]]; then
    warn "tag ${tag} 内 install.sh 的默认版本是 '${tag_default}'：用户经 raw/${tag}/install.sh 安装时默认装的不是 ${tag}"
    warn "建议流程：--bump ${tag} → 提交 → 重新打 tag。继续生成产物..."
  fi

  local outdir="${REPO_ROOT}/dist/${tag}"
  local name="debnas-${tag}.tar.gz"
  [[ ! -e "$outdir" ]] || die "${outdir} 已存在，请确认后手动删除再重试"
  mkdir -p "$outdir"

  info "生成 ${name}"
  git archive --format=tar.gz --prefix=debnas/ -o "${outdir}/${name}" "$tag"
  # 不用 grep -q：提前退出会让 tar 收到 SIGPIPE，在 pipefail 下误判失败
  tar -tzf "${outdir}/${name}" | grep -x 'debnas/bin/debnas' >/dev/null || die "归档内容异常：缺少 debnas/bin/debnas"
  cp "$tag_install" "${outdir}/install.sh"
  (cd "$outdir" && sha256sum "$name" install.sh > SHA256SUMS)

  info "签名 SHA256SUMS（可能弹出密码输入）"
  gpg --local-user "$keyid" --detach-sign --armor --output "${outdir}/SHA256SUMS.asc" "${outdir}/SHA256SUMS"

  # 自检：在副本上用 tag 内 install.sh 的 gpgv 验证函数与内嵌公钥走一遍用户侧流程
  info "自检（与 install.sh 相同的 gpgv 验证）"
  local check_dir="${_TMP}/selfcheck"
  mkdir -p "$check_dir"
  cp "${outdir}/${name}" "${outdir}/SHA256SUMS" "${outdir}/SHA256SUMS.asc" "$check_dir/"
  bash -c 'source "$1" && dearmor_pubkey "$DEBNAS_RELEASE_PUBKEY" "$2" && verify_release "$3" "$4" "$2" "$DEBNAS_RELEASE_KEY_FPR"' \
    _ "$tag_install" "${_TMP}/keyring.gpg" "$check_dir" "$name" || die "自检失败：产物无法通过 install.sh 的验证，请勿上传"
  ok "自检通过"

  # 更新工作区 install.sh 默认版本（main 分支的 install.sh 也是 debnas update 发现新版本的来源）
  local cur_default
  cur_default=$(sed -n 's/^readonly DEBNAS_RELEASE_TAG="\([^"]*\)"$/\1/p' "$INSTALL_SH" | head -n 1)
  if [[ "$cur_default" != "$tag" ]]; then
    bump_tag "$tag"
    info "请提交：git commit -am 'chore(release): 默认版本 ${tag}' && git push"
  fi

  cat >&2 <<EOF

========== 产物 ==========
$(ls -l "$outdir")

========== 上传步骤 ==========
1) GitHub Release（需 gh 已登录；也可网页 Releases → Draft a new release）:
   git push origin ${tag}
   gh release create ${tag} --verify-tag --title ${tag} --notes "见 CHANGELOG.md" \\
     dist/${tag}/${name} dist/${tag}/SHA256SUMS dist/${tag}/SHA256SUMS.asc dist/${tag}/install.sh

2) Gitee 发行版（网页）:
   git push gitee ${tag}
   仓库页 → 发行版 → 创建发行版 → 选择 tag ${tag} → 上传上述四个附件 → 发布

3) 上传后核验下载地址（Gitee 路径为推测格式，首次发布必须核实；
   若不一致须同步修改 install.sh 与 lib/system/installer.sh 中的 *_CN_BASE）:
   wget --timeout=30 -qO- https://github.com/kekylin/debnas/releases/download/${tag}/SHA256SUMS | diff - dist/${tag}/SHA256SUMS
   wget --timeout=30 -qO- https://gitee.com/kekylin/debnas/releases/download/${tag}/SHA256SUMS | diff - dist/${tag}/SHA256SUMS

4) 提交并推送 main 上 install.sh 的默认版本变更（如上一步有提示），用户的 debnas update 才会发现新版本。
EOF
}

# ==================== 入口 ====================

main() {
  case "${1:-}" in
    --embed-key)
      [[ $# -eq 2 ]] || die "用法: tools/release.sh --embed-key <公钥文件>"
      embed_key "$2"
      ;;
    --bump)
      [[ $# -eq 2 ]] || die "用法: tools/release.sh --bump <tag>"
      bump_tag "$2"
      ;;
    --sync-verify)
      [[ $# -eq 1 ]] || die "用法: tools/release.sh --sync-verify"
      sync_verify_block
      ;;
    --help|-h|"")
      usage
      ;;
    -*)
      die "未知参数: $1"
      ;;
    *)
      [[ $# -eq 2 ]] || die "用法: tools/release.sh <tag> <GPG 密钥 ID>"
      build_release "$1" "$2"
      ;;
  esac
}

main "$@"
