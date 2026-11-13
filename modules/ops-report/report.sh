#!/bin/bash
# ops-report: 数据聚合、终端摘要、HTML 报告与邮件内容生成
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

ops_period_label_cn() {
  case "${1:-7}" in
    7) echo "周报" ;;
    30) echo "月报" ;;
    365) echo "年报" ;;
    *) echo "周报" ;;
  esac
}

ops_period_label_en() {
  case "${1:-7}" in
    7) echo "Server Weekly" ;;
    30) echo "Server Monthly" ;;
    365) echo "Server Annual" ;;
    *) echo "Server Weekly" ;;
  esac
}

ops_period_reports_dir() {
  local base="${OPS_REPORTS_DIR:-${OPS_REPORT_DIR:-}/reports}"
  case "${1:-7}" in
    7) printf '%s/weekly' "$base" ;;
    30) printf '%s/monthly' "$base" ;;
    365) printf '%s/annual' "$base" ;;
    *) printf '%s/weekly' "$base" ;;
  esac
}

# HTML 转义（纯 bash，不起 sed 子进程；替换串里的 & 需转义，bash 5.2 的 patsub_replacement 会把 & 当作匹配文本）
ops_html_escape() {
  local s="$1"
  s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"; s="${s//\"/\&quot;}"; s="${s//\'/\&#39;}"
  printf '%s' "$s"
}

ops_normalize_date() {
  local value="$1"
  if [[ -z "$value" || "$value" == "-" ]]; then
    echo "-"
    return 0
  fi
  date -d "$value" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$value"
}

ops_value_count() {
  local values="${1:-}"
  printf '%s\n' "$values" | awk '
    {
      gsub(/[^0-9., ]+/, " ", $0)
      gsub(/,+/, " ", $0)
      n = split($0, a, / +/)
      if (n == 1 && a[1] == "") n = 0
      print n + 0
    }'
}

ops_auto_labels() {
  local values="${1:-}" n="${2:-}" i label out=""
  if [[ -z "$n" ]]; then
    n=$(ops_value_count "$values")
  fi
  if [[ -z "$n" || "$n" -eq 0 ]]; then
    n="${OPS_REPORT_DAYS:-7}"
  fi
  # 以截止日正午为基准按天回推（正午避开夏令时切换），不再每个标签起两次 date
  local until_noon
  until_noon=$(ops_until_noon_epoch)
  for ((i = n - 1; i >= 0; i--)); do
    printf -v label '%(%m-%d)T' "$((until_noon - i * 86400))"
    out="${out:+${out}, }${label}"
  done
  printf '%s' "$out"
}

# 报告截止日（OPS_REPORT_UNTIL 所在日期，缺省今天）正午的 epoch 秒，供按天/按周回推日期
ops_until_noon_epoch() {
  local until_date
  until_date=$(date -d "${OPS_REPORT_UNTIL:-today}" '+%Y-%m-%d' 2>/dev/null || echo "today")
  date -d "${until_date} 12:00" '+%s' 2>/dev/null || date '+%s'
}

# 把 OPS_UPDATE_LIST 每行的 "日期 时间" 一次性换算成 epoch，结果按行号存入 OPS_UPDATE_EPOCHS
# 说明：可用性/事件/更新表三处原来逐行（可用性里还按重启次数嵌套）起 date；这里只起一次，
#       个别行无法解析导致 date -f 输出行数不符时，回退为逐行解析（无法解析的行为空）
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

# 统计 sysstat 数据覆盖天数与最早日期（参数 $1 报告天数，仅为调用兼容保留）
ops_set_coverage() {
  OPS_SYSSTAT_DATA_DAYS=0
  OPS_DATA_START="无数据"
  if [[ -d /var/log/sysstat ]]; then
    local -a data_dates=()
    mapfile -t data_dates < <(find /var/log/sysstat -maxdepth 1 -type f -name 'sa*' \
      -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort -u)
    OPS_SYSSTAT_DATA_DAYS="${#data_dates[@]}"
    if [[ ${#data_dates[@]} -gt 0 ]]; then
      OPS_DATA_START="${data_dates[0]}"
    fi
  fi
  OPS_DATA_COVERAGE="sysstat 数据覆盖 ${OPS_SYSSTAT_DATA_DAYS} 天；登录日志覆盖范围以系统 wtmp/wtmpdb 保留策略为准"
}

ops_collect_resources() {
  OPS_CPU_AVG="N/A"
  OPS_CPU_MAX="N/A"
  OPS_MEM_AVG="N/A"
  OPS_MEM_MAX="N/A"
  OPS_NET_TOTAL_RX_BYTES=0
  OPS_NET_TOTAL_TX_BYTES=0
  OPS_NET_TOTAL_LABEL="待周期数据"
  OPS_NET_IFACES=""
  OPS_DISK_IO_SUMMARY=""
  OPS_CPU_DAILY_LIST=""
  OPS_MEM_DAILY_LIST=""
  OPS_NET_DAILY_RX_LIST=""
  OPS_NET_DAILY_TX_LIST=""
  OPS_NET_IFACE_SUMMARY=""
  OPS_NET_IFACE_PEAK_SUMMARY=""
  OPS_NET_PEAK_RATE_MBPS="待周期数据"
  OPS_SYSSTAT_SAMPLE_DAYS=0
  OPS_NET_SAMPLE_DAYS=0
  OPS_DISK_SAMPLE_DAYS=0
  OPS_CPU_DAILY_LABELS=""
  OPS_MEM_DAILY_LABELS=""
  OPS_NET_DAILY_LABELS=""
  OPS_CPU_PEAK_DATE=""
  OPS_MEM_PEAK_DATE=""
  OPS_DISK_IO_PEAK_DATE=""
  OPS_PHYS_NET_IFACES=""
  OPS_UPTIME_DAYS=0
  OPS_LOAD_AVG="N/A"
  OPS_KERNEL="N/A"
  OPS_DISK_USAGE_LINES=""
  OPS_NET_DEV=""
  OPS_MEM_TOTAL_KB=0
  OPS_MEM_AVAIL_KB=0
  OPS_MEM_CURRENT_PERCENT="N/A"
  OPS_SWAP_TOTAL_KB=0
  OPS_SWAP_USED_KB=0
  OPS_SWAP_PEAK_KB=0
  OPS_REBOOT_COUNT=0

  if [[ -r /proc/uptime ]]; then
    OPS_UPTIME_DAYS=$(awk '{print int($1 / 86400)}' /proc/uptime)
  fi
  if [[ -r /proc/loadavg ]]; then
    OPS_LOAD_AVG=$(awk '{print $1, $2, $3}' /proc/loadavg)
  fi
  OPS_KERNEL=$(uname -r 2>/dev/null || echo "N/A")
  OPS_DISK_USAGE_LINES=$(ops_physical_disk_usage || true)
  OPS_NET_DEV=$(cat /proc/net/dev 2>/dev/null || true)
  if [[ -n "$OPS_NET_DEV" ]]; then
    local net_iface net_rx net_tx
    local phys_ifaces=""
    OPS_NET_IFACES=""
    while IFS=' ' read -r net_iface net_rx net_tx; do
      [[ -n "$net_iface" ]] || continue
      [[ -e "/sys/class/net/${net_iface}/device" ]] || continue
      [[ -e "/sys/class/net/${net_iface}/bonding_slave" ]] && continue
      phys_ifaces="${phys_ifaces:+${phys_ifaces} }${net_iface}"
      OPS_NET_IFACES="${OPS_NET_IFACES:+${OPS_NET_IFACES}
}${net_iface} ${net_rx} ${net_tx}"
    done < <(printf '%s\n' "$OPS_NET_DEV" | awk 'NR > 2 {
      gsub(":", "", $1)
      if ($1 != "lo") print $1, $2, $10
    }')
    OPS_PHYS_NET_IFACES="$phys_ifaces"
    if [[ "$OPS_NET_TOTAL_RX_BYTES" -eq 0 ]]; then
      OPS_NET_TOTAL_RX_BYTES=0
      OPS_NET_TOTAL_TX_BYTES=0
      while IFS=' ' read -r net_iface net_rx net_tx; do
        [[ "$net_rx" =~ ^[0-9]+$ ]] || continue
        OPS_NET_TOTAL_RX_BYTES=$((OPS_NET_TOTAL_RX_BYTES + net_rx))
        OPS_NET_TOTAL_TX_BYTES=$((OPS_NET_TOTAL_TX_BYTES + net_tx))
      done <<< "${OPS_NET_IFACES}"
      OPS_NET_TOTAL_LABEL="待周期数据"
    fi
  fi

  OPS_MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  OPS_MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [[ "$OPS_MEM_TOTAL_KB" -gt 0 ]]; then
    OPS_MEM_CURRENT_PERCENT=$(awk -v t="$OPS_MEM_TOTAL_KB" -v a="$OPS_MEM_AVAIL_KB" \
      'BEGIN { printf "%.1f", ((t - a) * 100) / t }')
  fi
  OPS_SWAP_TOTAL_KB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  OPS_SWAP_USED_KB=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  OPS_SWAP_USED_KB=$((OPS_SWAP_TOTAL_KB > 0 ? OPS_SWAP_TOTAL_KB - OPS_SWAP_USED_KB : 0))

  OPS_SWAP_PEAK_KB=0
  if command -v sar >/dev/null 2>&1; then
    ops_collect_sysstat
  fi
}

# 读取 sysstat 历史并汇总 CPU/内存/网络/磁盘 I/O/Swap（ops_collect_resources 调用）
# 说明：每个数据文件只跑 5 次 sar，输出按类别追加到临时目录（文件前插入 "\001F <日期>" 分隔行），
#       最后由一个 awk 一次算出逐日序列、全周期统计与峰值日期；sar -n DEV 等原始输出不再整段
#       留在 shell 变量里拼接（年报 365 个文件时占用大量内存且拼接为平方级）。
# 输出：写入 OPS_CPU_* / OPS_MEM_* / OPS_NET_* / OPS_DISK_IO_* / OPS_SWAP_PEAK_KB / OPS_SYSSTAT_SAMPLE_DAYS
ops_collect_sysstat() {
  local f epoch full_day sar_src sar_dir="" i
  local -a sysstat_files=() sysstat_days=()
  # 只取报告周期内有写入的二进制数据文件（sa[0-9]*，排除 sa2 生成的 sarDD 文本报告），
  # 否则周报会把 HISTORY=400 天的全部历史算进平均值，且每次全量跑 sar
  local sysstat_since="${OPS_REPORT_SINCE:-$(date -d "${OPS_REPORT_DAYS:-7} days ago" '+%Y-%m-%d %H:%M:%S')}"
  while IFS=' ' read -r epoch f; do
    [[ -n "$f" ]] || continue
    sysstat_files+=("$f")
    printf -v full_day '%(%Y-%m-%d)T' "${epoch%.*}"
    sysstat_days+=("$full_day")
  done < <(find /var/log/sysstat -maxdepth 1 -type f -name 'sa[0-9]*' \
    -newermt "$sysstat_since" -printf '%T@ %p\n' 2>/dev/null | sort -n)

  # 单独 source report.sh（测试）时没有 create_temp_dir，回退 mktemp；都失败则不做历史统计
  sar_dir=$(create_temp_dir "ops-sar" 2>/dev/null) || sar_dir=$(mktemp -d 2>/dev/null) || sar_dir=""
  [[ -n "$sar_dir" ]] || return 0
  : > "${sar_dir}/u"; : > "${sar_dir}/r"; : > "${sar_dir}/S"; : > "${sar_dir}/n"; : > "${sar_dir}/d"
  for i in "${!sysstat_files[@]}"; do
    f="${sysstat_files[$i]}"
    [[ -f "$f" ]] || continue
    sar_src="$f"
    # COMPRESSAFTER=14 后历史文件被压缩，sar 无法直接读取，需先解压到临时文件
    case "$f" in
      *.xz|*.gz|*.bz2|*.zst)
        sar_src="${sar_dir}/raw.sa"
        case "$f" in
          *.xz) timeout 30 xz -dc -- "$f" > "$sar_src" 2>/dev/null || continue ;;
          *.gz) timeout 30 gzip -dc -- "$f" > "$sar_src" 2>/dev/null || continue ;;
          *.bz2) timeout 30 bzip2 -dc -- "$f" > "$sar_src" 2>/dev/null || continue ;;
          *.zst) timeout 30 zstd -qdc -- "$f" > "$sar_src" 2>/dev/null || continue ;;
        esac
        ;;
    esac
    full_day="${sysstat_days[$i]}"
    { printf '\001F %s\n' "$full_day"; timeout 10 sar -u -f "$sar_src" 2>/dev/null || true; } >> "${sar_dir}/u"
    { printf '\001F %s\n' "$full_day"; timeout 10 sar -r -f "$sar_src" 2>/dev/null || true; } >> "${sar_dir}/r"
    { printf '\001F %s\n' "$full_day"; timeout 10 sar -S -f "$sar_src" 2>/dev/null || true; } >> "${sar_dir}/S"
    { printf '\001F %s\n' "$full_day"; timeout 10 sar -n DEV -f "$sar_src" 2>/dev/null || true; } >> "${sar_dir}/n"
    { printf '\001F %s\n' "$full_day"; timeout 10 sar -d -f "$sar_src" 2>/dev/null || true; } >> "${sar_dir}/d"
  done

  local key value
  while IFS=$'\t' read -r key value; do
    case "$key" in
      CPU_AVG) OPS_CPU_AVG="$value" ;;
      CPU_MAX) OPS_CPU_MAX="$value" ;;
      MEM_AVG) OPS_MEM_AVG="$value" ;;
      MEM_MAX) OPS_MEM_MAX="$value" ;;
      NET_TOTAL_RX) OPS_NET_TOTAL_RX_BYTES="$value"; OPS_NET_TOTAL_LABEL="报告周期" ;;
      NET_TOTAL_TX) OPS_NET_TOTAL_TX_BYTES="$value" ;;
      NET_IFACE) OPS_NET_IFACE_SUMMARY="${OPS_NET_IFACE_SUMMARY:+${OPS_NET_IFACE_SUMMARY}$'\n'}${value}" ;;
      NET_PEAK) OPS_NET_IFACE_PEAK_SUMMARY="${OPS_NET_IFACE_PEAK_SUMMARY:+${OPS_NET_IFACE_PEAK_SUMMARY}$'\n'}${value}" ;;
      NET_PEAK_RATE) OPS_NET_PEAK_RATE_MBPS="$value" ;;
      DISK_IO) OPS_DISK_IO_SUMMARY="${OPS_DISK_IO_SUMMARY:+${OPS_DISK_IO_SUMMARY}$'\n'}${value}" ;;
      CPU_LIST) OPS_CPU_DAILY_LIST="$value" ;;
      CPU_LABELS) OPS_CPU_DAILY_LABELS="$value" ;;
      MEM_LIST) OPS_MEM_DAILY_LIST="$value" ;;
      MEM_LABELS) OPS_MEM_DAILY_LABELS="$value" ;;
      NET_RX_LIST) OPS_NET_DAILY_RX_LIST="$value" ;;
      NET_TX_LIST) OPS_NET_DAILY_TX_LIST="$value" ;;
      NET_LABELS) OPS_NET_DAILY_LABELS="$value" ;;
      CPU_PEAK) OPS_CPU_PEAK_DATE="${value#* }" ;;
      MEM_PEAK) OPS_MEM_PEAK_DATE="${value#* }" ;;
      DISK_PEAK) OPS_DISK_IO_PEAK_DATE="${value#* }" ;;
      SWAP_PEAK) OPS_SWAP_PEAK_KB="$value" ;;
      SAMPLE_DAYS) OPS_SYSSTAT_SAMPLE_DAYS="$value" ;;
      NET_SAMPLE_DAYS) OPS_NET_SAMPLE_DAYS="$value" ;;
      DISK_SAMPLE_DAYS) OPS_DISK_SAMPLE_DAYS="$value" ;;
    esac
  done < <(awk -v phys="$OPS_PHYS_NET_IFACES" -v report_days="${OPS_REPORT_DAYS:-7}" '
    function is_num(x) { return x ~ /^[0-9]+([.][0-9]+)?$/ }
    function is_phys(d) { return d ~ /^(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|hd[a-z])$/ }
    function join(list, item) { return (list == "") ? item : list ", " item }
    BEGIN {
      pc = (phys == "") ? 0 : split(phys, p, " ")
      for (i = 1; i <= pc; i++) pm[p[i]] = 1
    }
    FNR == 1 { cat = substr(FILENAME, length(FILENAME)) }
    /^\001F / {
      # 文件分隔行：逐日统计按文件重置表头列位置（全周期统计沿用上一次表头，与逐文件拼接时一致）
      if (cat == "u") { fu++; fday[fu] = $2 }
      else if (cat == "r") { fr++; mem_if = 0 }
      else if (cat == "n") { fn++; if_f = 0 }
      else if (cat == "d") { fd++; dev_if = 0 }
      next
    }
    cat == "u" {
      if ($1 ~ /^[0-9][0-9]:/) {
        all_i = 0
        for (i = 2; i <= NF; i++) if ($i == "all") { all_i = i; break }
        if (all_i && (all_i + 6) <= NF && is_num($(all_i + 6))) {
          v = 100 - ($(all_i + 6) + 0); if (v < 0) v = 0
          cs[fu] += v; cn[fu]++; if (v > cm[fu]) cm[fu] = v
          gcs += v; if (v > gcm) gcm = v; gcn++
        }
      }
      next
    }
    cat == "r" {
      if ($0 ~ /%memused/) for (i = 2; i <= NF; i++) if ($i == "%memused") { mem_if = i; mem_ig = i }
      if ($1 ~ /^[0-9][0-9]:/) {
        if (mem_if && is_num($mem_if)) { v = $mem_if + 0; ms[fr] += v; mn[fr]++; if (v > mm[fr]) mm[fr] = v }
        if (mem_ig && is_num($mem_ig)) { v = $mem_ig + 0; gms += v; if (v > gmm) gmm = v; gmn++ }
      }
      next
    }
    cat == "S" {
      if ($1 ~ /^[0-9][0-9]:/ && $3 ~ /^[0-9]+$/) { v = $3 + 0; if (v > swap_max) swap_max = v }
      next
    }
    cat == "n" {
      if ($0 ~ /IFACE/) for (i = 2; i <= NF; i++) if ($i == "IFACE") { if_f = i; if_g = i }
      if ($1 ~ /^[0-9][0-9]:/) {
        if (if_f && $if_f != "lo" && (pc == 0 || pm[$if_f] == 1)) { nrx[fn] += $(if_f + 3) + 0; ntx[fn] += $(if_f + 4) + 0; nn[fn]++ }
        if (if_g && $if_g != "lo" && (pc == 0 || pm[$if_g] == 1)) {
          rx = $(if_g + 3) + 0; tx = $(if_g + 4) + 0
          grx += rx; gtx += tx; gnn++
          d = $if_g
          ird[d] += rx; iwr[d] += tx; icnt[d]++
          if (!iorder[d]) { iorder[d] = ++itotal; inames[itotal] = d }
          if (rx * 8 > peak[d]) peak[d] = rx * 8
          if (tx * 8 > peak[d]) peak[d] = tx * 8
        }
      }
      next
    }
    cat == "d" {
      if ($0 ~ /DEV/) for (i = 2; i <= NF; i++) if ($i == "DEV") { dev_if = i; dev_ig = i }
      if ($1 ~ /^[0-9][0-9]:/) {
        if (dev_if && is_phys($dev_if)) { u = $(dev_if + 8) + 0; if (u > dm[fd]) dm[fd] = u }
        if (dev_ig && is_phys($dev_ig)) {
          d = $dev_ig
          drd[d] += $(dev_ig + 2) + 0; dwr[d] += $(dev_ig + 3) + 0; dcnt[d]++
          u = $(dev_ig + 8) + 0
          if (u > dutil[d]) { dutil[d] = u; dtm[d] = $1 }
          if (!dorder[d]) { dorder[d] = ++dtotal; dnames[dtotal] = d }
        }
      }
      next
    }
    END {
      cpu_list = cpu_labels = mem_list = mem_labels = ""
      rx_list = tx_list = net_labels = ""
      cpu_peak = mem_peak = disk_peak = ""
      cpu_n = mem_n = net_n = 0
      for (k = 1; k <= fu; k++) {
        day = fday[k]; label = substr(day, 6)
        if (cn[k] > 0) {
          avg = sprintf("%.0f", cs[k] / cn[k]); mx = sprintf("%.1f", cm[k])
          if (is_num(avg)) { cpu_list = join(cpu_list, avg); cpu_labels = join(cpu_labels, label); cpu_n++ }
          if (is_num(mx) && mx + 0 > (cpu_peak == "" ? 0 : cpu_peak + 0)) { cpu_peak = mx; cpu_date = day }
        }
        if (mn[k] > 0) {
          avg = sprintf("%.0f", ms[k] / mn[k]); mx = sprintf("%.1f", mm[k])
          if (is_num(avg)) { mem_list = join(mem_list, avg); mem_labels = join(mem_labels, label); mem_n++ }
          if (is_num(mx) && mx + 0 > (mem_peak == "" ? 0 : mem_peak + 0)) { mem_peak = mx; mem_date = day }
        }
        if (dm[k] != "") {
          mx = sprintf("%.1f", dm[k])
          if (is_num(mx) && mx + 0 > (disk_peak == "" ? 0 : disk_peak + 0)) { disk_peak = mx; disk_date = day }
        }
        if (nn[k] > 0) {
          r = sprintf("%.4f", nrx[k] / nn[k]); t = sprintf("%.4f", ntx[k] / nn[k])
          if (is_num(r) && is_num(t)) {
            r = sprintf("%.2f", r * 86400 / 1048576); t = sprintf("%.2f", t * 86400 / 1048576)
            rx_list = join(rx_list, r); tx_list = join(tx_list, t); net_labels = join(net_labels, label)
            net_n++
          }
        }
      }
      printf "CPU_LIST\t%s\nCPU_LABELS\t%s\nMEM_LIST\t%s\nMEM_LABELS\t%s\n", cpu_list, cpu_labels, mem_list, mem_labels
      printf "NET_RX_LIST\t%s\nNET_TX_LIST\t%s\nNET_LABELS\t%s\n", rx_list, tx_list, net_labels
      if (cpu_peak != "") printf "CPU_PEAK\t%s %s\n", cpu_peak, cpu_date
      if (mem_peak != "") printf "MEM_PEAK\t%s %s\n", mem_peak, mem_date
      if (disk_peak != "") printf "DISK_PEAK\t%s %s\n", disk_peak, disk_date
      if (gcn > 0) printf "CPU_AVG\t%.1f\nCPU_MAX\t%.1f\n", gcs / gcn, gcm; else printf "CPU_AVG\tN/A\nCPU_MAX\tN/A\n"
      if (gmn > 0) printf "MEM_AVG\t%.1f\nMEM_MAX\t%.1f\n", gms / gmn, gmm; else printf "MEM_AVG\tN/A\nMEM_MAX\tN/A\n"
      if (gnn > 0) {
        r = sprintf("%.4f", grx / gnn); t = sprintf("%.4f", gtx / gnn)
        if (r ~ /^[0-9.]+$/ && t ~ /^[0-9.]+$/) {
          dd = (net_n > 0) ? net_n : report_days
          printf "NET_TOTAL_RX\t%.0f\nNET_TOTAL_TX\t%.0f\n", r * 1024 * 86400 * dd, t * 1024 * 86400 * dd
        }
      }
      for (k = 1; k <= itotal; k++) { d = inames[k]; printf "NET_IFACE\t%s|%.4f|%.4f|%d\n", d, ird[d] / icnt[d], iwr[d] / icnt[d], icnt[d] }
      pmax = 0; has_peak = 0
      for (d in peak) {
        has_peak = 1
        ps = sprintf("%.1f", peak[d] / 1000)
        printf "NET_PEAK\t%s|%s\n", d, ps
        if (ps + 0 > pmax) pmax = ps + 0
      }
      if (has_peak) printf "NET_PEAK_RATE\t%s\n", (pmax > 0) ? sprintf("%.1f", pmax) : "待周期数据"
      for (k = 1; k <= dtotal; k++) {
        d = dnames[k]
        printf "DISK_IO\t%s|%.1f|%.1f|%.1f|%s|%d\n", d, drd[d] / dcnt[d], dwr[d] / dcnt[d], dutil[d], dtm[d], dcnt[d]
      }
      printf "SWAP_PEAK\t%d\n", swap_max + 0
      sd = (cpu_n > mem_n) ? cpu_n : mem_n
      if (net_n > sd) sd = net_n
      dsd = 0
      for (k = 1; k <= dtotal; k++) { if (dcnt[dnames[k]] > dsd) dsd = dcnt[dnames[k]] }
      printf "SAMPLE_DAYS\t%d\n", sd
      printf "NET_SAMPLE_DAYS\t%d\n", net_n
      printf "DISK_SAMPLE_DAYS\t%d\n", dsd
    }' "${sar_dir}/u" "${sar_dir}/r" "${sar_dir}/S" "${sar_dir}/n" "${sar_dir}/d" 2>/dev/null)
  rm -rf -- "$sar_dir"
}

