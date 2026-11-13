#!/usr/bin/env bats
# 测试: lib/system/module-probe.sh — 模块只读探测契约（module_status / module_plan）加载器
# 技术: 临时模块目录（DEBNAS_MODULES_DIR）+ 守卫/未守卫/超时/非法输出夹具

load '../../helpers/common-setup'

TEST_MODULES_DIR="$BATS_TMPDIR/probe-modules"
mkdir -p "$TEST_MODULES_DIR"
export DEBNAS_MODULES_DIR="$TEST_MODULES_DIR"

setup() {
  export NO_COLOR=1
  setup_debnas_lib
  rm -rf "$TEST_MODULES_DIR"
  mkdir -p "$TEST_MODULES_DIR"
  export DEBNAS_STATE_DIR="$BATS_TMPDIR/probe-state"
  rm -rf "$DEBNAS_STATE_DIR"; mkdir -p "$DEBNAS_STATE_DIR"
  MARKER="$BATS_TMPDIR/probe-main-ran"
  rm -f "$MARKER"
  export MARKER

  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  source "${DEBNAS_ROOT}/lib/system/state.sh"
  source "${DEBNAS_ROOT}/lib/system/module-registry.sh"
  source "${DEBNAS_ROOT}/lib/system/module-probe.sh"
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  _DEBNAS_BOOTSTRAPPED=1
  MODULE_PROBE_STATUS_TIMEOUT=2
  MODULE_PROBE_PLAN_TIMEOUT=2

  # 守卫 + 两个契约函数
  cat > "$TEST_MODULES_DIR/good.sh" << 'EOF'
#!/bin/bash
# @module: good
# @name: 样板模块
# @category: 系统工具
set -euo pipefail
module_status() { echo "running|一切正常"; }
module_plan() {
  echo "pkg|foo bar|apt 安装"
  echo "write|/etc/foo.conf|备份到 /etc/foo.conf.bak"
  echo "risk|SSH|不会断连"
}
main() { touch "$MARKER"; }
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
EOF

  # 守卫但未实现契约函数
  cat > "$TEST_MODULES_DIR/nofunc.sh" << 'EOF'
#!/bin/bash
# @module: nofunc
# @name: 无契约函数
# @category: 系统工具
main() { touch "$MARKER"; }
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
EOF

  # 旧式模块：未加守卫（绝不能被 source）
  cat > "$TEST_MODULES_DIR/legacy.sh" << 'EOF'
#!/bin/bash
# @module: legacy
# @name: 旧式模块
# @category: 系统工具
# @interactive: true
module_status() { echo "running|不应被调用"; }
main() { touch "$MARKER"; }
main "$@"
EOF

  # 输出非法状态码/类型
  cat > "$TEST_MODULES_DIR/bad.sh" << 'EOF'
#!/bin/bash
# @module: bad
# @name: 非法输出
# @category: 系统工具
module_status() { printf 'great|\e[31m红色\e[0m说明\n'; }
module_plan() { echo "explode|x|y"; echo ""; echo "info|只有目标"; }
main() { touch "$MARKER"; }
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
EOF

  # 超时
  cat > "$TEST_MODULES_DIR/slow.sh" << 'EOF'
#!/bin/bash
# @module: slow
# @name: 慢模块
# @category: 系统工具
module_status() { sleep 10; echo "applied|太慢"; }
main() { touch "$MARKER"; }
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
EOF

  # 超时时子 shell 里仍在跑的外部命令（孤儿检测用唯一参数）
  cat > "$TEST_MODULES_DIR/orphan.sh" << 'EOF'
#!/bin/bash
# @module: orphan
# @name: 孤儿模块
# @category: 系统工具
module_status() { sleep 37.4242; echo "applied|太慢"; }
main() { touch "$MARKER"; }
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
EOF

  discover_modules 2>/dev/null
}

teardown() {
  pkill -f 'sleep 37[.]4242' 2>/dev/null || true
  rm -rf "$TEST_MODULES_DIR" "$DEBNAS_STATE_DIR"
  rm -f "$MARKER"
}

# ==================== 守卫检测 ====================

@test "module_probe_supported: 有守卫返回 0" {
  run module_probe_supported good
  [ "$status" -eq 0 ]
}

@test "module_probe_supported: 无守卫返回 1" {
  run module_probe_supported legacy
  [ "$status" -eq 1 ]
}

@test "module_probe_supported: 不存在的模块返回 1" {
  run module_probe_supported nosuch
  [ "$status" -eq 1 ]
}

