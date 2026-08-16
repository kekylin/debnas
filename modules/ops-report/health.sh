#!/bin/bash
# ops-report: 内置 SMART/RAID/文件系统健康检查
set -euo pipefail
IFS=$'\n\t'

ops_collect_health() {
  OPS_HEALTH_SMART_SUMMARY="无数据/未启用"
  OPS_HEALTH_SMART_ALERT=0
  OPS_HEALTH_MDSTAT=""
  OPS_HEALTH_RAID_STATE="无 RAID/未启用"
  OPS_HEALTH_RAID_ALERT=0
  OPS_HEALTH_FS_LIST=""
  OPS_HEALTH_RO_MOUNTS=""
  OPS_HEALTH_FS_ALERT=0
  OPS_HEALTH_LOG_ISSUES=""
  OPS_HEALTH_LOG_ALERT=0
  OPS_HEALTH_FS_ERRORS=""
  OPS_HEALTH_KERNEL_ERRORS=""
  OPS_HEALTH_LOG_SUMMARY=""
  OPS_HEALTH_FS_ERROR_ALERT=0
  OPS_HEALTH_KERNEL_ERROR_ALERT=0

  if command -v smartctl >/dev/null 2>&1 && [[ "${OPS_INCLUDE_SMART:-1}" -eq 1 ]]; then
    local smart_rows=""
    local disk_name disk_type disk_size disk
    while IFS=' ' read -r disk_name disk_size disk_type; do
      [[ "$disk_type" == "disk" ]] || continue
      disk="/dev/${disk_name}"
      [[ -b "$disk" ]] || continue

      local smart_output health_line temp_line
      smart_output=$(timeout 15 smartctl -H -A -d auto "$disk" 2>/dev/null || true)
      health_line=$(printf '%s\n' "$smart_output" | grep -i "overall-health" \
        | head -1 | sed 's/^[[:space:]]*//' || true)
      temp_line=$(printf '%s\n' "$smart_output" \
        | grep -E 'Temperature_Celsius|Current_Temperature' | head -1 \
        | awk '{print $(NF-1)}' || true)

      smart_rows="${smart_rows:+${smart_rows}\n}${disk}: ${health_line:-状态不可读}${temp_line:+, ${temp_line}C}"
      if [[ -n "$health_line" ]] && ! grep -qi "passed" <<< "$health_line"; then
        OPS_HEALTH_SMART_ALERT=1
      fi
    done < <(lsblk -dnbo NAME,SIZE,TYPE 2>/dev/null || true)
    if [[ -n "$smart_rows" ]]; then
      OPS_HEALTH_SMART_SUMMARY="$smart_rows"
    fi
  fi

  if [[ -r /proc/mdstat ]]; then
    OPS_HEALTH_MDSTAT=$(cat /proc/mdstat)
    if grep -Eq 'degraded|recovering|FAILED|resync.*PENDING' /proc/mdstat 2>/dev/null; then
      OPS_HEALTH_RAID_STATE="需关注"
      OPS_HEALTH_RAID_ALERT=1
    else
      OPS_HEALTH_RAID_STATE="正常"
    fi
  fi

  if command -v findmnt >/dev/null 2>&1; then
    OPS_HEALTH_FS_LIST=$(findmnt -rn -o TARGET,FSTYPE,SOURCE,OPTIONS 2>/dev/null || true)
    OPS_HEALTH_RO_MOUNTS=$(printf '%s\n' "${OPS_HEALTH_FS_LIST}" | awk '
      $4 ~ /(^|[ ,])ro([ ,]|$)/ && $1 !~ /^\/boot\/efi/ && $1 !~ /^\/sys/ && $1 !~ /^\/proc/ && $1 !~ /^\/dev/ && $1 !~ /^\/run/ && $3 ~ /^\/dev\// {
        print
      }')
    if [[ -n "$OPS_HEALTH_RO_MOUNTS" ]]; then
      OPS_HEALTH_FS_ALERT=1
    fi
  fi

  if command -v journalctl >/dev/null 2>&1; then
    OPS_HEALTH_LOG_ISSUES=$(timeout 20 journalctl -k --since "${OPS_REPORT_SINCE:-$(date '+%Y-%m-%d %H:%M:%S')}" \
      --no-pager 2>/dev/null \
      | grep -Ei 'EXT4-fs error|XFS.*error|BTRFS.*error|I/O error|Out of memory|oom-kill|md/raid.*degraded' \
      | head -20 || true)
    if [[ -n "$OPS_HEALTH_LOG_ISSUES" ]]; then
      OPS_HEALTH_LOG_ALERT=1
      OPS_HEALTH_FS_ERRORS=$(printf '%s\n' "$OPS_HEALTH_LOG_ISSUES" \
        | grep -Ei 'EXT4-fs error|XFS.*error|BTRFS.*error|I/O error|filesystem' \
        | head -20 || true)
      OPS_HEALTH_KERNEL_ERRORS=$(printf '%s\n' "$OPS_HEALTH_LOG_ISSUES" \
        | grep -Ei 'Out of memory|oom-kill|kernel panic|BUG:|Call Trace|general protection fault|watchdog: BUG|md/raid.*degraded' \
        | head -20 || true)
      [[ -n "$OPS_HEALTH_FS_ERRORS" ]] && OPS_HEALTH_FS_ERROR_ALERT=1
      [[ -n "$OPS_HEALTH_KERNEL_ERRORS" ]] && OPS_HEALTH_KERNEL_ERROR_ALERT=1
      if [[ "$OPS_HEALTH_FS_ERROR_ALERT" -eq 1 && "$OPS_HEALTH_KERNEL_ERROR_ALERT" -eq 1 ]]; then
        OPS_HEALTH_LOG_SUMMARY="文件系统与内核错误"
      elif [[ "$OPS_HEALTH_FS_ERROR_ALERT" -eq 1 ]]; then
        OPS_HEALTH_LOG_SUMMARY="文件系统错误"
      elif [[ "$OPS_HEALTH_KERNEL_ERROR_ALERT" -eq 1 ]]; then
        OPS_HEALTH_LOG_SUMMARY="内核错误"
      else
        OPS_HEALTH_LOG_SUMMARY="系统日志异常"
      fi
    fi
  fi
}
