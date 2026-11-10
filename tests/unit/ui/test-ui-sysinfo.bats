#!/usr/bin/env bats
# 测试: lib/ui/sysinfo.sh — 仪表盘系统概况采集（/proc 注入）

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  FAKE_PROC="$BATS_TMPDIR/fake-proc"
  rm -rf "$FAKE_PROC"; mkdir -p "$FAKE_PROC/net"
  export DEBNAS_PROC_DIR="$FAKE_PROC"
  export DEBNAS_OS_RELEASE="$FAKE_PROC/os-release"
  cat > "$DEBNAS_OS_RELEASE" << 'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION_CODENAME=trixie
ID=debian
EOF
  printf 'cpu  100 0 100 800 0 0 0 0 0 0\n' > "$FAKE_PROC/stat"
  printf 'MemTotal:       1000 kB\nMemFree:         100 kB\nMemAvailable:    400 kB\n' > "$FAKE_PROC/meminfo"
  printf '273600.55 1000.00\n' > "$FAKE_PROC/uptime"
  printf 'Iface\tDestination\tGateway\n' > "$FAKE_PROC/net/route"
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  source "${DEBNAS_ROOT}/lib/ui/sysinfo.sh"
}

teardown() {
  rm -rf "$FAKE_PROC"
}

@test "ui_sysinfo_static: Debian 版本/代号/架构/主机名" {
  ui_sysinfo_static
  [ "$_SI_OS" = "Debian 13 trixie" ]
  [ -n "$_SI_ARCH" ]
  [ -n "$_SI_HOST" ]
  [ -n "$_SI_IP" ]
}

@test "ui_sysinfo_sample: 内存按 MemAvailable 计算" {
  ui_sysinfo_sample 0
  [ "$_SI_MEM" -eq 60 ]
}

@test "ui_sysinfo_sample: 首次 CPU 无差值为 -1，第二次按差值计算" {
  ui_sysinfo_sample 0
  [ "$_SI_CPU" -eq -1 ]
  # 新增 total 100（其中 idle 50）→ 50%
  printf 'cpu  125 0 125 850 0 0 0 0 0 0\n' > "$FAKE_PROC/stat"
  ui_sysinfo_sample 0
  [ "$_SI_CPU" -eq 50 ]
}

@test "ui_sysinfo_sample: 运行时长格式化为 天/小时" {
  ui_sysinfo_sample 0
  [ "$_SI_UPTIME" = "3天4小时" ]
}

@test "_ui_sysinfo_fmt_uptime: 小时/分钟格式" {
  _ui_sysinfo_fmt_uptime 15120
  [ "$_SI_UPTIME" = "4小时12分" ]
  _ui_sysinfo_fmt_uptime 720
  [ "$_SI_UPTIME" = "12分" ]
}

@test "ui_sysinfo_sample: 采样耗时 < 200ms" {
  local t0=${EPOCHREALTIME/[.,]/}
  ui_sysinfo_sample 1
  local t1=${EPOCHREALTIME/[.,]/}
  [ $(( (t1 - t0) / 1000 )) -lt 200 ]
}

@test "ui_sysinfo_updates: 只做 apt-get -s 模拟，不调用 apt update" {
  local mock="$BATS_TMPDIR/sysinfo-mock"
  mkdir -p "$mock"
  cat > "$mock/apt-get" << 'EOF'
#!/bin/bash
echo "$*" >> "$APT_LOG"
[[ "$*" == *"-s"* ]] && printf 'Inst a [1] (2 x)\nInst b [1] (2 x)\nConf a\n'
exit 0
EOF
  chmod +x "$mock/apt-get"
  export APT_LOG="$BATS_TMPDIR/apt.log"; rm -f "$APT_LOG"
  export DEBNAS_UPDATES_CACHE="$BATS_TMPDIR/no-such-dir/updates.cache"
  PATH="$mock:$PATH" ui_sysinfo_updates_start "$BATS_TMPDIR/upd.count"
  local i
  for (( i = 0; i < 50; i++ )); do ui_sysinfo_updates_poll && break; sleep 0.1; done
  [ "$_SI_UPDATES" = "2" ]
  ! grep -q 'update' "$APT_LOG"
  rm -rf "$mock" "$BATS_TMPDIR/upd.count"
}

@test "ui_sysinfo_updates_stop: 连同 apt-get 一起终止（不留孤儿进程）" {
  local mock="$BATS_TMPDIR/sysinfo-mock-slow"
  mkdir -p "$mock"
  printf '#!/bin/bash\nsleep 38.4242\n' > "$mock/apt-get"
  chmod +x "$mock/apt-get"
  export DEBNAS_UPDATES_CACHE="$BATS_TMPDIR/no-such-dir/updates.cache"
  PATH="$mock:$PATH" ui_sysinfo_updates_start "$BATS_TMPDIR/upd-slow.count"
  sleep 0.3
  pgrep -f 'sleep 38[.]4242' >/dev/null
  ui_sysinfo_updates_stop
  sleep 0.3
  local left=0
  pgrep -f 'sleep 38[.]4242' >/dev/null && left=1
  pkill -f 'sleep 38[.]4242' 2>/dev/null || true
  rm -rf "$mock" "$BATS_TMPDIR/upd-slow.count"
  [ "$left" -eq 0 ]
}
