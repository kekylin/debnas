#!/bin/bash
# cockpit-auto-bing-wallpaper: 壁纸下载模块
set -euo pipefail
IFS=$'\n\t'
update_wallpaper() {
  check_cockpit_version || return 1
  prepare_env
  local bing_json bing_url bing_title bing_copyright full_url first_run=false
  
  is_first_run && first_run=true
  
  # 获取API数据
  if ! bing_json=$(curl --fail --silent --location "$BING_API_URL" 2>/dev/null); then
    [[ "$first_run" == "true" ]] && return 1
    exit 0
  fi
  
  # 解析数据
  bing_url=$(echo "$bing_json" | grep -oP '(?<="url":")[^"]+' | head -n1 || true)
  bing_title=$(echo "$bing_json" | grep -oP '(?<="title":")[^"]+' | head -n1 || true)
  bing_copyright=$(echo "$bing_json" | grep -oP '(?<="copyright":")[^"]+' | head -n1 || true)
  
  if [[ -z "$bing_url" ]]; then
    [[ "$first_run" == "true" ]] && return 1
    exit 0
  fi
  
  # 下载壁纸
  full_url="https://www.bing.com${bing_url}"
  
  if curl --fail --location --silent --show-error -o "${WALLPAPER_FILE}.tmp" "$full_url"; then
    mv -f "${WALLPAPER_FILE}.tmp" "$WALLPAPER_FILE"
    printf '%s\n%s\n' "$bing_title" "$bing_copyright" > "$ISSUE_FILE"
    mark_initialized
    return 0
  else
    rm -f "${WALLPAPER_FILE}.tmp"
    [[ "$first_run" == "true" ]] && return 1
    exit 0
  fi
}

# 生成登录页样式文件
