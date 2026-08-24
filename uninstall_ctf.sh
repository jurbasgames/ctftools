#!/bin/bash
# CTF Tools Uninstaller
# Removes the configured CTF user and their home directory.
# Run with: sudo bash uninstall_ctf.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "${CTF_USER:-}" && -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
fi
CTF_USER="${CTF_USER:-ctf}"

if [[ $EUID -ne 0 ]]; then
    echo "Run this script with sudo: sudo bash $0"
    exit 1
fi

if [[ "$CTF_USER" == "root" || "$CTF_USER" == "0" ]]; then
    echo "[!] Refusing to remove protected user '$CTF_USER'." >&2
    exit 1
fi
if [[ ! "$CTF_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    echo "[!] Invalid CTF_USER: '$CTF_USER'." >&2
    exit 1
fi

if ! id -- "$CTF_USER" &>/dev/null; then
    echo "User '$CTF_USER' does not exist — nothing to do."
    exit 0
fi
if [[ "$(id -u -- "$CTF_USER")" == "0" ]]; then
    echo "[!] Refusing to remove UID 0 account '$CTF_USER'." >&2
    exit 1
fi

TARGET_HOME="$(getent passwd "$CTF_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" || "$TARGET_HOME" == "/" ]]; then
    echo "[!] Refusing unsafe home directory for '$CTF_USER': '$TARGET_HOME'." >&2
    exit 1
fi

echo "[*] Removing user '$CTF_USER' and home directory '$TARGET_HOME'..."
pkill -u "$CTF_USER" 2>/dev/null || true
sleep 2
pkill -9 -u "$CTF_USER" 2>/dev/null || true
userdel -r -- "$CTF_USER"

if id -- "$CTF_USER" &>/dev/null; then
    echo "[!] User '$CTF_USER' still exists after userdel." >&2
    exit 1
fi
if [[ -e "$TARGET_HOME" ]]; then
    echo "[!] Home directory still exists after userdel: $TARGET_HOME" >&2
    exit 1
fi

echo "[+] Done. User '$CTF_USER' and '$TARGET_HOME' removed."
echo ""
echo "Note: system packages installed by install_ctf.sh (gdb, JDK, exiftool, etc.)"
echo "were intentionally left in place — remove them manually with apt if needed."
