#!/bin/bash
# threat-ips: 威胁列表下载与解析模块

set -euo pipefail
IFS=$'\n\t'

download_threat_list() {
  local threat_level="${1:-${THREAT_LEVEL:-${DEFAULT_THREAT_LEVEL}}}"
  local temp_gz="$2" temp_txt="$3"

  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 || "${threat_level}" -gt 100 ]]; then
    log_warning \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi

  local download_url
  download_url=$(get_threat_list_url "${threat_level}")
  log_info "下载威胁等级 ${threat_level} 的 IP 列表"

  if ! wget -q --timeout=60 --tries=3 "${download_url}" -O "${temp_gz}"; then
    log_error \
      "下载威胁 IP 列表失败（威胁等级：${threat_level}）"
    return 1
  fi
  if ! gzip -dc "${temp_gz}" > "${temp_txt}"; then
    log_error "解压威胁 IP 列表失败"
    return 1
  fi
  if [[ ! -s "${temp_txt}" ]]; then
    log_error "威胁 IP 列表为空，放弃本次更新（保留现有封禁）"
    return 1
  fi
  rm -f "${temp_gz}"
  log_success "威胁 IP 列表下载完成（威胁等级：${threat_level}）"
}


prepare_input_file() {
  local input_file="$1"
  local temp_input
  temp_input=$(create_temp_file "processed_input" ".txt")
  grep -v '^\s*$' "${input_file}" | grep -v '^\s*#' > "${temp_input}" || {
    log_info "IP 列表为空或仅包含注释，无需处理"
    return 1
  }
  printf "%s" "${temp_input}"
}