ops_collect_availability() {
  local since_epoch until_epoch total_seconds=0 online_seconds=0
  since_epoch=$(date -d "${OPS_REPORT_SINCE:-$(date -d "$OPS_REPORT_DAYS days ago" '+%Y-%m-%d %H:%M:%S')}" '+%s' 2>/dev/null || true)
  until_epoch=$(date -d "${OPS_REPORT_UNTIL:-now}" '+%s' 2>/dev/null || date '+%s')
  [[ "$since_epoch" =~ ^[0-9]+$ ]] || since_epoch=0
  [[ "$until_epoch" =~ ^[0-9]+$ ]] || until_epoch=$(date '+%s')
  total_seconds=$((until_epoch - since_epoch))
  OPS_REBOOT_COUNT=0
  OPS_PLANNED_DOWNTIME_COUNT=0
  OPS_UNPLANNED_DOWNTIME_COUNT=0

  if [[ "$total_seconds" -le 0 ]] || ! command -v journalctl >/dev/null 2>&1; then
    OPS_AVAILABILITY_PCT="待周期数据"
    return 0
  fi

  local -a boot_fields=()
  local boot_id sd st ed et start_epoch end_epoch
  local overlap_start overlap_end reboot_count=0 planned_count=0 unplanned_count=0
  local boot_output boot_line boot_token
  local -a boot_raw=()
  boot_output=$(journalctl -q --list-boots --no-pager 2>/dev/null || true)
  ops_update_epochs
  while IFS= read -r boot_line; do
    # systemd 252（Debian 12）格式为 "... CST—Mon ..."（em dash 无空格），
    # 253+ 为表格格式；统一把 em dash 换成空格并去掉星期字段后按 8 字段解析
    boot_line="${boot_line//—/ }"
    IFS=' ' read -r -a boot_raw <<< "$boot_line"
    boot_fields=()
    for boot_token in "${boot_raw[@]}"; do
      [[ "$boot_token" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]] && continue
      boot_fields+=("$boot_token")
    done
    [[ ${#boot_fields[@]} -ge 8 ]] || continue
    boot_id="${boot_fields[1]}"
    [[ "$boot_id" =~ ^[0-9a-f]{8,}$ ]] || continue
    if [[ ${#boot_fields[@]} -eq 8 ]]; then
      sd="${boot_fields[2]}"; st="${boot_fields[3]}"
      ed="${boot_fields[5]}"; et="${boot_fields[6]}"
    elif [[ ${#boot_fields[@]} -eq 10 ]]; then
      sd="${boot_fields[3]}"; st="${boot_fields[4]}"
      ed="${boot_fields[7]}"; et="${boot_fields[8]}"
    else
      continue
    fi
    # journalctl 按本地时区输出；不把时区缩写交给 date 解析（GNU date 把 CST 当作 UTC-6，
    # 在 Asia/Shanghai 下会偏 14 小时）
    start_epoch=$(date -d "$sd $st" '+%s' 2>/dev/null || true)
    end_epoch=$(date -d "$ed $et" '+%s' 2>/dev/null || true)
    [[ "$start_epoch" =~ ^[0-9]+$ ]] || continue
    [[ "$end_epoch" =~ ^[0-9]+$ ]] || end_epoch="$until_epoch"
    overlap_start=$(( start_epoch > since_epoch ? start_epoch : since_epoch ))
    overlap_end=$(( end_epoch < until_epoch ? end_epoch : until_epoch ))
    if [[ "$overlap_end" -gt "$overlap_start" ]]; then
      online_seconds=$((online_seconds + overlap_end - overlap_start))
    fi
    if [[ "$start_epoch" -ge "$since_epoch" && "$start_epoch" -le "$until_epoch" ]]; then
      reboot_count=$((reboot_count + 1))
      local planned_marker=0 update_epoch
      for update_epoch in "${OPS_UPDATE_EPOCHS[@]}"; do
        [[ "$update_epoch" =~ ^[0-9]+$ ]] || continue
        if [[ "$update_epoch" -ge $((start_epoch - 900)) && "$update_epoch" -le $((start_epoch + 300)) ]]; then
          planned_marker=1
          break
        fi
      done
      if [[ "$planned_marker" -eq 1 ]]; then
        planned_count=$((planned_count + 1))
      else
        unplanned_count=$((unplanned_count + 1))
      fi
    fi
  done <<< "$boot_output"

  OPS_REBOOT_COUNT="$reboot_count"
  OPS_PLANNED_DOWNTIME_COUNT="$planned_count"
  OPS_UNPLANNED_DOWNTIME_COUNT="$unplanned_count"
  if [[ "$total_seconds" -gt 0 ]]; then
    OPS_AVAILABILITY_PCT=$(awk -v o="$online_seconds" -v t="$total_seconds" \
      'BEGIN { if (t > 0) printf "%.2f%%", (o * 100) / t; else print "待周期数据" }')
  else
    OPS_AVAILABILITY_PCT="待周期数据"
  fi
}

ops_physical_disk_usage() {
  command -v lsblk >/dev/null 2>&1 || return 0
  local disk_name disk_size disk_type
  while IFS=' ' read -r disk_name disk_size disk_type; do
    [[ "$disk_type" == "disk" ]] || continue
    local model=""
    [[ -r "/sys/block/${disk_name}/device/model" ]] \
      && model=$(cat "/sys/block/${disk_name}/device/model" 2>/dev/null || true)
    local disk_type="未知"
    if [[ -r "/sys/block/${disk_name}/queue/rotational" ]]; then
      local rotational
      rotational=$(cat "/sys/block/${disk_name}/queue/rotational" 2>/dev/null || true)
      if [[ "$rotational" == "0" ]]; then
        disk_type="SSD"
      elif [[ "$rotational" == "1" ]]; then
        disk_type="HDD"
      fi
    fi
    local total_size=0 total_used=0 mounts=""
    local part part_name mp df_line
    while read -r part; do
      part_name="${part%% *}"
      mp=$(lsblk -no MOUNTPOINT "/dev/${part_name}" 2>/dev/null || true)
      [[ -n "$mp" ]] || continue
      df_line=$(df -P "$mp" 2>/dev/null | tail -1 || true)
      if [[ -n "$df_line" ]]; then
        local sz us
        IFS=' ' read -r _ sz us _ <<< "$df_line"
        if [[ "$sz" =~ ^[0-9]+$ ]]; then total_size=$((total_size + sz)); fi
        if [[ "$us" =~ ^[0-9]+$ ]]; then total_used=$((total_used + us)); fi
        mounts="${mounts:+${mounts}, }${mp}"
      fi
    done < <(lsblk -rn -o NAME,TYPE "/dev/${disk_name}" 2>/dev/null || true)

    if [[ "$total_size" -gt 0 ]]; then
      local pct
      pct=$(awk -v u="$total_used" -v s="$total_size" 'BEGIN { printf "%d", (u * 100) / s }')
      printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$disk_name" "$(ops_format_bytes "$disk_size")" "$(ops_format_bytes "$total_used")" \
        "$pct" "${mounts:-未挂载}" "${model:-未知型号}" "$disk_type"
    fi
  done < <(lsblk -dnbo NAME,SIZE,TYPE 2>/dev/null || true)
}

# 磁盘容量预测：按"基线快照 → 当前"的使用率增速线性外推到 90% 告警线
# 快照文件 disk-usage.snapshot 每行 "盘名|使用率|采集时刻(epoch)"；每块盘每天保留一条、最多保留 400 天。
# 基线取报告周期内（周期天数 + 1 天余量）最早、且距今不少于 1 天的一条：
#   同一天内重复生成报告不会把基线冲掉，也不会拿几分钟的间隔外推出离谱的增速
# 输出 OPS_DISK_FORECAST：每行 "盘名|当前使用率|基线天数|日增速(百分点/天)|距 90% 天数"
#   没有可用基线时后三列为空；增速 <= 0 或已达 90% 时最后一列为空
ops_collect_disk_trend() {
  OPS_DISK_FORECAST=""
  [[ -n "${OPS_SNAPSHOT_DIR:-}" ]] || return 0
  mkdir -p "$OPS_SNAPSHOT_DIR" 2>/dev/null || true

  local snapshot="${OPS_SNAPSHOT_DIR}/disk-usage.snapshot"
  local now_ts period="${OPS_REPORT_DAYS:-7}" today_start
  now_ts=$(date '+%s')
  [[ "$period" =~ ^[0-9]+$ ]] || period=7
  # "当天已有样本"按本地日期判断：epoch/86400 是 UTC 日界，在东八区早上 8 点、
  # 西半球傍晚会切到另一天，同一天采集的两条样本都被留下（基线被冲掉）
  today_start=$(date -d '00:00' '+%s' 2>/dev/null || echo 0)
  [[ "$today_start" =~ ^[0-9]+$ ]] || today_start=0
  local min_ts=$((now_ts - (period + 1) * 86400)) keep_ts=$((now_ts - 400 * 86400))
  local -A base_pct=() base_ts=()
  local -a kept=()
  local name pct ts
  if [[ -f "$snapshot" ]]; then
    while IFS='|' read -r name pct ts; do
      [[ "$name" =~ ^[a-zA-Z0-9_]+$ && "$pct" =~ ^[0-9]+$ && "$ts" =~ ^[0-9]+$ ]] || continue
      [[ "$ts" -gt "$keep_ts" && "$ts" -le "$now_ts" ]] || continue
      # 当天已有的样本由本次采集替换
      [[ "$today_start" -gt 0 && "$ts" -ge "$today_start" ]] || kept+=("${name}|${pct}|${ts}")
      if [[ "$ts" -ge "$min_ts" && $((now_ts - ts)) -ge 86400 ]] \
        && [[ -z "${base_ts[$name]:-}" || "$ts" -lt "${base_ts[$name]:-0}" ]]; then
        base_pct[$name]="$pct"
        base_ts[$name]="$ts"
      fi
    done < "$snapshot"
  fi

  local forecast_rows="" span growth eta
  while IFS='|' read -r name _ _ pct _; do
    [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]] || continue
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    span="" growth="" eta=""
    if [[ -n "${base_ts[$name]:-}" ]]; then
      IFS=' ' read -r span growth eta < <(awk -v c="$pct" -v o="${base_pct[$name]}" \
        -v e="$((now_ts - ${base_ts[$name]}))" 'BEGIN {
          g = (c - o) * 86400 / e
          eta = (g > 0 && c < 90) ? sprintf("%.0f", (90 - c) / g) : "-"
          printf "%.0f %.2f %s\n", e / 86400, g, eta
        }')
      [[ "$eta" == "-" ]] && eta=""
    fi
    forecast_rows="${forecast_rows:+${forecast_rows}
}${name}|${pct}|${span}|${growth}|${eta}"
    kept+=("${name}|${pct}|${now_ts}")
  done <<< "${OPS_DISK_USAGE_LINES:-}"
  OPS_DISK_FORECAST="$forecast_rows"

  local tmp="${snapshot}.tmp"
  if [[ ${#kept[@]} -gt 0 ]]; then
    printf '%s\n' "${kept[@]}" > "$tmp"
  else
    : > "$tmp"
  fi
  mv "$tmp" "$snapshot" 2>/dev/null || true
}

# 运行中内核对应的 Debian 包版本（stdout 一行）
# 包名是 linux-image-$(uname -r)（形如 linux-image-6.1.0-18-amd64，带架构后缀）；元包 linux-image-amd64 的版本
# 是"最新已安装内核"，重启前与运行中的内核不一致，cloud/rt 等风味的元包名也不同，所以不查元包。
# 查不到（容器、PVE 等非 Debian 内核）时取 uname -v 里的版本串（"… Debian 6.1.76-1 (2024-02-01)" → 6.1.76-1），
# 仍取不到则输出 uname -r
ops_kernel_pkg_version() {
  local rel ver=""
  rel=$(uname -r 2>/dev/null || true)
  if [[ -n "$rel" ]] && command -v dpkg-query >/dev/null 2>&1; then
    # dpkg-query 对"已知但未安装"的包也返回 0（Version 为空），按安装状态过滤
    ver=$(dpkg-query -W -f='${db:Status-Status} ${Version}\n' "linux-image-${rel}" 2>/dev/null \
      | awk '$1 == "installed" && $2 != "" { print $2; exit }' || true)
  fi
  if [[ -z "$ver" ]]; then
    ver=$(uname -v 2>/dev/null \
      | awk '{ for (i = 2; i <= NF; i++) if ($i ~ /^\(/ && $(i - 1) ~ /^[0-9]+[.][0-9]/) { print $(i - 1); exit } }' || true)
  fi
  printf '%s\n' "${ver:-${rel:-未知}}"
}

# 最近一次内核元包升级：stdout 一行 "升级前版本|时间"，没有记录时无输出
# 参数：$1 - dpkg 日志（可选，默认 /var/log/dpkg.log）
# 元包名随风味/架构变化（linux-image-amd64、linux-image-cloud-amd64、linux-image-arm64 …）；
# dpkg.log 行格式："日期 时间 upgrade 包名:架构 旧版本 新版本"，上一版本是第 5 列
ops_kernel_prev_upgrade() {
  local log="${1:-/var/log/dpkg.log}"
  [[ -f "$log" ]] || return 0
  awk '$3 == "upgrade" && $4 ~ /^linux-image-([a-z]+-)?(amd64|arm64|686|686-pae)(:|$)/ { prev = $5; at = $1 " " $2 }
    END { if (prev != "") print prev "|" at }' "$log" 2>/dev/null || true
}

# 输出安全源索引里的包名（去重，每行一个）
# 参数：$1 - apt 列表目录（可选，默认 /var/lib/apt/lists）
# 返回：始终 0。没有 security 源（glob 不匹配）或索引被压缩存放（Acquire::GzipIndexes 等）时，
#       原来的 grep 管道返回非 0，会在 set -e 下中止整份报告；压缩索引经 apt-helper cat-file 解压读取
ops_security_package_names() {
  local dir="${1:-/var/lib/apt/lists}" f
  local -a files=()
  for f in "$dir"/*security*Packages*; do
    if [[ -f "$f" ]]; then files+=("$f"); fi
  done
  [[ "${#files[@]}" -gt 0 ]] || return 0
  {
    if [[ -x /usr/lib/apt/apt-helper ]]; then
      /usr/lib/apt/apt-helper cat-file "${files[@]}"
    else
      cat -- "${files[@]}"
    fi
  } 2>/dev/null | awk '/^Package:/ {print $2}' | sort -u || true
  return 0
}

# 统计更新会话数：相邻 dpkg 记录间隔 >120s 视为新会话（与更新明细表口径一致）
# 参数：无（读取 OPS_UPDATE_LIST）
# 输出：会话数
ops_update_session_count() {
  ops_update_epochs
  local prev_epoch=0 current_epoch count=0 first=1 i
  for i in "${!OPS_UPDATE_EPOCHS[@]}"; do
    current_epoch="${OPS_UPDATE_EPOCHS[$i]:-}"
    [[ "$current_epoch" =~ ^[0-9]+$ ]] || continue
    if [[ $first -eq 1 ]] || (( current_epoch - prev_epoch > 120 )); then
      count=$((count + 1))
      first=0
    fi
    prev_epoch=$current_epoch
  done
  printf '%s' "$count"
}

ops_collect_updates() {
  OPS_UPDATE_COUNT=0
  OPS_UPDATE_SESSIONS=0
  OPS_UPDATE_LIST=""
  OPS_PENDING_UPDATE_COUNT=0
  OPS_PENDING_SECURITY_COUNT=0
  OPS_PENDING_REGULAR_COUNT=0
  OPS_SYSTEM_VERSION_LINES=""
  OPS_SECURITY_INSTALLED_COUNT=0
  OPS_REGULAR_INSTALLED_COUNT=0
  OPS_SECURITY_PACKAGES=""
  OPS_SSL_SUMMARY="无数据/未启用"
  OPS_LAST_UPDATE_CHECK="待采集"
  OPS_REBOOT_REQUIRED="无"

  local since_dt="${OPS_REPORT_SINCE:-}"
  local until_dt="${OPS_REPORT_UNTIL:-}"
  if [[ -f /var/log/dpkg.log ]]; then
    OPS_UPDATE_LIST=$(awk -v since="$since_dt" -v until="$until_dt" '
      ($1" "$2) >= since && ($1" "$2) <= until && ($3 == "install" || $3 == "upgrade") { print }
    ' /var/log/dpkg.log 2>/dev/null || true)
    OPS_UPDATE_COUNT=$(printf '%s\n' "${OPS_UPDATE_LIST}" | grep -v '^$' | wc -l || true)
    OPS_UPDATE_SESSIONS=$(ops_update_session_count)
    local security_pkgs
    security_pkgs=$(ops_security_package_names /var/lib/apt/lists || true)
    if [[ -n "$security_pkgs" ]] && [[ -n "$OPS_UPDATE_LIST" ]]; then
      OPS_SECURITY_PACKAGES="$security_pkgs"
      OPS_SECURITY_INSTALLED_COUNT=$(printf '%s\n' "${OPS_UPDATE_LIST}" \
        | awk '{print $4}' | sed 's/:.*//' | sort -u \
        | grep -Fxf <(printf '%s\n' "$security_pkgs") | wc -l || true)
      OPS_REGULAR_INSTALLED_COUNT=$((OPS_UPDATE_COUNT > OPS_SECURITY_INSTALLED_COUNT ? OPS_UPDATE_COUNT - OPS_SECURITY_INSTALLED_COUNT : OPS_UPDATE_COUNT))
    else
      OPS_SECURITY_INSTALLED_COUNT=-1
      OPS_REGULAR_INSTALLED_COUNT=-1
    fi
  fi

  if command -v apt-get >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    local upgrade_preview up_rc=0
    upgrade_preview=$(timeout 30 apt-get -s upgrade 2>/dev/null) || up_rc=$?
    if [[ "$up_rc" -ne 0 && -z "$upgrade_preview" ]]; then
      # 模拟升级失败/超时与“确实为 0”不可区分；用 -1 表示未知，界面显示“待解析”
      OPS_PENDING_UPDATE_COUNT=-1
      OPS_PENDING_SECURITY_COUNT=-1
      OPS_PENDING_REGULAR_COUNT=-1
    else
      OPS_PENDING_UPDATE_COUNT=$(printf '%s\n' "$upgrade_preview" | grep -c '^Inst ' || true)
      OPS_PENDING_SECURITY_COUNT=$(printf '%s\n' "$upgrade_preview" \
        | grep -ci 'Debian-Security\|security' || true)
      OPS_PENDING_REGULAR_COUNT=$((OPS_PENDING_UPDATE_COUNT > OPS_PENDING_SECURITY_COUNT ? OPS_PENDING_UPDATE_COUNT - OPS_PENDING_SECURITY_COUNT : 0))
    fi
  fi

  local os_version kernel_version ssl_version docker_version
  os_version="未知"
  kernel_version="${OPS_KERNEL:-未知}"
  ssl_version="未安装"
  docker_version="未安装"
  if command -v dpkg-query >/dev/null 2>&1; then
    os_version=$(dpkg-query -W -f='${Version}' base-files 2>/dev/null || echo "未知")
    kernel_version=$(ops_kernel_pkg_version)
    ssl_version=$(dpkg-query -W -f='${Version}' openssl 2>/dev/null || echo "未安装")
    docker_version=$(dpkg-query -W -f='${Version}' docker.io 2>/dev/null || true)
    if [[ -z "$docker_version" ]] && command -v docker >/dev/null 2>&1; then
      docker_version=$(docker --version 2>/dev/null | sed 's/^Docker version //' || true)
    fi
    [[ -n "$docker_version" ]] || docker_version="未安装"
  fi

  local prev_kernel="" prev_time=""
  IFS='|' read -r prev_kernel prev_time <<< "$(ops_kernel_prev_upgrade /var/log/dpkg.log)"
  OPS_SYSTEM_VERSION_LINES=$(printf '操作系统|Debian %s|无数据|-\n内核|%s|%s|%s\nOpenSSL|%s|无数据|-\nDocker|%s|无数据|-\n' \
    "$os_version" "$kernel_version" "${prev_kernel:-无数据}" "${prev_time:--}" \
    "$ssl_version" "$docker_version")

  if command -v openssl >/dev/null 2>&1; then
    local cert_file=""
    local f
    for f in /etc/letsencrypt/live/*/fullchain.pem /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/private/*.pem; do
      [[ -f "$f" ]] || continue
      cert_file="$f"
      break
    done
    if [[ -n "$cert_file" ]]; then
      local enddate
      enddate=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null \
        | cut -d= -f2- | tr -d '\n' || true)
      if [[ -n "$enddate" ]]; then
        OPS_SSL_SUMMARY="${cert_file##*/} 将于 $(ops_normalize_date "$enddate") 到期"
      fi
    fi
  fi

  if [[ -d /var/lib/apt/lists ]]; then
    OPS_LAST_UPDATE_CHECK=$(stat -c '%y' /var/lib/apt/lists 2>/dev/null | cut -d. -f1 || true)
    [[ -n "$OPS_LAST_UPDATE_CHECK" ]] || OPS_LAST_UPDATE_CHECK="待采集"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    OPS_REBOOT_REQUIRED="是，存在 /var/run/reboot-required"
  fi
}

# 设备 I/O 峰值繁忙度（OPS_DISK_IO_SUMMARY 第 4 列最大值）
ops_disk_io_peak() {
  printf '%s\n' "${OPS_DISK_IO_SUMMARY}" \
    | awk -F'|' 'BEGIN { m = 0 } { if ($4 + 0 > m) m = $4 + 0 } END { print m }'
}

# 平均速率（kB/s）× 采样天数换算为周期累计字节数
# 参数：$1 - 平均速率（kB/s）；$2 - 该指标的采样天数（可选，默认全局 SAMPLE_DAYS）
ops_rate_bytes() {
  awk -v v="${1:-0}" -v d="${2:-${OPS_SYSSTAT_SAMPLE_DAYS:-1}}" 'BEGIN { printf "%.0f", v * 1024 * 86400 * d }'
}

ops_add_action() {
  local priority="$1" text="$2"
  local item existing
  item="[${priority}] ${text}"
  for existing in "${OPS_ACTION_ITEMS[@]:-}"; do
    [[ "$existing" == "$item" ]] && return 0
  done
  OPS_ACTION_ITEMS+=("$item")
}

ops_determine_status() {
  OPS_STATUS="green"
  OPS_STATUS_TEXT="正常"
  OPS_ACTION_ITEMS=()
  OPS_ACTION_COUNT=0
  OPS_EVENTS=""
  OPS_NEW_LISTEN_PORT_COUNT=0
  OPS_RISK_HIGH=0
  OPS_RISK_MEDIUM=0
  OPS_RISK_LOW=0
  OPS_SECURITY_CONCLUSION="未发现入侵迹象"
  OPS_HEALTH_ISSUE_SUMMARY=""
  local disk_event="" disk_impact="" disk_event_time=""

  local disk_pct
  while IFS='|' read -r _ _ _ disk_pct _ _; do
    [[ "$disk_pct" =~ ^[0-9]+$ ]] || continue
    if [[ "$disk_pct" -ge 90 ]]; then
      OPS_STATUS="red"
      ops_add_action "高" "磁盘使用率已达 ${disk_pct}%，请立即检查空间"
      disk_event="磁盘使用率已达 ${disk_pct}%"
      disk_impact="高风险 · 容量不足"
    elif [[ "$disk_pct" -ge 80 ]]; then
      [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
      ops_add_action "中" "磁盘使用率 ${disk_pct}%，建议规划扩容"
      disk_event="磁盘使用率 ${disk_pct}%"
      disk_impact="中风险 · 容量偏高"
    fi
  done <<< "${OPS_DISK_USAGE_LINES}"

  if [[ "${OPS_HEALTH_SMART_ALERT:-0}" -eq 1 ]] || [[ "${OPS_HEALTH_RAID_ALERT:-0}" -eq 1 ]] \
    || [[ "${OPS_HEALTH_FS_ALERT:-0}" -eq 1 ]] || [[ "${OPS_HEALTH_LOG_ALERT:-0}" -eq 1 ]]; then
    OPS_STATUS="red"
    local -a health_parts=()
    [[ "${OPS_HEALTH_SMART_ALERT:-0}" -eq 1 ]] && health_parts+=("SMART 异常")
    [[ "${OPS_HEALTH_RAID_ALERT:-0}" -eq 1 ]] && health_parts+=("RAID 降级")
    [[ "${OPS_HEALTH_FS_ALERT:-0}" -eq 1 ]] && health_parts+=("文件系统只读/异常")
    if [[ "${OPS_HEALTH_FS_ERROR_ALERT:-0}" -eq 1 ]]; then
      health_parts+=("文件系统错误")
    fi
    if [[ "${OPS_HEALTH_KERNEL_ERROR_ALERT:-0}" -eq 1 ]]; then
      health_parts+=("内核错误")
    fi
    if [[ ${#health_parts[@]} -gt 0 ]]; then
      OPS_HEALTH_ISSUE_SUMMARY=$(IFS='、'; echo "${health_parts[*]}")
    else
      OPS_HEALTH_ISSUE_SUMMARY="${OPS_HEALTH_LOG_SUMMARY:-系统日志异常}"
    fi
    disk_event="检测到${OPS_HEALTH_ISSUE_SUMMARY}"
    disk_impact="高风险 · 服务风险升高"
    ops_add_action "高" "检测到${OPS_HEALTH_ISSUE_SUMMARY}"
  fi

  local cpu_num=0 mem_num=0
  [[ "$OPS_CPU_AVG" =~ ^[0-9.]+$ ]] && cpu_num="${OPS_CPU_AVG}"
  [[ "$OPS_MEM_AVG" =~ ^[0-9.]+$ ]] && mem_num="${OPS_MEM_AVG}"
  if awk -v c="$cpu_num" 'BEGIN { exit !(c >= 95) }'; then
    OPS_STATUS="red"
    ops_add_action "高" "CPU 长期使用率较高"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${OPS_CPU_PEAK_DATE:-${OPS_REPORT_UNTIL}}|CPU 平均使用率 ${cpu_num}%|高风险 · 长期高占用|待处理"
  elif awk -v c="$cpu_num" 'BEGIN { exit !(c >= 80) }'; then
    [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
    ops_add_action "中" "CPU 平均使用率偏高"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${OPS_CPU_PEAK_DATE:-${OPS_REPORT_UNTIL}}|CPU 平均使用率 ${cpu_num}%|中风险 · 长期高占用|待处理"
  fi
  if awk -v m="$mem_num" 'BEGIN { exit !(m >= 95) }'; then
    OPS_STATUS="red"
    ops_add_action "高" "内存长期使用率较高"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${OPS_MEM_PEAK_DATE:-${OPS_REPORT_UNTIL}}|内存平均使用率 ${mem_num}%|高风险 · 长期高占用|待处理"
  elif awk -v m="$mem_num" 'BEGIN { exit !(m >= 85) }'; then
    [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
    ops_add_action "中" "内存平均使用率偏高"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${OPS_MEM_PEAK_DATE:-${OPS_REPORT_UNTIL}}|内存平均使用率 ${mem_num}%|中风险 · 长期高占用|待处理"
  fi

  if [[ -n "$OPS_DISK_IO_SUMMARY" ]]; then
    local disk_max
    disk_max=$(ops_disk_io_peak)
    if awk -v v="$disk_max" 'BEGIN { exit !(v >= 80) }'; then
      [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
      ops_add_action "中" "磁盘峰值繁忙度 ${disk_max}%"
      if [[ -z "$disk_event" ]]; then
        disk_event="磁盘 I/O 异常"
        disk_impact="中风险 · 峰值繁忙 ${disk_max}%"
        disk_event_time="${OPS_DISK_IO_PEAK_DATE:-${OPS_REPORT_UNTIL}}"
      fi
    fi
  fi
  if [[ -n "$disk_event" ]]; then
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${disk_event_time:-${OPS_REPORT_UNTIL}}|${disk_event}|${disk_impact}|待处理"
  fi

  if [[ "${OPS_SYSTEMD_FAILED_COUNT:-0}" -gt 0 ]]; then
    [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
    local failed_event_time="${OPS_REPORT_UNTIL}"
    if [[ -n "${OPS_SERVICE_STABILITY:-}" ]]; then
      failed_event_time=$(printf '%s\n' "${OPS_SERVICE_STABILITY}" \
        | awk -F'|' '$5 == "failed" && $4 != "" && $4 != "-" { print $4; exit }')
    fi
    [[ -n "$failed_event_time" ]] || failed_event_time="${OPS_REPORT_UNTIL}"
    failed_event_time=$(ops_normalize_date "$failed_event_time")
    [[ "$failed_event_time" != "-" ]] || failed_event_time="${OPS_REPORT_UNTIL}"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${failed_event_time}|存在 ${OPS_SYSTEMD_FAILED_COUNT} 个失败服务|中风险 · 服务状态异常|待处理"
    ops_add_action "中" "存在 ${OPS_SYSTEMD_FAILED_COUNT} 个失败服务"
  fi
  if [[ "${OPS_UPDATE_COUNT:-0}" -gt 0 && -n "${OPS_UPDATE_LIST:-}" ]]; then
    local update_session_key="" update_session_count=0 update_prev_epoch="" update_epoch
    local update_date update_time update_idx=-1
    ops_update_epochs
    while IFS=' ' read -r update_date update_time _; do
      update_idx=$((update_idx + 1))
      [[ -n "$update_date" ]] || continue
      update_epoch="${OPS_UPDATE_EPOCHS[update_idx]:-}"
      if [[ -z "$update_session_key" ]] \
        || [[ -n "$update_prev_epoch" && -n "$update_epoch" && $((update_epoch - update_prev_epoch)) -gt 120 ]]; then
        if [[ -n "$update_session_key" ]]; then
          OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${update_session_key}|系统更新（${update_session_count} 个软件包）|低风险 · 维护完成|已完成"
        fi
        update_session_key="${update_date} ${update_time}"
        update_session_count=0
      fi
      update_session_count=$((update_session_count + 1))
      [[ -n "$update_epoch" ]] && update_prev_epoch="$update_epoch"
    done <<< "${OPS_UPDATE_LIST}"
    if [[ -n "$update_session_key" ]]; then
      OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${update_session_key}|系统更新（${update_session_count} 个软件包）|低风险 · 维护完成|已完成"
    fi
  fi
  if [[ "${OPS_PENDING_SECURITY_COUNT:-0}" -gt 0 ]]; then
    [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${OPS_REPORT_UNTIL}|发现 ${OPS_PENDING_SECURITY_COUNT} 个安全更新待装|风险升高|待处理"
    ops_add_action "中" "存在 ${OPS_PENDING_SECURITY_COUNT} 个可用安全更新"
  fi
  if [[ "${OPS_SECURITY_ISSUE:-0}" -eq 1 ]]; then
    [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
    local login_event_desc="发现异常登录"
    [[ "${OPS_ABNORMAL_LOGIN_COUNT:-0}" -eq 0 ]] && login_event_desc="发现失败登录集中"
    local login_event_time="${OPS_REPORT_UNTIL}"
    if [[ -n "${OPS_SECURITY_EVENTS:-}" ]]; then
      local raw_login="${OPS_SECURITY_EVENTS%%$'\n'*}"
      raw_login="${raw_login#*：}"
      login_event_time=$(printf '%s\n' "$raw_login" \
        | awk '{ sub(/^[^ ]+ [^ ]+ /, ""); print }')
      if [[ -n "$login_event_time" ]]; then
        login_event_time=$(date -d "$login_event_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$OPS_REPORT_UNTIL")
      fi
    fi
    [[ -n "$login_event_time" ]] || login_event_time="${OPS_REPORT_UNTIL}"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${login_event_time}|${login_event_desc}|安全事件，待确认|处理中"
    ops_add_action "中" "存在异常登录或失败登录集中"
  fi
  if [[ "${OPS_SUSPICIOUS_PROGRAM_COUNT:-0}" -gt 0 ]]; then
    [[ "$OPS_STATUS" == "green" ]] && OPS_STATUS="yellow"
    OPS_EVENTS="${OPS_EVENTS:+${OPS_EVENTS}
}${OPS_REPORT_UNTIL}|发现 ${OPS_SUSPICIOUS_PROGRAM_COUNT} 个可疑进程|安全事件，待确认|处理中"
    ops_add_action "中" "发现 ${OPS_SUSPICIOUS_PROGRAM_COUNT} 个可疑进程"
  fi

  OPS_ACTION_COUNT=${#OPS_ACTION_ITEMS[@]}
  local risk_item
  for risk_item in "${OPS_ACTION_ITEMS[@]}"; do
    case "$risk_item" in
      "[高]"*) OPS_RISK_HIGH=$((OPS_RISK_HIGH + 1)) ;;
      "[中]"*) OPS_RISK_MEDIUM=$((OPS_RISK_MEDIUM + 1)) ;;
      "[低]"*) OPS_RISK_LOW=$((OPS_RISK_LOW + 1)) ;;
    esac
  done
  local security_findings=""
  [[ "${OPS_ABNORMAL_LOGIN_COUNT:-0}" -gt 0 ]] && security_findings="${OPS_ABNORMAL_LOGIN_COUNT} 项异常登录"
  [[ "${OPS_SUSPICIOUS_PROGRAM_COUNT:-0}" -gt 0 ]] && security_findings="${security_findings:+${security_findings}、}${OPS_SUSPICIOUS_PROGRAM_COUNT} 项可疑进程"
  if [[ -n "$security_findings" ]]; then
    OPS_SECURITY_CONCLUSION="存在 ${security_findings}待确认"
  fi
  if [[ "$OPS_STATUS" == "red" ]]; then
    OPS_STATUS_TEXT="需处理"
  elif [[ "$OPS_STATUS" == "yellow" ]]; then
    OPS_STATUS_TEXT="需要关注"
  else
    OPS_STATUS_TEXT="正常"
  fi
}

ops_render_trend_chart() {
  local values="${1:-}" color="${2:-#22D3EE}" unit="${3:-%}" width="${4:-480}" height="${5:-190}" labels="${6:-}" gid="${7:-}"
  local labels_arg="$labels"
  if [[ -z "$labels_arg" ]] || [[ "$(ops_value_count "$labels_arg")" -lt "$(ops_value_count "$values")" ]]; then
    labels_arg=$(ops_auto_labels "$values")
  fi
  local aria_label="趋势图"
  case "$gid" in
    Cpu) aria_label="CPU 使用率趋势" ;;
    Mem) aria_label="内存使用率趋势" ;;
  esac
  awk -v values="$values" -v color="$color" -v unit="$unit" -v w="$width" -v h="$height" \
      -v labels="$labels_arg" -v gid="$gid" -v aria_label="$aria_label" '
    function ceil(x) { return int(x) + (x > int(x)) }
    BEGIN {
      gid = (gid == "") ? "Trend" : gid
      gsub(/[^0-9., ]+/, " ", values)
      gsub(/,+/, " ", values)
      n = split(values, arr, / +/)
      no_data = 0
      if (n == 0 || (n == 1 && arr[1] == "")) {
        n = 7
        for (i = 1; i <= n; i++) arr[i] = 0
        no_data = 1
      }
      single = (!no_data && n == 1)
      if (unit == "%") {
        max = 100
      } else {
        max = arr[1]
        for (i = 2; i <= n; i++) if (arr[i] > max) max = arr[i]
        if (max <= 0) max = 1
        step = ceil(max / 4)
        max = step * 4
      }
      left = 48; right = w - 25; top = 15; bottom = h - 30
      printf "<svg class=\"chart\" viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"%s\">", w, h, aria_label
      printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#D2D2D7\"/>", left, bottom, right, bottom
      printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#D2D2D7\"/>", left, bottom, left, top
      for (t = 0; t <= 4; t++) {
        y = bottom - ((bottom - top) * t / 4)
        printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#E8E8ED\" stroke-dasharray=\"3 3\"/>", left, y, right, y
      }
      printf "<g fill=\"#86868B\" font-size=\"11\" text-anchor=\"end\">"
      for (t = 0; t <= 4; t++) {
        y = bottom - ((bottom - top) * t / 4)
        if (unit == "%") {
          label = t * 25
        } else {
          label = int((max * t) / 4)
        }
        printf "<text x=\"%d\" y=\"%d\">%d%s</text>", left - 8, y + 3, label, unit
      }
      printf "</g>"
      if (!no_data && single) {
        x = left
        y = bottom - ((bottom - top) * arr[1] / max)
        printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"%s\"/>", x, y, color
        printf "<text x=\"%.1f\" y=\"%.1f\" fill=\"%s\" font-size=\"11\" font-weight=\"700\">%.1f%s</text>", x + 8, y - 4, color, arr[1], unit
      } else if (!no_data) {
        path_points = ""
        peak_i = 1
        peak_v = arr[1]
        for (i = 1; i <= n; i++) {
          x = left + ((i - 1) * (right - left) / (n - 1))
          y = bottom - ((bottom - top) * arr[i] / max)
          if (arr[i] > peak_v) { peak_v = arr[i]; peak_i = i }
          if (i == 1) {
            path_points = sprintf("M%.1f %.1f", x, y)
          } else {
            x_prev = left + ((i - 2) * (right - left) / (n - 1))
            y_prev = bottom - ((bottom - top) * arr[i - 1] / max)
            c1 = x_prev + ((x - x_prev) / 3)
            c2 = x - ((x - x_prev) / 3)
            path_points = path_points sprintf(" C%.1f %.1f, %.1f %.1f, %.1f %.1f", c1, y_prev, c2, y, x, y)
          }
        }
        printf "<path fill=\"none\" stroke=\"%s\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\" d=\"%s\"/>", color, path_points
        peak_x = left + ((peak_i - 1) * (right - left) / (n - 1))
        peak_y = bottom - ((bottom - top) * peak_v / max)
        if (peak_v > 0) {
          printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"%s\"/>", peak_x, peak_y, color
          printf "<text x=\"%.1f\" y=\"%.1f\" fill=\"%s\" font-size=\"11\" font-weight=\"700\">%.1f%s</text>", peak_x + 8, peak_y - 4, color, peak_v, unit
        }
        label_step = int((n + 6) / 7)
        if (label_step < 1) label_step = 1
        for (i = 1; i <= n; i++) {
          if ((i - 1) % label_step != 0) continue
          x = left + ((i - 1) * (right - left) / (n - 1))
          y = bottom - ((bottom - top) * arr[i] / max)
          printf "<text x=\"%.1f\" y=\"%.1f\" fill=\"%s\" font-size=\"9\" text-anchor=\"middle\">%.1f%s</text>", x, y - 6, color, arr[i], unit
        }
      } else {
        printf "<text x=\"%d\" y=\"%d\" fill=\"#86868B\" font-size=\"11\">待周期数据</text>", left + 8, bottom - 12
      }
      nl = split(labels, la, /[ ,]+/)
      printf "<g fill=\"#86868B\" font-size=\"11\" text-anchor=\"middle\">"
      if (n == 1) {
        lab = (nl >= 1) ? la[1] : "-"
        printf "<text x=\"%d\" y=\"%d\">%s</text>", left, h - 12, lab
      } else {
        step = int((n + 6) / 7)
        if (step < 1) step = 1
        for (i = 1; i <= n; i += step) {
          x = left + ((i - 1) * (right - left) / (n - 1))
          lab = (i <= nl) ? la[i] : "-"
          printf "<text x=\"%.1f\" y=\"%d\">%s</text>", x, h - 12, lab
        }
      }
      printf "</g></svg>"
    }'
}

ops_render_network_chart() {
  local rx_values="${1:-}" tx_values="${2:-}" width="${3:-480}" height="${4:-200}" labels="${5:-}"
  local labels_arg="$labels"
  if [[ -z "$labels_arg" ]] || [[ "$(ops_value_count "$labels_arg")" -lt "$(ops_value_count "$rx_values")" ]]; then
    labels_arg=$(ops_auto_labels "$rx_values")
  fi
  awk -v rx_values="$rx_values" -v tx_values="$tx_values" -v labels="$labels_arg" \
      -v w="$width" -v h="$height" '
    function ceil(x) { return int(x) + (x > int(x)) }
    function nice_num(x) {
      if (x <= 0) return 1
      e = int(log(x) / log(10))
      if (x < 1) e = e - 1
      p = 10 ^ e
      f = x / p
      if (f <= 1) nf = 1
      else if (f <= 2) nf = 2
      else if (f <= 5) nf = 5
      else nf = 10
      return nf * p
    }
    function fmt_axis(v, nice) {
      if (v == int(v)) return sprintf("%d", v)
      if (nice < 1) return sprintf("%.2f", v)
      return sprintf("%.1f", v)
    }
    function fmt_data(v) {
      if (v == int(v)) return sprintf("%d", v)
      if (v < 100) return sprintf("%.2f", v)
      return sprintf("%.1f", v)
    }
    BEGIN {
      gsub(/[^0-9., ]+/, " ", rx_values)
      gsub(/[^0-9., ]+/, " ", tx_values)
      gsub(/,+/, " ", rx_values)
      gsub(/,+/, " ", tx_values)
      nr = split(rx_values, rx, / +/)
      nt = split(tx_values, txarr, / +/)
      no_data = 0
      if ((nr == 0 || (nr == 1 && rx[1] == "")) \
          && (nt == 0 || (nt == 1 && txarr[1] == ""))) {
        n = 7
        for (i = 1; i <= n; i++) { rx[i] = 0; txarr[i] = 0 }
        no_data = 1
      } else {
        n = (nr > nt) ? nr : nt
        if (nr == 1 && rx[1] == "") nr = 0
        if (nt == 1 && txarr[1] == "") nt = 0
      }
      max = 0
      for (i = 1; i <= n; i++) {
        if (rx[i] + 0 > max) max = rx[i] + 0
        if (txarr[i] + 0 > max) max = txarr[i] + 0
      }
      if (max <= 0) max = 1
      nice = nice_num(max)
      left = 48; right = w - 25; top = 15; bottom = h - 30
      printf "<svg class=\"chart\" viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"每日网络流量\">", w, h
      printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#D2D2D7\"/>", left, bottom, right, bottom
      printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#D2D2D7\"/>", left, bottom, left, top
      for (t = 0; t <= 5; t++) {
        y = bottom - ((bottom - top) * t / 5)
        printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#E8E8ED\" stroke-dasharray=\"3 3\"/>", left, y, right, y
      }
      printf "<g fill=\"#86868B\" font-size=\"11\" text-anchor=\"end\">"
      for (t = 0; t <= 5; t++) {
        y = bottom - ((bottom - top) * t / 5)
        printf "<text x=\"%d\" y=\"%d\">%s</text>", left - 8, y + 3, fmt_axis((nice * t) / 5, nice)
      }
      printf "</g>"
      if (no_data) {
        printf "<text x=\"%d\" y=\"%d\" fill=\"#86868B\" font-size=\"11\">待周期数据</text>", left + 8, bottom - 12
      } else {
        slot = (right - left) / n
        bar_w = slot * 0.24
        if (bar_w > 16) bar_w = 16
        label_step = int((n + 6) / 7)
        if (label_step < 1) label_step = 1
        for (i = 1; i <= n; i++) {
          x = left + ((i - 1) * slot)
          rx_h = (bottom - top) * (rx[i] + 0) / nice
          tx_h = (bottom - top) * (txarr[i] + 0) / nice
          if (n == 1) {
            center = left + ((right - left) / 2)
            rx_x = center - bar_w - 3
            tx_x = center + 3
          } else {
            rx_x = x + slot * 0.18
            tx_x = x + slot * 0.54
          }
          if (rx_h > 0) {
            printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" rx=\"2\" fill=\"#0066CC\"/>", rx_x, bottom - rx_h, bar_w, rx_h
            if ((i - 1) % label_step == 0) {
              label_y = bottom - rx_h - 4
              if (label_y < 12) label_y = 14
              printf "<text x=\"%.1f\" y=\"%.1f\" fill=\"#0066CC\" font-size=\"9\" text-anchor=\"middle\">%s</text>", rx_x + bar_w / 2, label_y, fmt_data(rx[i] + 0)
            }
          }
          if (tx_h > 0) {
            printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" rx=\"2\" fill=\"#86868B\"/>", tx_x, bottom - tx_h, bar_w, tx_h
            if ((i - 1) % label_step == 0) {
              label_y = bottom - tx_h - 4
              if (label_y < 12) label_y = 14
              printf "<text x=\"%.1f\" y=\"%.1f\" fill=\"#86868B\" font-size=\"9\" text-anchor=\"middle\">%s</text>", tx_x + bar_w / 2, label_y, fmt_data(txarr[i] + 0)
            }
          }
        }
      }
      nl = split(labels, la, /[ ,]+/)
      printf "<g fill=\"#86868B\" font-size=\"11\" text-anchor=\"middle\">"
      if (n == 1) {
        lab = (nl >= 1) ? la[1] : "-"
        printf "<text x=\"%d\" y=\"%d\">%s</text>", left, h - 12, lab
      } else {
        step = int((n + 6) / 7)
        if (step < 1) step = 1
        for (i = 1; i <= n; i += step) {
          x = left + ((i - 1) * (right - left) / (n - 1))
          lab = (i <= nl) ? la[i] : "-"
          printf "<text x=\"%.1f\" y=\"%d\">%s</text>", x, h - 12, lab
        }
      }
      printf "</g></svg>"
    }'
}

ops_render_login_hours_chart() {
  local data="$1" width="${2:-480}" height="${3:-200}" abnormal_hours="${4:-}"
  awk -v data="$data" -v w="$width" -v h="$height" -v abnormal="$abnormal_hours" '
    function ceil(x) { return int(x) + (x > int(x)) }
    BEGIN {
      n = split(data, lines, "\n")
      for (i = 1; i <= n; i++) {
        split(lines[i], a, " ")
        if (a[1] ~ /^[0-9]+$/ && a[2] ~ /^[0-9]+$/) count[a[1]] = a[2] + 0
      }
      n_ab = split(abnormal, ab, / +/)
      for (i = 1; i <= n_ab; i++) if (ab[i] ~ /^[0-9]+$/) red[ab[i] + 0] = 1
      max = 0
      for (i = 0; i < 24; i++) if (count[i] > max) max = count[i]
      no_data = 0
      if (max <= 0) { max = 1; no_data = 1 }
      nice = max
      left = 24; right = w - 25; top = 24; bottom = h - 30
      printf "<svg class=\"chart\" viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"24 小时登录时段分布\">", w, h
      printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#D2D2D7\"/>", left, bottom, right, bottom
      printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#D2D2D7\"/>", left, bottom, left, top
      for (t = 0; t <= 4; t++) {
        y = bottom - ((bottom - top) * t / 4)
        printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#E8E8ED\" stroke-dasharray=\"3 3\"/>", left, y, right, y
      }
      printf "<g fill=\"#86868B\" font-size=\"11\" text-anchor=\"end\">"
      for (t = 0; t <= 4; t++) {
        y = bottom - ((bottom - top) * t / 4)
        val = (nice * t) / 4
        if (val == int(val)) {
          printf "<text x=\"%d\" y=\"%d\">%d</text>", left - 8, y + 3, int(val)
        } else {
          printf "<text x=\"%d\" y=\"%d\">%.1f</text>", left - 8, y + 3, val
        }
      }
      printf "</g>"
      printf "<text x=\"12\" y=\"14\" fill=\"#86868B\" font-size=\"11\">次数</text>"
      slot = (right - left) / 24
      for (i = 0; i < 24; i++) {
        bar_w = slot * 0.78
        if (bar_w > 14) bar_w = 14
        x = left + (i * slot) + ((slot - bar_w) / 2)
        bar_h = no_data ? 0 : ((bottom - top) * count[i] / nice)
        color = red[i] ? "#C7000B" : "#0066CC"
        printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" rx=\"1.5\" fill=\"%s\"/>", x, bottom - bar_h, bar_w, bar_h, color
      }
      if (no_data) {
        printf "<text x=\"%d\" y=\"%d\" fill=\"#86868B\" font-size=\"11\">待周期数据</text>", left + 8, bottom - 12
      }
      printf "<g fill=\"#86868B\" font-size=\"11\">"
      for (i = 0; i < 24; i += 2) {
        x = left + (i * slot)
        printf "<text x=\"%d\" y=\"%d\">%02d</text>", x, h - 2, i
      }
      printf "</g></svg>"
    }'
}

ops_render_network_metrics() {
  local rx="$OPS_NET_TOTAL_RX_BYTES" tx="$OPS_NET_TOTAL_TX_BYTES"
  local total=$((rx + tx))
  local avg_rx="--" avg_tx="--"
  local rx_label="待周期数据" tx_label="待周期数据" total_label="待周期数据"
  local net_days="${OPS_NET_SAMPLE_DAYS:-${OPS_SYSSTAT_SAMPLE_DAYS:-0}}"
  [[ "$net_days" -gt 0 ]] || net_days="${OPS_REPORT_DAYS:-7}"
  if [[ "$OPS_NET_TOTAL_LABEL" == "报告周期" ]]; then
    rx_label=$(ops_format_bytes "$rx")
    tx_label=$(ops_format_bytes "$tx")
    total_label=$(ops_format_bytes "$total")
    avg_rx=$(awk -v b="$rx" -v d="$net_days" 'BEGIN { if (d > 0) printf "%.1f", b / d; else print 0 }')
    avg_tx=$(awk -v b="$tx" -v d="$net_days" 'BEGIN { if (d > 0) printf "%.1f", b / d; else print 0 }')
  fi
  cat <<EOF
<div class="metric-group">
  <div class="metric"><div class="k">总接收</div><div class="v">${rx_label}</div></div>
  <div class="metric"><div class="k">总发送</div><div class="v">${tx_label}</div></div>
  <div class="metric"><div class="k">总流量</div><div class="v">${total_label}</div></div>
  <div class="metric"><div class="k">日均接收</div><div class="v">$([ "$avg_rx" == "--" ] && echo 待周期数据 || ops_format_bytes "$avg_rx")</div></div>
  <div class="metric"><div class="k">日均发送</div><div class="v">$([ "$avg_tx" == "--" ] && echo 待周期数据 || ops_format_bytes "$avg_tx")</div></div>
  <div class="metric"><div class="k">峰值速率</div><div class="v small">$([ "${OPS_NET_PEAK_RATE_MBPS:-待周期数据}" != "待周期数据" ] && printf '%s Mbps' "$OPS_NET_PEAK_RATE_MBPS" || echo 待周期数据)</div></div>
</div>
EOF
}

ops_render_update_table() {
  local -A session_total=()
  local -A session_sec=()
  local -A session_reg=()
  local -A session_rows=()
  local date time pkg old new pkg_base type key sec_pkg_name
  local prev_epoch="" session_key="" current_epoch line_idx=-1
  # 安全包名单可能上万行：建一次关联数组查表（原来每行 printf | grep -Fxq，
  # 名单超过管道缓冲时 grep -q 提前退出令 printf 收到 SIGPIPE，pipefail 下会被误判为常规更新）
  local -A security_pkgs=()
  while IFS= read -r sec_pkg_name; do
    [[ -n "$sec_pkg_name" ]] && security_pkgs["$sec_pkg_name"]=1
  done <<< "${OPS_SECURITY_PACKAGES:-}"
  ops_update_epochs
  while IFS=' ' read -r date time _ pkg old new _; do
    line_idx=$((line_idx + 1))
    [[ -n "$date" ]] || continue
    current_epoch="${OPS_UPDATE_EPOCHS[line_idx]:-}"
    if [[ -z "$session_key" ]] \
      || [[ -n "$prev_epoch" && -n "$current_epoch" && $((current_epoch - prev_epoch)) -gt 120 ]]; then
      session_key="${date} ${time}"
    fi
    key="$session_key"
    pkg_base="${pkg%:*}"
    type="常规"
    if [[ -n "$pkg_base" && -n "${security_pkgs["$pkg_base"]:-}" ]]; then
      type="安全"
    fi
    session_rows["$key"]="${session_rows["$key"]:+${session_rows["$key"]}
}${pkg}|${type}|${old}|${new}"
    session_total["$key"]=$(( ${session_total["$key"]:-0} + 1 ))
    if [[ "$type" == "安全" ]]; then
      session_sec["$key"]=$(( ${session_sec["$key"]:-0} + 1 ))
    else
      session_reg["$key"]=$(( ${session_reg["$key"]:-0} + 1 ))
    fi
    [[ -n "$current_epoch" ]] && prev_epoch="$current_epoch"
  done <<< "${OPS_UPDATE_LIST}"

  local -a keys=()
  local k
  for k in "${!session_rows[@]}"; do
    keys+=("$k")
  done
  readarray -t keys < <(printf '%s\n' "${keys[@]}" | sort -r)

  local -i max_sessions=15 session_count=0 hidden_sessions=0
  case "${OPS_REPORT_DAYS:-7}" in
    30) max_sessions=30 ;;
    365) max_sessions=60 ;;
  esac
  local key total sec_count reg_count show_count rowspan first idx
  local item pkg type old new shown_sec shown_reg rem_sec rem_reg
  for key in "${keys[@]:-}"; do
    [[ -n "$key" ]] || continue
    session_count=$((session_count + 1))
    if [[ "$session_count" -gt "$max_sessions" ]]; then
      hidden_sessions=$((hidden_sessions + 1))
      continue
    fi
    local -a sec_rows=()
    local -a reg_rows=()
    while IFS='|' read -r pkg type old new; do
      [[ -n "$pkg" ]] || continue
      if [[ "$type" == "安全" ]]; then
        sec_rows+=("${pkg}|${type}|${old}|${new}")
      else
        reg_rows+=("${pkg}|${type}|${old}|${new}")
      fi
    done <<< "${session_rows[$key]}"

    total="${session_total["$key"]:-0}"
    sec_count="${session_sec["$key"]:-0}"
    reg_count="${session_reg["$key"]:-0}"
    show_count="$total"
    [[ "$total" -gt 5 ]] && show_count=5
    rowspan="$show_count"
    [[ "$total" -gt 5 ]] && rowspan=$((show_count + 1))
    shown_sec="$sec_count"
    [[ "$shown_sec" -gt "$show_count" ]] && shown_sec="$show_count"
    shown_reg=$((show_count - shown_sec))
    [[ "$shown_reg" -gt "$reg_count" ]] && shown_reg="$reg_count"
    rem_sec=$((sec_count - shown_sec))
    rem_reg=$((reg_count - shown_reg))

    first=1
    idx=0
    for item in "${sec_rows[@]}" "${reg_rows[@]}"; do
      [[ "$idx" -lt "$show_count" ]] || break
      IFS='|' read -r pkg type old new <<< "$item"
      if [[ "$first" -eq 1 ]]; then
        printf '<tr><td rowspan="%s">%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' \
          "$rowspan" "$(ops_html_escape "$key")" "$(ops_html_escape "$pkg")" "$type" \
          "$(ops_html_escape "$old")" "$(ops_html_escape "$new")"
        first=0
      else
        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' \
          "$(ops_html_escape "$pkg")" "$type" \
          "$(ops_html_escape "$old")" "$(ops_html_escape "$new")"
      fi
      idx=$((idx + 1))
    done
    if [[ "$total" -gt 5 ]]; then
      printf '<tr><td>其他 %s 个包</td><td>安全 %s · 常规 %s</td><td>-</td><td>-</td></tr>' \
        "$((total - show_count))" "$rem_sec" "$rem_reg"
    fi
  done
  if [[ "$hidden_sessions" -gt 0 ]]; then
    printf '<tr><td colspan="5" class="muted">其余 %s 次更新会话未展示</td></tr>' "$hidden_sessions"
  fi
}

ops_installed_count_label() {
  if [[ "${1:-0}" == "-1" ]]; then
    echo "待解析"
  else
    printf '%s 个' "${1:-0}"
  fi
}

ops_ban_label() {
  if [[ "${1:-0}" =~ ^[0-9]+$ ]]; then
    printf '%s IP' "${1:-0}"
  else
    printf '%s' "${1:-未启用}"
  fi
}

ops_network_value() {
  if [[ "${OPS_NET_TOTAL_LABEL:-待周期数据}" == "报告周期" ]]; then
    ops_format_bytes "${1:-0}"
  else
    echo "待周期数据"
  fi
}

ops_render_system_version_table() {
  local out="" line project current previous updated
  while IFS='|' read -r project current previous updated; do
    [[ -n "$project" ]] || continue
    out="${out}
<tr><td>$(ops_html_escape "$project")</td><td>$(ops_html_escape "$current")</td><td>$(ops_html_escape "$previous")</td><td>$(ops_html_escape "$updated")</td></tr>"
  done <<< "${OPS_SYSTEM_VERSION_LINES}"
  if [[ -z "$out" ]]; then
    echo '<tr><td colspan="4" class="muted">无数据/未启用</td></tr>'
  else
    printf '%s\n' "$out"
  fi
}

ops_render_events_table() {
  printf '%s\n' "${OPS_EVENTS:-}" | sort -k1,2 -r | while IFS='|' read -r event_time event_desc event_impact event_status; do
    [[ -n "$event_time" ]] || continue
    event_time=$(ops_normalize_date "$event_time")
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' \
      "$(ops_html_escape "$event_time")" "$(ops_html_escape "$event_desc")" \
      "$(ops_html_escape "$event_status")" "$(ops_html_escape "$event_impact")"
  done
  if [[ -z "${OPS_EVENTS:-}" ]]; then
    echo '<tr><td colspan="4" class="muted">本周期无已采集事件。</td></tr>'
  fi
}

ops_abnormal_login_hours() {
  local line ts hour
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    line="${line#*：}"
    ts=$(printf '%s\n' "$line" | awk '{ sub(/^[^ ]+ [^ ]+ /, ""); print }')
    hour=$(date -d "$ts" '+%H' 2>/dev/null || true)
    [[ "$hour" =~ ^[0-9]+$ ]] && printf '%s ' "$hour"
  done <<< "${OPS_SECURITY_EVENTS:-}"
  printf '\n'
}

ops_build_login_risk_note() {
  OPS_LOGIN_RISK_LABEL="异常登录"
  OPS_LOGIN_RISK_NOTE="未发现异常登录"
  OPS_LOGIN_RISK_ITEMS=0
  local abnormal_users abnormal_count fail_count parts
  abnormal_users=$(printf '%s\n' "${OPS_SECURITY_EVENTS:-}" \
    | sed 's/^[^：]*：//' | awk 'NF { print $1 }' | sort -u)
  abnormal_count=$(printf '%s\n' "$abnormal_users" | grep -v '^$' | wc -l || true)
  fail_count="${OPS_LOGIN_FAIL_COUNT:-0}"
  parts=""
  if [[ "$abnormal_count" -gt 0 ]]; then
    local users_text user_count
    users_text=$(printf '%s\n' "$abnormal_users" | head -3 \
      | awk 'NF { if (n++) printf "、"; printf "%s", $1 }' || true)
    user_count=$(printf '%s\n' "$abnormal_users" | grep -v '^$' | wc -l || true)
    if [[ "$user_count" -gt 3 ]]; then
      users_text="${users_text} 等 ${user_count} 个用户"
    fi
    parts="异常登录：${users_text}"
    OPS_LOGIN_RISK_ITEMS=$((OPS_LOGIN_RISK_ITEMS + 1))
  fi
  if [[ "$fail_count" -gt 0 ]]; then
    local fail_text ip
    fail_text="失败登录：${fail_count} 次"
    ip=$(printf '%s\n' "${OPS_FAIL_IP_STATS:-}" | head -1 | awk '{print $1}' || true)
    [[ -n "$ip" ]] && fail_text="${fail_text}（主要来源 ${ip}）"
    parts="${parts:+${parts}；}${fail_text}"
    OPS_LOGIN_RISK_ITEMS=$((OPS_LOGIN_RISK_ITEMS + 1))
  fi
  if [[ -n "$parts" ]]; then
    OPS_LOGIN_RISK_NOTE="$parts"
    if [[ "$abnormal_count" -gt 0 && "$fail_count" -gt 0 ]]; then
      OPS_LOGIN_RISK_LABEL="登录安全"
    elif [[ "$fail_count" -gt 0 ]]; then
      OPS_LOGIN_RISK_LABEL="失败登录"
    fi
  fi
}

ops_render_abnormal_login_row() {
  if [[ -z "${OPS_SECURITY_EVENTS:-}" ]]; then
    echo '<tr><td colspan="4" class="muted">未发现异常登录</td></tr>'
    return 0
  fi
  local raw_event judgement="远程登录，待确认" event user source ts source_label out=""
  while IFS= read -r raw_event; do
    [[ -n "$raw_event" ]] || continue
    if [[ "$raw_event" == 夜间登录：* ]]; then
      judgement="夜间登录"
      raw_event="${raw_event#*：}"
    elif [[ "$raw_event" == 非常规时段登录：* ]]; then
      judgement="偏离惯常时段"
      raw_event="${raw_event#*：}"
    elif [[ "$raw_event" == 远程\ root\ 登录：* ]]; then
      judgement="远程登录，待确认"
      raw_event="${raw_event#*：}"
    fi
    event="$raw_event"
    IFS=' ' read -r user source ts <<< "$event"
    [[ -n "$user" ]] || continue
    ts=$(ops_normalize_date "$ts")
    source="${source#::ffff:}"
    source_label="$source"
    case "$source" in
      local|localhost) source_label="${source}（本地）" ;;
      192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) source_label="${source}（局域网）" ;;
      *) source_label="${source}（公网）" ;;
    esac
    out="${out}
<tr><td class=\"warn\">$(ops_html_escape "$ts")</td><td>$(ops_html_escape "$user")</td><td>$(ops_html_escape "$source_label")</td><td class=\"warn\">$(ops_html_escape "$judgement")</td></tr>"
  done <<< "${OPS_SECURITY_EVENTS}"
  if [[ -z "$out" ]]; then
    echo '<tr><td colspan="4" class="muted">未发现异常登录</td></tr>'
  else
    printf '%s' "$out"
  fi
}

ops_render_security_drift_table() {
  if [[ -n "${OPS_SECURITY_DRIFT_LINES:-}" ]]; then
    printf '%s' "$OPS_SECURITY_DRIFT_LINES"
    return 0
  fi
  cat <<EOF
<tr><td>SSH 配置与授权密钥</td><td class="muted">待基线</td><td>低</td><td>-</td><td>-</td></tr>
<tr><td>防火墙规则</td><td class="muted">待基线</td><td>低</td><td>-</td><td>-</td></tr>
<tr><td>计划任务</td><td class="muted">待基线</td><td>低</td><td>-</td><td>-</td></tr>
<tr><td>用户账户</td><td class="muted">待基线</td><td>低</td><td>-</td><td>-</td></tr>
EOF
}

ops_key_services_counts() {
  local name errors restarts start state
  local -i active=0 total=0
  while IFS='|' read -r name errors restarts start state; do
    [[ -n "$name" ]] || continue
    case "$name" in
      ssh|nginx|docker|cron) ;;
      *) continue ;;
    esac
    total+=1
    [[ "$state" == "正常" ]] && active+=1
  done <<< "${OPS_SERVICE_STABILITY}"
  printf '%s / %s' "$active" "$total"
}

ops_render_actions_table() {
  local item priority content action status badge_class
  if [[ ${#OPS_ACTION_ITEMS[@]} -eq 0 ]]; then
    echo '<tr><td>当前没有需要立即处理的建议事项</td><td>-</td><td>-</td><td class="good">已解决</td></tr>'
    return 0
  fi
  for item in "${OPS_ACTION_ITEMS[@]}"; do
    priority="低风险"
    badge_class="badge-low"
    case "$item" in
      "[高]"*) priority="高风险"; badge_class="badge-high" ;;
      "[中]"*) priority="中风险"; badge_class="badge-medium" ;;
    esac
    content="${item#\[*\] }"
    action="查看报告详情"
    status="待处理"
    case "$content" in
      *"失败服务"*) action="重启并排查失败服务" ;;
      *"登录"*) action="确认是否本人操作并检查账户安全"; status="处理中" ;;
      *"安全更新"*) action="安排维护窗口安装" ;;
      *"磁盘"*) action="清理或扩容" ;;
      *"CPU"*|*"内存"*) action="排查持续高占用进程" ;;
    esac
    printf '<tr><td>%s</td><td><span class="badge %s">%s</span></td><td>%s</td><td class="warn">%s</td></tr>' \
      "$(ops_html_escape "$content")" "$badge_class" "$priority" "$(ops_html_escape "$action")" "$status"
  done
}

ops_short_event_label() {
  local event="$1"
  case "$event" in
    *"计划重启"*|*"系统更新"*|*"维护"*) echo "计划维护" ;;
    *"磁盘/RAID/文件系统或内核"*) echo "系统异常" ;;
    *"磁盘使用率"*) echo "磁盘使用率" ;;
    *"磁盘 I/O"*) echo "磁盘 I/O 异常" ;;
    *"SMART"*) echo "SMART 异常" ;;
    *"RAID"*) echo "RAID 降级" ;;
    *"文件系统"*) echo "文件系统错误" ;;
    *"内核"*|*"OOM"*|*"oom"*) echo "内核错误" ;;
    *"登录"*) echo "异常登录" ;;
    *"安全更新"*|*"更新"*) echo "安全更新待装" ;;
    *"CPU"*) echo "CPU 持续高占用" ;;
    *"内存"*) echo "内存持续高占用" ;;
    *"负载"*) echo "负载峰值" ;;
    *"磁盘"*) echo "磁盘 I/O 异常" ;;
    *"失败服务"*) echo "服务失败" ;;
    *) echo "${event:-事件}" ;;
  esac
}

