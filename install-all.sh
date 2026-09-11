#!/bin/sh
# One-line installer for the panel and a node on the same host.
#
#   wget -qO- https://raw.githubusercontent.com/kosje/skysbx-panel/main/install-all.sh | sh
#
# Arguments go through to deploy/install-all.sh after `-s --`:
#
#   ... | sh -s -- --domain panel.example.com --email you@example.com
#   ... | sh -s -- --domain panel.example.com --cf-token <cloudflare-token>
#
# The second form is worth understanding before choosing between them. The panel
# holds ports 80 and 443, so certbot's standalone mode — which wants 80 — cannot
# run here. Without a Cloudflare token this node gets no certificate, which
# costs AnyTLS and nothing else: Reality authenticates with its own key pair and
# Shadowsocks 2022 has no TLS layer.
#
# For a panel and node on separate machines, use install.sh in each repository
# instead. This script exists only for the case where they share one.
#
# Everything real is in deploy/install-all.sh, which is worth reading first.
set -eu

REPO=${SKYSBX_REPO:-https://github.com/kosje/skysbx-panel.git}
REF=${SKYSBX_REF:-main}

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); RST=$(printf '\033[0m')
say() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
die() { printf '%s fail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

if ! command -v git >/dev/null 2>&1; then
    say "installing git"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq git
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q git
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q git
    else
        die "install git first"
    fi
fi

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
say "fetching $REPO@$REF"
git clone -q --branch "$REF" --depth 1 "$REPO" "$SRC/skysbx-panel" \
    || die "cannot clone $REPO"

# A pipeline leaves stdin pointing at the downloaded script rather than the
# terminal, and this installer has questions to ask. Reattach the terminal if
# there is one; without one it falls back to SKYSBX_ADMIN_USER and
# SKYSBX_ADMIN_PASSWORD and says so if they are missing.
#
# bash, not sh: this launcher is POSIX because it is piped into whatever /bin/sh
# is, but what it hands over to is bash — on Debian /bin/sh is dash, which fails
# on the first line with "Illegal option -o pipefail".
command -v bash >/dev/null 2>&1 || die "bash is required"
if ( exec 3>/dev/tty ) 2>/dev/null; then
    exec bash "$SRC/skysbx-panel/deploy/install-all.sh" "$@" </dev/tty
fi
exec bash "$SRC/skysbx-panel/deploy/install-all.sh" "$@"