# 解析 IP 条目：一次 awk 批量完成清洗、分类与校验（旧实现每行起 5 个以上进程，6.5 万行需十几分钟）
# 规则逐条复刻旧实现，输出逐行一致：
#   清洗 = cut -d'#' -f1 | xargs（去注释；按空格/Tab 分词，处理引号与反斜杠，/bin/echo 吃掉开头的 -n/-e/-E）
#   判定顺序 = IPv4 CIDR > IPv6 CIDR > IPv4 范围（展开，≤ MAX_RANGE_SIZE）> IPv6 范围（只取两端）> 单个地址
#   地址合法性 = sipcalc 1.1.6 的 validate_v4addr / validate_netmask / validate_v6addr 判定（含其宽松之处）
# 参数：$1 - 已去空行/注释行的列表，$2/$3 - IPv4/IPv6 输出文件（追加）
# 返回：0 有有效条目，1 全部无效
parse_ip_entries() {
  local temp_input="$1" temp_file_ipv4="$2" temp_file_ipv6="$3"
  local warn_file stats msg total_count=0 valid_count=0 invalid_count=0

  warn_file=$(create_temp_file "parse_warn" ".txt") || return 1
  log_info "解析 IP 列表中..."
  stats=$(LC_ALL=C awk -v out4="${temp_file_ipv4}" -v out6="${temp_file_ipv6}" \
    -v warnf="${warn_file}" -v maxr="${MAX_RANGE_SIZE}" '
    function warn(m) { print m >> warnf }
    # 形如 d{1,3}.d{1,3}.d{1,3}.d{1,3}（mawk 旧版不支持 {m,n}，逐段判断）
    function quad(s,   o, i) {
      if (split(s, o, ".") != 4) return 0
      for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || length(o[i]) > 3) return 0
      return 1
    }
    # sipcalc validate_v4addr：四段、每段 1~3 位且 ≤ 255
    function v4ok(s,   o) {
      if (!quad(s)) return 0
      split(s, o, ".")
      return o[1] + 0 <= 255 && o[2] + 0 <= 255 && o[3] + 0 <= 255 && o[4] + 0 <= 255
    }
    function ip2n(s,   o) { split(s, o, "."); return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4] }
    # sipcalc validate_netmask == 2：a.b.c.d/m（"/" 前最多取 15 个字符），m 为 1~2 位且 ≤ 32
    function v4mask(s,   p, m) {
      p = index(s, "/")
      if (!p || length(s) > 18) return 0
      if (!v4ok(substr(s, 1, p - 1 < 15 ? p - 1 : 15))) return 0
      m = substr(s, p + 1)
      return m ~ /^[0-9][0-9]?$/ && m + 0 <= 32
    }
    # sipcalc validate_s_v6addr；v4in6=1 时 a 为内嵌 IPv4 之前的部分（如 "::ffff:"）
    function v6s(a, v4in6,   n, u, t, nc, cp, g, i) {
      n = length(a)
      if (n < 2 || n > 39 || a ~ /[^0-9A-Fa-f:]/ || index(a, ":::")) return 0
      if (substr(a, 1, 1) == ":" && substr(a, 2, 1) != ":") return 0
      if (!v4in6 && substr(a, n, 1) == ":" && substr(a, n - 1, 1) != ":") return 0
      u = a; nc = gsub(/:/, "", u)
      u = a; cp = gsub(/::/, "", u)
      if (cp > 1 || (!cp && nc != 7 - v4in6) || (cp && nc > 7 - v4in6)) return 0
      g = split(a, t, ":")
      for (i = 1; i <= g; i++) if (length(t[i]) > 4) return 0
      return 1
    }
    # sipcalc validate_v6addr（含 split_ipv6addr 的拆分方式：前缀长度 1~3 个任意字符、内嵌 IPv4）
    function v6ok(s,   n, p, t, nm, v4, pd, pc, x, y, k, e, len) {
      n = length(s); nm = ""; v4 = ""
      p = index(s, "/")
      t = s
      if (p && gsub(/\//, "/", t) == 1 && n - p + 1 > 1 && n - p + 1 < 5) nm = substr(s, p + 1)
      pd = index(s, "."); pc = index(s, ":")
      x = pd ? n - pd + 1 : 0; y = pc ? n - pc + 1 : 0
      t = s
      if (gsub(/\./, ".", t) == 3 && x < y) {
        for (k = pd - 1; substr(s, k, 1) != ":"; k--) ;
        e = p ? p - 1 : n
        if (e - k >= 7 && e - k <= 15) v4 = substr(s, k + 1, e - k)
      }
      len = n - length(v4) - length(nm) - (nm != "")
      if (len <= 1 || len >= 40) return 0
      if (!v6s(substr(s, 1, len), v4 != "")) return 0
      return v4 == "" || v4ok(v4)
    }
    # 旧实现 validate_ip（sipcalc 输出 -[ipv4 / -[ipv6）：4 / 6 / 0
    # "-" 开头的参数会被 sipcalc 当作选项（"-" 本身还会读走 stdin），一律视为无效
    function sipclass(s) {
      if (substr(s, 1, 1) == "-") return 0
      if (v6ok(s)) return 6
      if (v4mask(s) || v4ok(s)) return 4
      return 0
    }
    # cut -d"#" -f1 | xargs（GNU xargs + /bin/echo）
    function norm(s,   p, n, i, c, q, cur, hq, tk, nt, st, r) {
      p = index(s, "#"); if (p) s = substr(s, 1, p - 1)
      n = length(s); q = ""; cur = ""; hq = 0; nt = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; else cur = cur c; continue }
        # 参数开始前跳过所有空白字符（含 \r \v \f）；参数内部只有空格/Tab 才分隔
        if (cur == "" && !hq && index(" \t\r\v\f", c)) continue
        # 引号括起的空串（""）也算一个参数，echo 输出时会多出空格
        if (c == " " || c == "\t") { if (cur != "" || hq) tk[++nt] = cur; cur = ""; hq = 0; continue }
        if (c == "\\") { cur = cur (i < n ? substr(s, ++i, 1) : "\n"); continue }
        if (c == "\"" || c == "\047") { q = c; hq = 1; continue }
        cur = cur c
      }
      # 引号未闭合：xargs 只执行已完整的参数
      if (q == "" && (cur != "" || hq)) tk[++nt] = cur
      for (st = 1; st <= nt && tk[st] ~ /^-[neE]+$/; st++) ;
      r = ""
      for (i = st; i <= nt; i++) r = r (i > st ? " " : "") tk[i]
      sub(/\n+$/, "", r)
      return r
    }
    function parse(c,   t, p, m, sn, en, cnt, i, k) {
      if (c ~ /^[0-9.]+\/[0-9]+$/ && split(c, t, "/") == 2 && quad(t[1]) && length(t[2]) <= 2 \
        && t[2] + 0 <= 32 && v4ok(t[1])) { print c >> out4; return 1 }
      if (c ~ /^[0-9a-fA-F:]+\/[0-9]+$/) {
        p = index(c, "/"); m = substr(c, p + 1)
        if (length(m) <= 3) {
          if (m + 0 > 128) warn("无效 IPv6 CIDR 掩码：" c)
          else if (!v6ok(c)) warn("无效 IPv6 CIDR 格式：" c)
          else { print c >> out6; return 1 }
        }
      }
      if (c ~ /^[0-9.]+-[0-9.]+$/ && split(c, t, "-") == 2 && quad(t[1]) && quad(t[2])) {
        if (!v4ok(t[1]) || !v4ok(t[2])) warn("无效 IPv4 范围地址：" c)
        else {
          sn = ip2n(t[1]); en = ip2n(t[2]); cnt = en - sn + 1
          if (sn > en) warn("无效 IPv4 范围：" c "（起始地址大于结束地址）")
          else if (cnt > maxr) warn("IPv4 范围过大：" c "（" sprintf("%.0f", cnt) " 条，建议使用 CIDR 格式）")
          else {
            for (i = sn; i <= en; i++)
              printf("%d.%d.%d.%d\n", int(i / 16777216), int(i / 65536) % 256, int(i / 256) % 256, i % 256) >> out4
            return 1
          }
        }
      }
      if (c ~ /^[0-9a-fA-F:]+-[0-9a-fA-F:]+$/) {
        split(c, t, "-")
        if (!v6ok(t[1]) || !v6ok(t[2])) warn("无效 IPv6 范围：" c)
        else { print t[1] >> out6; print t[2] >> out6; return 1 }
      }
      k = sipclass(c)
      if (k == 4) { print c >> out4; return 1 }
      if (k == 6) { print c >> out6; return 1 }
      return 0
    }
    $0 == "" { next }
    {
      c = norm($0)
      if (c == "") { bad++; next }
      if (parse(c)) ok++
      else { warn("无效输入：" $0); bad++ }
    }
    END { printf "%d %d %d\n", NR, ok, bad }
  ' "${temp_input}") || { rm -f "${warn_file}"; log_error "解析 IP 列表失败"; return 1; }

  while IFS= read -r msg; do
    log_warning "${msg}"
  done < "${warn_file}"
  rm -f "${warn_file}"
  IFS=' ' read -r total_count valid_count invalid_count <<< "${stats}"

  if [[ ${valid_count} -gt 0 ]]; then
    log_info \
      "解析 IP 列表：${valid_count} 条有效，${invalid_count} 条无效"
  fi
  if [[ ${invalid_count} -eq ${total_count} ]]; then
    log_info "所有输入 IP (${invalid_count} 条) 无效，已跳过"
    return 1
  fi
}

