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
ok()   { printf '%s   ok%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s warn%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s fail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

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
Install the skysbx panel and a node on this one host.

  --domain <host>      the panel's domain; must already resolve here   [asked]
  --email <addr>       Let's Encrypt contact                           [asked]
  --node-name <name>   name for this host's node record          [default local]
  --node-domain <host> the name clients reach this node on   [default --domain]
  --token <token>      skip minting and use this node join token. Only needed
                       when the panel cannot mint one for us; normally the
                       script logs in and creates the node record itself.
  --cf-token <token>   Cloudflare API token. Without one the node gets no
                       certificate, because certbot's standalone mode needs
                       port 80 and the panel is holding it — Reality and
                       Shadowsocks still work, AnyTLS does not.
  --panel-src <dir>    use a checkout instead of cloning
  --node-src <dir>     same, for the node

The administrator is asked for here and set before anything listens. Set
SKYSBX_ADMIN_USER and SKYSBX_ADMIN_PASSWORD to install without a terminal.

Afterwards each half is managed by its own installer; see their --help.
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
        *)            usage; die "unknown argument: $1" ;;
    esac
done

# ─────────────────────────────── preflight ────────────────────────────────

say "preflight"
[ "$(id -u)" = 0 ] || die "run as root"

# Before anything is fetched or installed. Refusing after a clone and an
# apt-get is the same refusal, several minutes later.
if systemctl is-enabled --quiet skysbx-panel 2>/dev/null; then
    die "a panel is already installed here.
  This script is for a fresh host. To add a node to an existing panel, create
  the node in the panel and run the node installer with its token."
fi

command -v curl >/dev/null || { apt-get update -qq; apt-get install -y -qq curl; }
command -v git  >/dev/null || apt-get install -y -qq git

# The panel half is this checkout by default: install-panel-and-node.sh ships inside the
# panel repository, so the sources are already here. The node half has to come
# from somewhere, so clone it unless a checkout was named.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PANEL_SRC=${PANEL_SRC:-$HERE}
[ -f "$PANEL_SRC/deploy/install-panel.sh" ] \
    || die "no panel installer at $PANEL_SRC/deploy/install-panel.sh"

