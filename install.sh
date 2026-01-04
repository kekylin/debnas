#!/usr/bin/env bash
# 功能：DebNAS 安装自举脚本（整仓库 zip 包下载并解压，所有文件仅存于 /tmp/debnas，无持久化）

set -e

usage() {
  echo "用法: bash <(wget -qO- https://raw.githubusercontent.com/kekylin/debnas/main/install.sh) -s 平台@分支"
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

if [[ -z "${PLATFORM:-}" || -z "${BRANCH:-}" ]]; then
  echo "[FAIL] 必须指定 -s 平台@分支 参数"
  usage
fi

# 检查 root 权限（在下载前检查，避免浪费资源）
if [[ $EUID -ne 0 ]]; then
  echo "[FAIL] 脚本需要以 root 权限运行。请切换到 root 用户后重试。"
  exit 1
fi

# 设置下载链接和解压后子目录名
if [[ "$PLATFORM" == "gitee" ]]; then
  TAR_URL="https://gitee.com/kekylin/debnas/repository/archive/$BRANCH.tar.gz"
TAR_SUBDIR="debnas-$BRANCH"
elif [[ "$PLATFORM" == "github" ]]; then
  TAR_URL="https://github.com/kekylin/debnas/archive/refs/heads/$BRANCH.tar.gz"
TAR_SUBDIR="debnas-$BRANCH"
else
  echo "[FAIL] 不支持的平台: $PLATFORM"
  exit 2
fi

# 创建唯一临时根目录
TMPROOT=$(mktemp -d /tmp/debnas.XXXXXX)
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