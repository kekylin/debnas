# DebNAS 维护规范

> 版本：1.2.0 | 更新：2026-11-10

---

## 版本管理

### 版本号规则

遵循语义化版本（SemVer）：`主版本.次版本.修订号`

| 变更类型 | 版本号 | 示例 |
|------|--------|------|
| CLI 子命令删除/重命名、配置文件格式不兼容变更 | 主版本 +1 | 3.x.x → 4.0.0 |
| 新增模块、新增 CLI 子命令、向后兼容的公共 API 变更 | 次版本 +1 | 3.2.x → 3.3.0 |
| Bug 修复、文档更新、内部重构（不改变对外行为） | 修订号 +1 | 3.2.1 → 3.2.2 |

### 版本号记录位置

- 当前开发版本：CHANGELOG.md `[未发布]` 章节
- 发布时：打 Git tag（如 `v3.2.2`），CHANGELOG.md 中 `[未发布]` → `[v3.2.2]`

## 分支策略

参见 [DEVELOPMENT_GUIDE.md](DEVELOPMENT_GUIDE.md) §2.2。不使用 `develop`、`release`、`hotfix` 等额外分支 — 单人项目不需要。

## 发布流程

自 2026-11 起，`install.sh` 与 `debnas update` 只安装**已签名的发布版本**：每个 tag 在 GitHub Release 与 Gitee 发行版上附带
`debnas-<tag>.tar.gz`（`git archive --prefix=debnas/ <tag>`）、`install.sh`、`SHA256SUMS`、`SHA256SUMS.asc`（对 SHA256SUMS 的 GPG 分离签名）。
用户侧用 `gpgv` + 内嵌公钥验签、核对主密钥指纹，再 `sha256sum -c` 校验代码包。

**发布包内容**：`.gitattributes` 用 `export-ignore` 把 `tests/`、`docs/`、`tools/`、`.github/`、`.gitattributes`、`.gitignore`、`LATEST`、`LATEST.asc` 排除在 `git archive` 之外
（GitHub/Gitee 的分支归档同样生效），所以这些目录可以正常入库而不增加用户下载体积。安装/更新只部署 `bin/ lib/ modules/ config/ compose/ keys/` 与 `install.sh README.md LICENSE`。
`keys/` 是 `debnas update` 的信任根，**不能**加进 export-ignore（构建发布时会检查包里有 `keys/debnas-release.asc`）。

**版本指针**：仓库根的 `LATEST`（一行 tag）与 `LATEST.asc`（发布密钥对它的分离签名）告诉 `debnas update` 最新稳定版本是哪个。
update 从 main 分支 raw 地址取这两个文件，用已安装目录 `keys/` 里的公钥验签，通过才采用；`LATEST` 取到了但验签失败（或缺 `LATEST.asc`）→ 拒绝自动更新；
两个文件都取不到 → 告警并回退读 main 分支 `install.sh` 的 `DEBNAS_RELEASE_TAG`（未签名）。两种来源都只升不降。

### 一次性准备：发布密钥

1. 在可信（最好离线）的机器上生成 ed25519 主密钥，主密钥只用于认证，日常签名用子密钥：
   ```bash
   gpg --quick-gen-key "DebNAS Release <你的邮箱>" ed25519 cert 3y
   gpg --quick-add-key <主密钥指纹> ed25519 sign 1y
   ```
   - 设置强口令；GnuPG 会自动生成吊销证书（`~/.gnupg/openpgp-revocs.d/<指纹>.rev`），**另行离线备份**（打印/U 盘）。
   - 主密钥私钥离线保管（`gpg --export-secret-keys --armor` 备份后，在发布机上只保留子密钥：`gpg --export-secret-subkeys`）。
   - 子密钥到期前用主密钥续期（`gpg --quick-set-expire <主指纹> 1y '*'`），续期后需重新 `--embed-key`（公钥内容变了，指纹不变）。
