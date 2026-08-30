#!/usr/bin/env bash
# =============================================================================
# check-and-publish.sh — VSCodium loong64 → deb 自动打包发布
#
# 定时检查上游 VSCodium/vscodium 是否有新的 loongarch64 (loong64) 构建，
# 有则自动：
#   1. 下载并 sha256 校验 VSCodium-linux-loong64-<版本>.tar.gz
#   2. dpkg-deb 打包为 codium_<版本>_loong64.deb（/opt/vscodium + 软链 + .desktop + 图标）
#   3. 更新本仓库 README.md 的版本表（注明基于 Debian 13 / Loongnix 25）
#   4. 把脚本与 README 推送到 GitHub 仓库
#   5. 创建 GitHub Release 并把 deb 上传到 Release 页面
#
# 用法：
#   ./check-and-publish.sh --once           # 立即检查并发布（无更新则直接退出）
#   ./check-and-publish.sh --daemon 3600    # 每 3600 秒循环检查（配合 nohup/systemd 常驻）
#   ./check-and-publish.sh --force          # 忽略 state 记录，强制重新构建并发布
#   ./check-and-publish.sh --only-build     # 只构建 deb，不执行任何 GitHub 操作
#   ./check-and-publish.sh --help
#
# 依赖：bash, curl, jq, tar, sha256sum, dpkg-deb, git, python3
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 配置区（按需修改）
# ---------------------------------------------------------------------------
OWNER="leesin872"                       # GitHub 账号
REPO="vscodium-loong64-deb"             # 本仓库名
UPSTREAM="VSCodium/vscodium"            # 上游仓库
ARCH="loong64"                          # 目标架构
DISTRO_NOTE="Debian 13 (Loongnix 25)"   # 构建/验证环境说明

# 网络代理（curl/git 均生效；留空 = 直连）
PROXY="http://192.168.9.2:12450"        # 例: http://192.168.9.2:12450
NO_PROXY_DEFAULT="localhost,127.0.0.1,::1"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 本脚本所在目录
CACHE_DIR="$BASE_DIR/cache"             # 下载/构建缓存（gitignore）
STATE_DIR="$BASE_DIR/state"             # 状态（gitignore）
STATE_FILE="$STATE_DIR/last-version"    # 上次已发布的上游版本
TOKEN_FILE="$BASE_DIR/.github-token"    # GitHub token（chmod 600，gitignore）
DEB_OUT_DIR="$BASE_DIR"                 # deb 产物输出目录（gitignore *.deb）

mkdir -p "$CACHE_DIR" "$STATE_DIR"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" >&2; }   # 日志走 stderr，stdout 留给函数返回值
die()  { echo "[$(date '+%F %T')] 错误: $*" >&2; exit 1; }

# 应用代理环境变量（curl 自动读取；git 在 push 时显式指定）
load_proxy() {
    if [ -n "$PROXY" ]; then
        export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
        export no_proxy="$NO_PROXY_DEFAULT" NO_PROXY="$NO_PROXY_DEFAULT"
        log "已启用代理: $PROXY"
    else
        log "未配置代理，直连"
    fi
}

# GitHub API 封装（带鉴权，输出原始 JSON；失败时非零退出）
gh_api() { # gh_api METHOD PATH [JSON_DATA]
    local method="$1" path="$2" data="${3:-}"
    curl -fsS -X "$method" \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com$path" ${data:+-d "$data"}
}

load_token() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        TOKEN="$GITHUB_TOKEN"
    elif [ -f "$TOKEN_FILE" ]; then
        TOKEN="$(cat "$TOKEN_FILE")"
    else
        die "未找到 GitHub token：$TOKEN_FILE 或环境变量 GITHUB_TOKEN"
    fi
    [ -n "$TOKEN" ] || die "token 为空"
    if [ -f "$TOKEN_FILE" ] && [ "$(stat -c %a "$TOKEN_FILE")" != "600" ]; then
        chmod 600 "$TOKEN_FILE" 2>/dev/null || true
        log "已收紧 $TOKEN_FILE 权限为 600"
    fi
}

