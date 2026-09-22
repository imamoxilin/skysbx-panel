#!/usr/bin/env bash
# Install the skysbx panel on a Debian/Ubuntu host.
#
#   sudo ./install-panel.sh --domain panel.example.com --email you@example.com
#
# Re-running upgrades the binary in place; the database is never touched.
set -euo pipefail

ROOT=${SKYSBX_ROOT:-/opt/skysbx}
DOMAIN=""
EMAIL=""
SRC_DIR=""
GH_TOKEN=${GITHUB_TOKEN:-}
GH_OWNER=${SKYSBX_GH_OWNER:-kosje}
REF=${SKYSBX_REF:-main}
FROM_SOURCE=0
# Set when a node shares this host: the panel then writes its certificate to
# cert.pem/key.pem, which is where the node's AnyTLS inbounds look by default.
EXPORT_CERT=0
# Empty means whatever the newest release is. Pin it to reinstall the exact
# version a working host is already running.
SKYSBX_VERSION=${SKYSBX_VERSION:-}
# A checkout whatever invoked us already had. Not the same as --src: this only
# says "reuse this if you end up building", where --src says "build this and do
# not look for a published binary".
LAUNCHER_SRC=${SKYSBX_LAUNCHER_SRC:-}

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s 完成%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s 警告%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s 错误%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

ACTION=install

usage() {
    cat <<EOF
用法：sudo ./install-panel.sh [--domain <域名>] [选项]

动作（默认是安装）
  --version         查看已安装的版本。
  --upgrade         重新取得新版并重启。域名会从 systemd 单元里读回来，
                    所以不需要任何参数。数据库不会被动。
  --uninstall       停止并移除服务和二进制。保留数据库、证书和域名，
                    所以装回来只需要一条不带参数的 --upgrade。
  --purge           在 --uninstall 的基础上，连数据库和证书一起删除。
                    那是全部用户、节点和订阅 —— 没有撤销，别处也没有副本。

安装选项
  --domain <域名>   面板域名，必须已经解析到这台服务器。
  --email <邮箱>    Let's Encrypt 的联系邮箱（建议填写）。
  --src <目录>      用本地已有的检出编译，不再克隆。
  --from-source     从源码编译，不下载已发布的二进制。
  --export-cert     额外把证书写到 cert.pem/key.pem，供同机的节点用它跑
                    AnyTLS。只在这种情况下使用：它会覆盖那两个路径上原有
                    的文件。
  -h, --help        显示本说明。

80 和 443 端口必须空闲：面板自己终结 TLS、自己应答 ACME 验证，所以不需要装
任何反向代理，也没有额外的配置文件要维护。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)   ACTION=version; shift ;;
        --upgrade)   ACTION=upgrade; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        --purge)     ACTION=purge; shift ;;
        --domain)    DOMAIN=$2; shift 2 ;;
        --email)     EMAIL=$2; shift 2 ;;
        --src)       SRC_DIR=$2; shift 2 ;;
        --from-source) FROM_SOURCE=1; shift ;;
        --export-cert) EXPORT_CERT=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "无法识别的参数：$1（试试 --help）" ;;
    esac
done

# ───────────────────────── version / uninstall / purge ─────────────────────

if [ "$ACTION" = version ]; then
    if [ -x "$ROOT/skysbx-panel" ]; then
        "$ROOT/skysbx-panel" -version
        printf '安装于    %s\n' "$(stat -c %y "$ROOT/skysbx-panel" 2>/dev/null | cut -d. -f1)"
        systemctl is-active --quiet skysbx-panel \
            && printf '服务      运行中\n' || printf '服务      已停止\n'
        [ -f "$ROOT/skysbx.db" ] && printf '数据库    %s（%s）\n' "$ROOT/skysbx.db" \
            "$(du -h "$ROOT/skysbx.db" 2>/dev/null | cut -f1)"
    else
        printf '%s 下没有安装 skysbx-panel\n' "$ROOT"
    fi
    exit 0
fi