@test "module_probe_supported: 守卫字符串只出现在注释/字符串中不算（绝不 source）" {
  cat > "$TEST_MODULES_DIR/fake.sh" << 'EOF'
#!/bin/bash
# @module: fake
# @name: 注释里提到守卫
# @category: 系统工具
# 末行应改成 if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
echo "DEBNAS_MODULE_ACTION:-run" >/dev/null
main() { touch "$MARKER"; }
main "$@"
EOF
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  run module_probe_supported fake
  [ "$status" -eq 1 ]
  run module_probe fake status
  [[ "$output" == "unknown|未提供状态检测" ]]
  [ ! -e "$MARKER" ]
}

# ==================== status ====================

@test "module_probe status: 调用 module_status 且不执行 main" {
  run module_probe good status
  [ "$status" -eq 0 ]
  [ "$output" = "running|一切正常" ]
  [ ! -f "$MARKER" ]
}

@test "module_probe status: 守卫但未实现函数 → unknown" {
  run module_probe nofunc status
  [ "$output" = "unknown|未提供状态检测" ]
  [ ! -f "$MARKER" ]
}

@test "module_probe status: 未守卫模块绝不 source（main 不执行）" {
  run module_probe legacy status
  [ "$output" = "unknown|未提供状态检测" ]
  [ ! -f "$MARKER" ]
}

@test "module_probe status: 非法状态码归 unknown 且去除控制字符" {
  run module_probe bad status
  [[ "$output" == unknown\|* ]]
  [[ "$output" != *$'\e'* ]]
}

@test "module_probe status: 超时返回 unknown|状态检测超时" {
  run module_probe slow status
  [ "$output" = "unknown|状态检测超时" ]
}

@test "module_probe status: 超时连同子 shell 里的命令一起终止（不留孤儿进程）" {
  MODULE_PROBE_STATUS_TIMEOUT=1
  run module_probe orphan status
  [ "$output" = "unknown|状态检测超时" ]
  sleep 0.3
  [ -z "$(pgrep -f 'sleep 37[.]4242')" ]
}

@test "module_probe: 未知动作返回 2" {
  run module_probe good destroy
  [ "$status" -eq 2 ]
}

@test "module_probe status: 模块不存在 → unknown" {
  run module_probe nosuch status
  [ "$output" = "unknown|模块不存在" ]
}

# ==================== plan ====================

@test "module_probe plan: 输出规范化的三段式行" {
  run module_probe good plan
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pkg|foo bar|apt 安装" ]
  [ "${lines[1]}" = "write|/etc/foo.conf|备份到 /etc/foo.conf.bak" ]
  [ "${lines[2]}" = "risk|SSH|不会断连" ]
  [ ! -f "$MARKER" ]
}

@test "module_probe plan: 未守卫的交互式模块给出回退说明" {
  run module_probe legacy plan
  [[ "$output" == "info|legacy|未提供预演；交互式模块"* ]]
  [ ! -f "$MARKER" ]
}

@test "module_probe plan: 非法类型归 info、空行丢弃、缺字段补空" {
  run module_probe bad plan
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == info\|未识别的预演行\|* ]]
  [ "${lines[1]}" = "info|只有目标|" ]
}

# ==================== 规范化函数 ====================

@test "module_status_normalize: 取第一行非空行" {
  run module_status_normalize $'\n\napplied|好\nwarn|忽略'
  [ "$output" = "applied|好" ]
}

@test "module_status_normalize: 空输出 → unknown|未返回状态" {
  run module_status_normalize ""
  [ "$output" = "unknown|未返回状态" ]
}

@test "module_status_normalize: 只有状态码没有说明" {
  run module_status_normalize "absent"
  [ "$output" = "absent|" ]
}

# ==================== 仓库内样板模块 ====================

@test "样板模块 firewall/docker-ce 已加守卫并实现契约函数" {
  local f
  for f in "${DEBNAS_ROOT}/modules/firewall.sh" "${DEBNAS_ROOT}/modules/docker-ce.sh"; do
    grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$f"
    grep -q '^module_status()' "$f"
    grep -q '^module_plan()' "$f"
  done
}

@test "module-runner: execute_module 清除 DEBNAS_MODULE_ACTION，防止泄漏导致 main 被跳过" {
  grep -q 'unset _DEBNAS_BOOTSTRAPPED DEBNAS_MODULE_ACTION' "${DEBNAS_ROOT}/bin/module-runner.sh"
}

@test "module-runner: --probe status 对样板模块输出合法状态行（只读）" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status docker-ce
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
}

@test "module-runner: --probe 参数错误返回 1" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe bogus docker-ce
  [ "$status" -eq 1 ]
}