ops_event_category() {
  local event="$1"
  case "$event" in
    *登录*|*安全事件*|*入侵*) echo "security" ;;
    *磁盘*|*文件系统*|*内核*|*RAID*|*SMART*|*OOM*|*CPU*|*内存*|*负载*) echo "system" ;;
    *失败服务*) echo "service" ;;
    *安全更新*|*更新*) echo "update" ;;
    *网络*) echo "network" ;;
    *计划*|*维护*) echo "maintenance" ;;
    *) echo "other" ;;
  esac
}

ops_event_pulse_heading() {
  case "${OPS_REPORT_DAYS:-7}" in
    30)  echo "月度运行节奏（按天）" ;;
    365) echo "年度运行节奏（按周）" ;;
    *)   echo "一周运行节奏" ;;
  esac
}

ops_render_event_pulse() {
  local days="${OPS_REPORT_DAYS:-7}"
  local bucket_mode bucket_count label_step
  case "$days" in
    30)  bucket_mode="day";  bucket_count=30; label_step=5 ;;
    365) bucket_mode="week"; bucket_count=52; label_step=8 ;;
    *)   bucket_mode="day";  bucket_count=7;  label_step=1 ;;
  esac

  local i ago key dow label until_noon t
  local line etime event impact status prefix event_key date_idx
  local y cls cat short_label base_x node_x count
  local desc desc_part svg_title path x0 y0 x1 y1 dx node x label r
  local -a bucket_keys=() bucket_labels=() bucket_x=()
  # 桶日期由截止日正午按天回推（printf %()T 取日期，不再每桶起 3~4 次 date 与 1 次 awk）
  until_noon=$(ops_until_noon_epoch)
  for ((i = 0; i < bucket_count; i++)); do
    ago=$((bucket_count - 1 - i))
    if [[ "$bucket_mode" == "week" ]]; then
      # 周桶以周一为键，锚定「最近 52 周」；每日桶用完整 YYYY-MM-DD
      t=$((until_noon - ago * 7 * 86400))
      printf -v dow '%(%u)T' "$t"
      t=$((t - (dow - 1) * 86400))
    else
      t=$((until_noon - ago * 86400))
    fi
    printf -v key '%(%Y-%m-%d)T' "$t"
    printf -v label '%(%m-%d)T' "$t"
    bucket_keys+=("$key")
    bucket_labels+=("$label")
    # 80 + i*816/(n-1) 四舍五入取整（整数运算；n=7/30/52 时不会出现 .5）
    bucket_x+=("$((80 + (2 * i * 816 + bucket_count - 1) / (2 * (bucket_count - 1))))")
  done

  local -a bucket_y=() bucket_high=() bucket_mid=() bucket_low=()
  for ((i = 0; i < bucket_count; i++)); do
    bucket_y+=("220"); bucket_high+=("0"); bucket_mid+=("0"); bucket_low+=("0")
  done

  local -a nodes=() desc_parts=()
  while IFS='|' read -r etime event impact status; do
    [[ -n "$etime" ]] || continue
    prefix="${etime:0:10}"
    if [[ "$bucket_mode" == "week" ]]; then
      dow=$(date -d "$prefix" '+%u' 2>/dev/null || true)
      [[ -n "$dow" ]] || continue
      event_key=$(date -d "$prefix - $((dow - 1)) days" '+%Y-%m-%d' 2>/dev/null || true)
    else
      event_key="$prefix"
    fi
    date_idx=-1
    for i in "${!bucket_keys[@]}"; do
      if [[ "${bucket_keys[$i]}" == "$event_key" ]]; then
        date_idx="$i"
        break
      fi
    done
    [[ "$date_idx" -ge 0 ]] || continue
    y=220
    cls="low"
    if [[ "$event" == *系统更新* || "$event" == *计划* || "$event" == *维护* || "$event" == *更新* ]]; then
      y=220; cls="low"
    elif [[ "$event" == *安全更新* || "$impact" == *低* ]]; then
      y=220; cls="low"
    elif [[ "$event" == *入侵* ]]; then
      y=76; cls="critical"
    elif [[ "$event" == *SMART* || "$event" == *RAID* || "$event" == *文件系统* \
      || "$event" == *内核* || "$event" == *OOM* ]]; then
      y=76; cls="critical"
    elif [[ "$impact" == *高风险* || "$impact" == *高危* || "$impact" == *风险升高* ]]; then
      y=76; cls="critical"
    elif [[ "$event" == *登录* || "$impact" == *安全事件* || "$event" == *磁盘* \
      || "$event" == *CPU* || "$event" == *内存* || "$event" == *失败服务* \
      || "$impact" == *中* ]]; then
      y=148; cls="warning"
    fi
    base_x="${bucket_x[$date_idx]}"
    node_x="$base_x"
    count=0
    if [[ "$cls" == "critical" ]]; then
      count="${bucket_high[$date_idx]}"
      y=$((76 + count * 28))
      bucket_high[$date_idx]=$((count + 1))
    elif [[ "$cls" == "warning" ]]; then
      count="${bucket_mid[$date_idx]}"
      case "$count" in
        0) y=148 ;;
        1) y=184 ;;
        2) y=112 ;;
        *) y=132 ;;
      esac
      bucket_mid[$date_idx]=$((count + 1))
    else
      count="${bucket_low[$date_idx]}"
      y=$((220 - count * 24))
      bucket_low[$date_idx]=$((count + 1))
    fi
    [[ "$y" -lt "${bucket_y[$date_idx]}" ]] && bucket_y[$date_idx]="$y"
    cat=$(ops_event_category "$event")
    short_label=$(ops_short_event_label "$event")
    nodes+=("$node_x|$y|$cat|$cls|$(ops_html_escape "$short_label")")
    desc_parts+=("${bucket_labels[$date_idx]} ${cat}")
  done <<< "${OPS_EVENTS:-}"

  desc="纵轴表示事件影响等级，与第 2 章风险评级一致。"
  for desc_part in "${desc_parts[@]:-}"; do
    desc="${desc}${desc_part}，"
  done
  desc="${desc%，}"

  case "$days" in
    30) svg_title="最近三十天事件脉冲" ;;
    365) svg_title="最近一年事件脉冲（按周）" ;;
    *) svg_title="最近七天事件脉冲" ;;
  esac

  printf '<svg xmlns="http://www.w3.org/2000/svg" class="event-pulse-chart" viewBox="0 0 960 310" role="img" aria-labelledby="event-pulse-svg-title event-pulse-svg-desc">'
  printf '<title id="event-pulse-svg-title">%s</title>' "$svg_title"
  printf '<desc id="event-pulse-svg-desc">%s</desc>' "$desc"
  printf '<line class="pulse-baseline" x1="68" y1="220" x2="902" y2="220"/>'
  printf '<line class="pulse-grid" x1="68" y1="148" x2="902" y2="148"/>'
  printf '<line class="pulse-grid" x1="68" y1="76" x2="902" y2="76"/>'
  printf '<g class="pulse-axis" text-anchor="end"><text x="52" y="224">低</text><text x="52" y="152">中</text><text x="52" y="80">高</text></g>'

  path="M${bucket_x[0]} ${bucket_y[0]}"
  for ((i = 0; i < bucket_count - 1; i++)); do
    x0="${bucket_x[$i]}"; y0="${bucket_y[$i]}"; x1="${bucket_x[$((i + 1))]}"; y1="${bucket_y[$((i + 1))]}"
    dx=$(( (x1 - x0) / 2 ))
    path="${path} C $((x0 + dx)) ${y0}, $((x1 - dx)) ${y1}, ${x1} ${y1}"
  done
  printf '<path class="pulse-curve" d="%s"/>' "$path"

  printf '<g class="pulse-guide">'
  for i in "${!bucket_keys[@]}"; do
    if [[ "${bucket_y[$i]}" -lt 220 ]]; then
      printf '<line x1="%s" y1="220" x2="%s" y2="%s"/>' "${bucket_x[$i]}" "${bucket_x[$i]}" "${bucket_y[$i]}"
    fi
  done
  printf '</g>'

  printf '<g>'
  for node in "${nodes[@]:-}"; do
    [[ -n "$node" ]] || continue
    IFS='|' read -r x y cat cls label <<< "$node"
    r=6
    [[ "$cls" == "critical" ]] && r=7
    printf '<circle class="pulse-node %s" cx="%s" cy="%s" r="%s"><title>%s</title></circle>' "$cat" "$x" "$y" "$r" "$label"
  done
  printf '</g>'

  printf '<g class="pulse-date" text-anchor="middle">'
  for i in "${!bucket_keys[@]}"; do
    if (( i % label_step == 0 )) || (( i == bucket_count - 1 )); then
      printf '<text x="%s" y="278">%s</text>' "${bucket_x[$i]}" "${bucket_labels[$i]}"
    fi
  done
  printf '</g></svg>'
}

