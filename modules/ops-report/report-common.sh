#!/bin/bash
# ops-report: 通用格式化与共享 helper（由 report.sh 加载）
set -euo pipefail
IFS=$'\n\t'

ops_format_bytes() {
  local value="${1:-0}"
  awk -v b="$value" '
    BEGIN {
      split("B KB MB GB TB", u, " ")
      v = b + 0
      i = 1
      while (v >= 1024 && i < 5) { v = v / 1024; i++ }
      printf "%.1f %s", v, u[i]
    }'
}

ops_pct_label() {
  local value="${1:-N/A}"
  if [[ "$value" =~ ^[0-9.]+$ ]]; then
    printf '%s%%' "$value"
  else
    printf '%s' "$value"
  fi
}

ops_normalize_date() {
  local value="$1"
  if [[ -z "$value" || "$value" == "-" ]]; then
    echo "-"
    return 0
  fi
  date -d "$value" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$value"
}

ops_update_epochs() {
  OPS_UPDATE_EPOCHS=()
  [[ -n "${OPS_UPDATE_LIST:-}" ]] || return 0
  local line d t idx=0 k
  local -a stamps=() stamp_idx=() epochs=()
  while IFS= read -r line; do
    IFS=' ' read -r d t _ <<< "$line"
    OPS_UPDATE_EPOCHS[idx]=""
    if [[ -n "$d" ]]; then
      stamps+=("$d $t")
      stamp_idx+=("$idx")
    fi
    idx=$((idx + 1))
  done <<< "$OPS_UPDATE_LIST"
  [[ ${#stamps[@]} -gt 0 ]] || return 0
  mapfile -t epochs < <(printf '%s\n' "${stamps[@]}" | date -f - '+%s' 2>/dev/null)
  if [[ ${#epochs[@]} -ne ${#stamps[@]} ]]; then
    epochs=()
    for k in "${!stamps[@]}"; do
      epochs[k]=$(date -d "${stamps[k]}" '+%s' 2>/dev/null || true)
    done
  fi
  for k in "${!stamps[@]}"; do
    OPS_UPDATE_EPOCHS[${stamp_idx[k]}]="${epochs[k]}"
  done
}

ops_disk_io_peak() {
  printf '%s\n' "${OPS_DISK_IO_SUMMARY}" \
    | awk -F'|' 'BEGIN { m = 0 } { if ($4 + 0 > m) m = $4 + 0 } END { print m }'
}

ops_installed_count_label() {
  if [[ "${1:-0}" == "-1" ]]; then
    echo "待解析"
  else
    printf '%s 个' "${1:-0}"
  fi
}

