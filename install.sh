#!/usr/bin/env bash
set -e

# =====================
# Debian-HomeNAS 安装自举脚本（所有文件仅存于 /tmp/debian-homenas/，无持久化）
# 支持参数：-s 平台@分支（如 github@main、gitee@dev）
# 只下载 bin/、lib/、modules/、docker-compose/，排除文档和历史目录
# =====================

usage() {
  echo "用法: bash <(wget -qO- https://raw.githubusercontent.com/kekylin/Debian-HomeNAS/main/install.sh) -s 平台@分支"
  echo "示例: -s github@main 或 -s gitee@dev"
  exit 1
}

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s)
      shift
      if [[ "$1" =~ ^(github|gitee)@([a-zA-Z0-9_-]+)$ ]]; then
        PLATFORM="${BASH_REMATCH[1]}"
        BRANCH="${BASH_REMATCH[2]}"
      else
        echo "[FAIL] -s 参数格式错误，应为 平台@分支，如 github@main"
        usage
      fi
      ;;
    *)
      echo "[FAIL] 未知参数: $1"
      usage
      ;;
  esac
  shift
}

if [[ -z "$PLATFORM" || -z "$BRANCH" ]]; then
  echo "[FAIL] 必须指定 -s 平台@分支 参数"
  usage
fi

# 设置下载前缀
if [[ "$PLATFORM" == "gitee" ]]; then
  RAW_PREFIX="https://gitee.com/kekylin/Debian-HomeNAS/raw/$BRANCH"
elif [[ "$PLATFORM" == "github" ]]; then
  RAW_PREFIX="https://raw.githubusercontent.com/kekylin/Debian-HomeNAS/$BRANCH"
else
  echo "[FAIL] 不支持的平台: $PLATFORM"
  exit 2
fi

# 需要下载的文件列表（如有新增请补充）
FILES=(
  "bin/main.sh"
  # lib/core
  "lib/core/colors.sh"
  "lib/core/constants.sh"
  "lib/core/logging.sh"
  # lib/system
  "lib/system/dependency.sh"
  "lib/system/utils.sh"
  # lib/ui
  "lib/ui/menu.sh"
  "lib/ui/styles.sh"
  # modules
  "modules/acl-manager.sh"
  "modules/add-docker-mirror.sh"
  "modules/auto-update-hosts.sh"
  "modules/backup-restore.sh"
  "modules/block-threat-ips.sh"
  "modules/check-system-compatibility.sh"
  "modules/check-system-updates.sh"
  "modules/configure-security.sh"
  "modules/configure-sources.sh"
  "modules/disable-cockpit-external.sh"
  "modules/disable-login-mail.sh"
  "modules/enable-cockpit-external.sh"
  "modules/enable-login-mail.sh"
  "modules/install-basic-tools.sh"
  "modules/install-cockpit.sh"
  "modules/install-docker-apps.sh"
  "modules/install-docker.sh"
  "modules/install-fail2ban.sh"
  "modules/install-firewall.sh"
  "modules/install-service-query.sh"
  "modules/install-tunnel.sh"
  "modules/install-vm-components.sh"
  "modules/set-cockpit-network.sh"
  "modules/setup-homenas-basic.sh"
  "modules/setup-homenas-secure.sh"
  "modules/setup-mail-account.sh"
  # docker-compose
  "docker-compose/ddns-go.yaml"
  "docker-compose/dockge.yaml"
  "docker-compose/dweebui.yaml"
  "docker-compose/nginx-ui.yaml"
  "docker-compose/portainer_zh-cn.yaml"
  "docker-compose/portainer.yaml"
  "docker-compose/scrutiny.yaml"
)

# 临时根目录
TMPROOT="/tmp/debian-homenas"

# 创建临时根目录并设置权限
mkdir -p "$TMPROOT"
chmod 700 "$TMPROOT"

# 退出时自动清理临时目录
trap 'rm -rf "$TMPROOT"' EXIT

# 创建目标目录结构
for file in "${FILES[@]}"; do
  mkdir -p "$TMPROOT/$(dirname "$file")"
done

# 下载文件到临时目录
for file in "${FILES[@]}"; do
  tmpfile=$(mktemp "$TMPROOT/$(basename "$file").XXXXXX")
  echo "[ACTION] 正在下载 $file ..."
  wget -q -O "$tmpfile" "$RAW_PREFIX/$file" || { echo "[FAIL] 下载 $file 失败"; exit 1; }
  mv "$tmpfile" "$TMPROOT/$file"
done

echo "[SUCCESS] 所有依赖文件已下载到 $TMPROOT！"

# 执行主脚本并传递参数
exec bash "$TMPROOT/bin/main.sh" -s "$PLATFORM@$BRANCH" 