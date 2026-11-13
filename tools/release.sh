#!/usr/bin/env bash
# tools/release.sh — DebNAS 发布脚本（维护者使用，不随安装部署）
#
# 用法:
#   bash tools/release.sh --embed-key <公钥文件>   # 配置发布公钥（写 keys/ 与 install.sh 内嵌区块，只留这一把）
#   bash tools/release.sh --embed-key <新公钥文件> --keep-old
#                                                  # 换钥过渡：新公钥 + 现有 keys/ 里的旧公钥并存
#   bash tools/release.sh --bump <tag>             # 把 install.sh 默认版本、lib/system/args.sh 的
#                                                  # DEBNAS_VERSION 与 README 安装命令改为 <tag>
#   bash tools/release.sh --sync-verify            # 把 lib/system/installer.sh 的共用区块同步到 install.sh
#   bash tools/release.sh --sync-download          # 同上（下载/解压区块）；两个参数同步全部共用区块
#   bash tools/release.sh --check-keys             # 检查 install.sh 内嵌公钥与 keys/ 是否一致（支持多把）
#   bash tools/release.sh <tag> <GPG 密钥 ID>       # 生成发布产物到 dist/<tag>/、签名并自检，
#                                                  # 并生成版本指针 LATEST / LATEST.asc
#   bash tools/release.sh --sign-latest <tag> <GPG 密钥 ID>
#                                                  # 单独（重新）生成版本指针 LATEST / LATEST.asc
#
# 共用代码单一来源：lib/system/installer.sh 中的 DEBNAS-RELEASE-VERIFY（发布产物校验）、
#   DEBNAS-DOWNLOAD（下载与解压）与 DEBNAS-DEPLOY（安装目录整树替换 + 更新锁 + 全局命令包装脚本）区块；
#   install.sh 必须自包含，其中的同名区块由 --embed-key / --bump / --sync-verify / --sync-download 同步生成，
#   构建发布时检查 tag 内两份是否一致。
#
# 版本指针：仓库根的 LATEST（一行 tag）与 LATEST.asc（发布密钥对它的分离签名）。debnas update 从
#   main 分支 raw 地址取这两个文件，用已安装目录 keys/ 里的公钥验签后才采用其中的版本号；
#   两个文件都取不到时回退读 main 分支 install.sh 的 DEBNAS_RELEASE_TAG（未签名，只升不降）。
#   它们不进发布包（.gitattributes export-ignore）：tag 打出来时仓库里的 LATEST 还是上一个版本。
#
# ==================== 首次发布流程（完整步骤） ====================
# 1. 生成发布密钥（在可信、最好离线的机器上；主密钥只做认证，日常签名用子密钥）:
#      gpg --quick-gen-key "DebNAS Release <邮箱>" ed25519 cert 3y
#      gpg --quick-add-key <主密钥指纹> ed25519 sign 1y
#    - 设强口令；离线备份主密钥私钥（gpg --export-secret-keys --armor）与吊销证书
#      （~/.gnupg/openpgp-revocs.d/<指纹>.rev）。发布机上只保留签名子钥
#      （gpg --export-secret-subkeys 导出后在发布机导入）。
#    - 子钥到期前用主密钥续期（gpg --quick-set-expire <主指纹> 1y '*'），续期后重新 --embed-key。
# 2. 内嵌公钥:
#      gpg --armor --export-options export-minimal --export <主密钥指纹> > /tmp/debnas-release.asc
#      bash tools/release.sh --embed-key /tmp/debnas-release.asc
#    写 keys/debnas-release.asc、keys/debnas-release.fpr 与 install.sh 内嵌区块；核对打印的指纹后提交
#    （git add keys/ install.sh && git commit），并把指纹公布在 README/项目主页供用户交叉核对。
# 3. 改版本号（先 bump 再打 tag，tag 内 install.sh 默认安装的才是它自己这个版本）:
#      bash tools/release.sh --bump vX.Y.Z      # install.sh 默认版本 + args.sh DEBNAS_VERSION + README
#      git commit -am "chore(release): vX.Y.Z"
# 4. 打附注 tag（轻量 tag 会被拒绝）:
#      git tag -a vX.Y.Z -m "vX.Y.Z"
# 5. 构建、签名、自检:
#      bash tools/release.sh vX.Y.Z <签名密钥 ID 或指纹>
#    检查工作区干净、tag 为附注 tag、tag 内 install.sh 与 lib 共用区块一致、内嵌公钥与 tag 内 keys/ 一致、
#    签名密钥属于内嵌公钥；产物输出到 dist/vX.Y.Z/，并用 tag 内 install.sh 的验证函数走一遍用户侧验证。
#    正式版本（非 rc/beta）还会在工作区生成 LATEST / LATEST.asc（先不要提交推送，见第 8 步）。
# 6. 推送并上传四个文件（debnas-vX.Y.Z.tar.gz、install.sh、SHA256SUMS、SHA256SUMS.asc）:
#      git push && git push origin vX.Y.Z（以及 Gitee 远端：git push gitee main vX.Y.Z）
#      GitHub：gh release create vX.Y.Z --verify-tag dist/vX.Y.Z/*（或网页 Releases 上传）
#      Gitee：仓库页 → 发行版 → 创建发行版 → 选同一 tag → 上传同样四个附件
# 7. 核实下载路径（脚本末尾会打印 wget … | diff 命令）:
#    Gitee 附件路径 https://gitee.com/kekylin/debnas/releases/download/<tag>/<file> 是推测格式，
#    首次发布必须实测；不一致时同步修改 install.sh 的 RELEASE_CN_BASE 与
#    lib/system/installer.sh 的 DEBNAS_RELEASE_CN_BASE，然后从第 3 步重新发版。
# 8. 两个平台的附件都能下载之后，提交并推送版本指针（用户的 debnas update 由此发现新版本）:
#      git add LATEST LATEST.asc && git commit -m "chore(release): LATEST → vX.Y.Z" && git push
#    （以及 Gitee 远端）。先推指针后传附件会让 update 找到一个还下载不到的版本。
#    main 分支 install.sh 的 DEBNAS_RELEASE_TAG 仍要保持最新：它是取不到 LATEST 时的回退来源，
#    也是 v2026.11.0 及更早版本发现新版本的唯一来源。
# 9. 老用户升级：签名发布之前安装的机器没有 keys/ 与 RELEASE 标记，debnas update 会拒绝签名更新。
#    需过渡一次：重新执行新 tag 的 install.sh（推荐，同时刷新 /usr/local/bin/debnas 包装脚本），
#    或 debnas update --unsigned（不校验地拉取 main 分支，之后的更新即走签名校验）。请在 CHANGELOG/README 公告。
#
# ==================== 更换发布密钥（平滑过渡，两个版本完成） ====================
# 现象：用户机器上的 debnas update 只信任它已安装目录里的 keys/。直接换成新钥发版，
#   老用户手里只有旧公钥，验不过新钥签的包。所以要先发一个"两把都认"的过渡版。
# A. 过渡版 vN（仍用旧钥签名）:
#      gpg --armor --export-options export-minimal --export <新主密钥指纹> > /tmp/new.asc
#      bash tools/release.sh --embed-key /tmp/new.asc --keep-old
#    结果：keys/debnas-release.asc 与 install.sh 内嵌区块含新旧两把公钥，keys/debnas-release.fpr 两行，
#    install.sh 的 DEBNAS_RELEASE_KEY_FPR 为逗号分隔的两个指纹。提交后按上面第 3–8 步发版，
#    第 5 步与 LATEST 都用**旧钥**签名（老用户只认旧钥）。升级到 vN 的用户从此两把都认。
# B. 下一个版本 vN+1（改用新钥签名，同时移除旧钥）:
#      bash tools/release.sh --embed-key /tmp/new.asc          # 不带 --keep-old：只留新钥
#    提交后发版，第 5 步与 LATEST 用**新钥**签名。已升级到 vN 的用户能验过（它们认新钥）；
#    还停在 vN 之前的用户验不过，需要先 debnas update --tag vN 再更新，或重新执行 install.sh
#    —— 在 CHANGELOG / README 公告，并让 vN 存在足够久再发 vN+1。
#    注意 LATEST 一旦改用新钥签名，vN 之前的用户自动更新会报"LATEST 签名校验未通过"，同样按上面处理。
# 私钥泄露：没有过渡期可言。立即发布吊销证书，用新密钥 --embed-key（不带 --keep-old）并发版；
#   已安装用户需重新执行新 tag 的 install.sh。
#
# 发布产物（每个 tag）:
#   debnas-<tag>.tar.gz   git archive --prefix=debnas/ <tag>（内容与 tag 一致；tests/、docs/、tools/、
#                         .github/ 等按 .gitattributes 的 export-ignore 不进包，keys/ 必须在包里）
#   install.sh            tag 内的 install.sh（供谨慎用户手动核验引导脚本）
#   SHA256SUMS            以上两个文件的 sha256
#   SHA256SUMS.asc        对 SHA256SUMS 的 GPG 分离签名（ASCII armor）
# （docs/MAINTENANCE.md「发布流程」有更详细的说明）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
README_MD="${REPO_ROOT}/README.md"
KEY_ASC="${REPO_ROOT}/keys/debnas-release.asc"
KEY_FPR="${REPO_ROOT}/keys/debnas-release.fpr"
LATEST_FILE="${REPO_ROOT}/LATEST"
LATEST_SIG="${REPO_ROOT}/LATEST.asc"
MARK_BEGIN="# >>> DEBNAS-RELEASE-PUBKEY-BEGIN"
MARK_END="# <<< DEBNAS-RELEASE-PUBKEY-END"
LIB_INSTALLER="${REPO_ROOT}/lib/system/installer.sh"
ARGS_SH="${REPO_ROOT}/lib/system/args.sh"

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
  # 打印文件头注释（第 2 行起到第一个非注释行为止）
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# ==================== 共用区块同步（--sync-verify / --sync-download） ====================
# install.sh 必须自包含，其中与 lib/system/installer.sh 共用的代码以区块形式内嵌：
#   DEBNAS-RELEASE-VERIFY  发布产物签名/SHA256 校验
#   DEBNAS-DOWNLOAD        下载与解压（release_fetch / release_fetch_assets / release_extract）
#   DEBNAS-DEPLOY          安装目录整树替换（暂存 → 切换 → 回滚）与更新锁
SHARED_BLOCKS=(DEBNAS-RELEASE-VERIFY DEBNAS-DOWNLOAD DEBNAS-DEPLOY)

