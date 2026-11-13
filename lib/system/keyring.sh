#!/bin/bash
# 功能：第三方 APT 源公钥的下载、指纹校验与安装（统一 docker-ce / cockpit-45drives / tailscale 的三份实现）
# 说明：
#   gpg_key_fingerprint_verify  临时 GNUPGHOME 解析公钥，要求恰好一把主密钥且主密钥指纹等于期望值
#   keyring_install_verified    带超时下载（失败重试 1 次）→ 校验 → 临时 GNUPGHOME 导入后 export-minimal 导出
#                               （--dearmor 存二进制，否则保持下载格式）→ 再校验
#                               → 内容相同跳过 → 同目录临时文件 mv -fT 原子替换（不截断已有 keyring）
#   apt 之后用钉死的 keyring 校验 Release 签名：镜像站/下载地址被篡改也无法替换软件包。
# 依赖: core/logging.sh、system/tempfile.sh（create_temp_file/create_temp_dir）；
#       system/backup.sh、system/manifest.sh 可选（存在时替换前备份旧 keyring 并登记清单）

set -euo pipefail
IFS=$'\n\t'

# 规范化指纹：去空白、转大写
# 参数：$1 - 指纹
# 输出：规范化后的指纹（格式非法时输出空）
_keyring_normalize_fpr() {
  local fpr="${1:-}"
  fpr="${fpr//[[:space:]]/}"
  fpr="${fpr^^}"
  [[ "$fpr" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || fpr=""
  printf '%s' "$fpr"
}

# 校验公钥文件的主密钥指纹
# 参数：$1 - 公钥文件（ASCII armored 或二进制均可）
#       $2 - 期望的主密钥指纹（40/64 位十六进制，大小写/空格不敏感）
#       $3 - 显示名称（可选，用于日志，如 "Docker"）
# 返回：0 恰好一把主密钥且指纹相等；1 其他情况（含无 gpg、文件含私钥、密钥已吊销、多把主密钥）
# 说明：使用临时 GNUPGHOME，不读写任何用户 keyring；只比对主密钥指纹（子密钥指纹不算）
gpg_key_fingerprint_verify() {
  local key_file="${1:?gpg_key_fingerprint_verify: 缺少公钥文件}"
  local expected label="${3:-}" gpg_home colons line npub=0 want=0 fpr="" validity=""
  local -a f=()
  expected=$(_keyring_normalize_fpr "${2:-}")
  label="${label:+${label} }"

  if [[ -z "$expected" ]]; then
    log_error "${label}GPG 公钥期望指纹格式无效：${2:-（空）}"
    return 1
  fi
  if [[ ! -s "$key_file" ]]; then
    log_error "${label}GPG 公钥文件不存在或为空：${key_file}"
    return 1
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    log_error "缺少 gpg 命令，无法校验${label}公钥指纹（apt install gnupg）"
    return 1
  fi

  gpg_home=$(create_temp_dir "gpg-verify") || return 1
  colons=$(gpg --homedir "$gpg_home" --batch --quiet --no-autostart --show-keys --with-colons "$key_file" 2>/dev/null) || colons=""
  [[ -n "$gpg_home" ]] && rm -rf -- "$gpg_home"

  # --with-colons：pub 行之后的第一条 fpr 为主密钥指纹（sub 之后的 fpr 属于子密钥，跳过）
  while IFS= read -r line; do
    IFS=':' read -r -a f <<< "$line"
    case "${f[0]:-}" in
      sec | ssb)
        log_error "${label}公钥文件包含私钥，拒绝使用：${key_file}"
        return 1
        ;;
      pub)
        npub=$((npub + 1))
        validity="${f[1]:-}"
        want=1
        ;;
      sub)
        want=0
        ;;
      fpr)
        if (( want )); then
          fpr="${f[9]:-}"
          want=0
        fi
        ;;
    esac
  done <<< "$colons"

  if (( npub != 1 )); then
    log_error "${label}GPG 公钥文件必须恰好包含一把主密钥（实际 ${npub} 把），拒绝使用"
    return 1
  fi
  if [[ "$validity" == "r" || "$validity" == "e" || "$validity" == "d" || "$validity" == "i" ]]; then
    log_error "${label}GPG 公钥不可用（已吊销/过期/禁用/无效），拒绝使用"
    return 1
  fi
  if [[ "${fpr^^}" != "$expected" ]]; then
    log_error "${label}GPG 公钥指纹不匹配（期望 ${expected}，实际 ${fpr:-无}），拒绝使用"
    return 1
  fi
  return 0
}