if [ "$ACTION" = uninstall ] || [ "$ACTION" = purge ]; then
    [ "$(id -u)" = 0 ] || die "请用 root 运行"

    say "正在移除服务"
    systemctl disable --now skysbx-panel >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/skysbx-panel.service
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true
    ok "skysbx-panel 已停止并移除"

    rm -f "$ROOT/skysbx-panel"
    # The build tree is scratch space, not data: a fresh clone on every run.
    rm -rf "$ROOT/build/skysbx-panel"
    ok "二进制和构建缓存已删除"

    if [ "$ACTION" = purge ]; then
        say "正在清除"
        # Every user, node and subscription lives in this one file. Nothing else
        # in this script destroys anything that cannot be rebuilt.
        rm -f "$ROOT/skysbx.db" "$ROOT/skysbx.db-wal" "$ROOT/skysbx.db-shm"
        rm -f "$ROOT/panel.env"
        rm -rf "$ROOT/certs"
        rm -rf "$ROOT/go-mod-cache" "$ROOT/go-build-cache"
        # The toolchain is shared when a node lives on this host too, so it goes
        # only if nothing else is using it. It is a rebuildable cache either way.
        systemctl is-enabled --quiet skysbx-node 2>/dev/null || rm -rf "$ROOT/toolchain"
        ok "数据库和证书已删除"
        # Only ever true on a host set up by an older version of this script,
        # which installed Docker to build in. Nothing installs it any more, but
        # leaving a daemon behind that we put there would be rude.
        if [ -f "$ROOT/.docker-installed-by-skysbx" ] && command -v docker >/dev/null 2>&1; then
            say "正在卸载 docker（是本脚本的旧版本装的）"
            systemctl disable --now docker docker.socket containerd >/dev/null 2>&1 || true
            apt-get purge -y -qq docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
            apt-get autoremove -y -qq >/dev/null 2>&1 || true
            rm -rf /var/lib/docker /var/lib/containerd /etc/docker
            rm -f "$ROOT/.docker-installed-by-skysbx"
            ok "docker 已卸载"
        fi
    fi

    # The shortcut manages both halves, so it goes only when the other one is
    # not still relying on it.
    if [ ! -x "$ROOT/skysbx-node" ]; then
        rm -f /usr/local/bin/skysbx
    fi

    # Shared with the node when both are on one host, so it goes only if this
    # was the last thing in it.
    rmdir "$ROOT/build" 2>/dev/null || true
    if rmdir "$ROOT" 2>/dev/null; then
        ok "$ROOT 已删除"
    else
        warn "$ROOT 保留 —— 里面还有别的文件（节点的，或你自己的）："
        (ls -A "$ROOT" 2>/dev/null || true) | sed 's/^/       /'
    fi

    printf '\n%sskysbx 面板已移除。%s\n' "$GRN" "$RST"
    [ "$ACTION" = uninstall ] && printf \
        '数据库和证书保留在 %s；--purge 会把它们也删掉。\n' "$ROOT"
    exit 0
fi

