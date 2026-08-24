#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${CTF_TEST_IMAGE:-ubuntu:24.04}"

if [[ "${CTF_TEST_IN_CONTAINER:-0}" != "1" ]]; then
    command -v docker >/dev/null || {
        echo "[FAIL] docker is required to run the real uninstaller safety test" >&2
        exit 1
    }

    exec docker run --rm --privileged \
        -e CTF_TEST_IN_CONTAINER=1 \
        -v "$REPO_DIR:/workspace:ro" \
        -w /workspace \
        "$IMAGE" \
        bash tests/test_uninstall_ctf_real.sh
fi

fail() {
    echo "[FAIL] $*" >&2
    [[ -f /tmp/uninstall-real.log ]] && sed -n '1,80p' /tmp/uninstall-real.log >&2
    exit 1
}

STATE_FILE=/var/lib/ctftools/managed-user
USERS=(teamctf unmanaged sysctf dupealpha dupebeta symlinkuser intermediate mountuser)

cleanup() {
    mountpoint -q /srv/mountuser/shared 2>/dev/null && umount -l /srv/mountuser/shared || true
    for user in "${USERS[@]}"; do
        id -- "$user" >/dev/null 2>&1 && userdel -r -- "$user" >/dev/null 2>&1 || true
    done
    rm -rf /var/lib/ctftools /srv/teamctf /srv/unmanaged /srv/sysctf \
        /srv/dupealpha /srv/dupebeta /srv/symlink-real /srv/symlink-link \
        /srv/intermediate-real /srv/intermediate-link /srv/mountuser \
        /srv/mount-shared /home/teamctf /tmp/ctf-real-mock \
        /tmp/uninstall-real.log /tmp/install-real.log
}
trap cleanup EXIT
cleanup
mkdir -p /tmp/ctf-real-mock
cat > /tmp/ctf-real-mock/pkill <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > /tmp/ctf-real-mock/apt-get <<'EOF'
#!/usr/bin/env bash
# Stop the installer immediately after real account/state creation.
exit 77
EOF
chmod +x /tmp/ctf-real-mock/pkill /tmp/ctf-real-mock/apt-get

write_state() {
    local user="$1"
    local uid home
    uid=$(id -u -- "$user")
    home=$(getent passwd "$user" | cut -d: -f6)
    install -d -o root -g root -m 0755 /var/lib/ctftools
    printf '%s\t%s\t%s\n' "$user" "$uid" "$(realpath -ms -- "$home")" \
        > "$STATE_FILE"
    chown root:root "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

run_uninstaller() {
    local user="$1"
    CTF_USER="$user" \
        PATH="/tmp/ctf-real-mock:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /workspace/uninstall_ctf.sh >/tmp/uninstall-real.log 2>&1
}

run_installer_to_account_boundary() {
    CTF_USER=teamctf CTF_PASS=test-only \
        PATH="/tmp/ctf-real-mock:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /workspace/install_ctf.sh >/tmp/install-real.log 2>&1
}

assert_preserved() {
    local user="$1" sentinel="$2"
    id -- "$user" >/dev/null 2>&1 || fail "account '$user' was removed"
    [[ -e "$sentinel" ]] || fail "sentinel was removed: $sentinel"
}

# A real installer run creates the account and root-owned state before package
# installation. The uninstaller consumes that exact state and removes both.
if run_installer_to_account_boundary; then
    fail "installer boundary probe unexpectedly reached package installation"
else
    [[ "$?" == "77" ]] || fail "installer boundary probe failed before account creation"
fi
id -- teamctf >/dev/null 2>&1 || fail "installer did not create teamctf"
teamctf_uid="$(id -u -- teamctf)"
[[ "$(cat "$STATE_FILE")" == "$(printf 'teamctf\t%s\t/home/teamctf' "$teamctf_uid")" ]] \
    || fail "installer wrote unexpected managed state"
printf keep > /home/teamctf/KEEP
run_uninstaller teamctf || fail "managed account uninstall failed"
! id -- teamctf >/dev/null 2>&1 || fail "managed account remains"
[[ ! -e /home/teamctf ]] || fail "managed home remains"
[[ ! -e "$STATE_FILE" ]] || fail "managed state remains after success"
run_uninstaller teamctf || fail "second run is not an idempotent no-op"

# A name alone is never proof that ctftools owns an account.
useradd -m -d /srv/unmanaged -s /bin/bash unmanaged
printf keep > /srv/unmanaged/KEEP
if run_uninstaller unmanaged; then
    fail "unmanaged account was accepted"
fi
assert_preserved unmanaged /srv/unmanaged/KEEP

# System accounts and duplicate numeric UIDs are rejected before process kills.
useradd -m -d /srv/sysctf -s /bin/bash -u 500 sysctf
printf keep > /srv/sysctf/KEEP
write_state sysctf
if run_uninstaller sysctf; then
    fail "system UID was accepted"
fi
assert_preserved sysctf /srv/sysctf/KEEP

rm -f "$STATE_FILE"
useradd -m -d /srv/dupealpha -s /bin/bash -u 1500 dupealpha
useradd -o -m -d /srv/dupebeta -s /bin/bash -u 1500 dupebeta
printf keep > /srv/dupealpha/KEEP
printf keep > /srv/dupebeta/KEEP
write_state dupealpha
if run_uninstaller dupealpha; then
    fail "duplicate UID was accepted"
fi
assert_preserved dupealpha /srv/dupealpha/KEEP
assert_preserved dupebeta /srv/dupebeta/KEEP

# Trailing slashes and intermediate components cannot hide symlinks.
rm -f "$STATE_FILE"
mkdir -p /srv/symlink-real
printf keep > /srv/symlink-real/KEEP
ln -s /srv/symlink-real /srv/symlink-link
useradd -M -d /srv/symlink-link/ -s /bin/bash symlinkuser
chown -R symlinkuser:symlinkuser /srv/symlink-real
chown -h symlinkuser:symlinkuser /srv/symlink-link
write_state symlinkuser
if run_uninstaller symlinkuser; then
    fail "trailing-slash symlink home was accepted"
fi
assert_preserved symlinkuser /srv/symlink-real/KEEP

rm -f "$STATE_FILE"
mkdir -p /srv/intermediate-real/sub
printf keep > /srv/intermediate-real/sub/KEEP
ln -s /srv/intermediate-real /srv/intermediate-link
useradd -M -d /srv/intermediate-link/sub -s /bin/bash intermediate
chown -R intermediate:intermediate /srv/intermediate-real
write_state intermediate
if run_uninstaller intermediate; then
    fail "intermediate symlink component was accepted"
fi
assert_preserved intermediate /srv/intermediate-real/sub/KEEP

# A mount below the home would let userdel cross into external data.
rm -f "$STATE_FILE"
useradd -m -d /srv/mountuser -s /bin/bash mountuser
mkdir -p /srv/mount-shared /srv/mountuser/shared
printf keep > /srv/mount-shared/KEEP
mount --bind /srv/mount-shared /srv/mountuser/shared
write_state mountuser
if run_uninstaller mountuser; then
    fail "nested bind mount was accepted"
fi
assert_preserved mountuser /srv/mount-shared/KEEP
mountpoint -q /srv/mountuser/shared || fail "bind mount disappeared unexpectedly"
umount /srv/mountuser/shared

echo "[PASS] uninstall_ctf.sh real destructive-safety matrix"
