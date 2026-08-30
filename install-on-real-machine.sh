#!/usr/bin/env bash
# =============================================================================
# install-on-real-machine.sh — 真机验收 + 服务部署（在真实 Loongnix 25 / Debian 13 桌面上运行）
#
# 功能：
#   1. 校验并安装 codium_<版本>_loong64.deb（dpkg -i + apt-get -f install）
#   2. 冒烟测试：headless 版本输出 + （若有桌面会话）GUI 启动几秒验证
#   3. 部署 systemd user timer：定时运行 check-and-publish.sh 检查上游新版本
#   4. 打印最终状态
#
# 用法（真机，需 sudo）：
#   bash install-on-real-machine.sh [deb文件路径] [仓库目录]
#   默认: deb=同目录最新 codium_*.deb，仓库目录=脚本所在目录
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB="${1:-$(ls -1 "$SCRIPT_DIR"/codium_*_loong64.deb 2>/dev/null | head -1)}"
AUTODEB_DIR="${2:-$SCRIPT_DIR}"
LOG=/tmp/codium-install.log

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
die() { echo "[$(date '+%F %T')] 错误: $*" >&2 | tee -a "$LOG" >&2; exit 1; }

[ -n "$DEB" ] || die "未找到 deb 文件（用法: bash install-on-real-machine.sh [deb路径] [仓库目录]）"
[ -f "$DEB" ] || die "deb 不存在: $DEB"
[ -f "$AUTODEB_DIR/check-and-publish.sh" ] || die "仓库目录缺少 check-and-publish.sh: $AUTODEB_DIR"

log "==> 1/5 校验 deb"
dpkg-deb -I "$DEB" | grep -E "Package|Version|Architecture" || die "deb 元数据解析失败"
[ "$(uname -m)" = "loongarch64" ] || log "警告: 当前架构 $(uname -m)，不是 loongarch64"

log "==> 2/5 安装 deb（需要 root/sudo）"
if [ "$(id -u)" = 0 ]; then
    dpkg -i "$DEB"
else
    sudo -n dpkg -i "$DEB" 2>/dev/null || sudo dpkg -i "$DEB"
fi
sudo apt-get -f install -y || log "apt 依赖补齐失败或无需补齐（可手动 apt-get -f install）"

log "==> 3/5 headless 冒烟测试"
codium --version | head -3
[ -x /usr/bin/codium ] || die "/usr/bin/codium 不存在"

log "==> 4/5 GUI 冒烟测试（有桌面会话才执行）"
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ -S /tmp/.X11-unix/X0 ]; then
    timeout 8 codium --user-data-dir=/tmp/codium-smoke --disable-gpu \
        >/tmp/codium-gui.log 2>&1 &
    GUI_PID=$!
    sleep 5
    if kill -0 "$GUI_PID" 2>/dev/null; then
        log "GUI 启动正常（进程存活 5s），关闭冒烟实例"
        kill "$GUI_PID" 2>/dev/null || true
    else
        log "警告: GUI 进程提前退出，日志见 /tmp/codium-gui.log（无显示环境下属正常）"
    fi
else
    log "未检测到桌面会话，跳过 GUI 冒烟测试"
fi

log "==> 5/5 部署 systemd user timer（自动检查上游新版本）"
SERVICE_SRC="$AUTODEB_DIR/systemd/codium-autodeb.service"
TIMER_SRC="$AUTODEB_DIR/systemd/codium-autodeb.timer"
[ -f "$SERVICE_SRC" ] && [ -f "$TIMER_SRC" ] || die "缺少 systemd 单元文件: $AUTODEB_DIR/systemd/"
mkdir -p ~/.config/systemd/user
sed "s|ExecStart=.*check-and-publish.sh --once|ExecStart=$AUTODEB_DIR/check-and-publish.sh --once|" \
    "$SERVICE_SRC" > ~/.config/systemd/user/codium-autodeb.service
cp "$TIMER_SRC" ~/.config/systemd/user/codium-autodeb.timer
systemctl --user daemon-reload
systemctl --user enable --now codium-autodeb.timer || log "警告: timer 启用失败（检查 systemd user 会话）"
systemctl --user list-timers codium-autodeb.timer --no-pager || true

log "==> 完成"
log "  - 手动启动: codium"
log "  - 定时器:   systemctl --user status codium-autodeb.timer"
log "  - 立即检查: $AUTODEB_DIR/check-and-publish.sh --once"
