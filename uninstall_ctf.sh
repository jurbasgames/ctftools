#!/bin/bash
# CTF Tools Uninstaller
# Removes only the account recorded as ctftools-managed and its home directory.
# Run with: sudo bash uninstall_ctf.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="/var/lib/ctftools"
STATE_FILE="$STATE_DIR/managed-user"

die() {
    echo "[!] $*" >&2
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    die "Run this script with sudo: sudo bash $0"
fi

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

parse_env_literal() {
    local raw first last
    raw="$(trim_whitespace "$1")"
    if (( ${#raw} >= 2 )); then
        first="${raw:0:1}"
        last="${raw: -1}"
        if [[ "$first" == "'" || "$first" == '"' ]]; then
            [[ "$last" == "$first" ]] \
                || die "Unterminated quoted value in $SCRIPT_DIR/.env"
            raw="${raw:1:${#raw}-2}"
        fi
    fi
    CONFIG_VALUE="$raw"
}

load_env_defaults() {
    local file="$1" line trimmed raw
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        trimmed="$(trim_whitespace "$line")"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?CTF_USER[[:space:]]*=(.*)$ ]]; then
            raw="${BASH_REMATCH[2]}"
            parse_env_literal "$raw"
            [[ -n "${CTF_USER:-}" ]] || CTF_USER="$CONFIG_VALUE"
        fi
    done < "$file"
}

if [[ -z "${CTF_USER:-}" ]] \
        && [[ -e "$SCRIPT_DIR/.env" || -L "$SCRIPT_DIR/.env" ]]; then
    if [[ ! -f "$SCRIPT_DIR/.env" || -L "$SCRIPT_DIR/.env" ]]; then
        die "Refusing non-regular or symlink .env: $SCRIPT_DIR/.env"
    fi
    load_env_defaults "$SCRIPT_DIR/.env"
fi

CTF_USER="${CTF_USER:-ctf}"
if [[ "$CTF_USER" == "root" || "$CTF_USER" == "0" ]]; then
    die "Refusing to remove protected user '$CTF_USER'."
fi
if [[ ! "$CTF_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ || ${#CTF_USER} -gt 32 ]]; then
    die "Invalid CTF_USER: '$CTF_USER'. Use a portable lowercase Linux account name."
fi

assert_state_storage_safe() {
    local owner mode
    if [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
        [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] \
            || die "Refusing unsafe state directory: $STATE_DIR"
        owner="$(stat -c '%u' -- "$STATE_DIR")"
        mode="$(stat -c '%a' -- "$STATE_DIR")"
        if [[ "$owner" != "0" ]] || (( (8#$mode & 022) != 0 )); then
            die "State directory must be root-owned and not group/world-writable: $STATE_DIR"
        fi
    fi
}

load_managed_state() {
    local owner mode extra
    local -a lines=()
    if [[ ! -e "$STATE_FILE" && ! -L "$STATE_FILE" ]]; then
        return 1
    fi
    assert_state_storage_safe
    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] \
        || die "Refusing unsafe managed-account state: $STATE_FILE"
    owner="$(stat -c '%u' -- "$STATE_FILE")"
    mode="$(stat -c '%a' -- "$STATE_FILE")"
    if [[ "$owner" != "0" ]] || (( (8#$mode & 022) != 0 )); then
        die "Managed-account state must be root-owned and not group/world-writable."
    fi
    mapfile -t lines < "$STATE_FILE"
    (( ${#lines[@]} == 1 )) || die "Malformed managed-account state."
    IFS=$'\t' read -r MANAGED_USER MANAGED_UID MANAGED_HOME extra <<< "${lines[0]}"
    if [[ -z "$MANAGED_USER" || ! "$MANAGED_UID" =~ ^[0-9]+$ \
            || -z "$MANAGED_HOME" || -n "$extra" ]]; then
        die "Malformed managed-account state."
    fi
}

STATE_PRESENT=0
if load_managed_state; then
    STATE_PRESENT=1
fi

if ! id -- "$CTF_USER" &>/dev/null; then
    if (( STATE_PRESENT )) && [[ "$MANAGED_USER" == "$CTF_USER" ]]; then
        die "Refusing no-op: managed state remains but the account is missing. Inspect '$MANAGED_HOME' and remove '$STATE_FILE' only after recovery."
    fi
    echo "User '$CTF_USER' does not exist — nothing to do."
    exit 0
fi

if (( ! STATE_PRESENT )); then
    die "User '$CTF_USER' is not recorded as a ctftools-managed account. Refusing to remove it."
fi
if [[ "$MANAGED_USER" != "$CTF_USER" ]]; then
    die "Managed state belongs to '$MANAGED_USER', not '$CTF_USER'. Refusing to remove either account."
fi

TARGET_UID="$(id -u -- "$CTF_USER")"
if [[ "$TARGET_UID" == "0" ]]; then
    die "Refusing to remove UID 0 account '$CTF_USER'."
fi
UID_MIN="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true)"
[[ "$UID_MIN" =~ ^[0-9]+$ ]] || UID_MIN=1000
if (( TARGET_UID < UID_MIN )); then
    die "Refusing to remove system UID $TARGET_UID account '$CTF_USER' (UID_MIN=$UID_MIN)."
fi

TARGET_HOME_RAW="$(getent passwd "$CTF_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME_RAW" || "$TARGET_HOME_RAW" != /* ]]; then
    die "Refusing unsafe home directory for '$CTF_USER': '$TARGET_HOME_RAW'."
fi
TARGET_HOME_LEX="$(realpath -ms -- "$TARGET_HOME_RAW")"
TARGET_HOME_PHYS="$(realpath -m -- "$TARGET_HOME_RAW")"
if [[ "$TARGET_HOME_PHYS" != "$TARGET_HOME_LEX" ]]; then
    die "Refusing home with a symlink component for '$CTF_USER': '$TARGET_HOME_RAW'."
fi
case "$TARGET_HOME_LEX" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/snap|/srv|/sys|/tmp|/usr|/var)
        die "Refusing protected home directory for '$CTF_USER': '$TARGET_HOME_LEX'."
        ;;
esac
if [[ "$MANAGED_UID" != "$TARGET_UID" || "$MANAGED_HOME" != "$TARGET_HOME_LEX" ]]; then
    die "Account UID/home does not match the root-owned ctftools state."
fi

if [[ -e "$TARGET_HOME_RAW" || -L "$TARGET_HOME_RAW" ]]; then
    [[ -d "$TARGET_HOME_RAW" && ! -L "$TARGET_HOME_RAW" ]] \
        || die "Refusing non-directory or symlink home for '$CTF_USER': '$TARGET_HOME_RAW'."
    HOME_UID="$(stat -c '%u' -- "$TARGET_HOME_RAW")"
    if [[ "$HOME_UID" != "$TARGET_UID" ]]; then
        die "Refusing to remove '$CTF_USER': home directory is owned by UID $HOME_UID, not $TARGET_UID."
    fi
    HOME_SIGNATURE="$(stat -Lc '%d:%i:%u' -- "$TARGET_HOME_RAW")"
else
    HOME_SIGNATURE="absent"
fi

assert_account_graph_safe() {
    local passwd_db account account_uid account_home account_home_lex
    if ! passwd_db="$(getent passwd)"; then
        die "Could not enumerate accounts before removing '$CTF_USER'."
    fi
    while IFS=: read -r account _password account_uid _gid _gecos account_home _shell; do
        [[ "$account" == "$CTF_USER" ]] && continue
        if [[ "$account_uid" == "$TARGET_UID" ]]; then
            die "Refusing to remove '$CTF_USER': UID $TARGET_UID is also used by account '$account'."
        fi
        [[ "$account_home" == /* ]] || continue
        account_home_lex="$(realpath -ms -- "$account_home")"
        if [[ "$account_home_lex" == "$TARGET_HOME_LEX" \
                || "$account_home_lex" == "$TARGET_HOME_LEX/"* \
                || "$TARGET_HOME_LEX" == "$account_home_lex/"* ]]; then
            die "Refusing to remove '$CTF_USER': home directory overlaps account '$account' ('$account_home')."
        fi
    done <<< "$passwd_db"
}

assert_no_home_mounts() {
    local _id _parent _device _root mount_encoded _rest mount_path mount_lex
    while read -r _id _parent _device _root mount_encoded _rest; do
        printf -v mount_path '%b' "$mount_encoded"
        mount_lex="$(realpath -ms -- "$mount_path")"
        if [[ "$mount_lex" == "$TARGET_HOME_LEX" \
                || "$mount_lex" == "$TARGET_HOME_LEX/"* ]]; then
            die "Refusing to remove '$CTF_USER': mount detected at or below home: '$mount_path'. Unmount it first."
        fi
    done < /proc/self/mountinfo
}

revalidate_target() {
    local current_uid current_home_raw current_home_lex current_home_phys current_signature
    id -- "$CTF_USER" &>/dev/null \
        || die "Account '$CTF_USER' disappeared during preflight; no userdel was run."
    current_uid="$(id -u -- "$CTF_USER")"
    current_home_raw="$(getent passwd "$CTF_USER" | cut -d: -f6)"
    current_home_lex="$(realpath -ms -- "$current_home_raw")"
    current_home_phys="$(realpath -m -- "$current_home_raw")"
    if [[ "$current_uid" != "$TARGET_UID" || "$current_home_lex" != "$TARGET_HOME_LEX" \
            || "$current_home_phys" != "$TARGET_HOME_LEX" ]]; then
        die "Account UID/home changed during preflight; no userdel was run."
    fi
    if [[ -e "$current_home_raw" || -L "$current_home_raw" ]]; then
        current_signature="$(stat -Lc '%d:%i:%u' -- "$current_home_raw")"
    else
        current_signature="absent"
    fi
    [[ "$current_signature" == "$HOME_SIGNATURE" ]] \
        || die "Home directory changed during preflight; no userdel was run."
    load_managed_state \
        || die "Managed-account state disappeared during preflight; no userdel was run."
    if [[ "$MANAGED_USER" != "$CTF_USER" || "$MANAGED_UID" != "$TARGET_UID" \
            || "$MANAGED_HOME" != "$TARGET_HOME_LEX" ]]; then
        die "Managed-account state changed during preflight; no userdel was run."
    fi
    assert_account_graph_safe
    assert_no_home_mounts
}

assert_account_graph_safe
assert_no_home_mounts
command -v pkill >/dev/null 2>&1 \
    || die "Required command 'pkill' is unavailable; no destructive action was taken."

echo "[*] Removing managed user '$CTF_USER' and home directory '$TARGET_HOME_LEX'..."
pkill -u "$TARGET_UID" 2>/dev/null || true
sleep 2
pkill -9 -u "$TARGET_UID" 2>/dev/null || true
revalidate_target

USERDEL_RC=0
if userdel -r -- "$CTF_USER"; then
    USERDEL_RC=0
else
    USERDEL_RC=$?
fi

FAILED=0
if id -- "$CTF_USER" &>/dev/null; then
    echo "[!] User '$CTF_USER' still exists after userdel." >&2
    FAILED=1
fi
if [[ -e "$TARGET_HOME_RAW" || -L "$TARGET_HOME_RAW" ]]; then
    echo "[!] Home directory still exists after userdel: $TARGET_HOME_RAW" >&2
    FAILED=1
fi
if (( FAILED )); then
    (( USERDEL_RC == 0 )) || echo "[!] userdel exited with status $USERDEL_RC." >&2
    die "Partial uninstall detected. Managed state was preserved at '$STATE_FILE'."
fi

rm -f -- "$STATE_FILE"
rmdir --ignore-fail-on-non-empty "$STATE_DIR" 2>/dev/null || true
if (( USERDEL_RC != 0 )); then
    echo "[!] userdel exited with status $USERDEL_RC, but the verified account and home are gone." >&2
fi

echo "[+] Done. Managed user '$CTF_USER' and '$TARGET_HOME_LEX' removed."
echo ""
echo "Note: system packages installed by install_ctf.sh (gdb, JDK, exiftool, etc.)"
echo "were intentionally left in place — remove them manually with apt if needed."
