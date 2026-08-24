#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${CTF_TEST_IMAGE:-ubuntu:24.04}"

if [[ "${CTF_TEST_IN_CONTAINER:-0}" != "1" ]]; then
    command -v docker >/dev/null || {
        echo "[FAIL] docker is required to run the isolated uninstaller test" >&2
        exit 1
    }

    exec docker run --rm \
        -e CTF_TEST_IN_CONTAINER=1 \
        -v "$REPO_DIR:/workspace:ro" \
        -w /workspace \
        "$IMAGE" \
        bash tests/test_uninstall_ctf.sh
fi

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

assert_log_contains() {
    local needle="$1"
    grep -F -- "$needle" /tmp/ctf-uninstall/commands.log >/dev/null \
        || fail "command log is missing: $needle"
}

assert_output_contains() {
    local needle="$1"
    grep -F -- "$needle" /tmp/ctf-uninstall/output.log >/dev/null \
        || fail "output is missing: $needle"
}

create_user_fixture() {
    local user="$1"
    local home="${2:-/tmp/ctf-uninstall/homes/$user}"
    mkdir -p "/tmp/ctf-uninstall/users" "$home"
    chown 1001:1001 "$home"
    printf '%s\n' "$home" > "/tmp/ctf-uninstall/users/$user"
}

setup_fixture() {
    rm -rf /tmp/ctf-uninstall /tmp/ctftools-uninstall
    mkdir -p /tmp/ctf-uninstall/mockbin /tmp/ctftools-uninstall
    cp /workspace/uninstall_ctf.sh /tmp/ctftools-uninstall/uninstall_ctf.sh
    : > /tmp/ctf-uninstall/commands.log

    cat > /tmp/ctf-uninstall/mockbin/id <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
    shift
    [[ "${1:-}" == "--" ]] && shift
    user="${1:-}"
    [[ "$user" == "root" ]] && printf '0\n' && exit 0
    [[ -f "/tmp/ctf-uninstall/users/$user" ]] || exit 1
    printf '1001\n'
    exit 0
fi
[[ "${1:-}" == "--" ]] && shift
user="${1:-}"
[[ "$user" == "root" || -f "/tmp/ctf-uninstall/users/$user" ]]
EOF

    cat > /tmp/ctf-uninstall/mockbin/getent <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "passwd" ]] || exit 2
user="${2:-}"
print_user() {
    local name="$1" home
    home=$(<"/tmp/ctf-uninstall/users/$name")
    printf '%s:x:1001:1001::%s:/bin/bash\n' "$name" "$home"
}
if [[ -n "$user" ]]; then
    [[ -f "/tmp/ctf-uninstall/users/$user" ]] || exit 1
    print_user "$user"