# 查询上游最新 release，填充 TAG / ASSET_NAME / DOWNLOAD_URL / SHA256
get_latest() {
    log "查询上游 $UPSTREAM 最新 release ..."
    local rel
    rel="$(gh_api GET "/repos/$UPSTREAM/releases/latest")"
    TAG="$(echo "$rel" | jq -r .tag_name)"
    [ -n "$TAG" ] && [ "$TAG" != "null" ] || die "无法解析上游版本号"
    ASSET_NAME="VSCodium-linux-${ARCH}-${TAG}.tar.gz"
    local asset
    asset="$(echo "$rel" | jq -c --arg n "$ASSET_NAME" '.assets[] | select(.name==$n)' | head -1)"
    [ -n "$asset" ] || die "上游 release $TAG 缺少资产 $ASSET_NAME"
    DOWNLOAD_URL="$(echo "$asset" | jq -r .browser_download_url)"
    SHA256="$(echo "$asset" | jq -r .digest | sed 's/^sha256://')"
    if [ -z "$SHA256" ] || [ "$SHA256" = "null" ]; then
        log "上游未提供 digest，改为下载后本地计算 sha256"
        SHA256=""
    fi
    log "上游最新版本: $TAG"
}

# 确保目标仓库存在（不存在则创建，公开）
ensure_repo() {
    if gh_api GET "/repos/$OWNER/$REPO" >/dev/null 2>&1; then
        log "仓库已存在: https://github.com/$OWNER/$REPO"
    else
        log "创建公开仓库 $OWNER/$REPO ..."
        gh_api POST /user/repos "$(jq -n \
            --arg name "$REPO" \
            --arg desc "VSCodium loong64 → deb 自动打包发布（基于 $DISTRO_NOTE）" \
            '{name:$name, description:$desc, private:false}')" >/dev/null
        log "仓库已创建: https://github.com/$OWNER/$REPO"
    fi
}

# 下载并校验上游 tar.gz（有缓存且 sha256 相符则跳过下载）
fetch_tarball() {
    local tarball="$CACHE_DIR/$ASSET_NAME"
    local actual=""
    if [ -f "$tarball" ]; then
        actual="$(sha256sum "$tarball" | awk '{print $1}')"
        if [ -n "$SHA256" ] && [ "$actual" = "$SHA256" ]; then
            log "缓存命中: $ASSET_NAME"
            echo "$tarball"
            return 0
        fi
        log "缓存 sha256 不符（$actual），重新下载"
        rm -f "$tarball"
    fi
    log "下载 $ASSET_NAME ($DOWNLOAD_URL)"
    curl -fL --retry 3 --retry-delay 5 -C - -o "$tarball.part" "$DOWNLOAD_URL"
    mv -f "$tarball.part" "$tarball"
    actual="$(sha256sum "$tarball" | awk '{print $1}')"
    if [ -n "$SHA256" ]; then
        [ "$actual" = "$SHA256" ] || die "sha256 校验失败: $actual != $SHA256"
        log "sha256 校验通过: $actual"
    else
        SHA256="$actual"
        log "sha256（本地计算）: $actual"
    fi
    echo "$tarball"
}

