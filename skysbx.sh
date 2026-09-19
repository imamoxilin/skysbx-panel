#!/bin/sh
# skysbx — one command to install and maintain skysbx on this host.
#
#   wget -qO- https://raw.githubusercontent.com/kosje/skysbx-panel/main/skysbx.sh | sh
#
# With no arguments it shows a menu of whatever makes sense for this host: the
# install choices when nothing is here yet, the lifecycle ones when something
# is. Installing leaves a copy at /usr/local/bin/skysbx, so afterwards the same
# menu is one word away.
#
# Everything it offers is also a direct command, because a menu is no good in a
# script:
#
#   skysbx install panel|node|both [installer options...]
#   skysbx version|upgrade|uninstall|purge [panel|node]
#
# It does no installing itself. Each choice hands over to the installer that
# owns that half, which is where the real work and the real documentation are.
set -eu

PANEL_RAW=${SKYSBX_PANEL_RAW:-https://raw.githubusercontent.com/kosje/skysbx-panel/main}
NODE_RAW=${SKYSBX_NODE_RAW:-https://raw.githubusercontent.com/kosje/skysbx-node/main}
ROOT=${SKYSBX_ROOT:-/opt/skysbx}

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
BLD=$(printf '\033[1m');  DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
say()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s warn%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s fail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

have_panel() { [ -x "$ROOT/skysbx-panel" ]; }
have_node()  { [ -x "$ROOT/skysbx-node" ]; }

# ─────────────────────────────── handing over ──────────────────────────────

# Downloaded to a file rather than piped into sh, so the installer inherits
# this script's stdin — which is the terminal when there is one. Piping would
# point its stdin at the download and take away the thing it asks questions on.
run_installer() {
    url=$1; shift
    tmp=$(mktemp)
    if ! wget -qO- "$url" > "$tmp" 2>/dev/null && ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "cannot download $url"
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; die "downloaded nothing from $url"; }
    sh "$tmp" "$@"
    rc=$?
    rm -f "$tmp"
    return $rc
}

panel() { run_installer "$PANEL_RAW/install.sh" "$@"; }
node()  { run_installer "$NODE_RAW/install.sh" "$@"; }
both()  { run_installer "$PANEL_RAW/install-panel-and-node.sh" "$@"; }

# version is the one action worth answering without the network: it is what
# someone runs when something is wrong, and "cannot reach GitHub" is not a
# useful answer to "what is installed".
show_version() {
    any=0
    if have_panel; then "$ROOT/skysbx-panel" -version 2>/dev/null || true
        systemctl is-active --quiet skysbx-panel \
            && printf '  panel service running\n' || printf '  panel service stopped\n'
        any=1
    fi
    if have_node; then "$ROOT/skysbx-node" -version 2>/dev/null || true
        systemctl is-active --quiet skysbx-node \
            && printf '  node service running\n' || printf '  node service stopped\n'
        any=1
    fi
    [ "$any" = 1 ] || printf 'Nothing is installed at %s\n' "$ROOT"
}

# ──────────────────────────── choosing a half ──────────────────────────────

# Which half a lifecycle action applies to. On a host with only one there is
# nothing to ask. On a host with both, never assume: "uninstall" means a
# database to one half and a certificate to the other, and doing both because
# the answer was obvious to the script is how a database goes missing.
pick_half() {
    action=$1
    if have_panel && have_node; then
        printf '\n  Both halves are installed here. %s which?\n' "$action"
        printf '    1  panel\n    2  node\n    0  cancel\n'
        printf '  > '
        read -r h </dev/tty || h=0
        case "$h" in
            1) echo panel ;;
            2) echo node ;;
            *) echo "" ;;
        esac
        return
    fi
    have_panel && { echo panel; return; }
    have_node  && { echo node;  return; }
    echo ""
}

confirm_purge() {
    half=$1
    case "$half" in
      panel) what="the database — every user, node and subscription" ;;
      node)  what="this node's certificate and its environment file" ;;
    esac
    printf '\n%s  purge deletes %s.%s\n' "$RED" "$what" "$RST"
    printf '  There is no undo and no copy anywhere else.\n'
    printf '  Type %spurge%s to go ahead: ' "$BLD" "$RST"
    read -r answer </dev/tty || answer=""
    [ "$answer" = purge ]
}

