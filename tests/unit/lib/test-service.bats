#!/usr/bin/env bats
# 测试: lib/system/service.sh — 系统服务管理

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/core/constants.sh"

  # 创建 mock 命令目录
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"

  # 默认 mock systemctl: 全部成功
  cat > "$MOCK_BIN/systemctl" << 'INNEREOF'
#!/usr/bin/env bash
subcmd="$1"
case "$subcmd" in
  is-active)   exit 0 ;;
  is-enabled)  exit 0 ;;
  start)       exit 0 ;;
  stop)        exit 0 ;;
  enable)      exit 0 ;;
  disable)     exit 0 ;;
  restart)     exit 0 ;;
  list-unit-files) exit 0 ;;
  *)           exit 0 ;;
esac
INNEREOF
  chmod +x "$MOCK_BIN/systemctl"

  # 默认 mock sysctl: 全部成功
  cat > "$MOCK_BIN/sysctl" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  echo "old_value"
else
  exit 0
fi
INNEREOF
  chmod +x "$MOCK_BIN/sysctl"

  export PATH="$MOCK_BIN:$PATH"
  source "${DEBNAS_ROOT}/lib/system/service.sh"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# ==================== require_root 测试 ====================

@test "require_root: 非 root 返回 ERROR_PERMISSION" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "当前为 root 用户"
  fi
  run require_root
  [[ "$status" -eq "$ERROR_PERMISSION" ]]
}

# ==================== service_ensure 参数校验测试 ====================

@test "service_ensure: 缺少参数报错" {
  run service_ensure
  [[ "$status" -ne 0 ]]
}

@test "service_ensure: 无效状态报错" {
  run service_ensure "test-svc" "invalid_state"
  [[ "$status" -ne 0 ]]
}

# ==================== service_ensure 幂等性参数化测试 ====================
# 将 4 状态 × 2 场景（needs-op / already-satisfied）合并为 2 个参数化测试

@test "service_ensure: needs-op 时执行操作 (started/stopped/enabled/disabled) — 参数化" {
  # Mock 通过 _SVC_STATE 环境变量区分场景
  cat > "$MOCK_BIN/systemctl" << 'INNEREOF'
#!/usr/bin/env bash
subcmd="$1"
[[ "$subcmd" == "--quiet" ]] && { shift; subcmd="$1"; }
case "$subcmd" in
  is-active)
    case "$_SVC_STATE" in
      started) exit 1 ;;  # 未运行 → 需要启动
      stopped) exit 0 ;;  # 运行中 → 需要停止
    esac
    ;;
  is-enabled)
    case "$_SVC_STATE" in
      enabled)  exit 1 ;;  # 未启用 → 需要启用
      disabled) exit 0 ;;  # 已启用 → 需要禁用
    esac
    ;;
  start|stop|enable|disable|restart) exit 0 ;;
  *) exit 0 ;;
esac
INNEREOF
  chmod +x "$MOCK_BIN/systemctl"

  local states=("started" "stopped" "enabled" "disabled")
  for state in "${states[@]}"; do
    export _SVC_STATE="$state"
    run service_ensure "test-svc" "$state"
    [[ "$status" -eq 0 ]]
  done
}

@test "service_ensure: already-satisfied 时跳过操作 (started/stopped/enabled/disabled) — 参数化" {
  cat > "$MOCK_BIN/systemctl" << 'INNEREOF'
#!/usr/bin/env bash
subcmd="$1"
[[ "$subcmd" == "--quiet" ]] && { shift; subcmd="$1"; }
case "$subcmd" in
  is-active)
    case "$_SVC_STATE" in
      started) exit 0 ;;  # 已在运行 → 跳过
      stopped) exit 1 ;;  # 已停止 → 跳过
    esac
    ;;
  is-enabled)
    case "$_SVC_STATE" in
      enabled)  exit 0 ;;  # 已启用 → 跳过
      disabled) exit 1 ;;  # 已禁用 → 跳过
    esac
    ;;
  start|stop|enable|disable|restart) echo "UNEXPECTED_OP:$subcmd"; exit 99 ;;
  *) exit 0 ;;
esac
INNEREOF
  chmod +x "$MOCK_BIN/systemctl"

  local states=("started" "stopped" "enabled" "disabled")
  for state in "${states[@]}"; do
    export _SVC_STATE="$state"
    run service_ensure "test-svc" "$state"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"跳过"* ]]
  done
}