else
    shopt -s nullglob
    for entry in /tmp/ctf-uninstall/users/*; do
        print_user "$(basename "$entry")"
    done
fi
EOF

    cat > /tmp/ctf-uninstall/mockbin/pkill <<'EOF'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >> /tmp/ctf-uninstall/commands.log
EOF

    cat > /tmp/ctf-uninstall/mockbin/sleep <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> /tmp/ctf-uninstall/commands.log
EOF

    cat > /tmp/ctf-uninstall/mockbin/userdel <<'EOF'
#!/usr/bin/env bash
printf 'userdel %s\n' "$*" >> /tmp/ctf-uninstall/commands.log
user="${@: -1}"
home=$(<"/tmp/ctf-uninstall/users/$user")
rm -f "/tmp/ctf-uninstall/users/$user"
rm -rf "$home"
EOF

    chmod +x /tmp/ctf-uninstall/mockbin/*
}

run_uninstaller() {
    PATH="/tmp/ctf-uninstall/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /tmp/ctftools-uninstall/uninstall_ctf.sh \
        >/tmp/ctf-uninstall/output.log 2>&1
}

setup_fixture
bash -n /tmp/ctftools-uninstall/uninstall_ctf.sh \
    || fail "uninstall_ctf.sh has invalid Bash syntax"

# Environment configuration must target the same user selected by install_ctf.sh.
create_user_fixture teamctf
CTF_USER=teamctf run_uninstaller \
    || { cat /tmp/ctf-uninstall/output.log >&2; fail "custom-user uninstall failed"; }
assert_log_contains "pkill -u teamctf"
assert_log_contains "pkill -9 -u teamctf"
assert_log_contains "userdel -r -- teamctf"
assert_output_contains "/tmp/ctf-uninstall/homes/teamctf"
[[ ! -e /tmp/ctf-uninstall/users/teamctf ]] \
    || fail "custom user still exists after uninstall"
[[ ! -e /tmp/ctf-uninstall/homes/teamctf ]] \
    || fail "custom home still exists after uninstall"

# A neighboring .env remains the fallback when CTF_USER is not exported.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture labctf
printf 'CTF_USER=labctf\n' > /tmp/ctftools-uninstall/.env
env -u CTF_USER \
    PATH="/tmp/ctf-uninstall/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash /tmp/ctftools-uninstall/uninstall_ctf.sh \
    >/tmp/ctf-uninstall/output.log 2>&1 \
    || { cat /tmp/ctf-uninstall/output.log >&2; fail ".env fallback uninstall failed"; }
assert_log_contains "userdel -r -- labctf"

# userdel -r deletes a shared home even when another account still references it.
# The uninstaller must fail closed before invoking userdel in that case.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture alpha /tmp/ctf-uninstall/homes/shared
create_user_fixture beta /tmp/ctf-uninstall/homes/shared
if CTF_USER=alpha run_uninstaller; then
    fail "uninstaller accepted a home shared with another account"
fi
assert_output_contains "home directory overlaps account 'beta'"
[[ -e /tmp/ctf-uninstall/users/alpha && -e /tmp/ctf-uninstall/users/beta ]] \
    || fail "uninstaller removed an account from a shared-home fixture"
[[ -d /tmp/ctf-uninstall/homes/shared ]] \
    || fail "uninstaller removed the shared home"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for a shared home"
fi

# Equivalent path spellings must not bypass the shared-home guard.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture aliasalpha /tmp/ctf-uninstall/homes/alias-shared
create_user_fixture aliasbeta /tmp/ctf-uninstall/homes/alias-shared/.
if CTF_USER=aliasalpha run_uninstaller; then
    fail "uninstaller accepted an alias of a shared home"
fi
assert_output_contains "home directory overlaps account 'aliasbeta'"
[[ -d /tmp/ctf-uninstall/homes/alias-shared ]] \
    || fail "uninstaller removed the aliased shared home"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for an aliased shared home"
fi

# A malformed passwd entry must never turn a system top-level directory into
# a recursive deletion target.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture dangerous /home
if CTF_USER=dangerous run_uninstaller; then
    fail "uninstaller accepted a protected top-level home"
fi
assert_output_contains "Refusing protected home directory for 'dangerous': '/home'"
[[ -d /home ]] || fail "uninstaller removed a protected top-level directory"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for a protected top-level home"
fi

# userdel removes the account but leaves a home it does not own. Refuse before
# creating that partial-uninstall state.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture wrongowner /tmp/ctf-uninstall/homes/wrongowner
chown 0:0 /tmp/ctf-uninstall/homes/wrongowner
if CTF_USER=wrongowner run_uninstaller; then
    fail "uninstaller accepted a home owned by another UID"
fi
assert_output_contains "home directory is owned by UID 0, not 1001"
[[ -e /tmp/ctf-uninstall/users/wrongowner \
        && -d /tmp/ctf-uninstall/homes/wrongowner ]] \
    || fail "uninstaller partially removed the wrong-owner fixture"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for a home owned by another UID"
fi

# A home symlink has ambiguous deletion semantics in userdel; reject it before
# removing the account.
: > /tmp/ctf-uninstall/commands.log
mkdir -p /tmp/ctf-uninstall/homes/symlink-target
chown 1001:1001 /tmp/ctf-uninstall/homes/symlink-target
ln -s /tmp/ctf-uninstall/homes/symlink-target /tmp/ctf-uninstall/homes/symlink-home
chown -h 1001:1001 /tmp/ctf-uninstall/homes/symlink-home
printf '%s\n' /tmp/ctf-uninstall/homes/symlink-home \
    > /tmp/ctf-uninstall/users/symlinkuser
if CTF_USER=symlinkuser run_uninstaller; then
    fail "uninstaller accepted a symlink home"
fi
assert_output_contains "Refusing symlink home directory for 'symlinkuser'"
[[ -e /tmp/ctf-uninstall/users/symlinkuser \
        && -L /tmp/ctf-uninstall/homes/symlink-home \
        && -d /tmp/ctf-uninstall/homes/symlink-target ]] \
    || fail "uninstaller partially removed the symlink-home fixture"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for a symlink home"
fi

# Protected accounts must be rejected before any destructive command.
: > /tmp/ctf-uninstall/commands.log
if CTF_USER=root run_uninstaller; then
    fail "uninstaller accepted the root account"
fi
assert_output_contains "Refusing to remove protected user 'root'"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for root"
fi

# Repeated runs are successful no-ops and report the selected user accurately.
: > /tmp/ctf-uninstall/commands.log
CTF_USER=missing run_uninstaller \
    || fail "uninstaller is not idempotent when the user is absent"
assert_output_contains "User 'missing' does not exist — nothing to do."
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for an absent user"
fi

echo "[PASS] uninstall_ctf.sh isolated smoke test"
