#!/bin/bash
# ops-report: 登录、失败登录、封禁、时段审计与可疑进程检测
set -euo pipefail
IFS=$'\n\t'

# 解析 last -F（Debian 12，wtmp）/ wtmpdb last -F（Debian 13）的登录记录
# 输入：stdin 原始输出；输出：每条登录一行 "用户\t终端\t来源\t登录时间\t小时\t日期(YYYY-MM-DD)"
# 两种工具的列格式相同："用户(8) 终端(12) 来源(16) 登录时间 - 注销时间 (时长)"，但终端和来源都可能为空，
# 终端还可能带空格（Cockpit 的 "web console"），按空白分词会错位。因此：
#   1. 先定位登录时间（"Tue Nov 10 01:56:22 2026" 第一次出现的位置）
#   2. 时间之前的部分按固定列宽取 用户/终端/来源（第 9、22 列是空格时）；
#      列宽对不上（-w 等不截断的输出）时退回分词，并把 "web console" 当成一个终端名
#   3. 找不到完整时间的行（未带 -F 的短格式）走原来的分词逻辑
# 来源为空、":0" 这类本机显示、localhost 一律记为 local
ops_login_parse() {
  awk 'BEGIN {
      OFS="\t"
      ts_re = "(Mon|Tue|Wed|Thu|Fri|Sat|Sun) +(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +[0-9]+ +[0-9][0-9]:[0-9][0-9]:[0-9][0-9] +[0-9][0-9][0-9][0-9]"
    }
    function trim(s) { gsub(/^ +| +$/, "", s); return s }
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
    $2 == "begins" { next }
    NF >= 6 && $1 !~ /^(reboot|shutdown|runlevel|wtmp|btmp|last|wtmpdb|)$/ && $1 !~ /^\[/ && match($0, ts_re) {
      pre = substr($0, 1, RSTART - 1)
      n = split(substr($0, RSTART, RLENGTH), t, / +/)
      if (RSTART >= 23 && substr($0, 9, 1) == " " && substr($0, 22, 1) == " ") {
        user = trim(substr(pre, 1, 8))
        tty = trim(substr(pre, 10, 12))
        host = trim(substr(pre, 23))
      } else {
        n = split(pre, p, / +/)
        user = p[1]
        if (p[2] == "web" && p[3] == "console") { tty = "web console"; host = p[4] }
        else { tty = p[2]; host = p[3] }
      }
      if (user == "") next
      if (host ~ /^::ffff:/) host = substr(host, 8)
      if (host == "" || host ~ /^:/ || host == "localhost") host = "local"
      split(t[4], a, ":")
      print user, tty, host, t[1] " " t[2] " " t[3] " " t[4] " " t[5], a[1], t[5] "-" sprintf("%02d", month_num(t[2])) "-" sprintf("%02d", t[3])
      next
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
      hour = (a[1] ~ /^[0-9]+$/) ? a[1] : "-1"
      print user, tty, host, timestamp, hour, date_key
    }'
}

# 从失败登录日志行提取来源 IP（stdin 每行一条，stdout 每行一个 IP，取不到的行不输出）
# 说明：用户名可被攻击者控制，且总写在真实来源之前（sshd：用户名在 "from <IP> port N" 之前；
#       pam_unix：user= 在 rhost= 之后），所以：
#       - 消息本身以 "pam_xxx(...): authentication failure;" 开头的行：取第一个 rhost=
#       - 其他行：只取最后一个 "<IP> port <数字>"，用户名里伪造的 "from <IP>" 不计入
ops_fail_source_ips() {
  awk '
    {
      ip = ""; s = $0
      if ($0 ~ /^[^]]*\]: pam_[a-z_]+\([^)]*\): authentication failure;/) {
        if (match($0, /rhost=[0-9a-fA-F.:]+/)) ip = substr($0, RSTART + 6, RLENGTH - 6)
      } else {
        while (match(s, /[[:space:]][0-9a-fA-F.:]+[[:space:]]+port[[:space:]]+[0-9]+/)) {
          ip = substr(s, RSTART + 1, RLENGTH - 1)
          s = substr(s, RSTART + RLENGTH)
        }
        sub(/[[:space:]].*$/, "", ip)
      }
      sub(/^::ffff:/, "", ip)
      if (ip ~ /[.:]/ && ip ~ /[0-9a-fA-F]/) print ip
    }'
}

