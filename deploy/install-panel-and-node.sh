#!/usr/bin/env bash
# Install the panel and a node on the same host, in one pass.
#
# Two programs that normally live on different machines, so the things that
# only collide when they share one are this script's whole reason to exist:
#
#   - The panel owns 80 and 443. It terminates its own TLS and answers the ACME
#     challenge itself, so the node's inbounds cannot have either port. Reality
#     goes on 8443 by default, which is what the panel picks anyway.
#   - certbot --standalone also wants 80, and would lose to the panel every
#     time. So the node is installed without a certificate unless --cf-token is
#     given, in which case DNS-01 needs no port at all. Reality and Shadowsocks
#     need no certificate; only AnyTLS does.
#   - The node needs a join token, which does not exist until the panel is up
#     and a node record has been created. This script does that over the panel's
#     own HTTP API, with the administrator it just set, so nobody has to
#     copy-paste a token between two terminals.
#
# Both halves keep their own installers and their own lifecycle. --upgrade,
# --uninstall and --purge are deliberately not wrapped here: they mean different
# things for a panel (a database) and a node (a certificate), and one flag that
# quietly did both to a machine holding both is a way to lose a database.
set -euo pipefail

ROOT=${SKYSBX_ROOT:-/opt/skysbx}
DOMAIN=""
EMAIL=""
NODE_NAME=""
NODE_DOMAIN=""
CF_TOKEN=""
TOKEN=""
PANEL_SRC=""
PANEL_SRC_GIVEN=0
NODE_SRC=""
NODE_SRC_GIVEN=0

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
BLD=$(printf '\033[1m');  RST=$(printf '\033[0m')
say()  { printf '\n%s==>%s %s%s%s\n' "$GRN" "$RST" "$BLD" "$*" "$RST"; }
ok()   { printf '%s  完成%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s 警告%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s 错误%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# One trap, registered once. Two `trap ... EXIT` lines would not stack — the
# second silently replaces the first, leaking whatever the first was holding.
NODE_TMP=""; COOKIE=""
cleanup() {
    [ -n "$NODE_TMP" ] && rm -rf "$NODE_TMP"
    [ -n "$COOKIE" ] && rm -f "$COOKIE"
    return 0
}
trap cleanup EXIT

usage() {
    cat <<EOF
在同一台机器上安装 skysbx 的面板和一个节点。

  --domain <域名>      面板域名，必须已经解析到本机            [不给会询问]
  --email <邮箱>       Let's Encrypt 联系邮箱                  [不给会询问]
  --node-name <名称>   本机节点记录的名称                      [默认 local]
  --node-domain <域名> 客户端访问这个节点用的域名              [默认同 --domain]
  --token <token>      跳过自动创建，直接用这个接入令牌。只在面板无法为我们
                       创建时才需要；正常情况下脚本会自己登录面板并建好节点。
  --cf-token <token>   Cloudflare API token。不给的话节点拿不到自己的证书 ——
                       certbot 的 standalone 模式需要 80 端口，而面板占着它。
                       这种情况下面板会把自己的证书共享给节点，AnyTLS 依然可用。
  --panel-src <目录>   用本地已有的检出，不再克隆
  --node-src <目录>    同上，用于节点

管理员在这里询问一次，并在任何服务开始监听之前就设置好。没有终端时，设置环境变量
SKYSBX_ADMIN_USER 和 SKYSBX_ADMIN_PASSWORD 即可无人值守安装。

装完之后两半各由自己的安装器管理，详见它们各自的 --help。
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --domain)     DOMAIN=$2; shift 2 ;;
        --email)      EMAIL=$2; shift 2 ;;
        --node-name)  NODE_NAME=$2; shift 2 ;;
        --node-domain) NODE_DOMAIN=$2; shift 2 ;;
        --token)      TOKEN=$2; shift 2 ;;
        --cf-token)   CF_TOKEN=$2; shift 2 ;;
        --panel-src)  PANEL_SRC=$2; PANEL_SRC_GIVEN=1; shift 2 ;;
        --node-src)   NODE_SRC=$2; NODE_SRC_GIVEN=1; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die "无法识别的参数：$1" ;;
    esac
done

# ─────────────────────────────── preflight ────────────────────────────────

say "环境检查"
[ "$(id -u)" = 0 ] || die "请用 root 运行"

