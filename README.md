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

## 真机验收与部署

在真实 Loongnix 25 / Debian 13 桌面上一条命令完成：**校验 → 安装 deb → 冒烟测试（headless + GUI）→ 部署 systemd user timer**：

```sh
bash install-on-real-machine.sh [deb路径] [仓库目录]
```

- `deb路径` 默认取脚本同目录最新 `codium_*_loong64.deb`；`仓库目录` 默认脚本所在目录（timer 会定时调用其中的 `check-and-publish.sh --once`）。
- GUI 冒烟测试仅在检测到桌面会话时执行；headless 冒烟（`codium --version`）必执行。
- 需要 root/sudo（dpkg 安装）。

部署后：

```sh
systemctl --user status codium-autodeb.timer   # 定时器状态
systemctl --user list-timers codium-autodeb    # 下次触发时间
```

> 注：在无 systemd/cron 的容器沙箱里无法持久部署服务，脚本专为真机桌面设计。

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

### 定时调度（任选其一）

**A. systemd user timer**（真机推荐）：

```sh
mkdir -p ~/.config/systemd/user
cp systemd/codium-autodeb.service systemd/codium-autodeb.timer ~/.config/systemd/user/
# 按需修改 service 里的 ExecStart 路径
systemctl --user daemon-reload
systemctl --user enable --now codium-autodeb.timer
```

**B. cron**（每小时）：

```cron
0 * * * * /绝对路径/check-and-publish.sh --once >> /var/log/codium-autodeb.log 2>&1
```

**C. nohup 常驻**：

```sh
nohup ./check-and-publish.sh --daemon 3600 >> autodeb.log 2>&1 &
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `check-and-publish.sh` | 主自动化脚本（检查/构建/发布一体） |
| `README.md` | 本文件，版本表由脚本自动更新 |
| `systemd/` | 可选的 systemd timer 单元 |
| `cache/` `state/` | 下载缓存与已发布版本记录（不入库） |
| `.github-token` | GitHub 访问令牌（不入库） |

## 与上游的关系

本仓库只做 **重新打包与分发**，不改动任何上游二进制；deb 内容与官方 tar.gz 完全一致（外加 `.desktop` 与图标入口）。上游版本策略、许可（MIT，见 [VSCodium](https://github.com/VSCodium/vscodium)）均沿用。
