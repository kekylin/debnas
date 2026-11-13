#!/bin/bash
# ops-report: 数据聚合、终端摘要、HTML 报告与邮件内容生成
set -euo pipefail
IFS=$'\n\t'

# 渲染与图表函数（原 report.sh 移出，函数名与全局变量契约不变）
_ops_report_src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ops_report_src_dir}/report-render.sh"
unset _ops_report_src_dir

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

# 磁盘容量预测表（三列：磁盘 / 当前使用率 / 预测），数据来自 ops_collect_disk_trend 的 OPS_DISK_FORECAST

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