if [ -z "$NODE_SRC" ]; then
    NODE_REPO=${SKYSBX_NODE_REPO:-https://github.com/kosje/skysbx-node.git}
    NODE_REF=${SKYSBX_REF:-main}
    NODE_TMP=$(mktemp -d)
    say "fetching the node"
    git clone -q --branch "$NODE_REF" --depth 1 "$NODE_REPO" "$NODE_TMP/skysbx-node" \
        || die "cannot clone $NODE_REPO"
    NODE_SRC=$NODE_TMP/skysbx-node
    ok "$(git -C "$NODE_SRC" rev-parse --short HEAD)"
fi
[ -f "$NODE_SRC/deploy/install-node.sh" ] \
    || die "no node installer at $NODE_SRC/deploy/install-node.sh"

PANEL_INSTALLER=$PANEL_SRC/deploy/install-panel.sh
NODE_INSTALLER=$NODE_SRC/deploy/install-node.sh


if [ -z "$DOMAIN" ]; then
    [ -t 0 ] || { usage; die "--domain is required"; }
    printf '  Panel domain (must already resolve here): '
    read -r DOMAIN
fi
[ -n "$DOMAIN" ] || die "--domain is required"
if [ -z "$EMAIL" ] && [ -t 0 ]; then
    printf "  Let's Encrypt contact email [skip]: "
    read -r EMAIL
fi
NODE_NAME=${NODE_NAME:-local}

# Collected here rather than left to the panel installer, because this script
# needs them a minute later to log in and mint the node's token. Passing them
# down means the operator is asked exactly once.
ADMIN_USER=${SKYSBX_ADMIN_USER:-}
ADMIN_PASS=${SKYSBX_ADMIN_PASSWORD:-}
if [ -z "$ADMIN_PASS" ]; then
    [ -t 0 ] || die "no terminal to ask for the administrator on;
  set SKYSBX_ADMIN_USER and SKYSBX_ADMIN_PASSWORD"
    printf '  Administrator username [admin]: '
    read -r ADMIN_USER || die "no administrator given"
    ADMIN_USER=${ADMIN_USER:-admin}
    tries=0
    while :; do
        tries=$((tries + 1))
        [ "$tries" -le 5 ] || die "giving up on the administrator password"
        printf '  Administrator password (at least 12 characters): '
        stty -echo 2>/dev/null || true
        read -r ADMIN_PASS || { stty echo 2>/dev/null || true; die "no password given"; }
        stty echo 2>/dev/null || true; printf '\n'
        [ "${#ADMIN_PASS}" -ge 12 ] || { warn "too short"; ADMIN_PASS=""; continue; }
        printf '  Repeat it: '
        stty -echo 2>/dev/null || true
        read -r ADMIN_PASS2 || { stty echo 2>/dev/null || true; die "no password given"; }
        stty echo 2>/dev/null || true; printf '\n'
        [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] || { warn "they do not match"; ADMIN_PASS=""; continue; }
        ADMIN_PASS2=""; break
    done
fi
ADMIN_USER=${ADMIN_USER:-admin}
[ "${#ADMIN_PASS}" -ge 12 ] || die "the administrator password must be at least 12 characters"

if [ -z "$CF_TOKEN" ]; then
    warn "no --cf-token: this node gets no certificate of its own."
    warn "certbot's standalone mode cannot be used here — the panel holds port 80."
    warn "The panel will instead share its own certificate with the node, so"
    warn "AnyTLS still works: it is issued for the same name the node is reached"
    warn "on. Leave an AnyTLS inbound's certificate paths empty to use it."
fi

# ─────────────────────────────── the panel ────────────────────────────────

say "installing the panel"
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
    ok "using the node token given with --token"
else
    say "creating this host's node record"
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
                die "the panel is running but is not serving TLS on https://$DOMAIN.
  This is nearly always the certificate. To see why:
      journalctl -u skysbx-panel | grep -i acme
  The ACME challenge needs port 80 reachable from the internet, and the name
  must resolve straight here — a proxying CDN in front of it will not do."
            fi
            die "the panel did not come up at https://$DOMAIN
  journalctl -u skysbx-panel will say why."
        fi
        sleep 2
    done
    ok "panel is answering"

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
        ok "node '$NODE_NAME' created"
    else
        # Minting is a convenience, not the install. A panel too old for this
        # route, a changed form, a CSRF scheme this script does not know about —
        # none of those are a reason to abandon a panel that is installed and
        # running. Fall back to the thing a human would have done anyway.
        warn "could not create the node record automatically"
        printf '  Create a node at https://%s/nodes and paste its join token.\n' "$DOMAIN"
        if [ -t 0 ]; then
            printf '  token: '
            read -r TOKEN || TOKEN=""
        fi
        [ -n "$TOKEN" ] || die "no node token, and no terminal to ask on.
  The panel is installed and running. Finish by hand: create a node at
  https://$DOMAIN/nodes, then re-run this script with
  --token <token> (everything already done will be skipped)."
        ok "using the token you pasted"
    fi
fi

# ──────────────────────────────── the node ────────────────────────────────

say "installing the node"
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

${GRN}skysbx — panel and node, same host
==================================
Sign in   https://${DOMAIN}/login   as ${ADMIN_USER}
Data      ${ROOT}/skysbx.db

Ports     80, 443   the panel (its own TLS, its own ACME)
          8443+     the node's inbounds — 443 is taken, so Reality goes on 8443

Protocols $( [ -n "$CF_TOKEN" ] && echo "all three (the node has its own certificate, via DNS-01)" \
             || echo "all three. AnyTLS uses the panel's certificate, which is for
          this same name — leave an inbound's certificate paths empty." )

Next      open the panel, add an inbound to the '${NODE_NAME}' node, then a user.

Logs      journalctl -u skysbx-panel -f
          journalctl -u skysbx-node -f

Each half is upgraded and removed by its own installer; there is no combined
--purge, because on this host that flag would have to mean both "delete the
database" and "delete the certificate" at once.${RST}
EOF
