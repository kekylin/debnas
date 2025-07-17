#!/usr/bin/env bash
set -e

# =====================
# Debian-HomeNAS 安装自举脚本（整仓库 zip 包下载并解压，所有文件仅存于 /tmp/debian-homenas，无持久化）
# 支持参数：-s 平台@分支（如 github@main、gitee@dev）
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
done

if [[ -z "$PLATFORM" || -z "$BRANCH" ]]; then
  echo "[FAIL] 必须指定 -s 平台@分支 参数"
  usage
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

# 临时根目录
TMPROOT="/tmp/debian-homenas"

# 创建临时根目录并设置权限
mkdir -p "$TMPROOT"
chmod 700 "$TMPROOT"

# 退出时自动清理临时目录
trap 'rm -rf "$TMPROOT"' EXIT

# 下载并解压仓库
TARFILE="$TMPROOT/repo.tar.gz"
echo "[ACTION] 正在下载仓库压缩包..."
wget -qO "$TARFILE" "$TAR_URL" || { echo "[FAIL] 仓库下载失败"; exit 1; }
echo "[ACTION] 正在解压仓库..."
tar -xzf "$TARFILE" -C "$TMPROOT" || { echo "[FAIL] 解压失败"; exit 1; }

# 进入解压目录并执行主脚本
cd "$TMPROOT/$TAR_SUBDIR"
echo "[SUCCESS] 所有依赖文件已解压到 $TMPROOT/$TAR_SUBDIR！"

exec bash bin/main.sh -s "$PLATFORM@$BRANCH" 