# ==================== service_ensure restarted 测试 ====================

@test "service_ensure restarted: 重启成功" {
  run service_ensure "test-svc" "restarted"
  [[ "$status" -eq 0 ]]
}

@test "service_ensure restarted: 重启失败" {
  cat > "$MOCK_BIN/systemctl" << 'INNEREOF'
#!/usr/bin/env bash
case "$1" in
  restart) exit 1 ;;
esac
INNEREOF
  chmod +x "$MOCK_BIN/systemctl"

  run service_ensure "test-svc" "restarted"
  [[ "$status" -ne 0 ]]
}

# ==================== service_is_installed / service_is_active 测试 ====================

@test "service_is_installed: 缺少参数报错" {
  run service_is_installed
  [[ "$status" -ne 0 ]]
}

@test "service_is_active: 缺少参数报错" {
  run service_is_active
  [[ "$status" -ne 0 ]]
}

@test "service_is_installed: 已安装时返回 0" {
  # 默认 systemctl list-unit-files 返回 0
  service_is_installed "test-svc"
}

@test "service_is_active: 运行中返回 0" {
  # 默认 systemctl is-active 返回 0
  service_is_active "test-svc"
}

# ==================== sysctl_set 测试 ====================

@test "sysctl_set: 缺少参数报错" {
  run sysctl_set
  [[ "$status" -ne 0 ]]
}

@test "sysctl_set: 值相同时跳过" {
  cat > "$MOCK_BIN/sysctl" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  echo "bbr"
else
  exit 0
fi
INNEREOF
  chmod +x "$MOCK_BIN/sysctl"

  run sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"已设置"* || "$output" == *"跳过"* ]]
}

@test "sysctl_set: 值不同时设置" {
  cat > "$MOCK_BIN/sysctl" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  echo "cubic"
else
  exit 0
fi
INNEREOF
  chmod +x "$MOCK_BIN/sysctl"

  run sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
  [[ "$status" -eq 0 ]]
}

@test "sysctl_set: sysctl -w 失败时返回非 0" {
  cat > "$MOCK_BIN/sysctl" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  echo "cubic"
else
  exit 1
fi
INNEREOF
  chmod +x "$MOCK_BIN/sysctl"

  run sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
  [[ "$status" -ne 0 ]]
}

# ==================== sysctl_persist 测试 ====================

@test "sysctl_persist: 新建文件写入并调用 sysctl_set" {
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  DEBNAS_SYSCTL_DIR="$BATS_TMPDIR/sysctl.d"
  rm -rf "$DEBNAS_SYSCTL_DIR"
  run sysctl_persist "net.ipv4.ip_forward" "1" "10-test.conf"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$DEBNAS_SYSCTL_DIR/10-test.conf")" == "net.ipv4.ip_forward = 1" ]]
  [[ "$output" == *"sysctl 已设置"* ]]
  rm -rf "$DEBNAS_SYSCTL_DIR"
}

@test "sysctl_persist: 替换同名旧值、保留其他行，不留临时文件" {
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  DEBNAS_SYSCTL_DIR="$BATS_TMPDIR/sysctl.d"
  rm -rf "$DEBNAS_SYSCTL_DIR"; mkdir -p "$DEBNAS_SYSCTL_DIR"
  printf '# 注释\nvm.swappiness = 10\nnet.core.default_qdisc=fq_codel\nvm.swappiness_x = 3\n' > "$DEBNAS_SYSCTL_DIR/t.conf"
  run sysctl_persist "vm.swappiness" "1" "t.conf"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$DEBNAS_SYSCTL_DIR/t.conf")" == $'# 注释\nnet.core.default_qdisc=fq_codel\nvm.swappiness_x = 3\nvm.swappiness = 1' ]]
  [[ -z "$(find "$DEBNAS_SYSCTL_DIR" -name '.*.debnas.*')" ]]
  rm -rf "$DEBNAS_SYSCTL_DIR"
}

@test "sysctl_persist: 已有完全相同的行时不改文件" {
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  DEBNAS_SYSCTL_DIR="$BATS_TMPDIR/sysctl.d"
  rm -rf "$DEBNAS_SYSCTL_DIR"; mkdir -p "$DEBNAS_SYSCTL_DIR"
  printf 'vm.swappiness = 10\n' > "$DEBNAS_SYSCTL_DIR/t.conf"
  local before
  before=$(stat -c '%i %Y' "$DEBNAS_SYSCTL_DIR/t.conf")
  run sysctl_persist "vm.swappiness" "10" "t.conf"
  [[ "$status" -eq 0 && "$output" == *"已存在"* ]]
  [[ "$(stat -c '%i %Y' "$DEBNAS_SYSCTL_DIR/t.conf")" == "$before" ]]
  rm -rf "$DEBNAS_SYSCTL_DIR"
}

