<h1 align="center">基于Debian搭建HomeNAS<br />
</h1>

一个将Debian系统快速配置成准NAS系统的脚本。可视化WebUI操作界面，可以轻松实现文件共享、照片备份、家庭影音、管理Docker、管理虚拟机、建立RAID等功能，使得Debian系统能够高效稳定地承担NAS任务。

## 主要特性
- 开源
项目基于 Debian，使用开源脚本和组件，用户可自由访问、修改和分发代码，促进透明与协作。
- 安全
依托 Debian 安全机制，整合防火墙、Fail2ban、登录通知及权限限制，构建多层防护体系。
- 稳定
利用 Debian 软件包管理和长期支持，结合自动化脚本与 Cockpit 监控，确保系统稳定运行。
- 高效
采用 Debian 最小化安装，避免资源浪费，脚本优化配置，用户按需安装应用，保持轻量高效。
- 自由
提供完全控制权，用户可灵活修改配置、权限和功能，定制无限制，满足多样化需求。
- 易用
通过 Cockpit 图形界面和自动化脚本，简化系统配置与管理，降低技术门槛。

---
## 成果展示
截图中硬件平台为华擎 J3455 主板，16 GB 内存。底层 Debian 12 系统，运行 1 台虚拟化 Synology DSM 7.2 实例及 36 个 Docker 容器，日常 CPU 使用率约为 30%，系统资源利用率表现优异。  