deduplicate_and_sort_ips() {
  local temp_file="$1" output_file="$2"
  sort -u "${temp_file}" > "${output_file}" 2>/dev/null
}

# 收集受保护地址（不得被封禁）：保留/私有网段、本机地址、当前登录会话来源、用户白名单
collect_protected_addresses() {
  printf '%s\n' 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
    172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4
  if command -v ip &>/dev/null; then
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true
  fi
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    printf '%s\n' "${SSH_CLIENT%% *}"
  fi
  if command -v who &>/dev/null; then
    who 2>/dev/null | grep -oE '\([0-9a-fA-F:.]+\)' | tr -d '()' || true
  fi
  if [[ -f "${WHITELIST_FILE}" ]]; then
    sed 's/#.*//' "${WHITELIST_FILE}" | awk 'NF {print $1}' || true
  fi
}

# 剔除受保护地址与过宽条目，并把 IPv4 规范化为十进制（去前导 0、CIDR 取网络地址）
# 参数：$1 - IP 文件（原地改写），$2 - 类型 IPv4/IPv6
filter_protected_entries() {
  local ip_file="$1" ip_type="$2"
  local protected_file stat_file filtered_file stats
  protected_file=$(create_temp_file "protected" ".txt") || return 1
  stat_file=$(create_temp_file "filter_stat" ".txt") || return 1
  filtered_file=$(create_temp_file "filtered_${ip_type}" ".txt") || return 1
  collect_protected_addresses > "${protected_file}"

  if [[ "${ip_type}" == "IPv4" ]]; then
    awk -v minmask="${MIN_IPV4_PREFIX}" -v statfile="${stat_file}" '
      function ip2n(s,   o, i) {
        if (split(s, o, ".") != 4) return -1
        for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || o[i] + 0 > 255) return -1
        return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
      }
      function parse(s,   t, p, m, n, blk) {
        p = s; m = 32
        if (index(s, "/")) { split(s, t, "/"); p = t[1]; m = t[2] }
        if (m !~ /^[0-9]+$/ || m + 0 > 32) return 0
        m += 0; n = ip2n(p)
        if (n < 0) return 0
        blk = 2 ^ (32 - m)
        R_S = int(n / blk) * blk; R_E = R_S + blk - 1; R_M = m
        return 1
      }
      NR == FNR { if ($1 !~ /:/ && parse($1)) { ps[++np] = R_S; pe[np] = R_E }; next }
      {
        if (!parse($1)) { bad++; next }
        if (R_M < minmask) { wide++; next }
        for (k = 1; k <= np; k++) if (R_S <= pe[k] && R_E >= ps[k]) { prot++; next }
        n = R_S
        printf "%d.%d.%d.%d", int(n / 16777216), int(n / 65536) % 256, int(n / 256) % 256, n % 256
        if (index($1, "/")) printf "/%d", R_M
        printf "\n"
      }
      END { print bad + 0, wide + 0, prot + 0 > statfile }
    ' "${protected_file}" "${ip_file}" > "${filtered_file}"
  else
    awk -v minmask="${MIN_IPV6_PREFIX}" -v statfile="${stat_file}" '
      NR == FNR { if ($1 ~ /:/) { a = tolower($1); sub(/\/128$/, "", a); own[a] = 1 }; next }
      {
        e = tolower($1); addr = e; m = 128
        if (index(e, "/")) { split(e, t, "/"); addr = t[1]; m = t[2] + 0 }
        if (m < minmask) { wide++; next }
        if (addr == "::" || addr == "::1" || addr ~ /^(fe[89ab]|f[cd]|ff)/ || (addr in own)) { prot++; next }
        print $1
      }
      END { print 0, wide + 0, prot + 0 > statfile }
    ' "${protected_file}" "${ip_file}" > "${filtered_file}"
  fi

  mv "${filtered_file}" "${ip_file}"
  stats=$(cat "${stat_file}" 2>/dev/null) || stats=""
  rm -f "${protected_file}" "${stat_file}"
  local s_bad s_wide s_prot
  IFS=' ' read -r s_bad s_wide s_prot <<< "${stats:-0 0 0}"
  if [[ "${s_wide:-0}" -gt 0 || "${s_prot:-0}" -gt 0 || "${s_bad:-0}" -gt 0 ]]; then
    log_warning "${ip_type} 已剔除：过宽网段 ${s_wide:-0} 条，命中保护/白名单 ${s_prot:-0} 条，格式无效 ${s_bad:-0} 条"
  fi
}

check_and_limit_ip_count() {
  local ip_file="$1" ip_type="$2"
  local count
  count=$(wc -l < "${ip_file}")
  if [[ ${count} -gt ${MAX_IP_LIMIT} ]]; then
    log_warning \
      "${ip_type} IP 数量超出上限 ${MAX_IP_LIMIT}，截取前 ${MAX_IP_LIMIT} 条"
    head -n "${MAX_IP_LIMIT}" "${ip_file}" > "${ip_file}.tmp" \
      && mv "${ip_file}.tmp" "${ip_file}"
    count=${MAX_IP_LIMIT}
  fi
  printf "%s" "${count}"
}