lifecycle() {
    action=$1
    half=${2:-}
    if [ -z "$half" ]; then
        half=$(pick_half "$action")
        [ -n "$half" ] || { say "cancelled"; return 0; }
    fi
    case "$action" in
        upgrade)
            case "$half" in panel) panel --upgrade ;; node) node --upgrade ;; esac ;;
        uninstall)
            case "$half" in panel) panel --uninstall ;; node) node --uninstall ;; esac ;;
        purge)
            confirm_purge "$half" || { say "cancelled — nothing was deleted"; return 0; }
            case "$half" in panel) panel --purge ;; node) node --purge ;; esac ;;
    esac
}

# ─────────────────────────────────── menu ──────────────────────────────────

state_line() {
    if have_panel && have_node; then printf 'panel and node'
    elif have_panel; then printf 'panel'
    elif have_node; then printf 'node'
    else printf 'nothing yet'
    fi
}

menu() {
    installed=0
    { have_panel || have_node; } && installed=1

    printf '\n%sskysbx%s   %son this host: %s%s\n\n' \
        "$BLD" "$RST" "$DIM" "$(state_line)" "$RST"

    if [ "$installed" = 0 ]; then
        printf '  1  Install the panel\n'
        printf '  2  Install a node\n'
        printf '  3  Install both, here\n'
    else
        # Installing over something already here is how two panels end up
        # fighting over port 443, so the installed case leads with maintenance.
        printf '  1  Version\n'
        printf '  2  Upgrade\n'
        printf '  3  Uninstall      %skeeps the data%s\n' "$DIM" "$RST"
        printf '  4  Purge          %sdeletes the data%s\n' "$DIM" "$RST"
        have_panel || printf '  5  Add the panel here\n'
        have_node  || printf '  5  Add a node here\n'
    fi
    printf '  0  Quit\n\n  > '

    read -r choice </dev/tty || choice=0
    printf '\n'

    if [ "$installed" = 0 ]; then
        case "$choice" in
            1) panel ;;
            2) node ;;
            3) both ;;
            0|"") say "nothing done" ;;
            *) die "no such choice: $choice" ;;
        esac
    else
        case "$choice" in
            1) show_version ;;
            2) lifecycle upgrade ;;
            3) lifecycle uninstall ;;
            4) lifecycle purge ;;
            # An if, not `have_panel && node || panel`: that runs the panel
            # installer as well whenever the node installer exits non-zero.
            5) if have_panel; then node; else panel; fi ;;
            0|"") say "nothing done" ;;
            *) die "no such choice: $choice" ;;
        esac
    fi
}

usage() {
    cat <<EOF
skysbx — install and maintain skysbx on this host

  skysbx                              the menu
  skysbx install panel|node|both      ... plus any installer options
  skysbx version                      what is installed here
  skysbx upgrade   [panel|node]
  skysbx uninstall [panel|node]       keeps the data
  skysbx purge     [panel|node]       deletes the data

On a host with both halves, the lifecycle commands ask which one if you do not
say. They are never applied to both at once: "uninstall" means a database to
one half and a certificate to the other.

Installer options pass straight through, so this is still the way in:

  skysbx install both --domain panel.example.com --cf-token <token>
EOF
}

# ───────────────────────────────── dispatch ────────────────────────────────

# Help is the one thing worth answering to anyone: being told to sudo before
# being told what the command does helps nobody.
case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
esac

[ "$(id -u)" = 0 ] || die "run as root"

case "${1:-}" in
    version)   show_version; exit 0 ;;
    install)
        shift
        target=${1:-}; [ $# -gt 0 ] && shift
        case "$target" in
            panel) panel "$@" ;;
            node)  node "$@" ;;
            both)  both "$@" ;;
            *) usage; die "install what? panel, node or both" ;;
        esac
        exit 0 ;;
    upgrade|uninstall|purge)
        action=$1; shift
        half=${1:-}
        case "$half" in
            panel|node) ;;
            "") ;;
            *) usage; die "not a half: $half" ;;
        esac
        # Naming the half is what makes this scriptable; leaving it out is what
        # needs a terminal, because that is when there is a question to ask.
        if [ -z "$half" ] && have_panel && have_node && ! [ -t 0 ]; then
            die "$action which half? this host has both, and there is no terminal to ask on"
        fi
        lifecycle "$action" "$half"
        exit 0 ;;
    "") ;;
    *) usage; die "unknown command: $1" ;;
esac

# The menu needs a keyboard. Piped in from the web, stdin is the downloaded
# script, so the terminal has to be reached for directly — and a host without
# one gets told what to type instead of a prompt that can never be answered.
if ! ( exec 3>/dev/tty ) 2>/dev/null; then
    usage
    die "no terminal for the menu; give a command instead"
fi
menu