# 下载并安装经指纹校验的 APT keyring
# 用法：keyring_install_verified <url> <expected_fpr> <dest_keyring> [--dearmor] [--label <名称>]
#   --dearmor        目标存二进制 keyring（.gpg）：下载到 ASCII armored 时转换，已是二进制则原样使用
#   不加 --dearmor   按下载内容原样存放；目标以 .asc 结尾时要求下载内容为 ASCII armored
#   --label          日志中的显示名称（如 Docker / 45Drives / Tailscale）
# 返回：0 已安装或内容未变；1 失败（任何一步失败都不动已有 keyring）
# 说明：curl 带 --max-time/--connect-timeout、只允许 http(s)、限制 1MB，失败重试 1 次；
#       校验在原始下载物与最终写入物上各做一次；替换前旧 keyring 经 debnas_backup_file 集中备份，
#       写入后 manifest_add 登记（两者在 bootstrap-core 中已加载，单独 source 本文件时自动跳过）；
#       调用方负责事先安装 curl / gnupg（本函数缺命令时报错返回，不自动安装）
keyring_install_verified() {
  local url="${1:-}" expected="${2:-}" dest="${3:-}"
  local dearmor=0 label=""
  if [[ $# -lt 3 ]]; then
    log_error "用法：keyring_install_verified <url> <expected_fpr> <dest_keyring> [--dearmor] [--label <名称>]"
    return 1
  fi
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dearmor) dearmor=1 ;;
      --label)
        shift
        [[ $# -ge 1 ]] || { log_error "keyring_install_verified: --label 需要一个名称"; return 1; }
        label="$1"
        ;;
      *) log_error "keyring_install_verified: 未知参数 $1"; return 1 ;;
    esac
    shift
  done
  local name="${label:-GPG}"

  if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
    log_error "${name} 公钥下载地址不是合法的 http(s) 地址：${url}"
    return 1
  fi
  if [[ -z "$(_keyring_normalize_fpr "$expected")" ]]; then
    log_error "${name} 公钥期望指纹格式无效：${expected:-（空）}"
    return 1
  fi
  if [[ -z "$dest" || "$dest" != /* || "$dest" == */ ]]; then
    log_error "${name} keyring 目标路径必须是绝对文件路径：${dest:-（空）}"
    return 1
  fi
  local cmd
  for cmd in curl gpg; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "缺少 ${cmd} 命令，无法安装 ${name} 公钥"
      return 1
    fi
  done

  local tmp_dl tmp_out attempt downloaded=0
  tmp_dl=$(create_temp_file "keyring-dl" ".key") || return 1
  tmp_out=$(create_temp_file "keyring-out" ".gpg") || return 1
  for attempt in 1 2; do
    if curl -fsSL --proto '=https,http' --max-time 30 --connect-timeout 10 --max-filesize 1048576 \
      -o "$tmp_dl" -- "$url" 2>/dev/null && [[ -s "$tmp_dl" ]]; then
      downloaded=1
      break
    fi
    if [[ $attempt -eq 1 ]]; then
      log_warning "${name} GPG 公钥下载失败，重试中..."
      sleep 2
    fi
  done
  if [[ $downloaded -ne 1 ]]; then
    log_error "${name} GPG 公钥下载失败：${url}"
    return 1
  fi
  gpg_key_fingerprint_verify "$tmp_dl" "$expected" "$label" || return 1

  local armored=0
  grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$tmp_dl" 2>/dev/null && armored=1
  if [[ $dearmor -eq 0 && "$dest" == *.asc && $armored -eq 0 ]]; then
    log_error "${name} 公钥目标为 .asc，但下载内容不是 ASCII armored 格式：${url}"
    return 1
  fi
  # 不直接存下载到的原始字节：导入临时 GNUPGHOME 后按指纹导出 export-minimal 结果
  # （只含主密钥/子密钥与自签名，丢弃附带的其他数据包与第三方签名）；
  # --dearmor 存二进制，否则保持下载时的格式（armored 下载 → --armor，如 Docker 的 .asc）
  local gpg_home fpr_norm
  local -a armor_opt=()
  fpr_norm=$(_keyring_normalize_fpr "$expected")
  [[ $dearmor -eq 0 && $armored -eq 1 ]] && armor_opt=(--armor)
  gpg_home=$(create_temp_dir "gpg-export") || return 1
  if ! gpg --homedir "$gpg_home" --batch --quiet --no-autostart --import "$tmp_dl" >/dev/null 2>&1 \
    || ! gpg --homedir "$gpg_home" --batch --quiet --no-autostart --export --export-options export-minimal \
      "${armor_opt[@]}" -o "$tmp_out" --yes -- "$fpr_norm" 2>/dev/null; then
    [[ -n "$gpg_home" ]] && rm -rf -- "$gpg_home"
    log_error "${name} GPG 公钥导出（export-minimal）失败"
    return 1
  fi
  [[ -n "$gpg_home" ]] && rm -rf -- "$gpg_home"
  # 最终写入物再校验一次（防止转换环节出错）
  if [[ ! -s "$tmp_out" ]] || ! gpg_key_fingerprint_verify "$tmp_out" "$expected" "$label"; then
    log_error "${name} GPG 公钥校验失败，拒绝安装"
    return 1
  fi

  if [[ -f "$dest" ]] && cmp -s -- "$tmp_out" "$dest"; then
    log_info "${name} GPG 密钥未变更，跳过"
    return 0
  fi

  # 同目录临时文件 + rename 原子替换，不截断已有 keyring
  local dir="${dest%/*}" base="${dest##*/}" tmp_dst="" backup_rc=0
  [[ -n "$dir" ]] || dir="/"
  install -m 0755 -d -- "$dir" || return 1
  if [[ -f "$dest" ]] && declare -F debnas_backup_file >/dev/null 2>&1; then
    debnas_backup_file "$dest" || backup_rc=$?
    [[ "$backup_rc" -eq 1 ]] && log_warning "备份原 keyring 失败（继续写入）：${dest}"
  fi
  tmp_dst=$(mktemp -- "${dir}/.${base}.debnas.XXXXXX") || return 1
  if ! cat -- "$tmp_out" > "$tmp_dst" || ! chmod 644 -- "$tmp_dst" \
    || ! mv -fT -- "$tmp_dst" "$dest"; then
    [[ -n "$tmp_dst" ]] && rm -f -- "$tmp_dst"
    log_error "${name} GPG 密钥写入失败：${dest}"
    return 1
  fi
  if declare -F manifest_add >/dev/null 2>&1; then
    manifest_add "$dest" || true
  fi
  log_info "${name} GPG 密钥已更新（指纹 $(_keyring_normalize_fpr "$expected")）"
  return 0
}