2. 导出最小化公钥并写入仓库：
   ```bash
   gpg --armor --export-options export-minimal --export <主密钥指纹> > /tmp/debnas-release.asc
   bash tools/release.sh --embed-key /tmp/debnas-release.asc
   ```
   该命令会：拒绝私钥/多把主密钥/已吊销或过期/无签名能力的密钥；用规范化 armor 覆盖 `keys/debnas-release.asc`；写 `keys/debnas-release.fpr`；
   替换 `install.sh` 中 `DEBNAS-RELEASE-PUBKEY-BEGIN/END` 标记之间的 `DEBNAS_RELEASE_KEY_FPR` 与 `DEBNAS_RELEASE_PUBKEY`，并自检解码结果与原公钥逐字节一致。
3. 核对打印的指纹后提交：`git add keys/ install.sh && git commit -m "chore(release): 配置发布公钥"`。建议把指纹另外公布在 README/项目主页，便于用户交叉核对。

### 更换发布密钥（平滑过渡，分两个版本）

用户机器上的 `debnas update` 只信任它**已安装目录**里的 `keys/`。直接换新钥发版，老用户手里只有旧公钥，验不过新钥签的包。
所以先发一个"新旧两把都认"的过渡版，再在下一个版本移除旧钥：

| 步骤 | 命令 | keys/ 与 install.sh 内嵌区块 | 发布包与 LATEST 用哪把钥签 |
|------|------|------------------------------|----------------------------|
| 过渡版 vN | `bash tools/release.sh --embed-key /tmp/new.asc --keep-old` | 新 + 旧两把公钥（`.fpr` 两行，新钥在前；`DEBNAS_RELEASE_KEY_FPR` 为逗号分隔的两个指纹） | **旧钥**（老用户只认旧钥） |
| 下个版本 vN+1 | `bash tools/release.sh --embed-key /tmp/new.asc`（不带 `--keep-old`） | 只剩新钥 | **新钥** |

1. 生成新密钥（同「一次性准备」第 1 步），导出最小化公钥到 `/tmp/new.asc`。
2. `--embed-key /tmp/new.asc --keep-old`：读现有 `keys/debnas-release.asc` / `.fpr`，写出"新钥 + 旧钥"的公钥文件、指纹文件与 install.sh 内嵌区块（重复执行结果不变）。
   `bash tools/release.sh --check-keys` 应通过。提交后按「每次发布」发 vN，**签名仍用旧钥**。
3. 让 vN 存在足够久（建议至少一个发布周期），并在 CHANGELOG / README 公告"vN 是换钥过渡版，请先升级到 vN"。
4. 发 vN+1 前执行不带 `--keep-old` 的 `--embed-key /tmp/new.asc` 移除旧钥，提交，**用新钥签名**发版并签 `LATEST`。
   - 已升级到 vN 的用户：认新钥，自动更新正常。
   - 还停在 vN 之前的用户：只认旧钥，`debnas update` 会报"LATEST 签名校验未通过"或"SHA256SUMS 签名验证失败"。
     处理办法：`debnas update --tag vN`（旧钥签的过渡版）后再 `debnas update`，或重新执行新 tag 的 install.sh。

验证规则：keyring 含多把公钥，签名者主密钥指纹与指纹列表中任一个相同即通过（`release_check_sig`）；`--check-keys` 与构建时的检查要求
"内嵌指纹集合 = `.fpr` 集合 = 公钥文件里实际的主密钥集合"，且两份公钥解码后逐字节一致。

> 私钥泄露：没有过渡期可言（旧钥签的东西已不可信）。立即发布吊销证书，用新密钥 `--embed-key`（**不带** `--keep-old`）并发版，同时在 README 公告；已安装用户需重新执行新 tag 的 install.sh。

### 每次发布