if [ "$ACTION" = upgrade ]; then
    # panel.env first: it survives an --uninstall, so "reinstall" and "upgrade"
    # are the same command. The unit file is the fallback for panels installed
    # before panel.env existed.
    if [ -f "$ROOT/panel.env" ]; then
        DOMAIN=${DOMAIN:-$(sed -n 's/^SKYSBX_DOMAIN=//p' "$ROOT/panel.env")}
        EMAIL=${EMAIL:-$(sed -n 's/^SKYSBX_ACME_EMAIL=//p' "$ROOT/panel.env")}
        # Carried across upgrades: a node on this host is relying on the export,
        # and silently dropping it would leave AnyTLS serving an expiring
        # certificate until someone noticed.
        [ "$EXPORT_CERT" = 1 ] || EXPORT_CERT=$(sed -n 's/^SKYSBX_EXPORT_CERT=//p' \
            "$ROOT/panel.env" 2>/dev/null | head -1)
        EXPORT_CERT=${EXPORT_CERT:-0}
    elif [ -f /etc/systemd/system/skysbx-panel.service ]; then
        DOMAIN=${DOMAIN:-$(sed -n 's/.*--domain \([^ ]*\).*/\1/p' \
            /etc/systemd/system/skysbx-panel.service | head -1)}
        EMAIL=${EMAIL:-$(sed -n 's/.*--acme-email \([^ ]*\).*/\1/p' \
            /etc/systemd/system/skysbx-panel.service | head -1)}
    fi
    [ -n "$DOMAIN" ] || die "无法确定这个面板用的是哪个域名，请用 --domain 指定"
    # A panel installed before --acme-email was written conditionally recorded
    # the literal string "--db" as its contact, because that is what Go's flag
    # package took as the value of an empty flag. Reading it back and writing
    # it out again would rebuild the same broken command line and keep the host
    # without a certificate through an upgrade that looked like it worked.
    case "$EMAIL" in
        -*) warn "忽略记录中的 ACME 联系方式 '$EMAIL' —— 那不是一个邮箱地址"
            EMAIL="" ;;
    esac
    say "正在升级 —— 域名 $DOMAIN"
fi

# ─────────────────────────────── preflight ────────────────────────────────

say "环境检查"
[ "$(id -u)" = 0 ] || die "请用 root 运行"

if [ -z "$DOMAIN" ]; then
    if [ -t 0 ]; then
        printf '  面板域名（必须已经解析到本机）：'
        read -r DOMAIN
    fi
    [ -n "$DOMAIN" ] || { usage; die "必须提供 --domain"; }
fi
if [ -z "$EMAIL" ] && [ -t 0 ]; then
    printf '  Let'"'"'s Encrypt 联系邮箱（可留空跳过）：'
    read -r EMAIL
fi

# The administrator is set before the panel ever listens.
#
# Until one exists, /setup belongs to whoever reaches it first — and between
# the moment this script starts the service and the moment a human opens a
# browser, that is a race against everyone who can reach the domain. Asking
# here turns a window into no window.
#
# Only on a first install: an upgrade already has an administrator, and
# prompting for one would either be ignored or would silently replace it.
NEED_ADMIN=no
if [ "$ACTION" = install ] && [ ! -f "$ROOT/skysbx.db" ]; then
    NEED_ADMIN=yes
    ADMIN_USER=${SKYSBX_ADMIN_USER:-}
    ADMIN_PASS=${SKYSBX_ADMIN_PASSWORD:-}

    if [ -z "$ADMIN_PASS" ]; then
        # No terminal means no way to ask. Refusing beats carrying on: the
        # alternative is a panel whose administrator is whoever opens /setup
        # first, which is the thing this whole block exists to prevent.
        [ -t 0 ] || die "当前没有终端可以询问管理员账号。
  请设置 SKYSBX_ADMIN_USER 和 SKYSBX_ADMIN_PASSWORD，或直接运行：
    git clone https://github.com/${GH_OWNER}/skysbx-panel.git
    sudo ./skysbx-panel/deploy/install-panel.sh --domain $DOMAIN"

        printf '  管理员用户名（默认 admin）：'
        read -r ADMIN_USER || die "没有提供管理员用户名"
        ADMIN_USER=${ADMIN_USER:-admin}

        # Never echoed, and never an argument to anything: an argument is in
        # the process list while it runs and in the shell's history after.
        # Bounded, so a terminal that keeps returning EOF cannot spin here.
        tries=0
        while :; do
            tries=$((tries + 1))
            [ "$tries" -le 5 ] || die "管理员密码输入次数过多，已放弃"

            printf '  管理员密码（至少 12 位）：'
            stty -echo 2>/dev/null || true
            read -r ADMIN_PASS || { stty echo 2>/dev/null || true; die "没有提供密码"; }
            stty echo 2>/dev/null || true
            printf '\n'
            if [ "${#ADMIN_PASS}" -lt 12 ]; then
                warn "太短了 —— 至少 12 位"
                ADMIN_PASS=""
                continue
            fi

            printf '  再输入一次：'
            stty -echo 2>/dev/null || true
            read -r ADMIN_PASS2 || { stty echo 2>/dev/null || true; die "没有提供密码"; }
            stty echo 2>/dev/null || true
            printf '\n'
            if [ "$ADMIN_PASS" != "$ADMIN_PASS2" ]; then
                warn "两次输入不一致"
                ADMIN_PASS=""
                continue
            fi
            ADMIN_PASS2=""
            break
        done
    fi

    ADMIN_USER=${ADMIN_USER:-admin}
    [ "${#ADMIN_PASS}" -ge 12 ] || die "管理员密码至少要 12 位"
