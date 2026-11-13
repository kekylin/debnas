#!/usr/bin/env bats
# 测试: bin/doctor.sh — 诊断项行为（Mock 命令/函数，不依赖真实系统）

load '../../helpers/common-setup'

# 在隔离环境中加载 doctor.sh（守卫跳过 main），执行片段
_doctor_run() {
  local snippet="$1"
  run bash -c '
    export DEBNAS_DOCTOR_NO_MAIN=1
    source "$1/bin/doctor.sh"
    eval "$2"
  ' _ "${DEBNAS_ROOT}" "$snippet"
}

setup() {
  export NO_COLOR=1
  MOCK_BIN="${BATS_TEST_TMPDIR}/mockbin"
  mkdir -p "$MOCK_BIN"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

@test "doctor: check_system_compatibility 输出系统/架构与兼容结论" {
  _doctor_run '
    get_system_name() { echo Debian; }
    get_system_version() { echo 12; }
    get_system_codename() { echo bookworm; }
    get_system_architecture() { echo amd64; }
    verify_system_support() { return 0; }
    check_system_compatibility
  '
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Debian 12 (bookworm)"* ]]
  [[ "$output" == *"amd64"* ]]
  [[ "$output" == *"✅ 支持"* ]]
}

@test "doctor: 不支持的系统版本输出不支持" {
  _doctor_run '
    get_system_name() { echo Debian; }
    get_system_version() { echo 11; }
    get_system_codename() { echo bullseye; }
    get_system_architecture() { echo amd64; }
    verify_system_support() { return 1; }
    check_system_compatibility
  '
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"❌ 不支持"* ]]
}

@test "doctor: check_disk_space 只展示设备行" {
  cat > "${MOCK_BIN}/df" <<'EOF'
#!/bin/sh
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "tmpfs           1.0G     0  1.0G   0% /run"
echo "/dev/sda1       100G   40G   60G  40% /"
EOF
  chmod +x "${MOCK_BIN}/df"
  run env PATH="${MOCK_BIN}:$PATH" bash -c '
    export DEBNAS_DOCTOR_NO_MAIN=1
    source "$1/bin/doctor.sh"
    check_disk_space
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"── 磁盘"* ]]
  [[ "$output" == *"/dev/sda1"* ]]
  [[ "$output" != *"tmpfs"* ]]
}

@test "doctor: check_debnas_status 统计模块/定时任务并检查全局命令" {
  local bin="${BATS_TEST_TMPDIR}/debnas-bin"
  printf '#!/bin/sh\n' > "$bin"; chmod +x "$bin"
  _doctor_run '
    export DEBNAS_BIN="'"$bin"'"
    config_read() { echo cn; }
    state_list_installed() { echo hosts-sync; echo firewall; }
    crontab() { printf "%s\n" "0 0 * * * debnas run hosts-sync # DEBNAS-CRON: hosts-sync"; }
    check_debnas_status
  '
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"✅ ${bin}"* ]]
  [[ "$output" == *"模块:"*"2 个"* ]]
  [[ "$output" == *"定时任务:"*"1 个"* ]]
}

@test "doctor: check_services 依据 systemctl 状态输出三种结论" {
  cat > "${MOCK_BIN}/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
  list-unit-files)
    [[ "$2" == "cockpit.service" || "$2" == "docker.service" ]] && exit 0
    exit 1 ;;
  is-active) [[ "$3" == "cockpit" ]] && exit 0; exit 1 ;;
  is-enabled) [[ "$3" == "docker" ]] && exit 0; exit 1 ;;
esac
exit 0
EOF
  chmod +x "${MOCK_BIN}/systemctl"
  run env PATH="${MOCK_BIN}:$PATH" bash -c '
    export DEBNAS_DOCTOR_NO_MAIN=1
    source "$1/bin/doctor.sh"
    check_services
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Cockpit 管理面板:"*"✅ 运行中"* ]]
  [[ "$output" == *"Docker 容器引擎:"*"⚠️ 已安装但未运行"* ]]
  [[ "$output" == *"Firewalld 防火墙:"*"— 未安装"* ]]
}