1. 确保 CHANGELOG.md `[未发布]` 章节已更新；运行 `bash tests/run.sh unit` 与 `shellcheck --severity=error -x lib/**/*.sh bin/*.sh modules/*.sh tools/*.sh`
2. 在 Debian 12 和 Debian 13 VM 上验证安装流程（可用 `--unsigned --branch <分支>` 安装待发布分支）
3. 将 `[未发布]` 章节重命名为 `## [vX.Y.Z] — YYYY-MM-DD`
4. 改默认版本（先改再打 tag，tag 内的 install.sh 默认安装的才是它自己）：
   ```bash
   bash tools/release.sh --bump vX.Y.Z      # 改 install.sh 的 DEBNAS_RELEASE_TAG 与 README 安装命令
   git commit -am "chore(release): vX.Y.Z"
   git tag -a vX.Y.Z -m "vX.Y.Z"            # 必须是附注 tag
   ```
5. 生成产物、签名、自检：
   ```bash
   bash tools/release.sh vX.Y.Z <签名密钥 ID 或指纹>
   ```
   检查：工作区干净、tag 存在且为附注 tag、tag 内 install.sh 已内嵌公钥且与 `keys/debnas-release.fpr` 一致、签名密钥就是内嵌公钥。
   产物输出到 `dist/vX.Y.Z/`（已在 .gitignore），并用 **tag 内 install.sh 的验证函数**对副本走一遍用户侧验证。若工作区 install.sh 默认版本不是本 tag，会自动 `--bump` 并提示提交。
   正式版本（非 rc/beta）还会在工作区生成 `LATEST` / `LATEST.asc` 并自检（`LATEST` 已指向更高版本时不动；预发布版本不动）。**这两个文件先不要提交推送**，见第 8 步。
   单独重新生成：`bash tools/release.sh --sign-latest vX.Y.Z <签名密钥 ID 或指纹>`。
6. 推送并上传（脚本末尾会打印具体命令）：
   - `git push && git push --tags`（以及 Gitee 远端）
   - GitHub：`gh release create vX.Y.Z --verify-tag dist/vX.Y.Z/*`，或网页上传四个附件
   - Gitee：网页「发行版 → 创建发行版」选择同一 tag，上传四个附件
7. 核验下载地址：用脚本打印的 `wget … | diff - dist/vX.Y.Z/SHA256SUMS` 确认两个平台都能下载且内容一致。
   **Gitee 附件下载路径 `https://gitee.com/kekylin/debnas/releases/download/<tag>/<file>` 为推测格式，首次发布必须核实**；不一致时同步修改
   `install.sh` 的 `RELEASE_CN_BASE` 与 `lib/system/installer.sh` 的 `DEBNAS_RELEASE_CN_BASE`。
8. 两个平台的附件都核验可下载之后，提交并推送版本指针，用户的 `debnas update` 才会发现新版本：
   ```bash
   git add LATEST LATEST.asc && git commit -m "chore(release): LATEST → vX.Y.Z" && git push   # 以及 Gitee 远端
   ```
   顺序不能反：先推指针后传附件，update 会找到一个还下载不到的版本。
   main 分支 install.sh 的 `DEBNAS_RELEASE_TAG` 仍要保持最新并推送——它是取不到 `LATEST` 时的回退来源，也是 v2026.11.0 及更早版本发现新版本的唯一来源。
   update 只接受比已安装版本更新的 tag（显式 `--tag` 除外）。

## CI

`.github/workflows/ci.yml` 在 `debian:bookworm-slim` / `debian:trixie-slim` 容器里跑 `tests/run.sh`（static / syntax / unit / integration）与 `tests/check.sh`。注意：

- 每个 job 在 `actions/checkout` **之前**先 `apt-get install git`。容器里没有 git 时 checkout 改用平台归档接口下载源码，归档受 `export-ignore` 影响，`tests/` 不在工作区里。
- `tests/`、`docs/` 必须入库（不要再写进 `.gitignore`）；本地测试报告 `tests/reports/` 忽略。
- 测试不联网、以 root 运行；依赖 gpg / jq / git 等可选工具的用例在缺工具时 `skip`。新增用例若依赖最小容器里没有的命令，请同样加 `command -v … || skip`。

## 模块版本号

模块的 `@version` 元数据独立于项目版本。修改模块时更新其 `@version`：
- Bug 修复：修订号 +1
- 新增功能：次版本 +1
- 破坏性变更（参数名/行为变化）：主版本 +1