ops_render_week_focus() {
  local -i shown=0
  local item text name
  for item in "${OPS_ACTION_ITEMS[@]:-}"; do
    [[ -n "$item" ]] || continue
    shown+=1
    [[ "$shown" -le 3 ]] || break
    text="${item#\[*\] }"
    name="$text"
    case "$text" in
      *"失败服务"*) name="服务状态" ;;
      *"登录"*) name="异常登录" ;;
      *"安全更新"*) name="安全更新" ;;
      *"磁盘"*) name="存储容量" ;;
      *"CPU"*) name="CPU 持续高占用" ;;
      *"内存"*) name="内存持续高占用" ;;
    esac
    if [[ "$name" == "异常登录" ]]; then
      text="${OPS_LOGIN_RISK_NOTE:-$text}"
    fi
    printf '<div class="week-focus-item"><span class="week-focus-index">%02d</span><div><strong>%s</strong><small>%s</small></div></div>' \
      "$shown" "$(ops_html_escape "$name")" "$(ops_html_escape "$text")"
  done
  if [[ "$shown" -eq 0 ]]; then
    echo '<div class="week-focus-item"><span class="week-focus-index">01</span><div><strong>无待处理事项</strong><small>本周期无需立即跟进。</small></div></div>'
  fi
}

ops_render_disk_capacity_chart() {
  local name size pct
  local -i row=0 y=39 grid_bottom=151
  local out=""
  while IFS='|' read -r name size _ pct _; do
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    row+=1
    y=$((39 + (row - 1) * 40))
    grid_bottom=$((y + 8))
    local color="#0066CC"
    [[ "$pct" -ge 80 ]] && color="#D97706"
    [[ "$pct" -ge 90 ]] && color="#C7000B"
    local bw
    bw=$(awk -v p="$pct" 'BEGIN { if (p > 100) p = 100; printf "%.2f", p * 330 / 100 }')
    out="${out}
<rect x=\"112\" y=\"$y\" width=\"330\" height=\"8\" fill=\"#F5F5F7\"/>
<rect x=\"112\" y=\"$y\" width=\"$bw\" height=\"8\" fill=\"$color\"/>
<text x=\"102\" y=\"$((y + 9))\" text-anchor=\"end\" fill=\"#1D1D1F\" font-size=\"11\">${name} · ${size}</text>
<text x=\"$(awk -v b="$bw" 'BEGIN { printf "%.0f", 112 + b + 8 }')\" y=\"$((y + 9))\" fill=\"$color\" font-size=\"11\" font-weight=\"600\">${pct}%</text>"
  done <<< "${OPS_DISK_USAGE_LINES}"
  if [[ -z "$out" ]]; then
    echo '<text x="112" y="80" fill="#86868B" font-size="11">待周期数据</text>'
  else
    printf '<svg class="chart" viewBox="0 0 480 %d" role="img" aria-label="磁盘容量使用情况">' "$((grid_bottom + 54))"
    printf '<line x1="112" y1="20" x2="112" y2="%d" stroke="#D2D2D7"/>' "$grid_bottom"
    printf '<line x1="194.5" y1="20" x2="194.5" y2="%d" stroke="#E8E8ED" stroke-dasharray="3 3"/>' "$grid_bottom"
    printf '<line x1="277" y1="20" x2="277" y2="%d" stroke="#E8E8ED" stroke-dasharray="3 3"/>' "$grid_bottom"
    printf '<line x1="359.5" y1="20" x2="359.5" y2="%d" stroke="#E8E8ED" stroke-dasharray="3 3"/>' "$grid_bottom"
    printf '<line x1="442" y1="20" x2="442" y2="%d" stroke="#E8E8ED" stroke-dasharray="3 3"/>' "$grid_bottom"
    printf '<line x1="409" y1="14" x2="409" y2="%d" stroke="#C7000B" stroke-dasharray="4 3"/>' "$grid_bottom"
    printf '<text x="409" y="11" text-anchor="middle" fill="#C7000B" font-size="10" font-weight="600">90%%</text>'
    printf '%s' "$out"
    printf '<g fill="#86868B" font-size="11" text-anchor="middle"><text x="112" y="%d">0%%</text><text x="194.5" y="%d">25%%</text><text x="277" y="%d">50%%</text><text x="359.5" y="%d">75%%</text><text x="442" y="%d">100%%</text></g></svg>' "$((grid_bottom + 23))" "$((grid_bottom + 23))" "$((grid_bottom + 23))" "$((grid_bottom + 23))" "$((grid_bottom + 23))"
  fi
}