# Before anything is fetched or installed. Refusing after a clone and an
# apt-get is the same refusal, several minutes later.
if systemctl is-enabled --quiet skysbx-panel 2>/dev/null; then
    die "这台机器上已经装了面板。
  本脚本用于全新的机器。要给已有的面板添加节点，请先在面板里创建该节点，
  再用它的接入令牌 运行节点安装器。"
fi

command -v curl >/dev/null || { apt-get update -qq; apt-get install -y -qq curl; }
command -v git  >/dev/null || apt-get install -y -qq git

# The panel half is this checkout by default: install-panel-and-node.sh ships inside the
# panel repository, so the sources are already here. The node half has to come
# from somewhere, so clone it unless a checkout was named.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PANEL_SRC=${PANEL_SRC:-$HERE}
[ -f "$PANEL_SRC/deploy/install-panel.sh" ] \
    || die "$PANEL_SRC/deploy/install-panel.sh 不存在，找不到面板安装器"

if [ -z "$NODE_SRC" ]; then
    NODE_REPO=${SKYSBX_NODE_REPO:-https://github.com/kosje/skysbx-node.git}
    NODE_REF=${SKYSBX_REF:-main}
    NODE_TMP=$(mktemp -d)
    say "正在获取节点源码"
    git clone -q --branch "$NODE_REF" --depth 1 "$NODE_REPO" "$NODE_TMP/skysbx-node" \
        || die "无法克隆 $NODE_REPO"
    NODE_SRC=$NODE_TMP/skysbx-node
    ok "$(git -C "$NODE_SRC" rev-parse --short HEAD)"
fi
[ -f "$NODE_SRC/deploy/install-node.sh" ] \
    || die "$NODE_SRC/deploy/install-node.sh 不存在，找不到节点安装器"

PANEL_INSTALLER=$PANEL_SRC/deploy/install-panel.sh
NODE_INSTALLER=$NODE_SRC/deploy/install-node.sh


if [ -z "$DOMAIN" ]; then
    [ -t 0 ] || { usage; die "必须提供 --domain"; }
    printf '  面板域名（必须已经解析到本机）：'
    read -r DOMAIN
fi
[ -n "$DOMAIN" ] || die "必须提供 --domain"
if [ -z "$EMAIL" ] && [ -t 0 ]; then
    printf '  Let'"'"'s Encrypt 联系邮箱（可留空跳过）：'
    read -r EMAIL
fi
NODE_NAME=${NODE_NAME:-local}

# Collected here rather than left to the panel installer, because this script
# needs them a minute later to log in and mint the node's token. Passing them
# down means the operator is asked exactly once.
ADMIN_USER=${SKYSBX_ADMIN_USER:-}
ADMIN_PASS=${SKYSBX_ADMIN_PASSWORD:-}
if [ -z "$ADMIN_PASS" ]; then
    [ -t 0 ] || die "当前没有终端，无法询问管理员账号；
  请设置环境变量 SKYSBX_ADMIN_USER 和 SKYSBX_ADMIN_PASSWORD"
    printf '  管理员用户名（默认 admin）：'
    read -r ADMIN_USER || die "没有提供管理员用户名"
    ADMIN_USER=${ADMIN_USER:-admin}
    tries=0
    while :; do
        tries=$((tries + 1))
        [ "$tries" -le 5 ] || die "管理员密码输入次数过多，已放弃"
        printf '  管理员密码（至少 12 位）：'
        stty -echo 2>/dev/null || true
        read -r ADMIN_PASS || { stty echo 2>/dev/null || true; die "没有提供密码"; }
        stty echo 2>/dev/null || true; printf '\n'
        [ "${#ADMIN_PASS}" -ge 12 ] || { warn "太短了"; ADMIN_PASS=""; continue; }
        printf '  再输入一次：'
        stty -echo 2>/dev/null || true
        read -r ADMIN_PASS2 || { stty echo 2>/dev/null || true; die "没有提供密码"; }
        stty echo 2>/dev/null || true; printf '\n'
        [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] || { warn "两次输入不一致"; ADMIN_PASS=""; continue; }
        ADMIN_PASS2=""; break
    done
fi
ADMIN_USER=${ADMIN_USER:-admin}
[ "${#ADMIN_PASS}" -ge 12 ] || die "管理员密码至少要 12 位"

if [ -z "$CF_TOKEN" ]; then
    warn "没有提供 --cf-token：这个节点不会拥有自己的证书。"
    warn "这里用不了 certbot 的 standalone 模式 —— 80 端口被面板占着。"
    warn "面板会把自己的证书共享给节点，所以 AnyTLS 依然可用：那张证书"
    warn "签的正是客户端访问这个节点时用的同一个域名。新建 AnyTLS 入站时"
    warn "把证书路径留空即可使用。"
fi

# ─────────────────────────────── the panel ────────────────────────────────

say "正在安装面板"
PANEL_ARGS=(--domain "$DOMAIN")
[ -n "$EMAIL" ] && PANEL_ARGS+=(--email "$EMAIL")
# --src only when the operator named a checkout. PANEL_SRC is otherwise just
# the clone this script is running from, and passing that as --src tells the
# installer never to look for a published binary — which is how the download
# path ended up unreachable from here even though both halves supported it.
[ "$PANEL_SRC_GIVEN" = 1 ] && PANEL_ARGS+=(--src "$PANEL_SRC")
# Without a Cloudflare token the node cannot get a certificate of its own —
# certbot's standalone challenge wants port 80 and the panel has it — so AnyTLS
# would be unusable on this host. The panel's certificate is for the same name
# the node is reached on, so it is the right one; the panel is told to write it
# where the node's AnyTLS inbounds already look. With --cf-token the node gets
# its own over DNS-01 and the panel must not overwrite it.
if [ -z "$CF_TOKEN" ]; then
    PANEL_ARGS+=(--export-cert)
fi

SKYSBX_ADMIN_USER="$ADMIN_USER" SKYSBX_ADMIN_PASSWORD="$ADMIN_PASS" \
    SKYSBX_LAUNCHER_SRC="$PANEL_SRC" \
    bash "$PANEL_INSTALLER" "${PANEL_ARGS[@]}" </dev/null

# ──────────────────────────── the node's token ────────────────────────────

# The name clients will reach this node on. Same host as the panel, so the
# panel's own domain is the sane default; --node-domain overrides it for the
# case where the node answers on a second name.
NODE_DOMAIN=${NODE_DOMAIN:-$DOMAIN}

if [ -n "$TOKEN" ]; then
    ok "使用 --token 提供的接入令牌"
else
    say "正在为本机创建节点记录"
    COOKIE=$(mktemp)

    # The panel answers on 443 the moment it is up, but the certificate arrives
    # over ACME a beat later; --insecure here is about that beat, not about trust —
    # this is a request to localhost's own service, over the loopback of the machine
    # we are already root on.
    for i in $(seq 1 30); do
        curl -sk --max-time 5 -o /dev/null "https://$DOMAIN/login" && break
        if [ "$i" = 30 ]; then
            # "It never started" and "it is running but has no certificate to
            # serve" are indistinguishable from out here and lead to entirely
            # different things to go and look at, so say which one it is.
            if systemctl is-active --quiet skysbx-panel 2>/dev/null; then
                die "面板在运行，但没有在 https://$DOMAIN 上提供 TLS。
  这几乎总是证书的问题。查看原因：
      journalctl -u skysbx-panel | grep -i acme
  ACME 验证需要 80 端口能从公网访问，且域名要直接解析到这台机器 ——
  前面套一层代理型 CDN 是不行的。"
            fi
            die "面板没有在 https://$DOMAIN 上启动
  journalctl -u skysbx-panel 会说明原因。"
        fi
        sleep 2
    done
    ok "面板已响应"

    # POST /login is deliberately outside the CSRF gate — there is no session
    # yet for a token to be bound to — so cookies are all the login needs.
    curl -sk -c "$COOKIE" -o /dev/null "https://$DOMAIN/login" || true
    curl -sk -b "$COOKIE" -c "$COOKIE" -o /dev/null -X POST "https://$DOMAIN/login" \
        --data-urlencode "username=$ADMIN_USER" \
        --data-urlencode "password=$ADMIN_PASS" || true

    # Every state-changing route behind a session is CSRF-gated and POST /nodes
    # is one of them: without this header the panel answers 403 and no token is
    # ever minted. The value is the skysbx_csrf cookie the login just set — the
    # same value the rendered form would carry in its hidden field. Read it from
    # the jar rather than by parsing HTML; HttpOnly entries are stored there too,
    # just with a marker on the domain column, so the name/value columns hold.
    CSRF=$(awk '$6 == "skysbx_csrf" { print $7 }' "$COOKIE" 2>/dev/null | tail -1 || true)
    CSRF_ARGS=()
    [ -n "$CSRF" ] && CSRF_ARGS=(-H "X-CSRF-Token: $CSRF")

    # The address a node record carries is what subscriptions hand to clients.
    TOKEN=$(curl -sk -b "$COOKIE" -X POST "https://$DOMAIN/nodes" \
        ${CSRF_ARGS[@]+"${CSRF_ARGS[@]}"} \
        --data-urlencode "name=$NODE_NAME" \
        --data-urlencode "address=$NODE_DOMAIN" \
        --data-urlencode "country=XX" 2>/dev/null \
        | sed -n 's/.*<code>\([A-Za-z0-9_-]\{32,\}\)<\/code>.*/\1/p' | head -1 || true)

    if [ -n "$TOKEN" ]; then
        ok "节点 '$NODE_NAME' 已创建"
    else
        # Minting is a convenience, not the install. A panel too old for this
        # route, a changed form, a CSRF scheme this script does not know about —
        # none of those are a reason to abandon a panel that is installed and
        # running. Fall back to the thing a human would have done anyway.
        warn "无法自动创建节点记录"
        printf '  请到 https://%s/nodes 创建节点，然后把它的接入令牌 粘贴到这里。\n' "$DOMAIN"
        if [ -t 0 ]; then
            printf '  token: '
            read -r TOKEN || TOKEN=""
        fi
        [ -n "$TOKEN" ] || die "没有节点接入令牌，也没有终端可以询问。
  面板已经装好并在运行。请手动完成：到 https://$DOMAIN/nodes 创建节点，
  然后带 --token <token> 重新运行本脚本（已完成的步骤会跳过）。"
        ok "使用你粘贴的接入令牌"
    fi
fi

# ──────────────────────────────── the node ────────────────────────────────

say "正在安装节点"
NODE_ARGS=(--panel "https://$DOMAIN" --token "$TOKEN")
# Same distinction as the panel above: a checkout we cloned ourselves is not an
# instruction to build.
[ "$NODE_SRC_GIVEN" = 1 ] && NODE_ARGS+=(--src "$NODE_SRC")
# --domain only alongside --cf-token. Passing it without one would send certbot
# at port 80, which the panel is holding, and the only result would be a
# confusing failure in the middle of an otherwise good install.
if [ -n "$CF_TOKEN" ]; then
    NODE_ARGS+=(--domain "$NODE_DOMAIN" --cf-token "$CF_TOKEN")
    [ -n "$EMAIL" ] && NODE_ARGS+=(--email "$EMAIL")
fi

SKYSBX_LAUNCHER_SRC="$NODE_SRC" bash "$NODE_INSTALLER" "${NODE_ARGS[@]}" </dev/null

# ───────────────────────────────── summary ────────────────────────────────

ADMIN_PASS=""
sleep 3
cat <<EOF

${GRN}skysbx —— 面板和节点，同一台机器
==================================
登录    https://${DOMAIN}/login   用户名 ${ADMIN_USER}
数据    ${ROOT}/skysbx.db

端口    80、443   面板（自己终结 TLS，自己签证书）
        8443 起   节点的入站 —— 443 被占，所以 Reality 默认落在 8443

协议    $( [ -n "$CF_TOKEN" ] && echo "三个都可用（节点通过 DNS-01 拿到了自己的证书）" \
           || echo "三个都可用。AnyTLS 用的是面板的证书 —— 签的就是这个域名，
        新建入站时把证书路径留空即可。" )

下一步  打开面板，给 '${NODE_NAME}' 节点加一个入站，再建一个用户。

日志    journalctl -u skysbx-panel -f
        journalctl -u skysbx-node -f

两半各由自己的安装器升级和卸载。这里没有「一次清除两边」的选项：在这台机器上，
那个动作同时意味着「删掉数据库」和「删掉证书」，不该由一个开关代劳。

维护用 skysbx 命令：skysbx（菜单）、skysbx version、skysbx upgrade panel${RST}
EOF
