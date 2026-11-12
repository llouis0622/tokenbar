#!/bin/sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

ACTION="${1:-}"
SOURCE="${2:-}"
OWNER="${3:-}"
DEST=/Library/PrivilegedHelperTools/io.github.llouis0622.tokenbar.fan
RULE=/etc/sudoers.d/tokenbar-fan

[ "$(id -u)" = "0" ] || exit 77

case "$ACTION" in
install)
    case "$OWNER" in
        ""|-*|*[!A-Za-z0-9_.-]*) exit 64 ;;
    esac
    id -u "$OWNER" >/dev/null
    if [ ! -f "$SOURCE" ] || [ -L "$SOURCE" ]; then
        exit 65
    fi
    mkdir -p /Library/PrivilegedHelperTools
    install -o root -g wheel -m 0755 "$SOURCE" "$DEST"
    DRAFT="$(mktemp /private/tmp/tokenbar-fan.XXXXXX)"
    printf '%s ALL=(root) NOPASSWD: %s\n' "$OWNER" "$DEST" > "$DRAFT"
    if visudo -cf "$DRAFT" >/dev/null 2>&1; then
        install -o root -g wheel -m 0440 "$DRAFT" "$RULE"
        rm -f "$DRAFT"
    else
        rm -f "$DRAFT" "$DEST"
        exit 66
    fi
    ;;
uninstall)
    if [ -x "$DEST" ]; then
        "$DEST" auto all || true
    fi
    rm -f "$DEST" "$RULE"
    ;;
*)
    exit 64
    ;;
esac
