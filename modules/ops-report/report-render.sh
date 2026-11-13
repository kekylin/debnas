#!/bin/bash
# ops-report: HTML 渲染与图表生成（由 report.sh 加载）
# 说明：函数自 report.sh 原样移出，保持函数名与全局变量契约不变；
#       调用方仍只需 source report.sh。
set -euo pipefail
IFS=$'\n\t'

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

