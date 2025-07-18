#!/usr/bin/env bash
set -e

# =====================
# Debian-HomeNAS 安装自举脚本（整仓库 zip 包下载并解压，所有文件仅存于 /tmp/debian-homenas，无持久化）
# 自动识别平台和分支，无需参数
# =====================

# 自动识别平台和分支
wget_url=$(ps -o args= $PPID | grep -oE 'https://[^ ]+')
if [[ "$wget_url" =~ gitee.com/[^/]+/Debian-HomeNAS/raw/([^/]+)/install.sh ]]; then
  PLATFORM="gitee"
  BRANCH="${BASH_REMATCH[1]}"
elif [[ "$wget_url" =~ githubusercontent.com/[^/]+/Debian-HomeNAS/([^/]+)/install.sh ]]; then
  PLATFORM="github"
  BRANCH="${BASH_REMATCH[1]}"
else
  echo "[FAIL] 未能自动识别平台和分支，请用推荐方式运行脚本"
  exit 1
fi

# 设置下载链接和解压后子目录名
if [[ "$PLATFORM" == "gitee" ]]; then
  TAR_URL="https://gitee.com/kekylin/Debian-HomeNAS/repository/archive/$BRANCH.tar.gz"
  TAR_SUBDIR="Debian-HomeNAS-$BRANCH"
elif [[ "$PLATFORM" == "github" ]]; then
  TAR_URL="https://github.com/kekylin/Debian-HomeNAS/archive/refs/heads/$BRANCH.tar.gz"
  TAR_SUBDIR="Debian-HomeNAS-$BRANCH"
else
  echo "[FAIL] 不支持的平台: $PLATFORM"
  exit 2
fi

# 创建唯一临时根目录
TMPROOT=$(mktemp -d /tmp/debian-homenas.XXXXXX)
chmod 700 "$TMPROOT"

# 下载并解压仓库
TARFILE="$TMPROOT/repo.tar.gz"
echo "[ACTION] 正在下载仓库压缩包..."
wget -qO "$TARFILE" "$TAR_URL" || { echo "[FAIL] 仓库下载失败"; exit 1; }
echo "[ACTION] 正在解压仓库..."
tar -xzf "$TARFILE" -C "$TMPROOT" || { echo "[FAIL] 解压失败"; exit 1; }

# 进入解压目录并执行主脚本
cd "$TMPROOT/$TAR_SUBDIR"
echo "[SUCCESS] 所有依赖文件已解压到 $TMPROOT/$TAR_SUBDIR！"

exec bash bin/main.sh -s "$PLATFORM@$BRANCH" --tmpdir "$TMPROOT" 