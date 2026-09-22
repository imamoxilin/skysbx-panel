#!/bin/sh
# skysbx — one command to install and maintain skysbx on this host.
#
#   wget -qO- https://raw.githubusercontent.com/imamoxilin/skysbx-panel/main/skysbx.sh | sh
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
#
# Messages are in Chinese because that is who runs this. Comments stay in
# English: they are for whoever changes the script, not whoever runs it. The
# subcommands stay in English too — they are an interface other scripts type.
set -eu

PANEL_RAW=${SKYSBX_PANEL_RAW:-https://raw.githubusercontent.com/imamoxilin/skysbx-panel/main}
NODE_RAW=${SKYSBX_NODE_RAW:-https://raw.githubusercontent.com/kosje/skysbx-node/main}
ROOT=${SKYSBX_ROOT:-/opt/skysbx}

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
BLD=$(printf '\033[1m');  DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
say()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s 警告%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s 错误%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

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
        die "无法下载 $url"
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; die "从 $url 下载到的是空文件"; }
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
            && printf '  面板服务：运行中\n' || printf '  面板服务：已停止\n'
        any=1
    fi
    if have_node; then "$ROOT/skysbx-node" -version 2>/dev/null || true
        systemctl is-active --quiet skysbx-node \
            && printf '  节点服务：运行中\n' || printf '  节点服务：已停止\n'
        any=1
    fi
    [ "$any" = 1 ] || printf '%s 下没有安装任何组件\n' "$ROOT"
}

# ──────────────────────────── choosing a half ──────────────────────────────

# Which half a lifecycle action applies to. On a host with only one there is
# nothing to ask. On a host with both, never assume: "uninstall" means a
# database to one half and a certificate to the other, and doing both because
# the answer was obvious to the script is how a database goes missing.
#
# Prompts go to the terminal, not to stdout: the caller reads this function's
# stdout to learn which half was chosen, so anything printed there is swallowed
# into that variable instead of being shown. Asking a question nobody can see is
# worse than not asking.
pick_half() {
    action=$1
    if have_panel && have_node; then
        {
            printf '\n  这台机器上两半都装了，要%s哪一个？\n' "$action"
            printf '    1  面板\n    2  节点\n    0  取消\n'
            printf '  > '
        } >/dev/tty
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

# The word to type stays "purge", not a Chinese one: this is the moment to make
# someone stop and act deliberately, and switching input methods to answer is
# how a deliberate confirmation turns into a fumbled one.
confirm_purge() {
    half=$1
    case "$half" in
      panel) what="数据库 —— 所有用户、节点和订阅" ;;
      node)  what="这个节点的证书和它的环境文件" ;;
    esac
    printf '\n%s  清除会删掉%s。%s\n' "$RED" "$what" "$RST"
    printf '  没有撤销，别处也没有副本。\n'
    printf '  确定就输入 %spurge%s：' "$BLD" "$RST"
    read -r answer </dev/tty || answer=""
    [ "$answer" = purge ]
}

lifecycle() {
    action=$1
    half=${2:-}
    case "$action" in
        upgrade)   action_cn=升级 ;;
        uninstall) action_cn=卸载 ;;
        purge)     action_cn=清除 ;;
        *)         action_cn=$action ;;
    esac
    if [ -z "$half" ]; then
        half=$(pick_half "$action_cn")
        [ -n "$half" ] || { say "已取消"; return 0; }
    fi
    case "$action" in
        upgrade)
            case "$half" in panel) panel --upgrade ;; node) node --upgrade ;; esac ;;
        uninstall)
            case "$half" in panel) panel --uninstall ;; node) node --uninstall ;; esac ;;
        purge)
            confirm_purge "$half" || { say "已取消 —— 什么都没有删除"; return 0; }
            case "$half" in panel) panel --purge ;; node) node --purge ;; esac ;;
    esac
}

# ─────────────────────────────────── menu ──────────────────────────────────

state_line() {
    if have_panel && have_node; then printf '面板和节点'
    elif have_panel; then printf '面板'
    elif have_node; then printf '节点'
    else printf '尚未安装'
    fi
}