# 磁盘容量预测表（三列：磁盘 / 当前使用率 / 预测），数据来自 ops_collect_disk_trend 的 OPS_DISK_FORECAST
ops_render_disk_forecast_table() {
  local out="" name pct span growth eta text cls
  while IFS='|' read -r name pct span growth eta; do
    [[ -n "$name" ]] || continue
    cls=""
    if [[ "$pct" =~ ^[0-9]+$ && "$pct" -ge 90 ]]; then
      text="已达 90% 告警线"; cls=' class="warn"'
    elif [[ ! "$span" =~ ^[0-9]+$ ]]; then
      text="数据不足（需要相隔 1 天以上的两次报告）"; cls=' class="muted"'
    elif [[ ! "$eta" =~ ^[0-9]+$ ]]; then
      text="近 ${span} 天无增长"
    else
      if [[ "$eta" -lt 1 ]]; then eta="不足 1 天"; else eta="约 ${eta} 天"; fi
      text="按近 ${span} 天增速（+${growth}%/天），${eta}后达到 90%"
      [[ "$eta" == "不足 1 天" || "${eta//[!0-9]/}" -le 30 ]] && cls=' class="warn"'
    fi
    out="${out}
<tr><td>$(ops_html_escape "$name")</td><td>$(ops_html_escape "${pct}%")</td><td${cls}>$(ops_html_escape "$text")</td></tr>"
  done <<< "${OPS_DISK_FORECAST:-}"
  if [[ -z "$out" ]]; then
    echo '<tr><td colspan="3" class="muted">数据不足</td></tr>'
  else
    printf '%s' "$out"
  fi
}

