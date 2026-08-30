# VSCodium loong64 → deb 自动打包发布

把 [VSCodium](https://github.com/VSCodium/vscodium) 官方的 **loongarch64 (loong64)** 构建（上游只发 `.tar.gz`，不提供 loong64 的 `.deb`）自动打包成 Debian `.deb`，并发布到本仓库的 [Release 页面](https://github.com/leesin872/vscodium-loong64-deb/releases)。

> **构建/验证环境：Debian 13（Loongnix 25），loongarch64**
> 本仓库产出的 deb 在 Loongnix GNU/Linux 25（基于 Debian 13）上构建并验证可用（`dpkg -i` + `apt-get -f install` 后直接运行）。

## 当前版本

<!-- VERSION-BLOCK:START -->
| 版本 | 下载 | deb sha256 | 构建日期 | 上游 |
|---|---|---|---|---|
| 1.126.04524 | [codium_1.126.04524_loong64.deb](https://github.com/leesin872/vscodium-loong64-deb/releases/download/1.126.04524/codium_1.126.04524_loong64.deb) | `827ab9f3871826d3cb4372a0996f0e4ca5d234ed230d4c40dadb16094c1e878b` | 2026-08-31 | [1.126.04524](https://github.com/VSCodium/vscodium/releases/tag/1.126.04524) |

> 构建/验证环境：**Debian 13 (Loongnix 25)**（loongarch64）
<!-- VERSION-BLOCK:END -->

## 安装

```sh
sudo dpkg -i codium_<版本>_loong64.deb
sudo apt-get -f install   # 按需补齐依赖
codium                     # 桌面会话里启动
```

安装内容：

- `/opt/vscodium/` —— 原生 loong64 二进制
- `/usr/bin/codium` -> `/opt/vscodium/bin/codium`
- `/usr/share/applications/codium.desktop` + 图标（`/usr/share/icons/hicolor/512x512/apps/codium.png`）

## 服务部署（systemd，开机自启）

> 本仓库**只自动打包 + 上传 GitHub Release，不安装任何 deb**；deb 请按上面「安装」一节自行安装。

在真实 Loongnix 25 / Debian 13 机器上，一条命令把自动打包服务部署为 **systemd 服务并开机自启**（需要 root）：

```sh
sudo bash deploy-service.sh [仓库目录] [检查间隔秒]
```

- 默认：仓库目录 = 脚本所在目录；间隔 = 3600 秒（1 小时检查一次上游）
- 脚本会把仓库复制到 `/opt/vscodium-loong64-deb`，写入 `/etc/systemd/system/codium-autodeb.service`（`Type=simple` 常驻 + `Restart=always`），`systemctl enable --now` 立即启动并开机自启

部署后：

```sh
systemctl status codium-autodeb.service    # 服务状态
journalctl -u codium-autodeb -f            # 实时日志（检查/打包/上传都会记录）
systemctl disable --now codium-autodeb     # 停止并取消开机自启
```

> 注：在无 systemd/cron 的容器沙箱里无法持久部署服务，脚本专为真机设计。

## 自动化原理

`check-and-publish.sh` 定时检查上游是否有新版本，有则自动执行：

1. 查询 `VSCodium/vscodium` 最新 release，定位 `VSCodium-linux-loong64-<版本>.tar.gz`
2. 下载并用 GitHub 提供的 sha256 digest 校验
3. `dpkg-deb` 打包为 `codium_<版本>_loong64.deb`（复刻既有的手工打包布局）
4. 更新本 README 的版本表（含 deb sha256、构建日期、上游链接）
5. 把脚本与 README 推送到本仓库
6. 创建 GitHub Release 并上传 deb

### 用法

```sh
./check-and-publish.sh --once               # 立即检查并发布（无更新则直接退出）
./check-and-publish.sh --daemon 3600        # 每 3600 秒循环检查（常驻）
./check-and-publish.sh --force              # 忽略 state 记录，强制重新构建发布
./check-and-publish.sh --only-build         # 只构建 deb，不做任何 GitHub 操作
./check-and-publish.sh --help
```

GitHub token 通过 `GITHUB_TOKEN` 环境变量或仓库目录下 `.github-token` 文件（权限 600，已被 `.gitignore` 排除）提供。

网络代理在脚本「配置区」的 `PROXY` 变量设置（当前默认 `http://192.168.9.2:12450`，curl 与 git 均走该代理；留空则直连）。

### 定时运行（推荐 systemd 服务，见上；备选如下）

**A. cron**（每小时）：

```cron
0 * * * * /绝对路径/check-and-publish.sh --once >> /var/log/codium-autodeb.log 2>&1
```

**B. nohup 常驻**：

```sh
nohup ./check-and-publish.sh --daemon 3600 >> autodeb.log 2>&1 &
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `check-and-publish.sh` | 主自动化脚本（定时检查/打包/上传一体，不安装 deb） |
| `deploy-service.sh` | 部署脚本：装成 systemd 服务并开机自启 |
| `systemd/codium-autodeb.service` | systemd 单元（常驻 daemon 模式） |
| `README.md` | 本文件，版本表由脚本自动更新 |
| `cache/` `state/` | 下载缓存与已发布版本记录（不入库） |
| `.github-token` | GitHub 访问令牌（不入库） |

## 与上游的关系

本仓库只做 **重新打包与分发**，不改动任何上游二进制；deb 内容与官方 tar.gz 完全一致（外加 `.desktop` 与图标入口）。上游版本策略、许可（MIT，见 [VSCodium](https://github.com/VSCodium/vscodium)）均沿用。
