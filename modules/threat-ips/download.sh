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
  rm -f -- "${temp_gz}"
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
  local warn_file stats msg total_count=0 valid_count=0 invalid_count=0 warn_count=0

  warn_file=$(create_temp_file "parse_warn" ".txt") || return 1
  log_info "解析 IP 列表中..."
  stats=$(LC_ALL=C awk -v out4="${temp_file_ipv4}" -v out6="${temp_file_ipv6}" \
    -v warnf="${warn_file}" -v maxr="${MAX_RANGE_SIZE}" -v maxw="${MAX_PARSE_WARNINGS}" '
    # 告警只写前 maxw 条（其余只计数）；列表原文去掉控制字符并截断到 80 字符，防止日志/终端注入与刷屏
    function warn(m) { if (++nw <= maxw) print m >> warnf }
    function clean(s) {
      gsub("[\001-\037\177]", "", s)
      if (length(s) > 80) s = substr(s, 1, 80) "..."
      return s
    }
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
          if (m + 0 > 128) warn("无效 IPv6 CIDR 掩码：" clean(c))
          else if (!v6ok(c)) warn("无效 IPv6 CIDR 格式：" clean(c))
          else { print c >> out6; return 1 }
        }
      }
      if (c ~ /^[0-9.]+-[0-9.]+$/ && split(c, t, "-") == 2 && quad(t[1]) && quad(t[2])) {
        if (!v4ok(t[1]) || !v4ok(t[2])) warn("无效 IPv4 范围地址：" clean(c))
        else {
          sn = ip2n(t[1]); en = ip2n(t[2]); cnt = en - sn + 1
          if (sn > en) warn("无效 IPv4 范围：" clean(c) "（起始地址大于结束地址）")
          else if (cnt > maxr) warn("IPv4 范围过大：" clean(c) "（" sprintf("%.0f", cnt) " 条，建议使用 CIDR 格式）")
          else {
            for (i = sn; i <= en; i++)
              printf("%d.%d.%d.%d\n", int(i / 16777216), int(i / 65536) % 256, int(i / 256) % 256, i % 256) >> out4
            return 1
          }
        }
      }
      if (c ~ /^[0-9a-fA-F:]+-[0-9a-fA-F:]+$/) {
        split(c, t, "-")
        if (!v6ok(t[1]) || !v6ok(t[2])) warn("无效 IPv6 范围：" clean(c))
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
      else { warn("无效输入：" clean($0)); bad++ }
    }
    END { printf "%d %d %d %d\n", NR, ok, bad, nw }
  ' "${temp_input}") || { rm -f "${warn_file}"; log_error "解析 IP 列表失败"; return 1; }

  while IFS= read -r msg; do
    log_warning "${msg}"
  done < "${warn_file}"
  rm -f "${warn_file}"
  IFS=' ' read -r total_count valid_count invalid_count warn_count <<< "${stats}"
  if [[ "${warn_count:-0}" -gt "${MAX_PARSE_WARNINGS}" ]]; then
    log_warning "其余 $(( warn_count - MAX_PARSE_WARNINGS )) 条解析告警已省略（共 ${warn_count} 条）"
  fi

  if [[ ${valid_count} -gt 0 ]]; then
    log_info \
      "解析 IP 列表：${valid_count} 条有效，${invalid_count} 条无效"
  fi
  if [[ ${invalid_count} -eq ${total_count} ]]; then
    log_info "所有输入 IP (${invalid_count} 条) 无效，已跳过"
    return 1
  fi
}