ops_render_disk_io_chart() {
  local name avg_rd avg_wr max_util
  local -i row=0 y=32 disk_rows=0 grid_bottom=151
  local out=""
  local max_bytes=0
  local -A io_rb=()
  local -A io_wb=()
  while IFS='|' read -r name avg_rd avg_wr max_util _; do
    [[ -n "$name" ]] || continue
    disk_rows+=1
    local rb wb
    rb=$(ops_rate_bytes "$avg_rd" "${OPS_DISK_SAMPLE_DAYS:-${OPS_SYSSTAT_SAMPLE_DAYS:-1}}")
    wb=$(ops_rate_bytes "$avg_wr" "${OPS_DISK_SAMPLE_DAYS:-${OPS_SYSSTAT_SAMPLE_DAYS:-1}}")
    io_rb["$name"]="$rb"
    io_wb["$name"]="$wb"
    [[ "$rb" -gt "$max_bytes" ]] && max_bytes="$rb"
    [[ "$wb" -gt "$max_bytes" ]] && max_bytes="$wb"
  done <<< "${OPS_DISK_IO_SUMMARY}"
  if [[ "$max_bytes" -eq 0 ]]; then
    echo '<text x="112" y="80" fill="#86868B" font-size="11">待周期数据</text>'
    return 0
  fi
  grid_bottom=$((32 + (disk_rows - 1) * 46 + 8))
  local max_tb
  max_tb=$(awk -v b="$max_bytes" 'BEGIN { printf "%.6f", b / 1099511627776 }')
  [[ "$max_tb" =~ ^[0-9.]+$ ]] || max_tb="1.00"
  local nice_tb
  nice_tb=$(awk -v t="$max_tb" '
    BEGIN {
      if (t <= 0) { t = 1; print "1" }
      else if (t <= 0.5) print "0.5"
      else if (t <= 1) print "1"
      else if (t <= 2) print "2"
      else if (t <= 2.5) print "2.5"
      else if (t <= 5) print "5"
      else printf "%.0f", int(t) + 1
    }')
  local scale
  scale=$(awk -v t="$nice_tb" 'BEGIN { printf "%.10f", 330 / t }')
  local axis_grid="" axis_labels=""
  local i x val
  for ((i = 0; i <= 5; i++)); do
    printf -v x '%d.0' "$((112 + i * 66))"
    val=$(awk -v t="$nice_tb" -v i="$i" 'BEGIN { printf "%.1f", t * i / 5 }')
    axis_grid="${axis_grid}
<line x1=\"${x}\" y1=\"20\" x2=\"${x}\" y2=\"${grid_bottom}\" stroke=\"$([ "$i" -eq 0 ] && echo '#D2D2D7' || echo '#E8E8ED')\" stroke-dasharray=\"$([ "$i" -eq 0 ] && echo none || echo '3 3')\"/>"
    axis_labels="${axis_labels}<text x=\"${x}\" y=\"$((grid_bottom + 23))\">${val}</text>"
  done
  while IFS='|' read -r name avg_rd avg_wr max_util _; do
    [[ -n "$name" ]] || continue
    row+=1
    y=$((32 + (row - 1) * 46))
    local rb="${io_rb["$name"]:-0}"
    local wb="${io_wb["$name"]:-0}"
    local rw gw
    rw=$(awk -v b="$rb" -v s="$scale" 'BEGIN { w = b / 1099511627776 * s; if (w < 0) w = 0; printf "%.2f", w }')
    gw=$(awk -v b="$wb" -v s="$scale" 'BEGIN { w = b / 1099511627776 * s; if (w < 0) w = 0; printf "%.2f", w }')
    out="${out}
<text x=\"102\" y=\"$((y + 9))\" text-anchor=\"end\" fill=\"#1D1D1F\" font-size=\"11\">${name}</text>
<rect x=\"112\" y=\"$y\" width=\"${rw}\" height=\"8\" fill=\"#0066CC\"/>
<rect x=\"112\" y=\"$((y + 13))\" width=\"${gw}\" height=\"8\" fill=\"#86868B\"/>
<text x=\"$(awk -v b="$rw" 'BEGIN { printf "%.0f", 112 + b + 6 }')\" y=\"$((y + 8))\" fill=\"#0066CC\" font-size=\"11\" font-weight=\"600\">$(ops_format_bytes "$rb")</text>
<text x=\"$(awk -v b="$gw" 'BEGIN { printf "%.0f", 112 + b + 6 }')\" y=\"$((y + 21))\" fill=\"#86868B\" font-size=\"11\" font-weight=\"600\">$(ops_format_bytes "$wb")</text>
<text x=\"470\" y=\"$((y + 21))\" text-anchor=\"end\" fill=\"$([ "${max_util%%.*}" -ge 80 ] 2>/dev/null && echo '#D97706' || echo '#86868B')\" font-size=\"11\" font-weight=\"600\">${max_util}%</text>"
  done <<< "${OPS_DISK_IO_SUMMARY}"
  printf '<svg class="chart" viewBox="0 0 480 %d" role="img" aria-label="设备 I/O 周期累计对比">' "$((grid_bottom + 54))"
  printf '<title>设备 I/O 周期累计对比</title>'
  printf '<text x="112" y="14" fill="#86868B" font-size="11">TB</text>'
  printf '<text x="470" y="14" text-anchor="end" fill="#86868B" font-size="10">峰值繁忙度</text>'
  printf '%s' "$axis_grid"
  printf '%s' "$out"
  printf '<g fill="#86868B" font-size="11" text-anchor="middle">%s</g></svg>' "$axis_labels"
}

ops_render_service_list_table() {
  local out="" line name errors restarts start state cls type note
  local has_cron=0
  while IFS='|' read -r name errors restarts start state; do
    [[ -n "$name" ]] || continue
    start=$(ops_normalize_date "$start")
    [[ "$name" == "cron" ]] && has_cron=1
    cls=""
    case "$state" in
      正常) cls=' class="good"' ;;
      failed) cls=' class="warn"' ;;
      *) cls=' class="muted"' ;;
    esac
    type="systemd"
    # 错误与重启两条信息都保留，用"；"连接；都没有时显示 "-"
    note=""
    if [[ "$errors" =~ ^[0-9]+$ ]] && [[ "$errors" -gt 0 ]]; then
      note="周期错误 ${errors} 次"
    fi
    if [[ "$restarts" =~ ^[0-9]+$ ]] && [[ "$restarts" -gt 0 ]]; then
      note="${note:+${note}；}周期重启 ${restarts} 次"
    fi
    [[ -n "$note" ]] || note="-"
    out="${out}
<tr><td${cls}>$(ops_html_escape "$name")</td><td${cls}>$(ops_html_escape "$state")</td><td>${type}</td><td>${errors:-0}</td><td>${restarts:-0}</td><td>$(ops_html_escape "$start")</td><td>$(ops_html_escape "$note")</td></tr>"
  done <<< "${OPS_SERVICE_STABILITY}"
  if [[ "$has_cron" -eq 0 ]]; then
    out="${out}
<tr><td>cron</td><td>$(systemctl is-active cron 2>/dev/null || echo 待周期数据)</td><td>systemd</td><td>0</td><td>0</td><td>-</td><td>-</td></tr>"
  fi
  if [[ "${OPS_VM_COUNT:-0}" -gt 0 ]]; then
    out="${out}
<tr><td>虚拟机</td><td class=\"good\">${OPS_VM_RUNNING_COUNT}/${OPS_VM_COUNT} 运行</td><td>虚拟机</td><td>0</td><td>0</td><td>-</td><td>-</td></tr>"
  fi
  if [[ -z "$out" ]]; then
    echo '<tr><td colspan="7" class="muted">待周期数据</td></tr>'
  else
    printf '%s' "$out"
  fi
}