menu() {
    installed=0
    { have_panel || have_node; } && installed=1

    printf '\n%sskysbx%s   %s本机已装：%s%s\n\n' \
        "$BLD" "$RST" "$DIM" "$(state_line)" "$RST"

    if [ "$installed" = 0 ]; then
        printf '  1  安装面板\n'
        printf '  2  安装节点\n'
        printf '  3  在这台机器上同时安装两者\n'
    else
        # Installing over something already here is how two panels end up
        # fighting over port 443, so the installed case leads with maintenance.
        printf '  1  查看版本\n'
        printf '  2  升级\n'
        printf '  3  卸载        %s保留数据%s\n' "$DIM" "$RST"
        printf '  4  清除        %s删除数据%s\n' "$DIM" "$RST"
        have_panel || printf '  5  在这台机器上加装面板\n'
        have_node  || printf '  5  在这台机器上加装节点\n'
    fi
    printf '  0  退出\n\n  > '

    read -r choice </dev/tty || choice=0
    printf '\n'

    if [ "$installed" = 0 ]; then
        case "$choice" in
            1) panel ;;
            2) node ;;
            3) both ;;
            0|"") say "什么都没做" ;;
            *) die "没有这个选项：$choice" ;;
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
            0|"") say "什么都没做" ;;
            *) die "没有这个选项：$choice" ;;
        esac
    fi
}

usage() {
    cat <<EOF
skysbx —— 在这台机器上安装和维护 skysbx

  skysbx                              打开菜单
  skysbx install panel|node|both      安装，后面可直接跟安装器的参数
  skysbx version                      这台机器上装了什么
  skysbx upgrade   [panel|node]       升级
  skysbx uninstall [panel|node]       卸载，保留数据
  skysbx purge     [panel|node]       清除，删除数据

两半都装在同一台机器上时，上面几个动作如果没写是哪一半，会先问你。它们不会一次对两半
执行：「卸载」对有数据库的面板和对有证书的节点，不是同一个承诺。

安装器的参数原样透传，所以这仍然是完整的入口：

  skysbx install both --domain panel.example.com --cf-token <token>
EOF
}

# ───────────────────────────────── dispatch ────────────────────────────────

# Help is the one thing worth answering to anyone: being told to sudo before
# being told what the command does helps nobody.
case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
esac

[ "$(id -u)" = 0 ] || die "请用 root 运行"

case "${1:-}" in
    version)   show_version; exit 0 ;;
    install)
        shift
        target=${1:-}; [ $# -gt 0 ] && shift
        case "$target" in
            panel) panel "$@" ;;
            node)  node "$@" ;;
            both)  both "$@" ;;
            *) usage; die "要安装什么？panel、node 或 both" ;;
        esac
        exit 0 ;;
    upgrade|uninstall|purge)
        action=$1; shift
        half=${1:-}
        case "$half" in
            panel|node) ;;
            "") ;;
            *) usage; die "不是有效的组件名：$half（只能是 panel 或 node）" ;;
        esac
        # Naming the half is what makes this scriptable; leaving it out is what
        # needs a terminal, because that is when there is a question to ask.
        if [ -z "$half" ] && have_panel && have_node && ! [ -t 0 ]; then
            case "$action" in
                upgrade)   action_cn=升级 ;;
                uninstall) action_cn=卸载 ;;
                purge)     action_cn=清除 ;;
            esac
            die "要对哪一半执行 $action_cn？这台机器两半都装了，而当前没有终端可以询问"
        fi
        lifecycle "$action" "$half"
        exit 0 ;;
    "") ;;
    *) usage; die "无法识别的命令：$1" ;;
esac

# The menu needs a keyboard. Piped in from the web, stdin is the downloaded
# script, so the terminal has to be reached for directly — and a host without
# one gets told what to type instead of a prompt that can never be answered.
if ! ( exec 3>/dev/tty ) 2>/dev/null; then
    usage
    die "没有终端，菜单无法使用；请直接给出命令"
fi
menu