fi

command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
for p in git dig; do
    command -v "$p" >/dev/null || apt-get install -y -qq git dnsutils
done

PUBLIC_IP=$(curl -fsS --max-time 10 https://api.ipify.org || echo "")
RESOLVED=$( (dig +short "$DOMAIN" A @1.1.1.1 || true) | tail -1)
if [ -z "$RESOLVED" ]; then
    die "$DOMAIN 没有 A 记录"
elif [ -n "$PUBLIC_IP" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
    warn "$DOMAIN 解析到 $RESOLVED，而本机是 $PUBLIC_IP"
    warn "ACME 的 HTTP-01 验证需要直连，请关掉任何代理（Cloudflare 请用灰云）"
    if [ -t 0 ]; then
        printf '  仍然继续吗？[y/N] '
        read -r a; [ "$a" = y ] || [ "$a" = Y ] || exit 1
    fi
else
    ok "$DOMAIN -> $RESOLVED（就是本机）"
fi

# Only check the ports on a first install: on an upgrade they are held by the
# panel this script is about to replace.
if ! systemctl is-enabled --quiet skysbx-panel 2>/dev/null; then
    for port in 80 443; do
        if ss -tlnH | awk '{print $4}' | grep -qE "[:.]$port\$"; then
            die "$port 端口已被占用；面板自己终结 TLS，80 和 443 两个都需要"
        fi
    done
    ok "80 和 443 端口空闲"
fi

# ──────────────────────────────── build ───────────────────────────────────

install -d -m 0700 "$ROOT"
BUILD=$ROOT/build
mkdir -p "$BUILD"
# Keep Go's module and compilation caches outside the disposable build tree.
# Besides making a panel upgrade quicker, the same caches can be mounted by the
# same-host node installer so shared modules are downloaded only once.
GO_MOD_CACHE=$ROOT/go-mod-cache
GO_BUILD_CACHE=$ROOT/go-build-cache
install -d -m 0700 "$GO_MOD_CACHE" "$GO_BUILD_CACHE"

# ─────────────────────────── a published binary ───────────────────────────
#
# Compiling takes minutes and, on a small VPS, most of the memory: a cold build
# cache here was measured leaving 74MB free on a 954MB host. A published build
# is ~16MB and lands in seconds, so it is what we try first.
#
# Tried before the sources are fetched: when it succeeds there is nothing to
# compile, so there is no reason to have cloned anything.
#
# It is a preference, not a requirement. No release yet, an architecture nobody
# publishes for, a network that cannot reach GitHub's CDN — all of those fall
# through to building, which is the path that always works. --from-source skips
# straight to it for anyone who would rather not run a binary they did not
# build.
try_release() {
    [ "$FROM_SOURCE" = 1 ] && return 1
    [ -n "$SRC_DIR" ] && return 1   # asked for this checkout specifically

    case $(uname -m) in
        x86_64|amd64)  rel_arch=amd64 ;;
        aarch64|arm64) rel_arch=arm64 ;;
        *) return 1 ;;
    esac

    local base="https://github.com/${GH_OWNER}/skysbx-panel/releases"
    # GitHub serves the newest release's assets from this path, so resolving a
    # version through the API — and its rate limit, and its JSON — is avoidable.
    local from="$base/latest/download"
    [ -n "$SKYSBX_VERSION" ] && from="$base/download/$SKYSBX_VERSION"

    local tmp; tmp=$(mktemp -d)
    local asset="skysbx-panel-linux-$rel_arch"
    say "正在查找已发布的构建"
    if ! curl -fsSL --max-time 120 -o "$tmp/$asset" "$from/$asset" \
      || ! curl -fsSL --max-time 30 -o "$tmp/SHA256SUMS" "$from/SHA256SUMS"; then
        rm -rf "$tmp"
        return 1
    fi
    # Same rule as the toolchain tarball: nothing unverified gets installed and
    # run as root. A mismatch is not a reason to fall back quietly — a release
    # that does not match its own checksums is worth stopping for.
    if ! ( cd "$tmp" && grep " $asset\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ); then
        rm -rf "$tmp"
        die "已发布的面板二进制与校验和不符。
  拒绝安装。可以加 --from-source 改为从源码编译。"
    fi
    install -m 0755 "$tmp/$asset" "$ROOT/skysbx-panel"
    rm -rf "$tmp"
    ok "已安装发布版二进制（$rel_arch）"
    return 0
}