ops_render_source_ip_table() {
  local -A success=()
  local -A failed=()
  local -A last_map=()
  local ip count
  local last_ip last_time
  while IFS=' ' read -r last_ip last_time; do
    [[ -n "$last_ip" ]] || continue
    last_ip="${last_ip#::ffff:}"
    last_map["$last_ip"]="$last_time"
  done <<< "${OPS_LOGIN_IP_LAST}"
  while IFS=' ' read -r ip count; do
    [[ -n "$ip" ]] || continue
    ip="${ip#::ffff:}"
    success["$ip"]="$count"
  done <<< "${OPS_LOGIN_IP_STATS}"
  while IFS=' ' read -r ip count; do
    [[ -n "$ip" ]] || continue
    ip="${ip#::ffff:}"
    failed["$ip"]="$count"
  done <<< "${OPS_FAIL_IP_STATS}"
  local -a ips=()
  while IFS=' ' read -r ip count; do
    [[ -n "$ip" ]] || continue
    ip="${ip#::ffff:}"
    ips+=("$ip")
  done <<< "${OPS_LOGIN_IP_STATS}"
  while IFS=' ' read -r ip count; do
    [[ -n "$ip" ]] || continue
    ip="${ip#::ffff:}"
    local dup=0
    for item in "${ips[@]:-}"; do
      [[ "$item" == "$ip" ]] && dup=1
    done
    [[ "$dup" -eq 0 ]] && ips+=("$ip")
  done <<< "${OPS_FAIL_IP_STATS}"
  local out="" ip_type s f fail_cls last_label
  local -i total_success=0 total_failed=0
  for ip in "${ips[@]:-}"; do
    [[ -n "$ip" ]] || continue
    ip="${ip#::ffff:}"
    s="${success["$ip"]:-0}"
    f="${failed["$ip"]:-0}"
    total_success=$((total_success + s))
    total_failed=$((total_failed + f))
    ip_type="公网"
    [[ "$ip" == "local" || "$ip" == "localhost" ]] && ip_type="本地"
    [[ "$ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] && ip_type="局域网"
    fail_cls=""
    [[ "$f" -gt 0 ]] && fail_cls=' class="warn"'
    last_label="${last_map["$ip"]:-}"
    if [[ -z "$last_label" ]]; then
      if [[ "$f" -gt 0 ]]; then
        last_label="周期内（失败）"
      else
        last_label="周期内"
      fi
    else
      last_label=$(ops_normalize_date "$last_label")
    fi
    out="${out}
<tr><td>$(ops_html_escape "$ip")</td><td>${ip_type}</td><td${fail_cls}>${f}</td><td>${s}</td><td>$(ops_html_escape "$last_label")</td></tr>"
  done
  out="${out}
<tr><td colspan=\"2\">来源合计</td><td class=\"warn\">${total_failed}</td><td>${total_success}</td><td>Fail2ban $(ops_ban_label "${OPS_FAIL_BAN_COUNT:-未启用}")</td></tr>"
  printf '%s' "$out"
}

ops_render_user_stats_table() {
  local user count active_days ratio first_ts last_ts ip_count period
  local out=""
  local -i shown=0 total=0
  while IFS='|' read -r user count active_days ratio first_ts last_ts ip_count period; do
    [[ -n "$user" ]] || continue
    total=$((total + 1))
    shown=$((shown + 1))
    if [[ "$shown" -gt 20 ]]; then
      continue
    fi
    first_ts=$(ops_normalize_date "$first_ts")
    last_ts=$(ops_normalize_date "$last_ts")
    out="${out}
<tr><td>$(ops_html_escape "$user")</td><td>${count}</td><td>0</td><td>$(ops_html_escape "$last_ts")</td><td>${active_days} 天</td><td>${ratio}%</td><td>${ip_count}</td><td>$(ops_html_escape "$period")</td><td>$(ops_html_escape "$first_ts")</td></tr>"
  done <<< "${OPS_LOGIN_USER_STATS}"
  if [[ "$total" -gt 20 ]]; then
    out="${out}
<tr><td>其他用户</td><td>$(($total - 20))</td><td>0</td><td>-</td><td>-</td><td>-</td><td>-</td><td>-</td><td>-</td></tr>"
  fi
  if [[ -z "$out" ]]; then
    echo '<tr><td colspan="9" class="muted">待周期数据</td></tr>'
  else
    printf '%s' "$out"
  fi
}

ops_suspicious_summary() {
  if [[ "${OPS_SUSPICIOUS_PROGRAM_COUNT:-0}" -eq 0 ]]; then
    echo "静态启发式扫描未发现可疑进程"
    return 0
  fi
  local names
  names=$(printf '%s\n' "${OPS_SUSPICIOUS_PROGRAMS:-}" | head -3 \
    | awk '{ sub(/：.*/, "", $2); if (n++) printf "、"; printf "%s", $2 }' || true)
  if [[ "${OPS_SUSPICIOUS_PROGRAM_COUNT}" -gt 3 ]]; then
    names="${names} 等 ${OPS_SUSPICIOUS_PROGRAM_COUNT} 项"
  fi
  echo "$names"
}

ops_render_suspicious_process_section() {
  [[ "${OPS_SUSPICIOUS_PROGRAM_COUNT:-0}" -gt 0 ]] || return 0
  local line p comm reason
  cat <<'EOF'
      <h3>可疑进程</h3>
      <div class="wide-table-wrap">
        <table class="wide-table">
          <tr><th>PID</th><th>进程</th><th>命中规则</th></tr>
EOF
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p="${line%% *}"
    comm="${line#* }"; comm="${comm%%：*}"
    reason="${line#*：}"
    printf '<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "$(ops_html_escape "$p")" "$(ops_html_escape "$comm")" "$(ops_html_escape "$reason")"
  done <<< "${OPS_SUSPICIOUS_PROGRAMS:-}"
  cat <<'EOF'
        </table>
      </div>
EOF
}

ops_render_anomaly_table() {
  local cpu_state cpu_note mem_state mem_note login_state login_note
  local login_label="异常登录"
  local net_state net_note proc_state proc_note port_state port_note disk_state disk_note security_state security_note
  local service_state service_note service_row="" disk_label="磁盘 / 存储" disk_cls="good"
  cpu_state="无数据"; cpu_note="无 sysstat 周期数据"
  mem_state="无数据"; mem_note="无 sysstat 周期数据"
  net_state="无数据"; net_note="无周期网络采样数据"
  if [[ "${OPS_SUSPICIOUS_PROGRAM_COUNT:-0}" -gt 0 ]]; then
    proc_state="发现 ${OPS_SUSPICIOUS_PROGRAM_COUNT} 个"
    proc_note="$(ops_suspicious_summary)"
  else
    proc_state="未发现"; proc_note="静态启发式扫描未发现可疑进程"
  fi
  port_state="${OPS_LISTEN_PORT_BASELINE_STATE:-待基线}"; port_note="${OPS_LISTEN_PORT_BASELINE_NOTE:-未建立监听端口基线，暂不判定新增}"
  disk_state="待周期数据"; disk_note="需 sysstat 磁盘采样"
  security_state="未发现"; security_note="无待装安全更新"
  if [[ "${OPS_PENDING_SECURITY_COUNT:-0}" -eq -1 ]]; then
    security_state="未知"; security_note="apt 模拟升级失败，待装更新数未知"
  fi
  service_state="未发现"; service_note="无失败服务"
  login_state="无数据"; login_note="无登录日志数据"
  [[ -z "${OPS_LOGIN_SOURCE:-}" && -n "${OPS_LOGIN_SOURCE_NOTE:-}" ]] && login_note="无登录数据源（未安装 wtmpdb / last）"
  local net_days="${OPS_NET_SAMPLE_DAYS:-${OPS_SYSSTAT_SAMPLE_DAYS:-0}}"
  [[ "$net_days" -gt 0 ]] || net_days="${OPS_REPORT_DAYS:-7}"
  if [[ "$OPS_CPU_AVG" =~ ^[0-9.]+$ ]] && awk -v v="$OPS_CPU_AVG" 'BEGIN { exit !(v >= 80) }'; then
    cpu_state="关注"; cpu_note="CPU 平均 ${OPS_CPU_AVG}%，峰值 ${OPS_CPU_MAX}%，需排查持续高占用"
  elif [[ "$OPS_CPU_AVG" =~ ^[0-9.]+$ ]]; then
    cpu_state="未发现"; cpu_note="峰值 ${OPS_CPU_MAX}% 为短时，未形成持续压力"
  fi
  if [[ "$OPS_MEM_AVG" =~ ^[0-9.]+$ ]] && awk -v v="$OPS_MEM_AVG" 'BEGIN { exit !(v >= 85) }'; then
    mem_state="关注"; mem_note="内存平均 ${OPS_MEM_AVG}%，峰值 ${OPS_MEM_MAX}%，需排查持续高占用"
  elif [[ "$OPS_MEM_AVG" =~ ^[0-9.]+$ ]]; then
    mem_state="未发现"; mem_note="峰值 ${OPS_MEM_MAX}% 为短时，未形成持续压力"
  fi
  if [[ -n "$OPS_NET_DAILY_TX_LIST" ]]; then
    net_state="未发现"; net_note="发送日均 $(ops_network_value "$((OPS_NET_TOTAL_TX_BYTES / net_days))")，无突增时段"
  fi
  if [[ -n "$OPS_DISK_IO_SUMMARY" ]]; then
    local disk_max
    disk_max=$(ops_disk_io_peak)
    if awk -v v="$disk_max" 'BEGIN { exit !(v >= 80) }'; then
      disk_state="关注"; disk_note="磁盘峰值繁忙度 ${disk_max}%"
    else
      disk_state="未发现"; disk_note="磁盘峰值繁忙度 ${disk_max}%，未形成持续压力"
    fi
  fi
  local disk_alert=""
  local disk_dev=""
  while IFS='|' read -r disk_dev _ _ disk_pct _ _; do
    [[ -n "$disk_dev" && "$disk_label" == "磁盘 / 存储" ]] && disk_label="/dev/${disk_dev} 磁盘"
    [[ "$disk_pct" =~ ^[0-9]+$ ]] || continue
    if [[ "$disk_pct" -ge 80 ]]; then
      disk_state="关注"
      disk_alert="磁盘使用率 ${disk_pct}%"
      break
    fi
  done <<< "${OPS_DISK_USAGE_LINES:-}"
  if [[ "$disk_label" == "磁盘 / 存储" && -n "$OPS_DISK_IO_SUMMARY" ]]; then
    disk_label="/dev/$(printf '%s\n' "$OPS_DISK_IO_SUMMARY" | head -1 | cut -d'|' -f1) 磁盘"
  fi
  if [[ -n "${OPS_HEALTH_ISSUE_SUMMARY:-}" ]]; then
    disk_state="关注"
    disk_alert="${OPS_HEALTH_ISSUE_SUMMARY}"
  fi
  if [[ -n "$disk_alert" ]]; then
    disk_note="${disk_note:+${disk_note}；}${disk_alert}"
  fi
  if [[ "${OPS_SYSTEMD_FAILED_COUNT:-0}" -gt 0 ]]; then
    service_state="发现 ${OPS_SYSTEMD_FAILED_COUNT} 个"
    service_note="存在失败服务，请查看服务清单"
  fi
  if [[ "${OPS_SECURITY_ISSUE:-0}" -eq 1 || "${OPS_LOGIN_FAIL_COUNT:-0}" -gt 0 || -n "${OPS_SECURITY_EVENTS:-}" ]]; then
    ops_build_login_risk_note
    login_state="发现 ${OPS_LOGIN_RISK_ITEMS:-0} 项"
    login_note="${OPS_LOGIN_RISK_NOTE}"
    login_label="${OPS_LOGIN_RISK_LABEL}"
  elif [[ "${OPS_LOGIN_SUCCESS_COUNT:-0}" -gt 0 ]] || [[ "$OPS_LOGIN_USERS" != "无数据" ]]; then
    login_state="未发现"; login_note="未发现异常登录"
  fi
  if [[ "${OPS_PENDING_SECURITY_COUNT:-0}" -gt 0 ]]; then
    security_state="待装"; security_note="${OPS_PENDING_SECURITY_COUNT} 个安全更新待装"
  fi
  local badge_clear='<span class="badge badge-clear">正常</span>'
  local badge_medium='<span class="badge badge-medium">中风险</span>'
  local cpu_badge="$badge_clear" mem_badge="$badge_clear" disk_badge="$badge_clear"
  local service_badge="$badge_clear" port_badge="$badge_clear" proc_badge="$badge_clear"
  local port_cls="muted" proc_cls="muted"
  [[ "$cpu_state" == "关注" ]] && cpu_badge="$badge_medium"
  [[ "$mem_state" == "关注" ]] && mem_badge="$badge_medium"
  [[ "$disk_state" == "关注" ]] && disk_badge="$badge_medium"
  [[ "$service_state" != "未发现" ]] && service_badge="$badge_medium"
  if [[ "${OPS_SUSPICIOUS_PROGRAM_COUNT:-0}" -gt 0 ]]; then
    proc_badge="$badge_medium"
    proc_cls="warn"
  fi
  if [[ "${OPS_NEW_LISTEN_PORT_COUNT:-0}" -gt 0 ]]; then
    port_badge="$badge_medium"
    port_cls="warn"
  elif [[ "$port_state" != "待基线" ]]; then
    port_cls="good"
  fi
  local login_badge="$badge_clear" login_cls="good"
  case "$login_state" in
    "发现"*) login_badge="$badge_medium"; login_cls="warn" ;;
    "无数据") login_cls="muted" ;;
  esac
  [[ "$disk_state" == "关注" ]] && disk_cls="warn"
  if [[ "$service_state" != "未发现" ]]; then
    service_row=$(printf '<tr><td>服务状态</td><td>%s</td><td class="warn">%s</td><td>%s</td></tr>' \
      "$service_badge" "$service_state" "$service_note")
  fi
  cat <<EOF
<tr><td>${login_label}</td><td>${login_badge}</td><td class="${login_cls}">${login_state}</td><td>$(ops_html_escape "$login_note")</td></tr>
<tr><td>$(ops_html_escape "$disk_label")</td><td>${disk_badge}</td><td class="${disk_cls}">${disk_state}</td><td>$(ops_html_escape "$disk_note")</td></tr>
<tr><td>安全更新</td><td><span class="badge $([ "$security_state" == "待装" ] && echo badge-low || echo badge-clear)">$([ "$security_state" == "待装" ] && echo 低风险 || echo 正常)</span></td><td class="$([ "$security_state" == "待装" ] && echo warn || echo good)">${security_state}</td><td>${security_note}</td></tr>
${service_row}
<tr><td>CPU 持续高占用</td><td>${cpu_badge}</td><td class="good">${cpu_state}</td><td>${cpu_note}</td></tr>
<tr><td>内存持续高占用</td><td>${mem_badge}</td><td class="good">${mem_state}</td><td>${mem_note}</td></tr>
<tr><td>网络异常出站流量</td><td><span class="badge badge-clear">正常</span></td><td class="good">${net_state}</td><td>${net_note}</td></tr>
<tr><td>可疑程序</td><td>${proc_badge}</td><td class="${proc_cls}">${proc_state}</td><td>$(ops_html_escape "$proc_note")</td></tr>
<tr><td>新监听端口</td><td>${port_badge}</td><td class="${port_cls}">${port_state}</td><td>${port_note}</td></tr>
EOF
}

ops_render_period_comparison_table() {
  cat <<EOF
<tr><td>CPU 平均</td><td>$(ops_pct_label "${OPS_CPU_AVG}")</td><td class="muted">无上一周期</td><td>无数据</td></tr>
<tr><td>CPU 峰值</td><td>$(ops_pct_label "${OPS_CPU_MAX}")</td><td class="muted">无上一周期</td><td>无数据</td></tr>
<tr><td>内存平均</td><td>$(ops_pct_label "${OPS_MEM_AVG}")</td><td class="muted">无上一周期</td><td>无数据</td></tr>
<tr><td>内存峰值</td><td>$(ops_pct_label "${OPS_MEM_MAX}")</td><td class="muted">无上一周期</td><td>无数据</td></tr>
<tr><td>周期流量</td><td>$(ops_network_value "$((OPS_NET_TOTAL_RX_BYTES + OPS_NET_TOTAL_TX_BYTES))")</td><td class="muted">无上一周期</td><td>无数据</td></tr>
<tr><td>成功登录</td><td>${OPS_LOGIN_SUCCESS_COUNT} 次</td><td class="muted">无上一周期</td><td>无数据</td></tr>
<tr><td>失败登录</td><td>${OPS_LOGIN_FAIL_COUNT} 次</td><td class="muted">无上一周期</td><td>无数据</td></tr>
<tr><td>更新包数</td><td>${OPS_UPDATE_COUNT} 个</td><td class="muted">无上一周期</td><td>无数据</td></tr>
EOF
}

ops_render_network_iface_table() {
  local iface avg_rx avg_tx
  local -i total_rx=0 total_tx=0 count=0
  local out=""
  local -A peak_map=()
  local peak_iface peak_mbps
  while IFS='|' read -r peak_iface peak_mbps; do
    [[ -n "$peak_iface" ]] || continue
    peak_map["$peak_iface"]="$peak_mbps"
  done <<< "${OPS_NET_IFACE_PEAK_SUMMARY:-}"
  while IFS='|' read -r iface avg_rx avg_tx _; do
    [[ -n "$iface" ]] || continue
    local rx_bytes tx_bytes
    rx_bytes=$(ops_rate_bytes "$avg_rx" "${OPS_NET_SAMPLE_DAYS:-${OPS_SYSSTAT_SAMPLE_DAYS:-1}}")
    tx_bytes=$(ops_rate_bytes "$avg_tx" "${OPS_NET_SAMPLE_DAYS:-${OPS_SYSSTAT_SAMPLE_DAYS:-1}}")
    total_rx=$((total_rx + rx_bytes))
    total_tx=$((total_tx + tx_bytes))
    count=$((count + 1))
    local peak_label="${peak_map["$iface"]:-待周期数据}"
    out="${out}
<tr><td>$(ops_html_escape "$iface")</td><td>物理网卡</td><td>$(ops_format_bytes "$((rx_bytes + tx_bytes))")</td><td>$(ops_format_bytes "$rx_bytes")</td><td>$(ops_format_bytes "$tx_bytes")</td><td>$([ "$peak_label" != "待周期数据" ] && printf '%s Mbps' "$peak_label" || echo '<span class=\"muted\">待周期数据</span>')</td></tr>"
  done <<< "${OPS_NET_IFACE_SUMMARY}"
  if [[ -z "$out" ]]; then
    echo '<tr><td colspan="6" class="muted">待周期数据</td></tr>'
  else
    printf '%s\n' "${out}
<tr><td>物理网卡合计</td><td>${count} 个</td><td>$(ops_format_bytes "$((total_rx + total_tx))")</td><td>$(ops_format_bytes "$total_rx")</td><td>$(ops_format_bytes "$total_tx")</td><td>$([ "${OPS_NET_PEAK_RATE_MBPS:-待周期数据}" != "待周期数据" ] && printf '%s Mbps' "$OPS_NET_PEAK_RATE_MBPS" || echo '<span class=\"muted\">待周期数据</span>')</td></tr>"
  fi
}

ops_render_html_report() {
  local css_file="${MODULE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/report-style.css"
  local report_css
  report_css=$(cat "$css_file" 2>/dev/null || true)
  local host_ip fail_source_summary="" next_period_expr="next Monday 01:00"
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$host_ip" ]] || host_ip="未知 IP"
  if [[ "${OPS_LOGIN_FAIL_COUNT:-0}" -gt 0 ]]; then
    fail_source_summary=$(printf '%s\n' "${OPS_FAIL_IP_STATS:-}" | head -1 | awk '{print $1}' || true)
    if [[ "$fail_source_summary" == "未知" ]]; then
      fail_source_summary="，失败登录来源暂无法解析"
    elif [[ -n "$fail_source_summary" ]]; then
      fail_source_summary="，失败登录主要来自 ${fail_source_summary}"
    fi
  fi
  ops_build_login_risk_note
  local week_title="本周期未发现需要立即处理的事项。"
  if [[ "${OPS_ACTION_COUNT:-0}" -gt 0 ]]; then
    week_title="本周期发现 ${OPS_ACTION_COUNT} 项需要关注的事项。"
  fi
  case "$OPS_REPORT_DAYS" in
    30) next_period_expr="+30 days 01:00" ;;
    365) next_period_expr="+365 days 01:00" ;;
  esac

  cat <<HTML
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DebNAS 服务器$(ops_period_label_cn "${OPS_REPORT_DAYS:-7}") · 最近 ${OPS_REPORT_DAYS} 天</title>
  <style>
${report_css}
  </style>
</head>
<body>
  <div class="page">
    <div class="header">
      <div class="header-top">
        <div>
          <div class="eyebrow">DebNAS $(ops_period_label_en "${OPS_REPORT_DAYS:-7}") Ops Report</div>
          <h1>服务器$(ops_period_label_cn "${OPS_REPORT_DAYS:-7}")</h1>
        </div>
        <div class="header-meta">
          <div><span>报告周期</span><strong>$(date -d "${OPS_REPORT_SINCE}" '+%Y-%m-%d' 2>/dev/null || echo "${OPS_REPORT_SINCE%% *}") ~ $(date '+%Y-%m-%d')</strong></div>
        </div>
      </div>
      <div class="header-sub">$(ops_html_escape "$(hostname 2>/dev/null || echo "debnas")") · $(ops_html_escape "$host_ip")</div>
    </div>

    <div class="content">
      <section class="week-overview" aria-labelledby="week-overview-title">
        <div class="week-lead">
          <div class="week-lead-copy">
            <div class="week-kicker">$([[ "${OPS_REPORT_DAYS:-7}" == "7" ]] && echo "WEEKLY NARRATIVE · $(date -d "${OPS_REPORT_UNTIL:-today}" '+%V' 2>/dev/null || echo 7)" || echo "PERIOD NARRATIVE · ${OPS_REPORT_DAYS} DAYS")</div>
            <div id="week-overview-title" class="week-lead-title">${week_title}</div>
            <p class="week-lead-desc">${OPS_SECURITY_CONCLUSION}；周期可用性 ${OPS_AVAILABILITY_PCT:-待周期数据}，数据覆盖 ${OPS_SYSSTAT_DATA_DAYS:-0} 天。</p>
          </div>
          <div class="week-availability">
            <span>周期可用性</span>
            <strong>${OPS_AVAILABILITY_PCT:-待周期数据}</strong>
            <small>${OPS_DATA_START:-无数据} 起</small>
          </div>
        </div>
        <figure class="event-pulse" aria-labelledby="event-pulse-title">
          <div class="event-pulse-head">
            <div>
              <div class="event-pulse-label">EVENT PULSE · 事件影响等级</div>
              <h3 id="event-pulse-title">$(ops_event_pulse_heading)</h3>
            </div>
          </div>
          <div class="event-pulse-plot">
            $(ops_render_event_pulse)
            <div class="pulse-legend">
              <span><i style="background:var(--red)"></i>安全事件</span>
              <span><i style="background:var(--amber)"></i>磁盘 / 系统异常</span>
              <span><i style="background:var(--accent)"></i>安全更新</span>
              <span><i style="background:#0E7490"></i>网络异常</span>
              <span><i style="background:#7C3AED"></i>服务失败</span>
              <span><i style="background:var(--subtle)"></i>计划维护</span>
            </div>
          </div>
        </figure>
        <div class="week-focus">
          <div class="week-focus-heading">
            <span>重点跟进</span>
            <p>从本周期事件收束出的三项后续。</p>
          </div>
          $(ops_render_week_focus)
        </div>
      </section>

      <h2>1. 安全体检结论</h2>
      <p class="section-lead">本周期高风险 ${OPS_RISK_HIGH:-0} · 中风险 ${OPS_RISK_MEDIUM:-0} · 低风险 ${OPS_RISK_LOW:-0}；${OPS_SECURITY_CONCLUSION}；需处理事项 ${OPS_ACTION_COUNT:-0} 项。</p>
      <div class="wide-table-wrap">
        <table class="wide-table">
          <tr><th>研判项</th><th>风险等级</th><th>结论</th><th>说明</th></tr>
          $(ops_render_anomaly_table)
        </table>
      </div>

      <h2>2. 登录与身份审计</h2>
      <p class="section-lead">成功登录 ${OPS_LOGIN_SUCCESS_COUNT} 次，失败 ${OPS_LOGIN_FAIL_COUNT} 次，封禁 $(ops_ban_label "${OPS_FAIL_BAN_COUNT:-未启用}")；${OPS_ABNORMAL_LOGIN_COUNT:-0} 项异常登录待确认$(ops_html_escape "$fail_source_summary")。</p>