# 构建 deb：codium_<版本>_loong64.deb（结构复刻官方式布局：/opt/vscodium）
build_deb() {
    local tag="$1"
    local tarball; tarball="$(fetch_tarball)"
    local work="$CACHE_DIR/build-$tag"
    local debroot="$CACHE_DIR/debroot-$tag"
    local debfile="$DEB_OUT_DIR/codium_${tag}_loong64.deb"

    rm -rf "$work" "$debroot"
    mkdir -p "$work" "$debroot/DEBIAN" \
        "$debroot/opt/vscodium" \
        "$debroot/usr/bin" \
        "$debroot/usr/share/applications" \
        "$debroot/usr/share/icons/hicolor/512x512/apps"

    log "解压 $ASSET_NAME ..."
    tar -xzf "$tarball" -C "$work"

    log "组装 deb 目录树 ..."
    cp -a "$work"/. "$debroot/opt/vscodium/"

    # 主程序软链
    [ -e "$debroot/opt/vscodium/bin/codium" ] || die "tar 中缺少 bin/codium"
    ln -s /opt/vscodium/bin/codium "$debroot/usr/bin/codium"

    # 图标（取自应用自带资源）
    if [ -f "$work/resources/app/resources/linux/code.png" ]; then
        cp "$work/resources/app/resources/linux/code.png" \
           "$debroot/usr/share/icons/hicolor/512x512/apps/codium.png"
    fi

    # .desktop 条目
    cat > "$debroot/usr/share/applications/codium.desktop" <<'EOF'
[Desktop Entry]
Name=VSCodium
Comment=Code Editing. Redefined. (loong64)
GenericName=Text Editor
Exec=/opt/vscodium/bin/codium %F
Icon=codium
Type=Application
StartupNotify=false
StartupWMClass=VSCodium
Categories=Utility;TextEditor;Development;
MimeType=text/plain;inode/directory;
EOF

    # control（依赖列表与既有手工打包版本一致）
    local size
    size="$(du -sk "$debroot/opt" | awk '{print $1}')"
    cat > "$debroot/DEBIAN/control" <<EOF
Package: codium
Version: $tag
Section: editors
Priority: optional
Architecture: loong64
Depends: libgtk-3-0, libnss3, libxss1, libxtst6, libasound2, libatk1.0-0, libatk-bridge2.0-0, libcups2, libdrm2, libgbm1, libsecret-1-0, libnotify4, xdg-utils
Maintainer: Loong64 VSCodium build <vscodium@loong64.local>
Installed-Size: $size
Description: VSCodium - open-source code editor (VS Code binaries)
 VSCodium is an open-source community distribution of VS Code built without
 Microsoft telemetry and licensing restrictions. This is the native loongarch64
 (loong64) build.
EOF

    log "dpkg-deb 打包 ..."
    dpkg-deb --root-owner-group --build "$debroot" "$debfile"

    DEB_SHA256="$(sha256sum "$debfile" | awk '{print $1}')"
    log "deb 构建完成: $debfile"
    log "deb sha256: $DEB_SHA256"

    rm -rf "$work" "$debroot"   # 清理中间产物，节省磁盘
}

