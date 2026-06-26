# 贡献指南

感谢你对 DebNAS 项目的关注！我们欢迎各种形式的贡献。

## 如何贡献

### 报告 Bug

1. 确认问题尚未在 [Issues](https://github.com/kekylin/debnas/issues) 中报告
2. 使用 Bug Report 模板创建新 Issue
3. 提供：Debian 版本、错误日志、复现步骤

### 提交代码

1. Fork 本仓库
2. 从 `dev` 分支创建功能分支：`git checkout -b feature/xxx dev`
3. 编写代码并添加测试
4. 确保通过 CI 检查：
   - `shellcheck --severity=error` 零错误
   - `bash -n` 语法检查通过
   - `bats tests/unit/` 单元测试通过
5. 提交 PR 到 `dev` 分支

### 代码规范

- 遵循 [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- 缩进：2 空格
- 换行符：LF（Unix）
- 文件头：包含 `# 功能：` 说明
- Commit 消息：遵循 [Conventional Commits](https://www.conventionalcommits.org/)

### 模块开发规范

```bash
#!/bin/bash
# @module: your-module
# @name: 模块中文名
# @category: 所属分类
# @depends: 依赖命令列表（逗号分隔）
# @depend_modules: 依赖模块列表（逗号分隔）
# @version: 1.0.0
# @order: 数字（分类内排序）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 你的代码...
```

### 分类与排序

| 分类 | @order 范围 |
|------|:-----------:|
| 基础系统 | 10-19 |
| 管理面板 | 30-39 |
| 安全防护 | 40-49 |
| 容器管理 | 50-59 |
| 通知服务 | 60-69 |
| 系统工具 | 70-79 |
| 一键部署 | 80-89 |