HAVE_BINARY=0
try_release && HAVE_BINARY=1

if [ "$HAVE_BINARY" = 1 ]; then
    :
elif [ -n "$SRC_DIR" ]; then
    say "准备源码"
    rm -rf "$BUILD/skysbx-panel"
    cp -a "$SRC_DIR" "$BUILD/skysbx-panel"
    ok "使用 $SRC_DIR"
elif [ -n "$LAUNCHER_SRC" ] && [ -d "$LAUNCHER_SRC" ]; then
    say "准备源码"
    rm -rf "$BUILD/skysbx-panel"
    cp -a "$LAUNCHER_SRC" "$BUILD/skysbx-panel"
    ok "复用启动器已经克隆好的源码"
else
    say "准备源码"
    URL="https://github.com/${GH_OWNER}/skysbx-panel.git"
    rm -rf "$BUILD/skysbx-panel"
    # The token goes in a per-command header, not in the URL: git writes the
    # remote URL into the clone's .git/config, and a token in it would sit on
    # disk for as long as the build directory does.
    if [ -n "$GH_TOKEN" ]; then
        git -c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' \
            "$GH_TOKEN" | base64 -w0)" \
            clone -q --branch "$REF" --depth 1 "$URL" "$BUILD/skysbx-panel" \
            || die "无法克隆 ${GH_OWNER}/skysbx-panel（请检查 GITHUB_TOKEN）"
    else
        git clone -q --branch "$REF" --depth 1 "$URL" "$BUILD/skysbx-panel" \
            || die "无法克隆 ${GH_OWNER}/skysbx-panel（分支可能不存在；若是私有仓库请设置 GITHUB_TOKEN）"
    fi
    ok "$(git -C "$BUILD/skysbx-panel" rev-parse --short HEAD)"
fi

# Sources that travelled through a Windows checkout carry CRLF, and bash then
# fails on "bad interpreter".
find "$BUILD" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# ────────────────────────────── go toolchain ──────────────────────────────
#
# Go is needed to build and for nothing else. This used to install Docker for
# it: a package repository, a daemon and a ~350MB image, to run one compiler
# once. The official tarball is 64MB, leaves nothing running, and unpacks
# inside $ROOT where --purge already looks.
#
# 1.26.x is not a preference. sing-box reaches an unexported http2 field
# through go:linkname and 1.27 refuses to link it, so the node is pinned to
# 1.26.x; pinning the panel to the same version means a host running both
# downloads one toolchain instead of two.
GO_VERSION=1.26.5
GO_SHA256_amd64=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053
GO_SHA256_arm64=fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49