# 输出文件中某区块（含起止标记行；标记行之后的说明文字不计入比较）
# 参数：$1 - 文件  $2 - 区块名（默认 DEBNAS-RELEASE-VERIFY）
extract_verify_block() {
  local name="${2:-DEBNAS-RELEASE-VERIFY}"
  awk -v mb="# >>> ${name}-BEGIN" -v me="# <<< ${name}-END" '
    index($0, mb) == 1 { p = 1; print mb; next }
    index($0, me) == 1 { if (p) print me; p = 0; next }
    p { print }' "$1"
}

# 检查文件中起止标记各恰好一个
# 参数：$1 - 文件  $2 - 显示名  $3 - 区块名（默认 DEBNAS-RELEASE-VERIFY）
check_verify_marks() {
  local name="${3:-DEBNAS-RELEASE-VERIFY}" n_begin n_end
  n_begin=$(grep -c "^# >>> ${name}-BEGIN" "$1" || true)
  n_end=$(grep -c "^# <<< ${name}-END" "$1" || true)
  [[ "$n_begin" -eq 1 && "$n_end" -eq 1 ]] || die "$2 中 ${name} 区块标记应各有 1 个（起 ${n_begin}，止 ${n_end}）"
}

# 用 lib/system/installer.sh 的各共用区块替换 install.sh 中的同名区块（内容相同则不写）
sync_verify_block() {
  [[ -f "$LIB_INSTALLER" ]] || die "找不到 ${LIB_INSTALLER}（共用区块的单一来源）"
  local name
  for name in "${SHARED_BLOCKS[@]}"; do
    check_verify_marks "$LIB_INSTALLER" "lib/system/installer.sh" "$name"
    check_verify_marks "$INSTALL_SH" "install.sh" "$name"
  done
  local tmpd block new_install cur
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/debnas-sync.XXXXXX")
  block="${tmpd}/block"
  new_install="${tmpd}/install.sh"
  cur="${tmpd}/cur.sh"
  cp -- "$INSTALL_SH" "$cur"
  for name in "${SHARED_BLOCKS[@]}"; do
    # lib 中的起始标记行带说明文字，install.sh 中保持同一行（整行复制）
    awk -v mb="# >>> ${name}-BEGIN" -v me="# <<< ${name}-END" '
      index($0, mb) == 1 { p = 1 }
      p { print }
      index($0, me) == 1 { p = 0 }' "$LIB_INSTALLER" > "$block"
    awk -v bf="$block" -v mb="# >>> ${name}-BEGIN" -v me="# <<< ${name}-END" '
      index($0, mb) == 1 { while ((getline l < bf) > 0) print l; close(bf); skip = 1; next }
      index($0, me) == 1 && skip { skip = 0; next }
      !skip { print }' "$cur" > "$new_install"
    cp -- "$new_install" "$cur"
  done
  if ! bash -n "$new_install"; then
    rm -rf -- "${tmpd:?}"
    die "同步后的 install.sh 语法错误，未写入"
  fi
  if cmp -s "$new_install" "$INSTALL_SH"; then
    rm -rf -- "${tmpd:?}"
    info "install.sh 共用区块（发布校验 + 下载 + 部署）已与 lib/system/installer.sh 一致"
    return 0
  fi
  cat "$new_install" > "$INSTALL_SH"
  rm -rf -- "${tmpd:?}"
  ok "已把 lib/system/installer.sh 的共用区块（发布校验 + 下载 + 部署）同步到 install.sh"
}

