#!/bin/bash
# ops-report: 登录、失败登录、封禁、时段审计与可疑进程检测
set -euo pipefail
IFS=$'\n\t'

ops_login_parse() {
  awk 'BEGIN { OFS="\t" }
    function month_num(m) {
      m = toupper(m)
      if (m == "JAN") return 1
      if (m == "FEB") return 2
      if (m == "MAR") return 3
      if (m == "APR") return 4
      if (m == "MAY") return 5
      if (m == "JUN") return 6
      if (m == "JUL") return 7
      if (m == "AUG") return 8
      if (m == "SEP") return 9
      if (m == "OCT") return 10
      if (m == "NOV") return 11
      if (m == "DEC") return 12
      return 0
    }
    NF >= 7 && $1 !~ /^(reboot|shutdown|wtmp|btmp|last|wtmpdb|)$/ && $1 !~ /^\[/ {
      user = $1
      tty = $2
      if ($3 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) {
        host = "local"
        timestamp = $3 " " $4 " " $5 " " $6 " " $7
        time_field = $6
        date_key = $7 "-" sprintf("%02d", month_num($4)) "-" sprintf("%02d", $5)
      } else if ($3 ~ /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$/) {
        host = "local"
        timestamp = $3 " " $4 " " $5 " " $6
        time_field = $5
        date_key = $6 "-" sprintf("%02d", month_num($3)) "-" sprintf("%02d", $4)
      } else {
        host = $3
        if (host ~ /^::ffff:/) host = substr(host, 8)
        if (host == "" || host ~ /^:/ || host == "localhost") host = "local"
        timestamp = $4 " " $5 " " $6 " " $7 " " $8
        time_field = $7
        date_key = $8 "-" sprintf("%02d", month_num($5)) "-" sprintf("%02d", $6)
      }
      split(time_field, a, ":")
      hour = (a[1] ~ /^[0-9]+$/) ? a[1] : "0"
      print user, tty, host, timestamp, hour, date_key
    }'
}

ops_login_data_start() {
  local raw=""
  if command -v wtmpdb >/dev/null 2>&1; then
    raw=$(timeout 30 wtmpdb last -F 2>/dev/null \
      | grep -Ei '^(wtmp|wtmpdb) begins' | tail -1 \
      | sed -E 's/^[^ ]+ begins //' || true)
  fi
  if [[ -z "$raw" ]] && command -v last >/dev/null 2>&1; then
    raw=$(timeout 30 last -F 2>/dev/null \
      | grep -Ei '^(wtmp|wtmpdb) begins' | tail -1 \
      | sed -E 's/^[^ ]+ begins //' || true)
  fi
  if [[ -n "$raw" ]]; then
    OPS_LOGIN_DATA_START=$(date -d "$raw" '+%Y-%m-%d' 2>/dev/null || echo "$raw")
  else
    OPS_LOGIN_DATA_START="无数据"
  fi
}

ops_collect_security() {
  local since="${OPS_REPORT_SINCE:-$(date '+%Y-%m-%d %H:%M:%S')}"
  OPS_LOGIN_SUCCESS_COUNT=0
  OPS_LOGIN_FAIL_COUNT=0
  OPS_LOGIN_USERS="无数据"
  OPS_LOGIN_USER_STATS=""
  OPS_LOGIN_HOURS=""
  OPS_LOGIN_IP_STATS=""
  OPS_LOGIN_IP_LAST=""
  OPS_LOGIN_DETAILS=""
  OPS_FAIL_IP_STATS=""
  OPS_FAIL_BAN_COUNT="未启用"
  OPS_SECURITY_EVENTS=""
  OPS_SECURITY_ISSUE=0

  local raw_login=""
  if command -v wtmpdb >/dev/null 2>&1; then
    raw_login=$(timeout 20 wtmpdb last -F -s "${since}" 2>/dev/null || true)
  fi
  if [[ -z "$raw_login" ]] && command -v last >/dev/null 2>&1; then
    raw_login=$(timeout 20 last -F -s "${since}" 2>/dev/null || true)
  fi

  local parsed=""
  parsed=$(printf '%s\n' "$raw_login" | ops_login_parse || true)

  OPS_LOGIN_SUCCESS_COUNT=$(printf '%s\n' "$parsed" | grep -v '^$' | wc -l || true)
  OPS_LOGIN_DETAILS=$(printf '%s\n' "$parsed" | grep -v '^$' | tail -20 || true)
  OPS_LOGIN_USERS=$(printf '%s\n' "$parsed" | awk -F '\t' '$1 != "" {print $1}' \
    | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  [[ -n "$OPS_LOGIN_USERS" ]] || OPS_LOGIN_USERS="无数据"

  OPS_LOGIN_USER_STATS=$(printf '%s\n' "$parsed" | awk -F '\t' '
    $1 != "" {
      count[$1]++
      if (!seen[$1 "|" $3]++) ips[$1]++
      hour[$1 "|" $5]++
      active[$1 "|" $6]++
      key = $6 " " $5
      if (first_key[$1] == "" || key < first_key[$1]) {
        first_key[$1] = key
        first_ts[$1] = $4
      }
      if (last_key[$1] == "" || key > last_key[$1]) {
        last_key[$1] = key
        last_ts[$1] = $4
      }
    }
    END {
      total = 0
      for (u in count) total += count[u]
      for (u in count) {
        period = "-"
        active_days = 0
        active_hours = 0
        range_min = 24
        range_max = -1
        for (h = 0; h < 24; h++) {
          if (hour[u "|" h] > 0) {
            active_hours++
            if (h < range_min) range_min = h
            if (h > range_max) range_max = h
          }
        }
        if (active_hours >= 18) {
          period = "每小时服务登录"
        } else if (u == "root" && active_hours <= 2 && range_min <= 5) {
          period = "维护窗口"
        } else if (range_max >= range_min) {
          period = sprintf("%02d:00-%02d:00", range_min, range_max)
        }
        for (d in active) {
          split(d, p, "|")
          if (p[1] == u) active_days++
        }
        ratio = total > 0 ? (count[u] * 100 / total) : 0
        printf "%s|%d|%d|%.1f|%s|%s|%d|%s\n", u, count[u] + 0, active_days, ratio, first_ts[u], last_ts[u], ips[u] + 0, period
      }
    }' | sort -k2 -nr || true)

  OPS_LOGIN_HOURS=$(printf '%s\n' "$parsed" | awk -F '\t' '
    BEGIN { for (i = 0; i < 24; i++) c[i] = 0 }
    $5 ~ /^[0-9]+$/ { h = $5 + 0; if (h >= 0 && h < 24) c[h]++ }
    END { for (i = 0; i < 24; i++) print i, c[i] + 0 }
  ')

  OPS_LOGIN_IP_STATS=$(printf '%s\n' "$parsed" | awk -F '\t' '$3 != "" {print $3}' \
    | sort | uniq -c | sort -rn | awk '{print $2, $1}' | head -10 || true)

  OPS_LOGIN_IP_LAST=$(printf '%s\n' "$parsed" | awk -F '\t' '
    $3 != "" && $4 != "" {
      key = $6 " " $5
      if (last_key[$3] == "" || key > last_key[$3]) {
        last_key[$3] = key
        last_ts[$3] = $4
      }
    }
    END {
      for (ip in last_ts) print ip, last_ts[ip]
    }' | sort -k1,1 || true)

  local raw_fail=""
  if (command -v wtmpdb >/dev/null 2>&1 || [[ "$(get_system_version 2>/dev/null || true)" == 13* ]]) \
    && command -v journalctl >/dev/null 2>&1; then
    raw_fail=$(timeout 30 journalctl --since "${since}" --no-pager 2>/dev/null \
      | grep -Ei 'Failed password|Invalid user|authentication failure|Connection closed by authenticating user' \
      || true)
  elif command -v lastb >/dev/null 2>&1; then
    raw_fail=$(timeout 20 lastb -F -s "${since}" 2>/dev/null || true)
  fi
  if [[ -z "$raw_fail" ]] && command -v journalctl >/dev/null 2>&1; then
    raw_fail=$(timeout 30 journalctl --since "${since}" --no-pager 2>/dev/null \
      | grep -Ei 'Failed password|Invalid user|authentication failure|Connection closed by authenticating user' \
      || true)
  fi
  OPS_LOGIN_FAIL_COUNT=$(printf '%s\n' "$raw_fail" | grep -v '^$' | wc -l || true)
  OPS_FAIL_IP_STATS=$(printf '%s\n' "$raw_fail" \
    | grep -oE 'rhost=[0-9a-fA-F.:]+|from [0-9a-fA-F.:]+' \
    | sed 's/rhost=//;s/from //;s/^::ffff://' | sort | uniq -c | sort -rn \
    | awk '{print $2, $1}' | head -10 || true)
  if [[ -z "$OPS_FAIL_IP_STATS" && "${OPS_LOGIN_FAIL_COUNT:-0}" -gt 0 ]]; then
    OPS_FAIL_IP_STATS=$(printf '%s\n' "$raw_fail" \
      | awk 'NF >= 7 && $3 !~ /:/ && $3 !~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$/ {print $3}' \
      | sort | uniq -c | sort -rn | awk '{print $2, $1}' | head -10 || true)
  fi
  if [[ -z "$OPS_FAIL_IP_STATS" && "${OPS_LOGIN_FAIL_COUNT:-0}" -gt 0 ]]; then
    OPS_FAIL_IP_STATS="未知 ${OPS_LOGIN_FAIL_COUNT}"
  fi

  if command -v fail2ban-client >/dev/null 2>&1; then
    local jails jail banned total=0
    jails=$(timeout 10 fail2ban-client status 2>/dev/null \
      | grep 'Jail list:' | cut -d: -f2- || true)
    for jail in $jails; do
      jail=$(printf '%s' "$jail" | tr -d '[:space:]')
      [[ -n "$jail" ]] || continue
      banned=$(timeout 10 fail2ban-client status "$jail" 2>/dev/null \
        | awk -F: '/Currently banned:/ { gsub(/ /, "", $2); print $2 }' || true)
      [[ "$banned" =~ ^[0-9]+$ ]] && total=$((total + banned))
    done
    OPS_FAIL_BAN_COUNT="$total"
  fi

  local abnormal root_remote
  abnormal=$(printf '%s\n' "$parsed" | awk -F '\t' '$5 >= 0 && $5 <= 5 {print $1, $3, $4}' | head -20 || true)
  root_remote=$(printf '%s\n' "$parsed" | awk -F '\t' '$1 == "root" && $3 != "local" {print $1, $3, $4}' | head -20 || true)
  OPS_SECURITY_EVENTS="${abnormal:+非工作时间登录：${abnormal}}"
  OPS_SECURITY_EVENTS="${OPS_SECURITY_EVENTS:+${OPS_SECURITY_EVENTS}
}${root_remote:+远程 root 登录：${root_remote}}"

  if [[ -n "$abnormal" ]] || [[ "$OPS_LOGIN_FAIL_COUNT" -ge 50 ]]; then
    OPS_SECURITY_ISSUE=1
  fi
}

ops_drift_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

ops_drift_append_row() {
  local label="$1" type="$2" summary="$3" risk="$4" time="$5"
  local risk_cls=""
  [[ "$risk" == "高" || "$risk" == "中" ]] && risk_cls=' class="warn"'
  OPS_SECURITY_DRIFT_LINES="${OPS_SECURITY_DRIFT_LINES}<tr><td>$(ops_drift_escape "$label")</td><td>$(ops_drift_escape "$type")</td><td${risk_cls}>$(ops_drift_escape "$risk")</td><td>$(ops_drift_escape "$summary")</td><td>$(ops_drift_escape "$time")</td></tr>"
}

ops_drift_compact_diff() {
  local lines="$1" max="${2:-4}"
  local count out
  count=$(printf '%s\n' "$lines" | grep -v '^$' | wc -l || true)
  out=$(printf '%s\n' "$lines" | grep -v '^$' | head -"$max" \
    | awk 'NF { if (n++) printf " · "; printf "%s", $0 }')
  if [[ "$count" -gt "$max" ]]; then
    out="${out} 等 ${count} 项"
  fi
  printf '%s' "$out"
}

ops_collect_suspicious_processes() {
  OPS_SUSPICIOUS_PROGRAMS=""
  OPS_SUSPICIOUS_PROGRAM_COUNT=0
  local pid p exe cwd cmdline comm reason argv0 proc_base
  for pid in /proc/[0-9]*; do
    [[ -d "$pid" ]] || continue
    p="${pid##*/}"
    exe=$(readlink "$pid/exe" 2>/dev/null || true)
    cwd=$(readlink "$pid/cwd" 2>/dev/null || true)
    cmdline=$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null || true)
    comm=$(cat "$pid/comm" 2>/dev/null || true)
    reason=""
    # 1) 二进制已删除（运行中被替换/卸载）
    if [[ "$exe" == *" (deleted)" ]]; then
      reason="二进制已删除：${exe}"
    fi
    # 2) 异常启动路径（临时可写目录）
    if [[ -z "$reason" ]]; then
      proc_base="${exe:-$cwd}"
      if [[ "$proc_base" == /tmp/* || "$proc_base" == /var/tmp/* \
        || "$proc_base" == /dev/shm/* || "$proc_base" == /run/shm/* ]]; then
        reason="异常启动路径：${proc_base}"
      fi
    fi
    # 3) 隐藏进程名（argv[0] 或 comm 以 . 开头）
    if [[ -z "$reason" ]]; then
      argv0="${cmdline%% *}"
      if [[ "$comm" == .* || "$argv0" == .* ]]; then
        reason="隐藏进程名：${argv0:-$comm}"
      fi
    fi
    # 4) 下载并执行（curl/wget 管道到 shell）
    if [[ -z "$reason" ]]; then
      local has_downloader=0 has_shell=0
      [[ "$cmdline" == *curl* || "$cmdline" == *wget* ]] && has_downloader=1
      if [[ "$cmdline" =~ (^|[[:space:]])(/usr/bin/|/bin/|/usr/sbin/|/sbin/)?(ba|da)?sh([[:space:]]|$) ]]; then
        has_shell=1
      fi
      if [[ "$has_downloader" -eq 1 && "$has_shell" -eq 1 ]]; then
        reason="下载并执行：${cmdline}"
      fi
    fi
    [[ -n "$reason" ]] || continue
    OPS_SUSPICIOUS_PROGRAMS="${OPS_SUSPICIOUS_PROGRAMS:+${OPS_SUSPICIOUS_PROGRAMS}
}${p} ${comm}：${reason}"
    OPS_SUSPICIOUS_PROGRAM_COUNT=$((OPS_SUSPICIOUS_PROGRAM_COUNT + 1))
  done
}

ops_collect_security_drift() {
  OPS_SECURITY_DRIFT_LINES=""
  [[ -n "${OPS_SNAPSHOT_DIR:-}" ]] || return 0
  mkdir -p "${OPS_SNAPSHOT_DIR}/drift" 2>/dev/null || true
  local drift_dir="${OPS_SNAPSHOT_DIR}/drift"
  local now_label now
  now_label=$(date '+%Y-%m-%d %H:%M')
  now=$(date '+%s')

  local ssh_content fw_content cron_content user_content
  ssh_content=$( {
      awk 'NF && $1 !~ /^#/' /etc/ssh/sshd_config 2>/dev/null
      find /root /home -maxdepth 4 -type f -name authorized_keys -print0 2>/dev/null \
        | xargs -0 -r -n1 sh -c 'printf "%s: " "$1"; sha256sum "$1" | awk "{print \$1}"' sh
    } 2>/dev/null || true)
  fw_content=$( { iptables-save 2>/dev/null || nft list ruleset 2>/dev/null; } \
    | grep -v '^#' | sed -E 's/\[[0-9]+:[0-9]+\]//g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | awk 'NF' | sort -u || true)
  cron_content=$( {
      awk 'NF && $1 !~ /^#/' /etc/crontab 2>/dev/null
      find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly -type f -print0 2>/dev/null \
        | xargs -0 -r -n1 sh -c 'printf "%s: " "$1"; sha256sum "$1" | awk "{print \$1}"' sh
    } 2>/dev/null || true)
  user_content=$( {
      getent passwd 2>/dev/null
      getent group 2>/dev/null
    } | sort || true)

  local category label current_file previous_file old changed current_content
  for category in ssh firewall cron users; do
    case "$category" in
      ssh) label="SSH 配置与授权密钥"; current_file="${drift_dir}/ssh.current"; previous_file="${drift_dir}/ssh.previous"; current_content="$ssh_content"; ;;
      firewall) label="防火墙规则"; current_file="${drift_dir}/firewall.current"; previous_file="${drift_dir}/firewall.previous"; current_content="$fw_content"; ;;
      cron) label="计划任务"; current_file="${drift_dir}/cron.current"; previous_file="${drift_dir}/cron.previous"; current_content="$cron_content"; ;;
      users) label="用户账户"; current_file="${drift_dir}/users.current"; previous_file="${drift_dir}/users.previous"; current_content="$user_content"; ;;
    esac

    printf '%s\n' "$current_content" > "$current_file" 2>/dev/null || true
    if [[ ! -f "$previous_file" ]]; then
      mv "$current_file" "$previous_file" 2>/dev/null || true
      ops_drift_append_row "$label" "已建立基线" "-" "低" "$now_label"
      continue
    fi

    old=$(cat "$previous_file" 2>/dev/null || true)
    if [[ "$old" == "$current_content" ]]; then
      mv "$current_file" "$previous_file" 2>/dev/null || true
      ops_drift_append_row "$label" "无变化" "-" "低" "$now_label"
      continue
    fi

    local removed added type item risk summary="" removed_count added_count changed_count
    removed=$(diff -u "$previous_file" "$current_file" 2>/dev/null \
      | grep '^-' | grep -v '^---' | sed 's/^-//' || true)
    added=$(diff -u "$previous_file" "$current_file" 2>/dev/null \
      | grep '^+' | grep -v '^+++' | sed 's/^+//' || true)
    removed_count=$(printf '%s\n' "$removed" | grep -v '^$' | wc -l || true)
    added_count=$(printf '%s\n' "$added" | grep -v '^$' | wc -l || true)
    changed_count=$((removed_count + added_count))
    removed=$(ops_drift_compact_diff "$removed")
    added=$(ops_drift_compact_diff "$added")
    type="修改"
    item="${category}"
    risk="中"
    if [[ "$category" == "users" ]]; then
      local old_users new_users user_added user_removed
      old_users=$(awk -F: '$1 !~ /^#/ && $1 != "" {print $1}' "$previous_file" | sort -u)
      new_users=$(awk -F: '$1 !~ /^#/ && $1 != "" {print $1}' "$current_file" | sort -u)
      user_added=$(comm -13 <(printf '%s\n' "$old_users") <(printf '%s\n' "$new_users") | paste -sd ',' -)
      user_removed=$(comm -23 <(printf '%s\n' "$old_users") <(printf '%s\n' "$new_users") | paste -sd ',' -)
      item="用户账户"
      removed="${user_removed:-无}"
      added="${user_added:-无}"
      type="用户变更"
      if [[ "$removed" == *root* || "$added" == *root* || "$removed" == *sudo* || "$added" == *sudo* ]]; then
        risk="高"
      fi
      summary="新增用户：${added}；删除用户：${removed}"
    elif [[ "$category" == "ssh" ]]; then
      item="sshd_config / authorized_keys"
      if printf '%s' "$removed" | grep -q 'PermitRootLogin'; then risk="高"; fi
      summary="修改 ${changed_count} 项；旧值：${removed}；新值：${added}"
    elif [[ "$category" == "firewall" && -n "$removed" && "$removed" != "无" ]]; then
      risk="高"
      summary="修改 ${changed_count} 项；旧值：${removed}；新值：${added}"
    else
      summary="修改 ${changed_count} 项；旧值：${removed}；新值：${added}"
    fi
    mv "$current_file" "$previous_file" 2>/dev/null || true
    ops_drift_append_row "$label" "$type" "$summary" "$risk" "$now_label"
  done

  OPS_NEW_LISTEN_PORT_COUNT=0
  OPS_LISTEN_PORT_BASELINE_STATE="待基线"
  OPS_LISTEN_PORT_BASELINE_NOTE="未建立监听端口基线，暂不判定新增"
  local port_lines port_file old_ports new_ports new_count new_note
  port_lines=$(printf '%s\n' "${OPS_LISTEN_PORTS:-}" \
    | awk 'NF >= 5 {
        proto = tolower($1)
        split($5, a, ":")
        port = a[length(a)]
        if (port ~ /^[0-9]+$/) print proto ":" port
      }' \
    | grep -v '^$' | sort -u || true)
  port_file="${OPS_SNAPSHOT_DIR}/listen-ports.snapshot"
  if [[ -f "$port_file" ]]; then
    old_ports=$(cat "$port_file" 2>/dev/null || true)
    if printf '%s\n' "$old_ports" | grep -q '[[:space:]]'; then
      printf '%s\n' "$port_lines" > "$port_file"
      OPS_LISTEN_PORT_BASELINE_STATE="已建立基线"
      OPS_LISTEN_PORT_BASELINE_NOTE="首次报告建立监听端口基线后开始对比"
    elif [[ "$old_ports" == "$port_lines" ]]; then
      OPS_LISTEN_PORT_BASELINE_STATE="未发现"
      OPS_LISTEN_PORT_BASELINE_NOTE="周期内无新增监听端口"
    else
      new_ports=$(comm -13 <(printf '%s\n' "$old_ports") <(printf '%s\n' "$port_lines") | grep -v '^$')
      new_count=$(printf '%s\n' "$new_ports" | grep -v '^$' | wc -l || true)
      new_note=$(printf '%s\n' "$new_ports" | head -10 | paste -sd ',' -)
      if [[ "$new_count" -gt 10 ]]; then
        new_note="${new_note} 等 ${new_count} 项"
      fi
      OPS_NEW_LISTEN_PORT_COUNT="$new_count"
      OPS_LISTEN_PORT_BASELINE_STATE="发现 ${new_count} 个"
      OPS_LISTEN_PORT_BASELINE_NOTE="新增监听端口：${new_note}"
      printf '%s\n' "$port_lines" > "$port_file"
    fi
  else
    printf '%s\n' "$port_lines" > "$port_file"
    OPS_LISTEN_PORT_BASELINE_STATE="已建立基线"
    OPS_LISTEN_PORT_BASELINE_NOTE="首次报告建立监听端口基线后开始对比"
  fi
}