ensure_go() {
    GO="$ROOT/toolchain/go/bin/go"
    if [ -x "$GO" ] && "$GO" version 2>/dev/null | grep -q "go$GO_VERSION "; then
        ok "go $GO_VERSION 已经解包过了"
        return
    fi
    case $(uname -m) in
        x86_64|amd64)  go_arch=amd64; go_sha=$GO_SHA256_amd64 ;;
        aarch64|arm64) go_arch=arm64; go_sha=$GO_SHA256_arm64 ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
    say "正在下载 go $GO_VERSION（$go_arch）"
    mkdir -p "$ROOT/toolchain"
    go_tgz="$ROOT/toolchain/go.tar.gz"
    rm -f "$go_tgz"
    if ! curl -fsSL -o "$go_tgz" "https://go.dev/dl/go$GO_VERSION.linux-$go_arch.tar.gz"; then
        rm -f "$go_tgz"
        die "无法下载 go 工具链"
    fi
    # A tarball unpacked as root is not something to wave through unverified.
    # The rejected bytes go with it: 64MB of unexplained file left in $ROOT by
    # a failed install is how this becomes a mystery to whoever looks next.
    if ! printf '%s  %s\n' "$go_sha" "$go_tgz" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$go_tgz"
        die "go 压缩包校验和不符 —— 拒绝解包"
    fi
    rm -rf "$ROOT/toolchain/go"
    tar -C "$ROOT/toolchain" -xzf "$go_tgz"
    rm -f "$go_tgz"
    [ -x "$GO" ] || die "go 工具链解包结果不符合预期"
    ok "go $GO_VERSION 就绪"
}

if [ "$HAVE_BINARY" = 0 ]; then
    ensure_go

    # Stamped into the binary so `--version` can answer what is running without
    # anyone reading a build log.
    VER=$(git -C "$BUILD/skysbx-panel" rev-parse --short HEAD 2>/dev/null || echo unknown)

    say "正在编译"
    # GOTOOLCHAIN=local is what makes the pin real: without it Go reads the `go`
    # line in go.mod and will silently fetch and use a newer toolchain, which is
    # exactly the 1.27 that cannot link the node half.
    ( cd "$BUILD/skysbx-panel" && env \
        GOTOOLCHAIN=local GOFLAGS=-buildvcs=false CGO_ENABLED=0 GOOS=linux \
        GOMODCACHE="$GO_MOD_CACHE" GOCACHE="$GO_BUILD_CACHE" \
        "$GO" build -trimpath -ldflags "-s -w -X main.version=$VER" \
            -o skysbx-panel ./cmd/panel )
    install -m 0755 "$BUILD/skysbx-panel/skysbx-panel" "$ROOT/skysbx-panel"
    ok "面板二进制已安装"
fi

# Before the service starts, so there is never a moment where the panel is
# reachable without an administrator. The password goes in on stdin — printf is
# a shell builtin, so it never becomes a process with the password in its argv.
if [ "$NEED_ADMIN" = yes ]; then
    say "设置管理员"
    printf '%s' "$ADMIN_PASS" | "$ROOT/skysbx-panel" \
        -db "$ROOT/skysbx.db" -set-admin "$ADMIN_USER" >/dev/null \
        || die "无法设置管理员"
    ADMIN_PASS=""
    ok "管理员 $ADMIN_USER 已设置"
fi

# ─────────────────────────────── service ──────────────────────────────────

say "配置服务"
# Kept beside the data rather than only in the unit file, so that --upgrade
# still knows the domain after an --uninstall has removed the unit. Without it,
# reinstalling would mean remembering and retyping what the panel already knew.
cat > "$ROOT/panel.env" <<EOF
SKYSBX_DOMAIN=${DOMAIN}
SKYSBX_ACME_EMAIL=${EMAIL}
SKYSBX_EXPORT_CERT=${EXPORT_CERT}
EOF
chmod 600 "$ROOT/panel.env"

# Written as a whole flag or not at all. An empty EMAIL used to leave
# `--acme-email ` followed by `--db`, and Go's flag package reads the next
# argument as the value: the ACME contact became the literal string "--db",
# Let's Encrypt rejected it with "unable to parse email address", and the
# panel then had no certificate — for ever, retrying in the background. The
# database escaped only by luck, because the flag it swallowed has a relative
# default that WorkingDirectory happened to resolve to the same file.
ACME_EMAIL_FLAG=""
[ -n "$EMAIL" ] && ACME_EMAIL_FLAG="--acme-email $EMAIL"
EXPORT_CERT_FLAG=""
[ "$EXPORT_CERT" = 1 ] && EXPORT_CERT_FLAG="--export-cert"