# IP 网段 awk 函数库（IPv4/IPv6 共用，纯 awk，不依赖 python）
#   netparse(s)  解析 "地址[/前缀]"（前缀须为纯数字，IPv4 0~32、IPv6 0~128）。成功返回 1 并设置：
#                NKEY 网络地址（主机位清零）的定长十六进制串（IPv4 8 位、IPv6 32 位，可直接按字符串排序/比较）、
#                NM 前缀长度、NFAM 4/6、NSLASH 原文是否带 "/"；格式非法返回 0。
#                IPv6 展开 :: 与内嵌 IPv4，大小写/前导 0/压缩写法不同的同一地址得到同一 NKEY
#   netcontains(pk, pm, xk, xm)  网段 pk/pm 是否包含 xk/xm（同族；CIDR 网段要么嵌套要么不相交，重叠即包含）
#   netcanon()   按最近一次 netparse 结果输出规范写法（IPv4 点分十进制；IPv6 小写、去前导 0、最长连续 0 组压缩为 ::）
# shellcheck disable=SC2016  # awk 程序文本，$ 由 awk 解释
_THREAT_NET_AWK='
function hexv(h,   i, v) {
  v = 0
  for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
  return v
}
function v6group(t) { return t ~ /^[0-9a-f]+$/ && length(t) <= 4 }
function netparse(s,   p, m, o, g, n, i, lc, v4, dc, left, right, nl, nr, L, R, r, cut, val, key) {
  s = tolower(s); NSLASH = 0; m = -1
  p = index(s, "/")
  if (p) {
    m = substr(s, p + 1); s = substr(s, 1, p - 1); NSLASH = 1
    if (m !~ /^[0-9]+$/ || length(m) > 3) return 0
    m += 0
  }
  if (s ~ /^[0-9.]+$/) {
    if (split(s, o, ".") != 4) return 0
    for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || length(o[i]) > 3 || o[i] + 0 > 255) return 0
    if (m < 0) m = 32
    if (m > 32) return 0
    NFAM = 4; n = 2
    g[1] = o[1] * 256 + o[2]; g[2] = o[3] * 256 + o[4]
  } else {
    if (s !~ /^[0-9a-f:.]+$/ || !index(s, ":") || index(s, ":::")) return 0
    if (m < 0) m = 128
    if (m > 128) return 0
    # 内嵌 IPv4（如 ::ffff:1.2.3.4）：最后一段点分地址换成两组十六进制
    if (index(s, ".")) {
      for (lc = length(s); lc > 0 && substr(s, lc, 1) != ":"; lc--) ;
      v4 = substr(s, lc + 1)
      if (split(v4, o, ".") != 4) return 0
      for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || length(o[i]) > 3 || o[i] + 0 > 255) return 0
      s = substr(s, 1, lc) sprintf("%x:%x", o[1] * 256 + o[2], o[3] * 256 + o[4])
    }
    dc = index(s, "::")
    if (dc) {
      left = substr(s, 1, dc - 1); right = substr(s, dc + 2)
      if (index(right, "::")) return 0
    } else {
      left = s; right = ""
    }
    nl = left == "" ? 0 : split(left, L, ":")
    nr = right == "" ? 0 : split(right, R, ":")
    for (i = 1; i <= nl; i++) if (!v6group(L[i])) return 0
    for (i = 1; i <= nr; i++) if (!v6group(R[i])) return 0
    if (dc ? nl + nr > 7 : nl != 8) return 0
    NFAM = 6; n = 8
    for (i = 1; i <= 8; i++) g[i] = 0
    for (i = 1; i <= nl; i++) g[i] = hexv(L[i])
    for (i = 1; i <= nr; i++) g[8 - nr + i] = hexv(R[i])
  }
  NM = m; key = ""
  for (i = 1; i <= n; i++) {
    r = NM - 16 * (i - 1); val = g[i]
    if (r <= 0) val = 0
    else if (r < 16) { cut = 2 ^ (16 - r); val = int(val / cut) * cut }
    key = key sprintf("%04x", val)
  }
  NKEY = key
  return 1
}
function netcontains(pk, pm, xk, xm,   q, r) {
  if (length(pk) != length(xk) || pm + 0 > xm + 0) return 0
  q = int(pm / 4); r = pm % 4
  if (substr(pk, 1, q) != substr(xk, 1, q)) return 0
  if (r == 0) return 1
  return int(hexv(substr(pk, q + 1, 1)) / 2 ^ (4 - r)) == int(hexv(substr(xk, q + 1, 1)) / 2 ^ (4 - r))
}
function netcanon(   i, h, a, b, out, bs, bl, cs, cl) {
  if (NFAM == 4) {
    a = hexv(substr(NKEY, 1, 4)); b = hexv(substr(NKEY, 5, 4))
    out = int(a / 256) "." (a % 256) "." int(b / 256) "." (b % 256)
  } else {
    bs = 0; bl = 0; cl = 0
    for (i = 1; i <= 8; i++) {
      h[i] = hexv(substr(NKEY, 4 * i - 3, 4))
      if (h[i] == 0) { if (!cl) cs = i; cl++; if (cl > bl) { bl = cl; bs = cs } } else cl = 0
    }
    if (bl < 2) bs = 0
    out = ""
    for (i = 1; i <= 8; i++) {
      if (bs && i == bs) { out = out "::"; i += bl - 1; continue }
      out = out ((out == "" || substr(out, length(out), 1) == ":") ? "" : ":") sprintf("%x", h[i])
    }
  }
  return NSLASH ? out "/" NM : out
}
'

