#!/usr/bin/env bash
# =============================================================================
# deploy-service.sh — 把 codium-autodeb 部署为 systemd 服务（开机自启动）
#
# 作用：只做【定时检查上游 → 有新版本就打包 deb → 打包成功就上传 GitHub Release】，
#       不安装任何 deb（deb 由你自己安装）。
#
# 用法（真机，需要 root/sudo）：
#   sudo bash deploy-service.sh [仓库目录] [检查间隔秒]
#   默认：仓库目录 = 脚本所在目录，间隔 = 3600 秒（1 小时）
#
# 部署内容：
#   1. 把仓库（脚本/README/token）复制到 /opt/vscodium-loong64-deb
#   2. 写入系统级 systemd 单元 /etc/systemd/system/codium-autodeb.service
#      （Type=simple 常驻服务，Restart=always，--daemon <间隔> 循环检查）
#   3. systemctl enable --now → 开机自启动 + 立即启动
# =============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/opt/vscodium-loong64-deb"
INTERVAL="${INTERVAL:-${2:-3600}}"
UNIT="/etc/systemd/system/codium-autodeb.service"

[ "$(id -u)" = 0 ] || { echo "需要 root：sudo bash deploy-service.sh" >&2; exit 1; }
[ -f "$SRC/check-and-publish.sh" ] || { echo "仓库目录缺少 check-and-publish.sh: $SRC" >&2; exit 1; }
[ -f "$SRC/.github-token" ] || echo "警告: 未找到 $SRC/.github-token（请用 GITHUB_TOKEN 环境变量或补上该文件）"

echo "==> 1/3 复制仓库到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
# 只复制运行所需；排除大产物/日志与 .git
cp -a "$SRC/check-and-publish.sh" \
      "$SRC/README.md" \
      "$SRC/systemd" \
      "$DEST/"
# .gitignore 必须带上：否则部署副本里 git add -A 会把 deb/tar.gz/token 误纳入版本库，
# push 超过 GitHub 100MB 单文件限制必然失败 → state 写不进 → 每轮都重新构建（恶性循环）
[ -f "$SRC/.gitignore" ] && cp -a "$SRC/.gitignore" "$DEST/"
# 保留已发布版本记录与下载缓存：避免每次重新部署后对同一版本重复构建/重复下载 200MB
[ -d "$SRC/state" ] && cp -a "$SRC/state" "$DEST/"
mkdir -p "$DEST/cache"
cp -a "$SRC"/cache/*.tar.gz "$DEST/cache/" 2>/dev/null || true
[ -f "$SRC/.github-token" ] && cp -a "$SRC/.github-token" "$DEST/"
chmod 600 "$DEST/.github-token" 2>/dev/null || true
chmod +x "$DEST/check-and-publish.sh"

echo "==> 2/3 写入 systemd 单元 $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=Auto-package & publish VSCodium loong64 deb (daemon)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DEST/check-and-publish.sh --daemon $INTERVAL
Restart=always
RestartSec=60
WorkingDirectory=$DEST

[Install]
WantedBy=multi-user.target
EOF

echo "==> 3/3 启用并启动（开机自启）"
systemctl daemon-reload
systemctl enable codium-autodeb.service
systemctl restart codium-autodeb.service
sleep 3
systemctl --no-pager --full status codium-autodeb.service | head -12

echo
echo "完成。常用命令："
echo "  systemctl status codium-autodeb.service    # 服务状态"
echo "  journalctl -u codium-autodeb -f            # 实时日志（每次检查/打包/上传都会记录）"
echo "  systemctl disable --now codium-autodeb     # 停止并取消开机自启"