# ==================== --embed-key ====================

# 参数：$1 - 新公钥文件（恰好一把主密钥）
#       $2 - 1 = 保留 keys/ 里现有的旧公钥（换钥过渡期新旧并存；新钥排第一），默认 0 = 只留新钥
embed_key() {
  local keyfile="${1:-}" keep_old="${2:-0}"
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

  # 要写入的主密钥指纹：新钥在前；--keep-old 时后接 keys/ 里现有的其他指纹
  local -a fprs=("$fpr")
  if [[ "$keep_old" -eq 1 ]]; then
    [[ -f "$KEY_ASC" && -f "$KEY_FPR" ]] || die "--keep-old 需要现有的 keys/debnas-release.asc 与 keys/debnas-release.fpr"
    local old_list old old_validity
    old_list=$(read_fpr_file "$KEY_FPR") || die "现有指纹文件格式错误：${KEY_FPR}"
    gpg --homedir "$home" --batch --quiet --import "$KEY_ASC" 2>/dev/null || die "导入现有 keys/debnas-release.asc 失败"
    while IFS= read -r old; do
      [[ -n "$old" && "$old" != "$fpr" ]] || continue
      old_validity=$(gpg --homedir "$home" --batch --with-colons --list-keys "$old" 2>/dev/null \
        | awk -F: '$1 == "pub" { print $2; exit }') || old_validity=""
      [[ -n "$old_validity" ]] || die "现有 keys/debnas-release.asc 中没有指纹文件列出的公钥 ${old}"
      case "$old_validity" in
        r) die "旧密钥 ${old} 已吊销，不能保留（私钥泄露时不要用 --keep-old）" ;;
        e) warn "旧密钥 ${old} 已过期：它签的产物本来就验不过，保留没有意义" ;;
      esac
      fprs+=("$old")
    done < <(tr ',' '\n' <<<"$old_list")
    if [[ "${#fprs[@]}" -eq 1 ]]; then
      warn "现有 keys/ 中没有与新钥不同的旧公钥，--keep-old 无效果"
    fi
  fi

  local norm="${_TMP}/norm.asc" bin="${_TMP}/norm.gpg" f
  : > "$norm"; : > "$bin"
  for f in "${fprs[@]}"; do
    gpg --homedir "$home" --batch --armor --export-options export-minimal --export "$f" >> "$norm"
    gpg --homedir "$home" --batch --export-options export-minimal --export "$f" >> "$bin"
  done
  [[ -s "$norm" && -s "$bin" ]] || die "导出规范化公钥失败"
  [[ "$(grep -c '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$norm" || true)" -eq "${#fprs[@]}" ]] || die "导出规范化公钥失败（公钥块数量不符）"
  if grep -q "'" "$norm"; then
    die "规范化公钥中含单引号，无法内嵌（异常的 armor 头）"
  fi
  local fpr_csv
  fpr_csv=$(IFS=','; printf '%s' "${fprs[*]}")

  # 写 keys/
  mkdir -p "$(dirname "$KEY_ASC")"
  cat "$norm" > "$KEY_ASC"
  printf '%s\n' "${fprs[@]}" > "$KEY_FPR"

  # 写 install.sh 内嵌区块（只替换两个标记之间的内容）
  grep -q "^${MARK_BEGIN}" "$INSTALL_SH" || die "install.sh 中找不到内嵌公钥起始标记"
  grep -q "^${MARK_END}" "$INSTALL_SH" || die "install.sh 中找不到内嵌公钥结束标记"
  local block="${_TMP}/block"
  {
    echo "# 发布公钥主密钥指纹（大写十六进制无空格）与 ASCII armor 公钥（与 keys/debnas-release.asc 一致）"
    echo "# 两者为空 = 维护者尚未配置发布公钥，签名安装不可用"
    echo "# 换钥过渡期：指纹为逗号分隔的多个（新钥在前），公钥为依次排列的多个公钥块，任一把签的产物都能通过"
    printf 'readonly DEBNAS_RELEASE_KEY_FPR="%s"\n' "$fpr_csv"
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
    _ "$INSTALL_SH" "${_TMP}/embedded.gpg" "$fpr_csv" || die "自检失败：install.sh 内嵌公钥无法解码或指纹不符"
  cmp -s "${_TMP}/embedded.gpg" "$bin" || die "自检失败：内嵌公钥解码结果与原公钥不一致"

  ok "已写入 keys/debnas-release.asc、keys/debnas-release.fpr 与 install.sh 内嵌区块"
  ok "主密钥指纹: ${fpr}"
  if [[ "${#fprs[@]}" -gt 1 ]]; then
    ok "同时保留旧公钥: $(IFS=' '; printf '%s' "${fprs[*]:1}")"
    info "过渡版请继续用旧钥签名发布；下一个版本再执行不带 --keep-old 的 --embed-key 移除旧钥并改用新钥签名"
  fi
  info "请核对指纹无误后提交：git add keys/ install.sh && git commit -m 'chore(release): 配置发布公钥'"
}

# ==================== 公钥一致性检查（--check-keys） ====================

# 读取指纹文件：每行一个主密钥指纹（行内空格忽略、大小写不敏感；空行与 # 注释跳过）。
# 支持多行是为密钥轮换留口子：新旧两把主密钥并存期间，任一指纹匹配即可通过校验
# 参数：$1 - 指纹文件
# 输出：逗号分隔的大写指纹列表；返回：1 文件中有非法行或没有指纹
read_fpr_file() {
  local line out=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    line="${line^^}"
    [[ "$line" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || return 1
    out="${out:+${out},}${line}"
  done < "$1"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# 逗号分隔的指纹列表 → 排序后的逐行列表（用于不计顺序的集合比较）
sorted_fprs() {
  tr ',' '\n' <<<"${1:-}" | sort -u
}

# 检查 install.sh 内嵌公钥与 keys/ 副本一致（单把或换钥过渡期的多把）：
#   - 内嵌指纹集合 = 指纹文件中的指纹集合；
#   - 两份公钥解码后的二进制完全相同；
#   - 本机有 gpg 时：公钥文件里实际包含的主密钥 = 指纹文件列出的主密钥（不多不少）
# 参数：$1 - install.sh  $2 - keys/debnas-release.asc  $3 - keys/debnas-release.fpr
# 输出：内嵌指纹（逗号分隔）；不一致时 die
check_keys() {
  local inst="$1" asc="$2" fprf="$3" emb_fpr file_fprs tmpd
  [[ -f "$inst" && -f "$asc" && -f "$fprf" ]] || die "缺少文件：${inst} / ${asc} / ${fprf}"
  emb_fpr=$(sed -n 's/^readonly DEBNAS_RELEASE_KEY_FPR="\([^"]*\)"$/\1/p' "$inst" | head -n 1)
  emb_fpr="${emb_fpr//[[:space:]]/}"; emb_fpr="${emb_fpr^^}"
  [[ -n "$emb_fpr" ]] || die "install.sh 未内嵌发布公钥：先 --embed-key 并提交（构建发布时还需重新打 tag）"
  [[ "$emb_fpr" =~ ^([0-9A-F]{40}|[0-9A-F]{64})(,([0-9A-F]{40}|[0-9A-F]{64}))*$ ]] || die "install.sh 内嵌指纹格式错误：${emb_fpr}"
  file_fprs=$(read_fpr_file "$fprf") || die "指纹文件格式错误（每行一个 40/64 位十六进制主密钥指纹）：${fprf}"
  if [[ "$(sorted_fprs "$emb_fpr")" != "$(sorted_fprs "$file_fprs")" ]]; then
    die "install.sh 内嵌指纹（${emb_fpr}）与 keys/debnas-release.fpr（${file_fprs}）不一致（应由 --embed-key 同时生成）"
  fi
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/debnas-keys.XXXXXX")
  if ! bash -c 'source "$1" && dearmor_pubkey "$DEBNAS_RELEASE_PUBKEY" "$2" && release_dearmor "$3" < "$4"' \
      _ "$inst" "${tmpd}/emb.gpg" "${tmpd}/asc.gpg" "$asc"; then
    rm -rf -- "${tmpd:?}"
    die "无法解码 install.sh 内嵌公钥或 keys/debnas-release.asc"
  fi
  if ! cmp -s "${tmpd}/emb.gpg" "${tmpd}/asc.gpg"; then
    rm -rf -- "${tmpd:?}"
    die "keys/debnas-release.asc 与 install.sh 内嵌公钥不一致（应由 --embed-key 同时生成）"
  fi
  if command -v gpg >/dev/null 2>&1; then
    local actual
    mkdir -m 700 "${tmpd}/gnupg"
    actual=$(gpg --homedir "${tmpd}/gnupg" --batch --with-colons --show-keys "${tmpd}/asc.gpg" 2>/dev/null \
      | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print toupper($10); p = 0 }' | sort -u) || actual=""
    if [[ "$actual" != "$(sorted_fprs "$file_fprs")" ]]; then
      rm -rf -- "${tmpd:?}"
      die "keys/debnas-release.asc 实际包含的主密钥（$(tr '\n' ' ' <<<"$actual")）与 keys/debnas-release.fpr（${file_fprs}）不一致"
    fi
  fi
  rm -rf -- "${tmpd:?}"
  printf '%s\n' "$emb_fpr"
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
  # 代码版本号（debnas --version、迁移、update 缺少 RELEASE 标记时的防降级基准）与发布 tag 统一
  grep -q '^readonly DEBNAS_VERSION="${DEBNAS_VERSION:-[^"]*}"$' "$ARGS_SH" || die "lib/system/args.sh 中找不到 DEBNAS_VERSION 常量"
  sed -i "s/^readonly DEBNAS_VERSION=\"\${DEBNAS_VERSION:-[^\"]*}\"$/readonly DEBNAS_VERSION=\"\${DEBNAS_VERSION:-${tag}}\"/" "$ARGS_SH"
  grep -q "^readonly DEBNAS_VERSION=\"\${DEBNAS_VERSION:-${tag}}\"$" "$ARGS_SH" || die "更新 DEBNAS_VERSION 失败"
  ok "install.sh 默认版本、lib/system/args.sh 的 DEBNAS_VERSION 与 README 安装命令已改为 ${tag}"
}

# ==================== 版本指针（--sign-latest） ====================

# 正式版本号（v1.2.3 / 2026.11.0）；带 -rc1、~beta 等后缀的预发布版本不应成为"最新稳定版本"
is_stable_tag() {
  [[ "${1:-}" =~ ^[vV]?[0-9]+(\.[0-9]+)*$ ]]
}

# 生成仓库根的 LATEST（一行 tag）与 LATEST.asc（分离签名），并用 lib 的验证函数自检
# 参数：$1 - tag  $2 - GPG 密钥 ID（主密钥须在 keys/debnas-release.fpr 之内）
sign_latest() {
  local tag="${1:-}" keyid="${2:-}"
  valid_tag "$tag" || die "非法的 tag: ${tag}"
  [[ -n "$keyid" ]] || die "缺少 GPG 密钥 ID"
  need_cmd gpg gpgv awk base64
  [[ -f "$KEY_ASC" && -f "$KEY_FPR" ]] || die "缺少 keys/debnas-release.asc / .fpr：先 --embed-key"
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/${tag}" >/dev/null || die "tag 不存在: ${tag}（LATEST 只能指向已发布的版本）"
  fi

  local file_fprs sign_fpr
  file_fprs=$(read_fpr_file "$KEY_FPR") || die "指纹文件格式错误：${KEY_FPR}"
  sign_fpr=$(gpg --batch --with-colons --list-secret-keys -- "$keyid" 2>/dev/null \
    | awk -F: '$1 == "sec" { p = 1; next } p && $1 == "fpr" { print toupper($10); exit }') || sign_fpr=""
  [[ -n "$sign_fpr" ]] || die "本机 keyring 中找不到密钥 ${keyid} 的私钥"
  [[ ",${file_fprs}," == *",${sign_fpr},"* ]] || die "签名密钥 ${sign_fpr} 不在 keys/debnas-release.fpr（${file_fprs}）中"

  [[ -n "$_TMP" ]] || make_tmp
  local work="${_TMP}/latest"
  rm -rf -- "${work:?}"
  mkdir -p "$work"
  printf '%s\n' "$tag" > "${work}/LATEST"
  info "签名 LATEST（可能弹出密码输入）"
  gpg --local-user "$keyid" --detach-sign --armor --output "${work}/LATEST.asc" "${work}/LATEST" \
    || die "签名 LATEST 失败"

  # 自检：与 debnas update 相同的验证路径（keys/ 公钥 → keyring → installer_verify_latest）
  local got
  got=$(bash -c 'source "$1" && release_dearmor "$2" < "$3" && installer_verify_latest "$4" "$2" "$5"' \
    _ "$LIB_INSTALLER" "${work}/keyring.gpg" "$KEY_ASC" "$work" "$file_fprs") || die "自检失败：LATEST 无法通过 debnas update 的验证"
  [[ "$got" == "$tag" ]] || die "自检失败：LATEST 解析结果 '${got}' 与 ${tag} 不符"

  cat "${work}/LATEST" > "$LATEST_FILE"
  cat "${work}/LATEST.asc" > "$LATEST_SIG"
  ok "已生成 LATEST（${tag}）与 LATEST.asc（签名者 ${sign_fpr}）"
  info "确认 ${tag} 的发布附件在 GitHub 与 Gitee 都能下载之后再提交推送："
  info "  git add LATEST LATEST.asc && git commit -m 'chore(release): LATEST → ${tag}' && git push"
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
  local blk
  for blk in "${SHARED_BLOCKS[@]}"; do
    check_verify_marks "$tag_lib" "tag 内 lib/system/installer.sh" "$blk"
    check_verify_marks "$tag_install" "tag 内 install.sh" "$blk"
    if ! cmp -s <(extract_verify_block "$tag_lib" "$blk") <(extract_verify_block "$tag_install" "$blk"); then
      die "tag ${tag} 中 install.sh 的 ${blk} 区块与 lib/system/installer.sh 不一致：先 --sync-verify 并提交，再重新打 tag"
    fi
  done

  # tag 内 install.sh 的内嵌公钥就是用户实际用来验证的公钥；tag 内 keys/ 是 debnas update 用的副本，两者必须一致
  local emb_fpr tag_default tag_asc="${_TMP}/tag-key.asc" tag_fprf="${_TMP}/tag-key.fpr"
  git show "${tag}:keys/debnas-release.asc" > "$tag_asc" 2>/dev/null || die "tag 中没有 keys/debnas-release.asc"
  git show "${tag}:keys/debnas-release.fpr" > "$tag_fprf" 2>/dev/null || die "tag 中没有 keys/debnas-release.fpr"
  emb_fpr=$(check_keys "$tag_install" "$tag_asc" "$tag_fprf") || exit 1

  # 签名密钥必须就是内嵌公钥（主密钥指纹比对）
  local sign_fpr
  sign_fpr=$(gpg --batch --with-colons --list-secret-keys -- "$keyid" 2>/dev/null \
    | awk -F: '$1 == "sec" { p = 1; next } p && $1 == "fpr" { print toupper($10); exit }') || sign_fpr=""
  [[ -n "$sign_fpr" ]] || die "本机 keyring 中找不到密钥 ${keyid} 的私钥"
  [[ ",${emb_fpr}," == *",${sign_fpr},"* ]] || die "签名密钥 ${sign_fpr} 不在 install.sh 内嵌公钥指纹（${emb_fpr}）中"

  # 代码版本号与 tag 一致（--bump 会一起改）
  local tag_ver
  tag_ver=$(git show "${tag}:lib/system/args.sh" 2>/dev/null | sed -n 's/^readonly DEBNAS_VERSION="${DEBNAS_VERSION:-\([^"]*\)}"$/\1/p' | head -n 1)
  if [[ "$tag_ver" != "$tag" ]]; then
    warn "tag ${tag} 内 lib/system/args.sh 的 DEBNAS_VERSION 是 '${tag_ver}'（应为 ${tag}，建议 --bump ${tag} → 提交 → 重新打 tag）"
  fi

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
  # keys/ 是 debnas update 的信任根，必须随包分发（.gitattributes 的 export-ignore 不能把它排除掉）
  tar -tzf "${outdir}/${name}" | grep -x 'debnas/keys/debnas-release.asc' >/dev/null || die "归档内容异常：缺少 debnas/keys/debnas-release.asc（检查 .gitattributes）"
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

  # 版本指针：正式版本生成 LATEST / LATEST.asc（工作区文件，待附件上传后再提交推送）
  local cur_latest="" latest_note="（本次未生成，如需要：bash tools/release.sh --sign-latest ${tag} <密钥 ID>）"
  [[ -f "$LATEST_FILE" ]] && cur_latest=$(head -n 1 "$LATEST_FILE")
  if ! is_stable_tag "$tag"; then
    info "${tag} 是预发布版本，不更新版本指针 LATEST"
  elif [[ -n "$cur_latest" && "$cur_latest" != "$tag" \
      && "$(printf '%s\n%s\n' "${cur_latest#[vV]}" "${tag#[vV]}" | sort -V | tail -n 1)" == "${cur_latest#[vV]}" ]]; then
    warn "LATEST 当前为 ${cur_latest}，不低于 ${tag}，未改动（确需指向 ${tag}：--sign-latest ${tag} <密钥 ID>）"
  else
    sign_latest "$tag" "$keyid"
    latest_note=""
  fi

  # 更新工作区 install.sh 默认版本（main 分支的 install.sh 是取不到 LATEST 时发现新版本的回退来源）
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

4) 提交并推送 main 上 install.sh 的默认版本变更（如上一步有提示）。

5) 两个平台的附件都核验可下载之后，提交并推送版本指针，用户的 debnas update 才会发现新版本：
   git add LATEST LATEST.asc && git commit -m "chore(release): LATEST → ${tag}" && git push
   ${latest_note}
EOF
}

# ==================== 入口 ====================

main() {
  case "${1:-}" in
    --embed-key)
      if [[ $# -eq 3 && "$3" == "--keep-old" ]]; then
        embed_key "$2" 1
      elif [[ $# -eq 2 ]]; then
        embed_key "$2" 0
      else
        die "用法: tools/release.sh --embed-key <公钥文件> [--keep-old]"
      fi
      ;;
    --sign-latest)
      [[ $# -eq 3 ]] || die "用法: tools/release.sh --sign-latest <tag> <GPG 密钥 ID>"
      sign_latest "$2" "$3"
      ;;
    --bump)
      [[ $# -eq 2 ]] || die "用法: tools/release.sh --bump <tag>"
      bump_tag "$2"
      ;;
    --sync-verify|--sync-download)
      [[ $# -eq 1 ]] || die "用法: tools/release.sh ${1}"
      sync_verify_block
      ;;
    --check-keys)
      [[ $# -eq 1 ]] || die "用法: tools/release.sh --check-keys"
      check_keys "$INSTALL_SH" "$KEY_ASC" "$KEY_FPR" >/dev/null
      ok "install.sh 内嵌公钥与 keys/ 一致"
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