$([[ -z "${OPS_LOGIN_SOURCE_NOTE:-}" ]] || printf '      <p class="muted">%s</p>\n' "$(ops_html_escape "$OPS_LOGIN_SOURCE_NOTE")")
      <h3>按用户统计</h3>
      <div class="wide-table-wrap">
        <table class="wide-table">
          <tr><th>用户</th><th>成功</th><th>失败</th><th>最后登录</th><th>活跃天数</th><th>活跃占比</th><th>来源数</th><th>最常用时段</th><th>首次登录</th></tr>
          $(ops_render_user_stats_table)
        </table>
      </div>
      <div class="grid-2">
        <div class="panel">
          <h3>24 小时登录时段分布</h3>
          $(ops_render_login_hours_chart "${OPS_LOGIN_HOURS}" 480 200 "$(ops_abnormal_login_hours)")
          <div class="legend"><span><i style="background:#0066CC"></i>成功登录</span><span><i style="background:#C7000B"></i>异常登录时段</span></div>
        </div>
        <div class="panel time-anomaly-panel">
          <h3>时段异常登录</h3>
          <div class="wide-table-wrap">
            <table class="time-anomaly-table wide-table">
              <tr><th>时间</th><th>用户</th><th>来源</th><th>判定</th></tr>
              $(ops_render_abnormal_login_row)
            </table>
          </div>
        </div>
      </div>
      <div class="wide-table-panel">
        <h3>登录来源 IP 统计</h3>
        <div class="wide-table-wrap">
          <table class="source-ip-table wide-table">
            <tr><th>来源 IP</th><th>类型</th><th>失败</th><th>成功</th><th>最后活动</th></tr>
            $(ops_render_source_ip_table)
          </table>
        </div>
      </div>

      <h2>3. 网络与通信审计</h2>
      <p class="section-lead">$(ops_network_value "$((OPS_NET_TOTAL_RX_BYTES + OPS_NET_TOTAL_TX_BYTES))") 总流量，未发现异常出站流量。</p>
      <div class="grid-2">
        <div class="panel">
          <h3>网络流量 · 每日（GB）</h3>
          $(ops_render_network_chart "${OPS_NET_DAILY_RX_LIST}" "${OPS_NET_DAILY_TX_LIST}" 480 200 "${OPS_NET_DAILY_LABELS}")
          <div class="legend"><span><i style="background:#0066CC"></i>接收</span><span><i style="background:#86868B"></i>发送</span><span>单位：GB</span><span>仅统计物理网卡</span></div>
        </div>
        <div class="panel network-summary">
          <h3>网络阶段汇总</h3>
          $(ops_render_network_metrics)
          <div class="network-summary-table-wrap wide-table-wrap">
            <table class="network-summary-table wide-table">
              <tr><th>接口</th><th>类型</th><th>总流量</th><th>接收</th><th>发送</th><th>峰值</th></tr>
              $(ops_render_network_iface_table)
            </table>
          </div>
        </div>
      </div>

      <h2>4. 主机与进程安全</h2>
      <p class="section-lead">异常进程与安全配置漂移情况如下；可疑进程采用静态启发式扫描（异常路径 / 已删除二进制 / 隐藏进程名 / 下载并执行）。</p>
      $(ops_render_suspicious_process_section)
      <h3>安全配置漂移</h3>
      <div class="wide-table-wrap">
        <table class="wide-table">
          <tr><th>对象</th><th>变化类型</th><th>风险等级</th><th>变化摘要</th><th>检测时间</th></tr>
          $(ops_render_security_drift_table)
        </table>
      </div>
      <h2>5. 系统可用性</h2>
      <p class="section-lead">周期可用性 ${OPS_AVAILABILITY_PCT:-待周期数据}，当前内核 ${OPS_KERNEL}。</p>
      <table class="availability-summary">
        <tr><th>周期可用性</th><td class="good">${OPS_AVAILABILITY_PCT:-待周期数据}</td></tr>
        <tr><th>内核</th><td>${OPS_KERNEL}</td></tr>
        <tr><th>重启/关机</th><td>${OPS_REBOOT_COUNT:-0} 次重启/关机</td></tr>
        <tr><th>停机统计</th><td>计划内 ${OPS_PLANNED_DOWNTIME_COUNT:-0} 次 · 非计划 ${OPS_UNPLANNED_DOWNTIME_COUNT:-0} 次</td></tr>
        <tr><th>系统负载</th><td>${OPS_LOAD_AVG}</td></tr>
        <tr><th>OOM / 内核错误</th><td>$([ -n "$OPS_HEALTH_KERNEL_ERRORS" ] && printf '<span class="bad">检测到内核错误</span>' || echo '<span class="good">未检测到内核错误</span>')</td></tr>
      </table>
      <h3>本周期事件时间线</h3>
      <table>
        <tr><th>时间</th><th>事件</th><th>状态</th><th>影响</th></tr>
        $(ops_render_events_table)
      </table>

      <h2>6. 资源使用情况</h2>
      <p class="section-lead">CPU 平均 $(ops_pct_label "${OPS_CPU_AVG}") · 峰值 $(ops_pct_label "${OPS_CPU_MAX}")；内存平均 $(ops_pct_label "${OPS_MEM_AVG}") · 峰值 $(ops_pct_label "${OPS_MEM_MAX}")。</p>
      <div class="grid-2">
        <div class="panel">
          <h3>CPU 使用率趋势</h3>
          $(ops_render_trend_chart "${OPS_CPU_DAILY_LIST}" "#0066CC" "%" 480 190 "${OPS_CPU_DAILY_LABELS}" "Cpu")
          <div class="legend"><span><i class="legend-line solid"></i>本周期 CPU 平均 $(ops_pct_label "${OPS_CPU_AVG}") · 峰值 $(ops_pct_label "${OPS_CPU_MAX}")</span><span><i class="legend-line dash"></i>上一周期无数据</span></div>
        </div>
        <div class="panel">
          <h3>内存使用率趋势</h3>
          $(ops_render_trend_chart "${OPS_MEM_DAILY_LIST}" "#0066CC" "%" 480 190 "${OPS_MEM_DAILY_LABELS}" "Mem")
          <div class="legend"><span><i class="legend-line solid"></i>本周期内存平均 $(ops_pct_label "${OPS_MEM_AVG}") · 峰值 $(ops_pct_label "${OPS_MEM_MAX}")</span><span><i class="legend-line dash"></i>上一周期无数据</span></div>
        </div>
      </div>
      <h3>Swap 使用</h3>
      <table>
        <tr><th>项目</th><th>当前</th><th>周期峰值</th></tr>
        <tr><td>Swap</td><td>$(ops_format_bytes "$((OPS_SWAP_USED_KB * 1024))") / $(ops_format_bytes "$((OPS_SWAP_TOTAL_KB * 1024))")</td><td>$(ops_format_bytes "$((OPS_SWAP_PEAK_KB * 1024))")</td></tr>
      </table>
      <h3>关键指标周期对比</h3>
      <table>
        <tr><th>指标</th><th>本周期</th><th>变化</th><th>上一周期</th></tr>
        $(ops_render_period_comparison_table)
      </table>
      <h3>磁盘容量与 I/O 对比</h3>
      <div class="grid-2">
        <div class="panel">
          <h3>磁盘容量使用率</h3>
          $(ops_render_disk_capacity_chart)
        </div>
        <div class="panel">
          <h3>设备 I/O 对比 · 周期累计</h3>
          $(ops_render_disk_io_chart)
        </div>
      </div>
      <h3>磁盘容量预测</h3>
      <table>
        <tr><th>磁盘</th><th>当前使用率</th><th>预测（按使用率增速线性外推）</th></tr>
        $(ops_render_disk_forecast_table)
      </table>

      <h2>7. 存储与数据安全</h2>
      <p class="section-lead">${OPS_HEALTH_RAID_STATE}；$(ops_html_escape "$OPS_HEALTH_SMART_SUMMARY")</p>
      <h3>阵列与文件系统</h3>
      <table>
        <tr><th>项目</th><th>状态</th></tr>
        <tr><td>RAID</td><td>${OPS_HEALTH_RAID_STATE}</td></tr>
        <tr><td>文件系统</td><td>$(if [[ -n "$OPS_HEALTH_RO_MOUNTS" ]]; then printf '<span class="bad">检测到只读挂载</span>'; elif [[ -n "$OPS_HEALTH_FS_ERRORS" ]]; then printf '<span class="bad">检测到文件系统错误</span>'; else echo '<span class="good">无只读挂载、无异常卸载、无文件系统错误</span>'; fi)</td></tr>
      </table>

      <h2>8. 服务与应用状态</h2>
      <p class="section-lead">Docker ${OPS_DOCKER_RUNNING_COUNT} / $((OPS_DOCKER_RUNNING_COUNT + OPS_DOCKER_STOPPED_COUNT)) 运行，失败服务 ${OPS_SYSTEMD_FAILED_COUNT:-0} 个。</p>
      <div class="metric-group service-metrics">
        <div class="metric"><div class="k">Docker 运行中</div><div class="v">${OPS_DOCKER_RUNNING_COUNT} / $((OPS_DOCKER_RUNNING_COUNT + OPS_DOCKER_STOPPED_COUNT))</div></div>
        <div class="metric"><div class="k">虚拟机</div><div class="v">${OPS_VM_RUNNING_COUNT} / ${OPS_VM_COUNT}</div></div>
        <div class="metric"><div class="k">失败服务</div><div class="v warn">${OPS_SYSTEMD_FAILED_COUNT}</div></div>
        <div class="metric"><div class="k">关键服务</div><div class="v">$(ops_key_services_counts)</div></div>
      </div>
      <h3>服务与应用清单</h3>
      <div class="wide-table-wrap">
        <table class="wide-table">
          <tr><th>名称</th><th>当前状态</th><th>类型</th><th>周期错误</th><th>周期重启</th><th>最近一次启动</th><th>说明</th></tr>
          $(ops_render_service_list_table)
        </table>
      </div>

      <h2>9. 维护与更新</h2>
      <p class="section-lead">本周期完成 ${OPS_UPDATE_SESSIONS:-0} 次更新，共安装 ${OPS_UPDATE_COUNT} 个软件包。</p>
      <div class="metric-group">
        <div class="metric"><div class="k">周期内更新次数</div><div class="v">${OPS_UPDATE_SESSIONS:-0} 次</div></div>
        <div class="metric"><div class="k">已安装更新包</div><div class="v">${OPS_UPDATE_COUNT} 个</div></div>
        <div class="metric"><div class="k">安全更新已装</div><div class="v">$(ops_installed_count_label "${OPS_SECURITY_INSTALLED_COUNT:-0}")</div></div>
        <div class="metric"><div class="k">常规更新已装</div><div class="v">$(ops_installed_count_label "${OPS_REGULAR_INSTALLED_COUNT:-0}")</div></div>
        <div class="metric"><div class="k">待装安全更新</div><div class="v">$(ops_installed_count_label "${OPS_PENDING_SECURITY_COUNT:-0}")</div></div>
        <div class="metric"><div class="k">待装常规更新</div><div class="v">$(ops_installed_count_label "${OPS_PENDING_REGULAR_COUNT:-0}")</div></div>
      </div>
      <h3>系统版本更新</h3>
      <table>
        <tr><th>项目</th><th>当前版本</th><th>上一版本</th><th>更新时间</th></tr>
        $(ops_render_system_version_table)
      </table>
      <h3>更新执行记录</h3>
      <div class="wide-table-wrap">
        <table class="wide-table">
          <tr><th>执行时间</th><th>包名</th><th>类型</th><th>旧版本</th><th>新版本</th></tr>
          $(ops_render_update_table)
        </table>
      </div>
      <h3>其他维护信息</h3>
      <table>
        <tr><th>项目</th><th>结果</th></tr>
        <tr><td>最近更新检查</td><td>${OPS_LAST_UPDATE_CHECK}</td></tr>
        <tr><td>重启需求</td><td class="$([[ "$OPS_REBOOT_REQUIRED" == "无" ]] && echo good || echo warn)">${OPS_REBOOT_REQUIRED}</td></tr>
        <tr><td>Journal 错误摘要</td><td>${OPS_JOURNAL_ERROR_COUNT:-0} 条</td></tr>
        <tr><td>SSL 证书</td><td>$(ops_html_escape "$OPS_SSL_SUMMARY")</td></tr>
        <tr><td>定时任务</td><td>${OPS_TIMER_TASKS:-0} 个 systemd 定时器</td></tr>
      </table>

      <h2>10. 建议与行动项</h2>
      <p class="section-lead">建议优先处理风险等级最高的事项。</p>
      <table>
        <tr><th>事项</th><th>优先级</th><th>建议动作</th><th>状态</th></tr>
        $(ops_render_actions_table)
      </table>
    </div>
    <div class="footer">
      <div class="footer-grid">
        <div><span>数据覆盖</span><strong>${OPS_DATA_START:-无数据} 起</strong></div>
        <div><span>生成时间</span><strong>$(date '+%Y-%m-%d %H:%M')</strong></div>
        <div><span>上一期报告</span><strong>${OPS_PREVIOUS_REPORT_DATE:-未找到}</strong></div>
        <div><span>下一期预计</span><strong>$(date -d "$next_period_expr" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "未计算")</strong></div>
      </div>
      <div class="footer-note">此报告由 DebNAS 自动生成</div>
    </div>
  </div>
</body>
</html>
HTML
}

ops_print_terminal_summary() {
  printf '\n'
  printf 'DebNAS 运维报告\n'
  printf '────────────────────────────────────────────\n'
  printf '周期：最近 %s 天       总体状态：%s\n' "$OPS_REPORT_DAYS" "$OPS_STATUS_TEXT"
  printf '运行：%s 天   CPU：%s   内存：%s\n' "$OPS_UPTIME_DAYS" "$(ops_pct_label "$OPS_CPU_AVG")" "$(ops_pct_label "$OPS_MEM_CURRENT_PERCENT")"
  printf '登录成功：%s   失败：%s   待更新：%s   建议：%s\n' \
    "$OPS_LOGIN_SUCCESS_COUNT" "$OPS_LOGIN_FAIL_COUNT" "$(ops_installed_count_label "$OPS_PENDING_UPDATE_COUNT")" "$OPS_ACTION_COUNT"
  printf '报告目录：%s\n' "${OPS_PERIOD_REPORTS_DIR:-$OPS_REPORTS_DIR}"
  printf '报告文件：%s（%s 字节）\n' "$OPS_LAST_REPORT" "$OPS_REPORT_SIZE"
  printf '固定入口：%s/latest.html\n' "${OPS_PERIOD_REPORTS_DIR:-$OPS_REPORTS_DIR}"
  printf '提示：报告目录按安全规范为 root 权限（700/600），请以 root 用户查看。\n'
  printf '────────────────────────────────────────────\n'
}

# 并发保护：cron 周报/年报与手动生成可能同时运行，共用快照 .tmp 与基线文件，
# 用 flock 串行化；锁文件放在 root 700 的报告目录中，不使用 /tmp 固定路径
ops_generate_report() {
  ops_ensure_report_dirs || return 1
  local lock_fd rc=0
  if ! exec {lock_fd}>"${OPS_REPORT_DIR}/.generate.lock"; then
    log_error "无法创建报告生成锁：${OPS_REPORT_DIR}/.generate.lock"
    return 1
  fi
  if ! flock -n "$lock_fd"; then
    exec {lock_fd}>&-
    log_warning "已有运维报告生成任务正在运行，本次跳过"
    if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
      return 0
    fi
    return 1
  fi
  # 直接调用以保留 set -e 语义；异常退出时进程结束会自动释放锁
  _ops_generate_report_locked "$@"
  rc=$?
  exec {lock_fd}>&-
  return "$rc"
}

_ops_generate_report_locked() {
  local days="${1:-${OPS_DEFAULT_PERIOD}}"
  local email="${2:-0}"
  case "$days" in
    7|30|365) ;;
    *) days="$OPS_DEFAULT_PERIOD" ;;
  esac

  OPS_REPORT_DAYS="$days"
  OPS_REPORT_SINCE=$(date -d "$days days ago" '+%Y-%m-%d %H:%M:%S')
  OPS_REPORT_UNTIL=$(date '+%Y-%m-%d %H:%M:%S')
  OPS_ACTION_ITEMS=()
  OPS_REPORT_SIZE=0
  local started
  started=$(date +%s)

  if ! ops_setup_enable; then
    log_warning "数据采集初始化未完成，报告将继续生成，但周期历史数据可能不足"
  fi
  ops_ensure_report_dirs || return 1
  ops_set_coverage "$days"
  ops_collect_resources
  ops_collect_disk_trend
  ops_collect_health
  ops_collect_security
  ops_collect_suspicious_processes
  ops_collect_services
  ops_collect_security_drift
  ops_collect_updates
  ops_collect_availability
  ops_determine_status

  local filename report_path previous_file prev_base period_tag period_reports_dir
  case "$days" in
    7) period_tag="7d" ;;
    30) period_tag="30d" ;;
    365) period_tag="365d" ;;
    *) period_tag="7d" ;;
  esac
  period_reports_dir=$(ops_period_reports_dir "$days")
  OPS_PERIOD_REPORTS_DIR="$period_reports_dir"
  mkdir -p "$period_reports_dir" 2>/dev/null || true
  filename="ops-report-${period_tag}-$(date '+%Y%m%d-%H%M%S').html"
  report_path="${period_reports_dir}/${filename}"
  OPS_PREVIOUS_REPORT_DATE="未找到"
  while IFS= read -r previous_file; do
    prev_base="${previous_file##*/}"
    [[ "$prev_base" == "$filename" ]] && continue
    if [[ "$prev_base" =~ ^ops-report-([0-9]+d)-([0-9]{8})-([0-9]{6})\.html$ ]]; then
      OPS_PREVIOUS_REPORT_DATE="${BASH_REMATCH[2]:0:4}-${BASH_REMATCH[2]:4:2}-${BASH_REMATCH[2]:6:2} ${BASH_REMATCH[3]:0:2}:${BASH_REMATCH[3]:2:2}"
    elif [[ "$prev_base" =~ ^ops-report-([0-9]{8})-([0-9]{6})\.html$ ]]; then
      OPS_PREVIOUS_REPORT_DATE="${BASH_REMATCH[1]:0:4}-${BASH_REMATCH[1]:4:2}-${BASH_REMATCH[1]:6:2} ${BASH_REMATCH[2]:0:2}:${BASH_REMATCH[2]:2:2}"
    fi
  done < <(find "$period_reports_dir" -maxdepth 1 -name 'ops-report-*.html' -printf '%f\n' 2>/dev/null | sort)
  # 先以 600 创建再写入，避免写入期间按 umask 以 644 暴露登录 IP 等敏感内容
  install -m 600 /dev/null "$report_path"
  ops_render_html_report > "$report_path"
  chmod 600 "$report_path"

  if [[ ! -s "$report_path" ]] || ! grep -q '</html>' "$report_path" 2>/dev/null; then
    log_error "报告文件生成失败或不完整：${report_path}"
    return 1
  fi

  OPS_REPORT_SIZE=$(wc -c < "$report_path" | tr -d '[:space:]')
  OPS_LAST_REPORT="$report_path"
  ln -sf "$filename" "${period_reports_dir}/latest.html" 2>/dev/null || true

  local ended duration
  ended=$(date +%s)
  duration=$((ended - started))

  state_set "ops-report" "report_file" "$report_path"
  state_set "ops-report" "report_period" "${days}d"
  state_set "ops-report" "report_duration" "${duration}s"
  state_set "ops-report" "data_coverage" "$OPS_DATA_COVERAGE"
  state_set "ops-report" "report_size" "$OPS_REPORT_SIZE"

  if [[ "$email" -eq 1 ]]; then
    ops_send_report_email "$days" || true
  fi

  ops_print_terminal_summary
  module_mark_action
  return 0
}
