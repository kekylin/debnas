#!/usr/bin/env bats
# 测试: lib/core/constants.sh — 错误码定义

load '../../helpers/common-setup'

setup() {
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
}

@test "constants: 错误码常量值均正确" {
  declare -A expect=(
    [SUCCESS]=0
    [ERROR_GENERAL]=1
    [ERROR_DEPENDENCY]=2
    [ERROR_PERMISSION]=4
    [ERROR_UNSUPPORTED_OS]=6
  )

  local failures=0
  for var in "${!expect[@]}"; do
    if [[ "${!var}" -ne "${expect[$var]}" ]]; then
      printf "FAIL: %-22s expected %d, got %d\n" "$var" "${expect[$var]}" "${!var}"
      failures=$((failures + 1))
    fi
  done

  [[ $failures -eq 0 ]]
}
