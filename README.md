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

Github地址
  ```shell
bash <(wget -qO- https://raw.githubusercontent.com/kekylin/debnas/main/install.sh) -s github@main
  ```
Gitee地址（国内用户推荐）
  ```shell
bash <(wget -qO- https://gitee.com/kekylin/debnas/raw/main/install.sh) -s gitee@main
  ```
- `-s` 参数格式：平台@分支名，如 `-s github@main`、`-s gitee@dev`

### 4、登陆使用
> **脚本执行完毕后，SSH 控制台将输出 Cockpit 与 Docker 管理平台地址，请按提示登录访问。**

Cockpit  
一个基于 Web 的服务器图形界面，在 Web 浏览器中查看您的服务器并使用鼠标执行系统任务。启动容器、管理存储、配置网络和检查日志都很容易。基本上，您可以将 Cockpit 视为图形“桌面界面”。
Cockpit是直接使用系统账户进行登陆使用，出于安全考虑，Cockpit默认禁用root账户登陆，建议使用您安装系统时创建的第一个用户登陆。
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