cat > /etc/systemd/system/skysbx-panel.service <<EOF
[Unit]
Description=skysbx panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ROOT}
ExecStart=${ROOT}/skysbx-panel --domain ${DOMAIN} ${ACME_EMAIL_FLAG} ${EXPORT_CERT_FLAG} --db ${ROOT}/skysbx.db
Restart=always
RestartSec=3

# Binding 80 and 443 is the only privilege it needs.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${ROOT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q skysbx-panel
systemctl restart skysbx-panel
ok "systemd 服务单元已安装"

# The `skysbx` command: the same menu this may well have been started from,
# left behind so maintenance does not mean remembering a raw.githubusercontent
# URL. Prefer the copy in the checkout when there is one — a download install
# has no checkout, and then it comes off the network like everything else.
#
# Best effort on purpose. It manages the panel; it is not part of it, and a
# host that could not fetch one convenience script still has a working panel.
if [ -f "$BUILD/skysbx-panel/skysbx.sh" ]; then
    install -m 0755 "$BUILD/skysbx-panel/skysbx.sh" /usr/local/bin/skysbx
    ok "skysbx 命令已安装"
elif curl -fsSL --max-time 30 -o /tmp/skysbx.$$ \
        "https://raw.githubusercontent.com/${GH_OWNER}/skysbx-panel/${REF}/skysbx.sh" \
     && [ -s /tmp/skysbx.$$ ]; then
    install -m 0755 /tmp/skysbx.$$ /usr/local/bin/skysbx
    rm -f /tmp/skysbx.$$
    ok "skysbx 命令已安装"
else
    rm -f /tmp/skysbx.$$
    warn "无法安装 skysbx 快捷命令；不影响面板本身"
fi

printf '    正在等待证书签发 '
CERT_LIVE=0
for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "https://$DOMAIN/login" >/dev/null 2>&1; then
        printf '\n'; ok "https://$DOMAIN 已可访问"
        CERT_LIVE=1
        break
    fi
    printf '.'; sleep 3
done

# Running out of that loop used to fall straight through to the success banner,
# so an install that never got a certificate looked exactly like one that
# worked and the first symptom was a browser that would not connect.
if [ "$CERT_LIVE" = 0 ]; then
    printf '\n'
    warn "三分钟内没有拿到证书 —— https://$DOMAIN 暂时打不开。"
    warn "面板本身已经装好并在运行。常见原因是下面两种之一："
    warn "  · 80 端口从公网访问不到（ACME 验证需要它）"
    warn "  · $DOMAIN 走了代理型 CDN，没有直接解析到这台机器"
    warn "具体原因见：journalctl -u skysbx-panel | grep -i acme"
    warn "certmagic 会一直重试，所以把原因解决掉就行，不用重装。"
fi

if [ "$NEED_ADMIN" = yes ]; then
    LOGIN_LINE="登录    https://${DOMAIN}/login   用户名 ${ADMIN_USER}"
    NEXT_LINE="下一步：登录面板，添加一个节点，复制它的接入令牌。"
else
    LOGIN_LINE="登录    https://${DOMAIN}/login"
    NEXT_LINE="下一步：登录面板。忘了密码？${ROOT}/skysbx-panel -db ${ROOT}/skysbx.db -set-admin <用户名>"
fi

cat <<EOF

${GRN}skysbx 面板
===========
地址    https://${DOMAIN}
${LOGIN_LINE}
数据    ${ROOT}/skysbx.db          ← 面板的全部状态都在这一个文件里

日志    journalctl -u skysbx-panel -f

维护    skysbx（菜单）、skysbx version、skysbx upgrade

${NEXT_LINE}${RST}
EOF
