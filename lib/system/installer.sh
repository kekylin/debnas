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
  if ! wget -q --timeout=30 -O "$tarball" "$primary_url" 2>/dev/null; then
    log_warning "主源下载失败，尝试备用源..."
    if ! wget -q --timeout=30 -O "$tarball" "$fallback_url" 2>/dev/null; then
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
  # --no-same-owner：以 root 解压时不沿用归档内记录的 uid/gid（否则文件可能归属任意普通用户，
  # 该用户即可改写之后由 root 执行的脚本）
  if ! tar -xzf "$tarball" -C "$extract_dir" --strip-components=1 --no-same-owner 2>/dev/null; then
    log_error "解压失败"
    return 1
  fi
  return 0
}

# 部署文件到安装目录（覆盖代码文件，保留配置和状态）
# 参数：$1 - 解压源目录
#       $2 - 安装目标目录
# 返回：0 成功，1 失败
# 说明：先把各目录完整复制到暂存目录（.<dir>.new），全部成功后再逐个 rename 替换：
#       - 复制中途失败不会留下"半新半旧"的安装；
#       - 上游已删除的旧模块/文件会随旧目录一起移除；
#       - rename 不改写正在执行的 bin/debnas 的 inode（原地覆写会让运行中的 bash 读到错位内容）。
#       config/ 与 compose/（docker-apps、service-query、部署方案依赖）一并部署。
installer_deploy() {
  local src_dir="$1"
  local install_dir="$2"
  local d

  if [[ -z "$src_dir" || -z "$install_dir" ]]; then
    log_error "installer_deploy: 缺少源目录或安装目录参数"
    return 1
  fi

  # 校验更新包完整性（在动现有安装之前）
  if [[ ! -f "${src_dir}/bin/debnas" ]]; then
    log_error "部署后关键文件缺失：${src_dir}/bin/debnas"
    return 1
  fi
  for d in lib modules; do
    if [[ ! -d "${src_dir}/${d}" ]]; then
      log_error "更新包不完整，缺少目录：${d}"
      return 1
    fi
  done

  mkdir -p "$install_dir"

  # 第一阶段：复制到暂存目录
  local -a staged=()
  for d in bin lib modules config compose; do
    [[ -d "${src_dir}/${d}" ]] || continue
    rm -rf -- "${install_dir}/.${d}.new"
    if ! cp -R -- "${src_dir}/${d}" "${install_dir}/.${d}.new"; then
      log_error "复制失败：${d}"
      rm -rf -- "${install_dir}/.${d}.new"
      for d in "${staged[@]+"${staged[@]}"}"; do
        rm -rf -- "${install_dir}/.${d}.new"
      done
      return 1
    fi
    staged+=("$d")
  done

  # 第二阶段：逐目录替换
  for d in "${staged[@]}"; do
    rm -rf -- "${install_dir}/.${d}.old"
    if [[ -e "${install_dir}/${d}" ]] && ! mv -- "${install_dir}/${d}" "${install_dir}/.${d}.old"; then
      log_error "替换失败：${install_dir}/${d}"
      return 1
    fi
    if ! mv -- "${install_dir}/.${d}.new" "${install_dir}/${d}"; then
      # 回滚当前目录
      if [[ -e "${install_dir}/.${d}.old" ]]; then
        mv -- "${install_dir}/.${d}.old" "${install_dir}/${d}" || true
      fi
      log_error "替换失败：${install_dir}/${d}"
      return 1
    fi
    rm -rf -- "${install_dir}/.${d}.old"
  done

  # 验证关键文件
  if [[ ! -f "${install_dir}/bin/debnas" ]]; then
    log_error "部署后关键文件缺失：${install_dir}/bin/debnas"
    return 1
  fi

  # 设置可执行权限
  chmod +x "${install_dir}/bin/"* 2>/dev/null || true

  return 0
}
