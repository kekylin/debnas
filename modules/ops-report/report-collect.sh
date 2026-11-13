#!/bin/bash
# ops-report: 数据采集与状态判定（由 report.sh 加载）
set -euo pipefail
IFS=$'\n\t'

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

ops_kernel_prev_upgrade() {
  local log="${1:-/var/log/dpkg.log}"
  [[ -f "$log" ]] || return 0
  awk '$3 == "upgrade" && $4 ~ /^linux-image-([a-z]+-)?(amd64|arm64|686|686-pae)(:|$)/ { prev = $5; at = $1 " " $2 }
    END { if (prev != "") print prev "|" at }' "$log" 2>/dev/null || true
}

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