# 更新 README.md 的版本表（<!-- VERSION-BLOCK:START/END --> 之间）
update_readme() {
    local tag="$1" readme="$BASE_DIR/README.md"
    [ -f "$readme" ] || die "缺少 $readme"
    local today; today="$(date '+%Y-%m-%d')"
    local dl_url="https://github.com/$OWNER/$REPO/releases/download/$tag/codium_${tag}_loong64.deb"
    local up_url="https://github.com/$UPSTREAM/releases/tag/$tag"
    local block
    block="<!-- VERSION-BLOCK:START -->
| 版本 | 下载 | deb sha256 | 构建日期 | 上游 |
|---|---|---|---|---|
| $tag | [codium_${tag}_loong64.deb]($dl_url) | \`$DEB_SHA256\` | $today | [$tag]($up_url) |

> 构建/验证环境：**$DISTRO_NOTE**（loongarch64）
<!-- VERSION-BLOCK:END -->"
    python3 - "$readme" "$block" <<'PY'
import sys
path, block = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    text = f.read()
start = text.find('<!-- VERSION-BLOCK:START -->')
end = text.find('<!-- VERSION-BLOCK:END -->')
if start == -1 or end == -1:
    sys.exit('README 缺少 VERSION-BLOCK 标记')
text = text[:start] + block + text[end + len('<!-- VERSION-BLOCK:END -->'):]
with open(path, 'w', encoding='utf-8') as f:
    f.write(text)
PY
    log "README.md 版本表已更新"
}

# 提交并推送脚本与 README 到仓库（deb/cache/state/token 均被 .gitignore 排除）
push_repo() {
    cd "$BASE_DIR"
    git init -q 2>/dev/null || true
    git config user.name  "leesin872" >/dev/null 2>&1 || true
    git config user.email "leesin872@users.noreply.github.com" >/dev/null 2>&1 || true
    git add -A
    if git diff --cached --quiet; then
        log "无代码变更，跳过 commit"
    else
        git commit -q -m "build: VSCodium ${1} loong64 deb" || true
        log "已提交: $(git rev-parse --short HEAD)"
    fi
    git branch -M main
    git remote remove origin 2>/dev/null || true
    git remote add origin "https://github.com/$OWNER/$REPO.git"
    log "推送到 https://github.com/$OWNER/$REPO ..."
    local push_url="https://x-access-token:${TOKEN}@github.com/$OWNER/$REPO.git"
    if [ -n "$PROXY" ]; then
        git -c http.proxy="$PROXY" -c https.proxy="$PROXY" push "$push_url" main:main \
            || die "git push 失败（token 权限？代理？）"
    else
        git push "$push_url" main:main \
            || die "git push 失败（token 权限？）"
    fi
    git branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
    log "推送完成"
}

# 创建（或复用）Release，并把 deb 上传为资产
publish_release() {
    local tag="$1"
    local rel_json id
    rel_json="$(gh_api GET "/repos/$OWNER/$REPO/releases/tags/$tag" 2>/dev/null || true)"
    if [ -n "$rel_json" ] && echo "$rel_json" | jq -e 'has("id") and (.id != null)' >/dev/null 2>&1; then
        id="$(echo "$rel_json" | jq -r .id)"
        log "Release $tag 已存在 (id=$id)，复用"
    else
        log "创建 Release $tag ..."
        local body
        body="$(printf 'VSCodium **%s** 的 loongarch64 (loong64) 原生 deb 包。\n\n- 上游: %s/releases/tag/%s\n- 构建/验证环境: **%s** / loongarch64\n- deb sha256: `%s`\n\n安装:\n\n```sh\nsudo dpkg -i codium_%s_loong64.deb\nsudo apt-get -f install\n```' "$tag" "$UPSTREAM" "$tag" "$DISTRO_NOTE" "$DEB_SHA256" "$tag")"
        local created
        created="$(gh_api POST "/repos/$OWNER/$REPO/releases" "$(jq -n \
            --arg tag "$tag" \
            --arg name "VSCodium $tag (loong64)" \
            --arg body "$body" \
            '{tag_name:$tag, name:$name, body:$body}')")"
        id="$(echo "$created" | jq -r .id)"
        log "Release 已创建 (id=$id)"
    fi

    local asset_name="codium_${tag}_loong64.deb"
    local has
    has="$(gh_api GET "/repos/$OWNER/$REPO/releases/$id/assets" \
        | jq --arg n "$asset_name" '[.[] | select(.name==$n)] | length')"
    if [ "$has" -gt 0 ]; then
        log "资产 $asset_name 已存在，跳过上传"
    else
        log "上传 $asset_name 到 Release ..."
        curl -fsS -X POST \
            -H "Authorization: token $TOKEN" \
            -H "Content-Type: application/octet-stream" \
            --data-binary @"$DEB_OUT_DIR/$asset_name" \
            "https://uploads.github.com/repos/$OWNER/$REPO/releases/$id/assets?name=$asset_name" >/dev/null
        log "上传完成"
    fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    load_proxy
    load_token
    get_latest
    if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$TAG" ] && [ "$FORCE" != 1 ]; then
        log "已是最新版本 $TAG，无需操作（--force 可强制重新构建发布）"
        return 0
    fi
    if [ "$ONLY_BUILD" != 1 ]; then
        ensure_repo
    fi
    build_deb "$TAG"
    if [ "$ONLY_BUILD" = 1 ]; then
        log "仅构建模式完成: $DEB_OUT_DIR/codium_${TAG}_loong64.deb"
        return 0
    fi
    update_readme "$TAG"
    push_repo "$TAG"
    publish_release "$TAG"
    echo "$TAG" > "$STATE_FILE"
    log "完成: https://github.com/$OWNER/$REPO/releases/tag/$TAG"
}

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
FORCE=0
ONLY_BUILD=0
DAEMON=0
DAEMON_INTERVAL=3600

while [ $# -gt 0 ]; do
    case "$1" in
        --once)              DAEMON=0 ;;
        --daemon)            DAEMON=1; DAEMON_INTERVAL="${2:-3600}"; shift ;;
        --force)             FORCE=1 ;;
        --only-build)        ONLY_BUILD=1 ;;
        --help|-h)           usage; exit 0 ;;
        *)                   die "未知参数: $1（--help 查看用法）" ;;
    esac
    shift
done

if [ "$DAEMON" = 1 ]; then
    log "守护模式：每 ${DAEMON_INTERVAL}s 检查一次（Ctrl-C 退出）"
    while true; do
        if main; then
            log "本轮检查完成"
        else
            log "本轮检查失败，稍后重试"
        fi
        sleep "$DAEMON_INTERVAL"
    done
else
    main
fi