![2、最终成果](https://github.com/user-attachments/assets/b30d4eb4-350f-48da-bdb8-81b313326f07)

#### [更多搭建成果展示图（点此打开查看）](https://kekylin.github.io/debnas-docs/guide/achievement/)
---

## 支持系统
Debian-12.x-amd64  

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
bash <(wget -qO- https://raw.githubusercontent.com/kekylin/Debian-HomeNAS/main/install.sh) -s github@main
  ```
Gitee地址（国内用户推荐）
  ```shell
bash <(wget -qO- https://gitee.com/kekylin/Debian-HomeNAS/raw/main/install.sh) -s gitee@main
  ```
- `-s` 参数格式：**平台@分支名**，如 `-s github@main`、`-s gitee@dev`

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

<details>
  <summary><h2>教程汇总(点我展开)</h2></summary>
欢迎阅读本项目。在此，我想对本项目的内容做出以下免责声明：
  
<br>1、内容来源： 本项目的内容主要来源于互联网，以及我个人在学习和探索过程中的知识总结。我会尽可能保证内容的准确性和可靠性，但不对信息的完整性和及时性做出任何担保。

<br>2、版权保护： 本项目的所有原创内容均采用 CC BY 4.0 许可协议。欢迎个人或非商业性使用者在遵守此协议的前提下引用或转载内容。转载时请注明出处并附上项目的链接。对于任何形式的商业使用或修改内容，须在遵守该许可协议的同时保留原作者信息并注明来源。

<br>3、内容时效性： 鉴于技术和知识的发展迅速，本项目中的一些内容可能会随着时间的推移而失去实用性或准确性。我会尽力更新和修订内容，以保持其新鲜和准确，但无法对过时内容负责。

<br>4、侵权联系： 我尊重他人的知识产权和版权，如果您认为本项目的内容侵犯了您的权益，请通过项目中提供的联系方式与我取得联系。一旦确认侵权行为，我将会立即采取措施删除相关内容或做出调整。

<br>最后，希望您在阅读本项目时能够理解并遵守以上免责声明。感谢您的支持和理解！
<h3>项目简介</h3>
<a href="https://github.com/kekylin/Debian-HomeNAS/blob/main/Docs/%E6%88%90%E6%9E%9C%E5%B1%95%E7%A4%BA.md">搭建成果展示</a><br>
<a href="https://github.com/kekylin/Debian-HomeNAS/blob/main/Docs/%E8%84%9A%E6%9C%AC%E4%BB%8B%E7%BB%8D.md">脚本介绍（使用前阅读）</a><br>

<h3>系统相关教程</h3>
<a href="https://docs.qq.com/doc/p/ac7a498302fca24ec7f0d002820ee32eceb03c13">基于Debian搭建HomeNAS图文教程 （本项目核心教程）</a><br>
<a href="https://docs.qq.com/doc/p/7859e20c9c3fa6816cb9f4d4e5e02a67495fc4a6">基于Ubuntu搭建HomeNAS图文教程 （本项目核心教程）</a><br>
<a href="https://github.com/kekylin/Debian-HomeNAS/blob/main/Docs/Debian%E7%B3%BB%E7%BB%9F%E6%9C%80%E5%B0%8F%E5%8C%96%E5%AE%89%E8%A3%85%E6%95%99%E7%A8%8B.md">Debian系统最小化安装教程</a><br>
<a href="https://github.com/kekylin/Debian-HomeNAS/blob/main/Docs/Debian%E7%B3%BB%E7%BB%9F%E9%80%9A%E8%BF%87Cockpit%E9%9D%A2%E6%9D%BF%E7%9B%B4%E9%80%9A%E7%A1%AC%E7%9B%98%E5%AE%89%E8%A3%85%E9%BB%91%E7%BE%A4%E6%99%96.md">Debian系统通过Cockpit面板直通硬盘安装黑群晖</a><br>
<a href="https://github.com/kekylin/Debian-HomeNAS/blob/main/Docs/%E5%86%85%E7%BD%91%E7%A9%BF%E9%80%8F%E6%9C%8D%E5%8A%A1Tailscale%E5%AE%89%E8%A3%85%E4%BD%BF%E7%94%A8%E6%95%99%E7%A8%8B.md">内网穿透服务Tailscale安装使用教程</a><br>
<a href="https://github.com/kekylin/Debian-HomeNAS/blob/main/Docs/Nginx%E5%8F%8D%E4%BB%A3%E9%99%90%E5%88%B6%E5%9B%BD%E5%A4%96IP%E8%AE%BF%E9%97%AE%E6%95%99%E7%A8%8B.md">Nginx反代限制国外IP访问教程</a><br>

<h3>Docker相关教程</h3>
<a href="https://docs.qq.com/doc/p/359de0f852ffbf9ba159dbec3ddcf119c33462f2">HomePage导航页部署教程</a><br>
<a href="https://github.com/kekylin/Debian-HomeNAS/blob/main/Docs/%E9%83%A8%E7%BD%B2Docker%E7%89%88%E8%B0%B7%E6%AD%8C%E6%B5%8F%E8%A7%88%E5%99%A8%E6%95%99%E7%A8%8B.md">部署Docker版谷歌浏览器教程</a><br>

<h3>B站视频</h3>
<a href="https://www.bilibili.com/video/BV16w4m1m78x">基于Linux搭建HomeNAS最终效果展示(Debian/Ubuntu)</a><br>
<a href="https://www.bilibili.com/video/BV1az42117pt">基于Debian搭建HomeNAS系列教程之系统安装篇</a><br>
<a href="https://www.bilibili.com/video/BV1EU411d7PM">只需8分钟，快速将Debian系统配置成准NAS系统</a><br>
<a href="https://www.bilibili.com/video/BV1vZ421H74n">一首歌的时间，在Debian系统直通硬盘安装黑群晖</a><br>
<a href="https://www.bilibili.com/video/BV1apYXeyEHT">以可视化面板展示NAS服务外网访问来源_Nginx日志监控</a><br>
  
</details>

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
      https://api.star-history.com/svg?repos=kekylin/Debian-HomeNAS&type=Date&theme=dark
    "
  />
  <source
    media="(prefers-color-scheme: light)"
    srcset="
      https://api.star-history.com/svg?repos=kekylin/Debian-HomeNAS&type=Date
    "
  />
  <img
    alt="Star History Chart"
    src="https://api.star-history.com/svg?repos=kekylin/Debian-HomeNAS&type=Date"
  />
</picture>

## 支持与赞赏
如果觉得本项目对您有所帮助，欢迎通过赞赏来支持我的工作！  
![赞赏码](https://github.com/user-attachments/assets/0e79f8b6-fc8b-41d7-80b2-7bd8ce2f1dee)