# ==================== sshd_listen_ports 测试 ====================

# 无 sshd 命令的 PATH：走配置文件分支
_no_sshd_path() {
  local d="$BATS_TMPDIR/nosshd-bin" c
  mkdir -p "$d"
  for c in cat; do ln -sf "$(command -v "$c")" "$d/$c"; done
  printf '%s' "$d"
}

@test "sshd_listen_ports: sshd -T 输出优先" {
  cat > "$MOCK_BIN/sshd" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] && printf 'port 2222\nport 22\nlistenaddress 0.0.0.0:2222\n'
INNEREOF
  chmod +x "$MOCK_BIN/sshd"
  SSH_CONNECTION="" run sshd_listen_ports
  [[ "$output" == $'22\n2222' ]]
  SSH_CONNECTION="" run sshd_listen_ports_csv
  [[ "$output" == "22,2222" ]]
}

@test "sshd_listen_ports: 回退读配置文件（含 sshd_config.d），去重升序" {
  local cfg="$BATS_TMPDIR/sshcfg"
  rm -rf "$cfg"; mkdir -p "$cfg/sshd_config.d"
  printf 'Port 2200\n#Port 9999\nport 22\n' > "$cfg/sshd_config"
  printf 'Port 2200\nPort 443\n' > "$cfg/sshd_config.d/a.conf"
  DEBNAS_SSHD_CONFIG="$cfg/sshd_config" SSH_CONNECTION="" PATH="$(_no_sshd_path)" run sshd_listen_ports
  [[ "$output" == $'22\n443\n2200' ]]
  rm -rf "$cfg"
}

@test "sshd_listen_ports: 未配置 Port 默认 22；追加当前会话端口（--no-session 不追加）" {
  local cfg="$BATS_TMPDIR/sshcfg"
  rm -rf "$cfg"; mkdir -p "$cfg"
  printf 'PermitRootLogin no\n' > "$cfg/sshd_config"
  DEBNAS_SSHD_CONFIG="$cfg/sshd_config" SSH_CONNECTION="10.0.0.2 50000 10.0.0.1 8022" PATH="$(_no_sshd_path)" run sshd_listen_ports
  [[ "$output" == $'22\n8022' ]]
  DEBNAS_SSHD_CONFIG="$cfg/sshd_config" SSH_CONNECTION="10.0.0.2 50000 10.0.0.1 8022" PATH="$(_no_sshd_path)" run sshd_listen_ports --no-session
  [[ "$output" == "22" ]]
  rm -rf "$cfg"
}

@test "sshd_listen_ports: sshd -T 的 listenaddress 端口计入（IPv4/[v6]），超范围端口过滤" {
  cat > "$MOCK_BIN/sshd" << 'INNEREOF'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] && printf 'port 22\nport 99999\nlistenaddress 0.0.0.0:2222\nlistenaddress [::]:2223\nlistenaddress [::1]:70000\n'
INNEREOF
  chmod +x "$MOCK_BIN/sshd"
  SSH_CONNECTION="" run sshd_listen_ports
  [[ "$output" == $'22\n2222\n2223' ]]
}

@test "sshd_listen_ports: 回退读配置文件时解析 ListenAddress 端口（无端口/裸 IPv6 不计）" {
  local cfg="$BATS_TMPDIR/sshcfg-la"
  rm -rf "$cfg"; mkdir -p "$cfg/sshd_config.d"
  printf 'ListenAddress 0.0.0.0:2222\nListenAddress 10.0.0.1\nListenAddress ::1\n' > "$cfg/sshd_config"
  printf 'listenaddress [fe80::1]:2444 rdomain x\nListenAddress 1.2.3.4:65536\n' > "$cfg/sshd_config.d/a.conf"
  DEBNAS_SSHD_CONFIG="$cfg/sshd_config" SSH_CONNECTION="" PATH="$(_no_sshd_path)" run sshd_listen_ports
  [[ "$output" == $'22\n2222\n2444' ]]
  rm -rf "$cfg"
}