# 登录记录数据源：stdout 输出 wtmpdb / last，都没有时无输出并返回 1（只读，供 module_status/module_plan 与采集共用）
# Debian 12：util-linux 的 last 读 /var/log/wtmp；Debian 13：wtmp 已移除，改由 wtmpdb 包提供 wtmpdb（及 last 链接）
ops_login_source() {
  if command -v wtmpdb >/dev/null 2>&1; then
    echo "wtmpdb"
  elif command -v last >/dev/null 2>&1; then
    echo "last"
  else
    return 1
  fi
}

# 当前系统能否自动补装登录数据源（Debian 13 及以上才有 wtmpdb 包）
# 返回：0 可以，1 不可以
ops_login_source_installable() {
  local ver
  ver=$(get_system_version 2>/dev/null || true)
  [[ "$ver" =~ ^([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" -ge 13 ]]
}

# 登录日志最早记录日期，写入 OPS_LOGIN_DATA_START（module.sh 数据覆盖状态显示）
# shellcheck disable=SC2034  # OPS_LOGIN_DATA_START 在 module.sh 中读取
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

# 采集登录/失败登录/封禁/异常时段；结果写入 OPS_LOGIN_* 等全局变量，由 report.sh 渲染
# shellcheck disable=SC2034  # OPS_* 结果变量在 report.sh 中读取
ops_collect_security() {
  local since="${OPS_REPORT_SINCE:-$(date '+%Y-%m-%d %H:%M:%S')}"
  OPS_LOGIN_SUCCESS_COUNT=0
  OPS_LOGIN_FAIL_COUNT=0
  OPS_LOGIN_USERS="无数据"
  OPS_LOGIN_USER_STATS=""
  OPS_LOGIN_HOURS=""
  OPS_LOGIN_IP_STATS=""
  OPS_LOGIN_IP_LAST=""
  OPS_FAIL_IP_STATS=""
  OPS_FAIL_BAN_COUNT="未启用"
  OPS_SECURITY_EVENTS=""
  OPS_SECURITY_ISSUE=0
  OPS_LOGIN_SOURCE=$(ops_login_source || true)
  OPS_LOGIN_SOURCE_NOTE=""

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
  OPS_LOGIN_USERS=$(printf '%s\n' "$parsed" | awk -F '\t' '$1 != "" {print $1}' \
    | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  [[ -n "$OPS_LOGIN_USERS" ]] || OPS_LOGIN_USERS="无数据"
  # 没有数据源 / 有数据源但没有记录：给报告一条明确说明，而不是留空
  if [[ -z "$OPS_LOGIN_SOURCE" ]]; then
    if ops_login_source_installable; then
      OPS_LOGIN_SOURCE_NOTE="无登录数据源：未安装 wtmpdb（自动安装未成功），无法读取登录记录，成功登录统计不可用。可手动执行 apt install wtmpdb libpam-wtmpdb 后重新生成报告。"
    else
      OPS_LOGIN_SOURCE_NOTE="无登录数据源：系统中没有 last 或 wtmpdb 命令，无法读取登录记录，成功登录统计不可用。"
    fi
  elif [[ "${OPS_LOGIN_SUCCESS_COUNT:-0}" -eq 0 ]]; then
    OPS_LOGIN_SOURCE_NOTE="登录数据源（${OPS_LOGIN_SOURCE}）可用，周期内没有登录记录。"
    [[ "$OPS_LOGIN_SOURCE" == "wtmpdb" ]] \
      && OPS_LOGIN_SOURCE_NOTE+="wtmpdb 刚安装时属正常：本地终端与 Cockpit 登录从安装 libpam-wtmpdb 之后才开始记录，此前的登录不会出现在报告里。"
  fi

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
    }' | sort -t'|' -k2,2nr || true)

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

  # 失败登录只读 auth(4)/authpriv(10) 两个 syslog facility（sshd 与 pam_unix 写入处），
  # 走 journal 字段索引；不再全量扫描周期内整个 journal（年报在 2 核机器上会被 timeout 截断）
  local raw_fail="" journal_scanned=0
  local fail_pattern='Failed password|Invalid user|authentication failure|Connection closed by authenticating user'
  if (command -v wtmpdb >/dev/null 2>&1 || [[ "$(get_system_version 2>/dev/null || true)" == 13* ]]) \
    && command -v journalctl >/dev/null 2>&1; then
    raw_fail=$(timeout 30 journalctl SYSLOG_FACILITY=4 SYSLOG_FACILITY=10 --since "${since}" --no-pager 2>/dev/null \
      | grep -Ei "$fail_pattern" || true)
    journal_scanned=1
  elif command -v lastb >/dev/null 2>&1; then
    raw_fail=$(timeout 20 lastb -F -s "${since}" 2>/dev/null || true)
  fi
  if [[ -z "$raw_fail" && "$journal_scanned" -eq 0 ]] && command -v journalctl >/dev/null 2>&1; then
    raw_fail=$(timeout 30 journalctl SYSLOG_FACILITY=4 SYSLOG_FACILITY=10 --since "${since}" --no-pager 2>/dev/null \
      | grep -Ei "$fail_pattern" || true)
  fi
  OPS_LOGIN_FAIL_COUNT=$(printf '%s\n' "$raw_fail" | grep -v '^$' | wc -l || true)
  # 来源 IP：用户名可被攻击者控制（"Invalid user x from 1.2.3.4 from <真实IP> port 22"），
  # 每行只取最后一个 "<IP> port <数字>"（sshd 把真实来源写在用户名之后）；没有时退回 pam 的 rhost=
  OPS_FAIL_IP_STATS=$(printf '%s\n' "$raw_fail" | ops_fail_source_ips \
    | sort | uniq -c | sort -rn \
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
    local -a jail_list=()
    jails=$(timeout 10 fail2ban-client status 2>/dev/null \
      | grep 'Jail list:' | cut -d: -f2- || true)
    # Jail list 形如 "sshd, recidive"；全局 IFS=$'\n\t' 下 $jails 不会按逗号/空格分词
    IFS=', ' read -r -a jail_list <<< "$jails"
    for jail in "${jail_list[@]}"; do
      jail="${jail//[[:space:]]/}"
      [[ -n "$jail" ]] || continue
      banned=$(timeout 10 fail2ban-client status "$jail" 2>/dev/null \
        | awk -F: '/Currently banned:/ { gsub(/[[:space:]]/, "", $2); print $2 }' || true)
      [[ "$banned" =~ ^[0-9]+$ ]] && total=$((total + banned))
    done
    OPS_FAIL_BAN_COUNT="$total"
  fi

  # 异常登录时段判定（方案 A）：
  #   夜间登录：hour ∈ [night_start, night_end] 硬规则，全用户生效（豁免 24 小时服务账户）。
  #   非常规时段登录：对每用户建立 0-23 小时直方图，若该小时仅出现 1 次、
  #                   且用户存在明显高频时段（峰值 ≥ min_peak）、样本 ≥ min_sample，
  #                   则判定为偏离惯常时段（夜间窗口内不重复标记）。
  local night off_pattern root_remote night_count off_pattern_count root_remote_count
  local night_start=0 night_end=5 min_sample=5 min_peak=3
  local flagged
  flagged=$(printf '%s\n' "$parsed" | awk -F '\t' -v ns="$night_start" -v ne="$night_end" \
      -v min_sample="$min_sample" -v min_peak="$min_peak" '
    {
      n++
      evt_user[n] = $1
      evt_host[n] = $3
      evt_ts[n] = $4
      h = ($5 ~ /^[0-9]+$/) ? $5 + 0 : -1
      evt_hour[n] = h
      if (h >= 0 && h < 24) {
        cnt[$1 "|" h]++
        total[$1]++
      }
    }
    END {
      for (u in total) {
        active[u] = 0
        peak[u] = 0
        for (h = 0; h < 24; h++) {
          c = cnt[u "|" h] + 0
          if (c > 0) active[u]++
          if (c > peak[u]) peak[u] = c
        }
      }
      for (i = 1; i <= n; i++) {
        u = evt_user[i]
        h = evt_hour[i]
        if (h < 0 || h >= 24) continue
        if (active[u] >= 18) continue
        if (h >= ns && h <= ne) {
          print "night|" u " " evt_host[i] " " evt_ts[i]
        } else if (total[u] >= min_sample && peak[u] >= min_peak && cnt[u "|" h] == 1) {
          print "off|" u " " evt_host[i] " " evt_ts[i]
        }
      }
    }' || true)
  night=$(printf '%s\n' "$flagged" | awk -F'|' '$1=="night" {print $2}' || true)
  off_pattern=$(printf '%s\n' "$flagged" | awk -F'|' '$1=="off" {print $2}' || true)
  root_remote=$(printf '%s\n' "$parsed" | awk -F '\t' '$1 == "root" && $3 != "local" {print $1, $3, $4}' || true)
  night_count=$(printf '%s\n' "$night" | grep -vc '^$' || true)
  off_pattern_count=$(printf '%s\n' "$off_pattern" | grep -vc '^$' || true)
  root_remote_count=$(printf '%s\n' "$root_remote" | grep -vc '^$' || true)
  OPS_ABNORMAL_LOGIN_COUNT=$((night_count + off_pattern_count + root_remote_count))
  # 展示列表封顶，避免报告过长；计数仍为真实值
  night=$(printf '%s\n' "$night" | head -20 || true)
  off_pattern=$(printf '%s\n' "$off_pattern" | head -20 || true)
  root_remote=$(printf '%s\n' "$root_remote" | head -20 || true)
  OPS_SECURITY_EVENTS="${night:+夜间登录：${night}}"
  OPS_SECURITY_EVENTS="${OPS_SECURITY_EVENTS:+${OPS_SECURITY_EVENTS}
}${off_pattern:+非常规时段登录：${off_pattern}}"
  OPS_SECURITY_EVENTS="${OPS_SECURITY_EVENTS:+${OPS_SECURITY_EVENTS}
}${root_remote:+远程 root 登录：${root_remote}}"

  if [[ "$OPS_ABNORMAL_LOGIN_COUNT" -gt 0 ]] || [[ "$OPS_LOGIN_FAIL_COUNT" -ge 50 ]]; then
    OPS_SECURITY_ISSUE=1
  fi
}

# 漂移表转义 & < >（纯 bash；替换串中的 & 需转义，见 report.sh 的 ops_html_escape）
ops_drift_escape() {
  local s="$1"
  s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"
  printf '%s' "$s"
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
    | awk 'NF { if (n++) printf " · "; printf "%s", $0 }' || true)
  if [[ "$count" -gt "$max" ]]; then
    out="${out} 等 ${count} 项"
  fi
  printf '%s' "$out"
}

ops_collect_suspicious_processes() {
  OPS_SUSPICIOUS_PROGRAMS=""
  OPS_SUSPICIOUS_PROGRAM_COUNT=0
  local pid p exe cwd cmdline comm reason argv0 proc_base arg link_dir link_name link_target
  local ctrl=$'\001'-$'\037'$'\177'
  local -a pids=(/proc/[0-9]*)
  local -A links=()
  # exe/cwd 链接目标用一次 find 取完（原来每个进程各起 2 次 readlink）；\0 分隔，路径含换行也不会错位
  while IFS= read -r -d '' link_dir && IFS= read -r -d '' link_name && IFS= read -r -d '' link_target; do
    link_target="${link_target%"${link_target##*[!$'\n']}"}"
    links["${link_dir}/${link_name}"]="$link_target"
  done < <(find "${pids[@]}" -mindepth 1 -maxdepth 1 \( -name exe -o -name cwd \) -printf '%h\0%f\0%l\0' 2>/dev/null)
  for pid in "${pids[@]}"; do
    [[ -d "$pid" ]] || continue
    p="${pid##*/}"
    exe="${links["${pid}/exe"]:-}"
    cwd="${links["${pid}/cwd"]:-}"
    # exe/cwd 路径同样可被本地用户控制（目录名可含换行/ESC 等），去掉控制字符后再进报告
    exe="${exe//[$ctrl]/ }"
    cwd="${cwd//[$ctrl]/ }"
    # comm/cmdline 可被任意本地用户控制：NUL 与换行/制表等控制字符替换为空格，
    # 防止伪造多行记录；cmdline 截断避免报告被超长参数撑大（HTML 转义在渲染层完成）
    # 用 read 直接读 /proc 文件，不再每个进程起 2 次 tr
    cmdline="" arg=""
    { while IFS= read -r -d '' arg; do cmdline+="${arg} "; done; cmdline+="$arg"; } < "$pid/cmdline" 2>/dev/null || true
    cmdline="${cmdline//[$ctrl]/ }"
    cmdline="${cmdline:0:300}"
    comm=""
    { IFS= read -r -d '' comm || true; } < "$pid/comm" 2>/dev/null || true
    comm="${comm//[$ctrl]/ }"
    comm="${comm% }"
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
      # 排除 ./prog、../prog 这类相对路径启动的正常写法
      if [[ "$comm" == .* || ( "$argv0" == .* && "$argv0" != ./* && "$argv0" != ../* ) ]]; then
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

# 安全配置漂移与监听端口基线；结果写入 OPS_SECURITY_DRIFT_LINES / OPS_*LISTEN_PORT* 全局变量
# shellcheck disable=SC2034  # OPS_* 结果变量在 report.sh 中读取
ops_collect_security_drift() {
  OPS_SECURITY_DRIFT_LINES=""
  [[ -n "${OPS_SNAPSHOT_DIR:-}" ]] || return 0
  mkdir -p "${OPS_SNAPSHOT_DIR}/drift" 2>/dev/null || true
  local drift_dir="${OPS_SNAPSHOT_DIR}/drift"
  local now_label
  printf -v now_label '%(%Y-%m-%d %H:%M)T' -1

  local ssh_content fw_content cron_content user_content
  ssh_content=$( {
      awk 'NF && $1 !~ /^#/' /etc/ssh/sshd_config 2>/dev/null
      find /root /home -maxdepth 4 -type f -name authorized_keys -print0 2>/dev/null \
        | xargs -0 -r -n1 sh -c 'printf "%s: " "$1"; timeout 5 sha256sum "$1" | awk "{print \$1}"' sh
    } 2>/dev/null || true)
  fw_content=$( { iptables-save 2>/dev/null || nft list ruleset 2>/dev/null; } \
    | grep -v '^#' | sed -E 's/\[[0-9]+:[0-9]+\]//g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | awk 'NF' | sort -u || true)
  cron_content=$( {
      awk 'NF && $1 !~ /^#/' /etc/crontab 2>/dev/null
      find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly -type f -print0 2>/dev/null \
        | xargs -0 -r -n1 sh -c 'printf "%s: " "$1"; timeout 5 sha256sum "$1" | awk "{print \$1}"' sh
    } 2>/dev/null || true)
  user_content=$( {
      getent passwd 2>/dev/null
      getent group 2>/dev/null
    } | sort || true)

  local category label current_file previous_file old current_content
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

    local removed added type risk summary="" removed_count added_count changed_count
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
    risk="中"
    if [[ "$category" == "users" ]]; then
      local old_users new_users user_added user_removed
      old_users=$(awk -F: '$1 !~ /^#/ && $1 != "" {print $1}' "$previous_file" 2>/dev/null | sort -u || true)
      new_users=$(awk -F: '$1 !~ /^#/ && $1 != "" {print $1}' "$current_file" 2>/dev/null | sort -u || true)
      user_added=$(comm -13 <(printf '%s\n' "$old_users") <(printf '%s\n' "$new_users") | paste -sd ',' - || true)
      user_removed=$(comm -23 <(printf '%s\n' "$old_users") <(printf '%s\n' "$new_users") | paste -sd ',' - || true)
      removed="${user_removed:-无}"
      added="${user_added:-无}"
      type="用户变更"
      if [[ "$removed" == *root* || "$added" == *root* || "$removed" == *sudo* || "$added" == *sudo* ]]; then
        risk="高"
      fi
      summary="新增用户：${added}；删除用户：${removed}"
    elif [[ "$category" == "ssh" ]]; then
      [[ "$removed" == *PermitRootLogin* ]] && risk="高"
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
    # 旧版快照每行是 ss 原始行（含空白），视为无基线重新建立；换行本身不算
    if [[ "$old_ports" == *[$' \t\r\v\f']* ]]; then
      printf '%s\n' "$port_lines" > "$port_file"
      OPS_LISTEN_PORT_BASELINE_STATE="已建立基线"
      OPS_LISTEN_PORT_BASELINE_NOTE="首次报告建立监听端口基线后开始对比"
    elif [[ "$old_ports" == "$port_lines" ]]; then
      OPS_LISTEN_PORT_BASELINE_STATE="未发现"
      OPS_LISTEN_PORT_BASELINE_NOTE="周期内无新增监听端口"
    else
      # 只减少端口时 comm 无输出，grep 返回 1，pipefail 下会让 set -e 终止整个报告
      new_ports=$(comm -13 <(printf '%s\n' "$old_ports") <(printf '%s\n' "$port_lines") | grep -v '^$' || true)
      new_count=$(printf '%s\n' "$new_ports" | grep -v '^$' | wc -l || true)
      new_note=$(printf '%s\n' "$new_ports" | head -10 | paste -sd ',' - || true)
      if [[ "$new_count" -gt 10 ]]; then
        new_note="${new_note} 等 ${new_count} 项"
      fi
      if [[ "$new_count" -gt 0 ]]; then
        OPS_NEW_LISTEN_PORT_COUNT="$new_count"
        OPS_LISTEN_PORT_BASELINE_STATE="发现 ${new_count} 个"
        OPS_LISTEN_PORT_BASELINE_NOTE="新增监听端口：${new_note}"
      else
        OPS_LISTEN_PORT_BASELINE_STATE="未发现"
        OPS_LISTEN_PORT_BASELINE_NOTE="周期内无新增监听端口（部分端口已关闭）"
      fi
      printf '%s\n' "$port_lines" > "$port_file"
    fi
  else
    printf '%s\n' "$port_lines" > "$port_file"
    OPS_LISTEN_PORT_BASELINE_STATE="已建立基线"
    OPS_LISTEN_PORT_BASELINE_NOTE="首次报告建立监听端口基线后开始对比"
  fi
}
