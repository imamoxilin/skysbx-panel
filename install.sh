#!/bin/sh
# One-line installer for the Install skysbx-panel and skysbx-node.
#
#   wget -qO- https://raw.githubusercontent.com/imamoxilin/skysbx-panel/main/install.sh | sh
#
# Arguments go through to deploy/install-panel.sh after `-s --`:
#
#   ... | sh -s -- --domain panel.example.com --email you@example.com
#   ... | sh -s -- --version      what is installed
#   ... | sh -s -- --upgrade      rebuild and restart; the database is untouched
#   ... | sh -s -- --uninstall    remove the service; keep the database
#   ... | sh -s -- --purge        remove everything, database included
#
# This file exists only to fetch the repository and hand over. Everything real
# is in deploy/install-panel.sh, which is worth reading before running either.
set -eu

REPO=${SKYSBX_REPO:-https://github.com/imamoxilin/skysbx-panel.git}
REF=${SKYSBX_REF:-main}

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); RST=$(printf '\033[0m')
say() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
die() { printf '%s 错误%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 运行（sudo sh -c \"\$(wget -qO- ...)\")"

if ! command -v git >/dev/null 2>&1; then
    say "正在安装 git"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq git
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q git
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q git
    else
        die "请先安装 git"
    fi
fi

SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
say "正在获取 $REPO@$REF"
git clone -q --branch "$REF" --depth 1 "$REPO" "$SRC/skysbx-panel" \
    || die "无法克隆 $REPO"

# A pipeline leaves stdin pointing at the downloaded script, not the terminal,
# so the installer would find nothing to prompt on and refuse. Reattach the
# terminal if there is one.
#
# The test is a subshell on purpose: on a host with no controlling terminal,
# opening /dev/tty fails, and under dash a failed redirection in the current
# shell is fatal — which used to kill this script silently, with no output at
# all, in the one situation it most needed to explain itself.
#
# bash, not sh: this launcher is POSIX because it is piped into whatever /bin/sh
# is, but the installer it hands over to is bash — on Debian /bin/sh is dash,
# which fails on the first line with "Illegal option -o pipefail".
command -v bash >/dev/null 2>&1 || die "需要 bash"
# Handed over in the environment, not as --src: this only says "the clone I had
# to make to find the installer is here, reuse it if you end up building".
# --src means "build this checkout rather than anything published", which is a
# different instruction and not one the launcher is entitled to give.
SKYSBX_LAUNCHER_SRC="$SRC/skysbx-panel"
export SKYSBX_LAUNCHER_SRC

if ( exec 3>/dev/tty ) 2>/dev/null; then
    exec bash "$SRC/skysbx-panel/deploy/install-panel.sh" "$@" </dev/tty
fi
exec bash "$SRC/skysbx-panel/deploy/install-panel.sh" "$@"
