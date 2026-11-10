#!/usr/bin/env bats
# 测试: lib/system/urls.sh — URL 配置、镜像站查找、网络探测
# 覆盖 TC-ID: TC-P0-URL-001~008
# 技术: PATH Injection (curl/wget Mock) + 直接函数调用
#
# PATH 隔离说明: 系统 curl/wget 位于 /usr/bin/。
#   - 需要 mock 时：PATH="$MOCK_BIN:/bin"（不含 /usr/bin，避免找到系统 curl）
#   - mock 脚本使用 #!/bin/bash（不依赖 PATH 中的 env）

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"

  source "${DEBNAS_ROOT}/lib/system/urls.sh"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# 辅助：创建 mock（shebang=/bin/bash，不依赖 PATH 中的 /usr/bin/env）
_mock() {
  local cmd="$1" exit_code="$2"
  cat > "$MOCK_BIN/$cmd" << EOF
#!/bin/bash
exit $exit_code
EOF
  chmod +x "$MOCK_BIN/$cmd"
}

# ==================== TC-P0-URL-001: probe_url curl 可达 ====================

@test "probe_url: curl 可达返回 0（TC-P0-URL-001）" {
  _mock curl 0
  PATH="$MOCK_BIN:/bin" run probe_url "https://example.com"
  [[ "$status" -eq 0 ]]
}

# ==================== TC-P0-URL-002: probe_url curl 不可达 ====================

@test "probe_url: curl 不可达返回 1（TC-P0-URL-002）" {
  _mock curl 7
  PATH="$MOCK_BIN:/bin" run probe_url "https://unreachable.example.com"
  [[ "$status" -ne 0 ]]
}

# ==================== TC-P0-URL-003: probe_url curl 缺失回退到 wget ====================

@test "probe_url: curl 缺失时回退到 wget（TC-P0-URL-003）" {
  # curl/wget 都在 /bin/，需用子 shell + command 覆盖模拟 curl 缺失
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/system/urls.sh 2>/dev/null
    command() {
      if [[ "$1" == "-v" && "$2" == curl ]]; then return 1; fi
      builtin command "$@"
    }
    wget() { return 0; }
    probe_url "https://example.com"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
}

# ==================== TC-P0-URL-004: probe_url 两者都缺失 ====================

@test "probe_url: curl 和 wget 均缺失时返回 1（TC-P0-URL-004）" {
  # 系统 curl/wget 位于 /bin/，无法通过 PATH 排除（bash 也在 /bin）
  # 使用子 shell + command 覆盖来模拟"两者都不存在"
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/system/urls.sh 2>/dev/null
    command() {
      if [[ "$1" == "-v" ]]; then
        case "$2" in curl|wget) return 1 ;; esac
      fi
      builtin command "$@"
    }
    probe_url "https://example.com"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -ne 0 ]]
}

# ==================== TC-P0-URL-005: get_mirror_name 已知 URL ====================

@test "get_mirror_name: 已知 URL 返回中文名称（TC-P0-URL-005）" {
  run get_mirror_name "https://mirrors.tuna.tsinghua.edu.cn"
  [[ "$output" == "清华大学开源软件镜像站" ]]
}

@test "get_mirror_name: mirrors.ustc 返回中国科学技术大学" {
  run get_mirror_name "https://mirrors.ustc.edu.cn"
  [[ "$output" == "中国科学技术大学开源软件镜像站" ]]
}

@test "get_mirror_name: mirrors.aliyun 返回阿里云" {
  run get_mirror_name "https://mirrors.aliyun.com"
  [[ "$output" == "阿里云开源镜像站" ]]
}

# ==================== TC-P0-URL-006: get_mirror_name 未知 URL ====================

@test "get_mirror_name: 未知 URL 返回原始 URL（TC-P0-URL-006）" {
  run get_mirror_name "https://unknown.mirror.example.com"
  [[ "$output" == "https://unknown.mirror.example.com" ]]
}

# ==================== probe_url: wget 回退失败 ====================

@test "probe_url: curl 缺失 + wget 也不可达时返回非零" {
  # curl/wget 都在 /bin/，需用子 shell + command 覆盖来模拟 curl 缺失、wget 失败
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/system/urls.sh 2>/dev/null
    # 模拟：curl 不存在，wget 存在但失败
    _wget_exit=4
    command() {
      if [[ "$1" == "-v" ]]; then
        case "$2" in curl) return 1 ;; esac
      fi
      builtin command "$@"
    }
    wget() { return $_wget_exit; }
    probe_url "https://example.com"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -ne 0 ]]
}
