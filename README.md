<h1 align="center">基于Debian搭建HomeNAS<br />
</h1>

一个将Debian系统快速配置成准NAS系统的脚本。可视化WebUI操作界面，可以轻松实现文件共享、照片备份、家庭影音、管理Docker、管理虚拟机、建立RAID等功能，使得Debian系统能够高效稳定地承担NAS任务。

## 主要特性
- **开源** 
- **安全** 
- **稳定** 
- **高效** 
- **自由**
- **易用**

---
## 成果展示
截图中硬件平台为华擎 J3455 主板，16 GB 内存。底层 Debian 12 系统，运行 1 台虚拟化 Synology DSM 7.2 实例及 36 个 Docker 容器，日常 CPU 使用率约为 30%，系统资源利用率表现优异。  

![2、最终成果](https://github.com/user-attachments/assets/b30d4eb4-350f-48da-bdb8-81b313326f07)

#### [更多搭建成果展示图（点此打开查看）](https://kekylin.github.io/debnas-docs/guide/achievement/)
---

## 支持系统
- Debian 12.x/13.x（amd64 架构）  
> 当前自动化脚本仅适配 Debian 12/13（amd64）系统，其他系统及架构（包括 Ubuntu、ARM 架构等）暂不在支持范围内。

由于本人技术能力与维护精力有限，脚本在设计时优先针对 Debian 12.x/13.x 进行深度优化和完整测试，以确保部署的稳定性与可维护性。对于其他系统环境，建议参考项目文档中的架构与配置思路，手动完成环境搭建。虽然不提供自动化支持，但仍可作为参考方案灵活扩展。

## 使用文档
[DebNAS文档](https://kekylin.github.io/debnas-docs/ "DebNAS文档")

## 快速开始
### 1、安装系统
[Debian系统最小化安装教程](https://kekylin.github.io/debnas-docs/guide/debian-minimal-installation/)  

### 2、连接系统
系统安装完成后，通过 SSH 工具连接目标主机，并执行以下命令运行自动化配置脚本。。  
> 注意事项：  
> 1、Debian 默认禁止 root 用户通过 SSH 登录，请使用首次安装时创建的普通用户账户登录；  
> 2、登录后需使用 su - 切换为 root 账户执行脚本；。  
  ```shell
su -
  ```

### 3、运行脚本
建议在执行前阅读[脚本介绍](https://kekylin.github.io/debnas-docs/guide/script-introduction/)，了解脚本模块与执行选项。下面运行脚本命令（二选一）  

Gitee地址（国内用户推荐）
  ```shell
wget https://gitee.com/kekylin/debnas/raw/v2026.11.0/install.sh && bash install.sh --region cn
  ```
Github地址
  ```shell
wget https://github.com/kekylin/debnas/raw/v2026.11.0/install.sh && bash install.sh
  ```
- 项目在 Gitee 和 GitHub 同步维护，通过任一地址下载脚本均可使用
- 不指定 `--region` 默认使用国际源（GitHub 优先，Gitee 备用）
- 指定 `--region cn` 使用国内源（Gitee 优先，GitHub 备用）
- 下载时两个地址互为备用，任一失效自动切换
- 安装完成后自动启动交互菜单
- 旧教程里的写法 `bash <(wget -qO- …/install.sh) -s github@main` / `-s gitee@main` 仍可用：`-s github@…` 等同 `--region global`，`-s gitee@…` 等同 `--region cn`，`@` 后的分支名被忽略（安装的始终是已签名的发布版本）

#### 完整性校验与信任边界
- 安装脚本默认下载固定发布版本的代码包（GitHub/Gitee Release 附件），先用脚本内嵌的发布公钥通过 `gpgv` 验证 `SHA256SUMS` 的 GPG 签名并核对签名者指纹，再用 `sha256sum` 校验代码包；任一步失败即中止安装。`debnas update` 使用已安装目录中的公钥做同样的校验。
- `debnas update` 查询"最新版本号"时，读取 main 分支上的 `LATEST` 与它的签名 `LATEST.asc`，同样用已安装的发布公钥验签，通过才采用；签名对不上则拒绝自动更新（可用 `debnas update --tag <版本号>` 指定版本，代码包照常验签）。自动发现的版本只升不降。
- 签名保护的是之后下载的代码包；`install.sh` 本身经 HTTPS 从代码托管平台获取，它的可信度取决于下载渠道。上面的命令指向**发布 tag 下的 `install.sh`**（而不是随时变动的 main 分支），发布后内容不再变化。谨慎的用户可从 Release 页面下载 `install.sh`、`SHA256SUMS`、`SHA256SUMS.asc`，用 `gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS` 自行核验后再执行。
- 安装指定版本：`bash install.sh --tag <版本号>`。
- 开发调试可按分支安装（**不做任何校验**）：`bash install.sh --unsigned --branch dev`，脚本会醒目警告并要求手动输入 `yes`，非交互环境下拒绝执行。

### 4、登陆使用
> **脚本执行完毕后，SSH 控制台将输出 Cockpit 与 Docker 管理平台地址，请按提示登录访问。**

Cockpit  
一个基于 Web 的服务器图形界面，在 Web 浏览器中查看您的服务器并使用鼠标执行系统任务。启动容器、管理存储、配置网络和检查日志都很容易。基本上，您可以将 Cockpit 视为图形“桌面界面”。
Cockpit是直接使用系统账户进行登陆使用，出于安全考虑，Cockpit默认禁用root账户登陆，建议使用您安装系统时创建的第一个用户登陆。
Samba / NFS 共享在 Cockpit 左侧菜单「共享管理」中配置（DebNAS 自研插件）。如更习惯 45Drives 的 File Sharing 插件，可在 `/etc/debnas/debnas.conf` 设置 `file_sharing_ui=45drives` 后重新运行「安装共享管理面板」，两者共用同一份配置，切换后共享不丢失。
  ```shell
https://localhost:9090
  ```
Portainer  
一个Docker的可视化工具，可提供一个交互界面显示Docker的详细信息供用户操作。功能包括状态显示、应用模板快速部署、容器镜像网络数据卷的基本操作（包括上传下载镜像，创建容器等操作）、事件日志显示、容器控制台操作、Swarm集群和服务等集中管理和操作、登录用户管理和控制等功能。
  ```shell
https://localhost:9443
  ```


---
## 交流Q群
  ```shell
339169752
  ```
## 星标历史
<picture>
  <source
    media="(prefers-color-scheme: dark)"
    srcset="
      https://api.star-history.com/svg?repos=kekylin/debnas&type=Date&theme=dark
    "
  />
  <source
    media="(prefers-color-scheme: light)"
    srcset="
      https://api.star-history.com/svg?repos=kekylin/debnas&type=Date
    "
  />
  <img
    alt="Star History Chart"
    src="https://api.star-history.com/svg?repos=kekylin/debnas&type=Date"
  />
</picture>

## 支持与赞赏
如果觉得本项目对您有所帮助，欢迎通过赞赏来支持我的工作！  
![赞赏码](https://github.com/user-attachments/assets/0e79f8b6-fc8b-41d7-80b2-7bd8ce2f1dee)