# 剔除被其他条目包含的网段（如同时有 1.2.3.0/24 与 1.2.3.4，丢弃后者；重复条目只留一条）
# firewalld 校验 hash:net 条目时发现任意两条重叠会整批拒绝，必须在写入前消除
# 参数：$1 - IP 文件（原地改写，已经 filter_protected_entries 校验），$2 - 类型（日志用）
merge_overlapping_entries() {
  local ip_file="$1" ip_type="$2"
  local merged_file stat_file dropped=0
  merged_file=$(create_temp_file "merged_${ip_type}" ".txt") || return 1
  stat_file=$(create_temp_file "merge_stat" ".txt") || return 1
  LC_ALL=C awk "${_THREAT_NET_AWK}"'
    netparse($1) { printf "%s %03d %s\n", NKEY, NM, $1 }
  ' "${ip_file}" | LC_ALL=C sort -k1,1 -k2,2n | LC_ALL=C awk -v statfile="${stat_file}" "${_THREAT_NET_AWK}"'
    { if (have && netcontains(lk, lm, $1, $2 + 0)) { dropped++; next }; lk = $1; lm = $2 + 0; have = 1; print $3 }
    END { print dropped + 0 > statfile }
  ' > "${merged_file}" || { rm -f "${merged_file}" "${stat_file}"; return 1; }
  mv "${merged_file}" "${ip_file}"
  dropped=$(cat "${stat_file}" 2>/dev/null) || dropped=0
  rm -f "${stat_file}"
  if [[ "${dropped:-0}" -gt 0 ]]; then
    log_info "${ip_type} 已合并重叠条目：丢弃被其他网段包含的 ${dropped} 条"
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
    # 按前缀计算重叠（展开为 8 组十六进制后比较），不再只做字符串比较：
    # 白名单/本机地址落在威胁网段内（或威胁条目落在白名单网段内）都算命中；输出规范化写法
    LC_ALL=C awk -v minmask="${MIN_IPV6_PREFIX}" -v statfile="${stat_file}" "${_THREAT_NET_AWK}"'
      BEGIN {
        nb = split("::/128 ::1/128 fe80::/10 fc00::/7 ff00::/8", B, " ")
        for (i = 1; i <= nb; i++) if (netparse(B[i])) { pk[++np] = NKEY; pm[np] = NM }
      }
      NR == FNR { if ($1 ~ /:/ && netparse($1) && NFAM == 6) { pk[++np] = NKEY; pm[np] = NM }; next }
      {
        if (!netparse($1) || NFAM != 6) { bad++; next }
        if (NM < minmask) { wide++; next }
        for (k = 1; k <= np; k++)
          if (netcontains(pk[k], pm[k], NKEY, NM) || netcontains(NKEY, NM, pk[k], pm[k])) { prot++; next }
        print netcanon()
      }
      END { print bad + 0, wide + 0, prot + 0 > statfile }
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
