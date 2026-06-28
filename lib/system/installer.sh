#!/bin/bash
# 功能：DebNAS 安装/更新公共逻辑
# 说明：提供下载、解压、文件部署的统一函数，供 cmd_update 等复用
# 注意：install.sh 引导脚本因自包含需求不使用此库

set -euo pipefail
IFS=$'\n\t'

# ==================== 常量 ====================

# ⚠️ 此 URL 与 install.sh 中的定义必须保持同步
readonly DEBNAS_REPO_CN_URL="https://gitee.com/kekylin/debnas/repository/archive/main.tar.gz"
readonly DEBNAS_REPO_GLOBAL_URL="https://github.com/kekylin/debnas/archive/refs/heads/main.tar.gz"

# ==================== 公共函数 ====================

# 根据 region 获取下载 URL
# 参数：$1 - region (cn|global)
# 输出：下载 URL
installer_get_url() {
  local region="${1:-global}"
  if [[ "$region" == "cn" ]]; then
    echo "$DEBNAS_REPO_CN_URL"
  else
    echo "$DEBNAS_REPO_GLOBAL_URL"
  fi
}

# 下载仓库压缩包（主源失败自动切换备用源）
# 参数：$1 - region (cn|global)
#       $2 - 输出 tarball 路径
# 返回：0 成功，1 失败
installer_download() {
  local region="$1"
  local tarball="$2"
  local primary_url fallback_url

  if [[ "$region" == "cn" ]]; then
    primary_url="$DEBNAS_REPO_CN_URL"
    fallback_url="$DEBNAS_REPO_GLOBAL_URL"
  else
    primary_url="$DEBNAS_REPO_GLOBAL_URL"
    fallback_url="$DEBNAS_REPO_CN_URL"
  fi

  log_info "从 ${region} 源下载..."
  if ! wget -q -O "$tarball" "$primary_url" 2>/dev/null; then
    log_warning "主源下载失败，尝试备用源..."
    if ! wget -q -O "$tarball" "$fallback_url" 2>/dev/null; then
      log_error "所有下载源均失败"
      return 1
    fi
  fi
  return 0
}

# 解压仓库压缩包
# 参数：$1 - tarball 路径
#       $2 - 解压目标目录
# 返回：0 成功，1 失败
installer_extract() {
  local tarball="$1"
  local extract_dir="$2"

  mkdir -p "$extract_dir"
  if ! tar -xzf "$tarball" -C "$extract_dir" --strip-components=1 2>/dev/null; then
    log_error "解压失败"
    return 1
  fi
  return 0
}

# 部署文件到安装目录（覆盖代码文件，保留配置和状态）
# 参数：$1 - 解压源目录
#       $2 - 安装目标目录
# 返回：0 成功，1 失败
installer_deploy() {
  local src_dir="$1"
  local install_dir="$2"

  mkdir -p "$install_dir"

  cp -rf "$src_dir"/bin "$install_dir/" 2>/dev/null || true
  cp -rf "$src_dir"/lib "$install_dir/" 2>/dev/null || true
  cp -rf "$src_dir"/modules "$install_dir/" 2>/dev/null || true

  # 验证关键文件
  if [[ ! -f "${install_dir}/bin/debnas" ]]; then
    log_error "部署后关键文件缺失：${install_dir}/bin/debnas"
    return 1
  fi

  # 设置可执行权限
  chmod +x "${install_dir}/bin/"* 2>/dev/null || true

  return 0
}
