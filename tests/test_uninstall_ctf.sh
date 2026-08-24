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
    local uid="${3:-1001}"
    mkdir -p "/tmp/ctf-uninstall/users" "/tmp/ctf-uninstall/uids" "$home"
    chown "$uid:$uid" "$home"
    printf '%s\n' "$home" > "/tmp/ctf-uninstall/users/$user"
    printf '%s\n' "$uid" > "/tmp/ctf-uninstall/uids/$user"
}

write_managed_state() {
    local user="$1"
    local uid home
    uid=$(<"/tmp/ctf-uninstall/uids/$user")
    home=$(<"/tmp/ctf-uninstall/users/$user")
    mkdir -p /var/lib/ctftools
    printf '%s\t%s\t%s\n' "$user" "$uid" "$(realpath -ms -- "$home")" \
        > /var/lib/ctftools/managed-user
    chown root:root /var/lib/ctftools/managed-user
    chmod 0600 /var/lib/ctftools/managed-user
}

setup_fixture() {
    rm -rf /tmp/ctf-uninstall /tmp/ctftools-uninstall /var/lib/ctftools
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
    cat "/tmp/ctf-uninstall/uids/$user"
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
    local name="$1" home uid
    home=$(<"/tmp/ctf-uninstall/users/$name")
    uid=$(<"/tmp/ctf-uninstall/uids/$name")
    printf '%s:x:%s:%s::%s:/bin/bash\n' "$name" "$uid" "$uid" "$home"
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
case "${CTF_TEST_USERDEL_MODE:-success}" in
    success)
        rm -f "/tmp/ctf-uninstall/users/$user" "/tmp/ctf-uninstall/uids/$user"
        rm -rf "$home"
        ;;
    account-remains)
        rm -rf "$home"
        ;;
    home-remains)
        rm -f "/tmp/ctf-uninstall/users/$user" "/tmp/ctf-uninstall/uids/$user"
        ;;
    partial-nonzero)
        rm -f "/tmp/ctf-uninstall/users/$user" "/tmp/ctf-uninstall/uids/$user"
        exit 12
        ;;
    *) exit 98 ;;
esac
EOF

    chmod +x /tmp/ctf-uninstall/mockbin/*
}

run_uninstaller() {
    CTF_TEST_USERDEL_MODE="${CTF_TEST_USERDEL_MODE:-success}" \
        PATH="/tmp/ctf-uninstall/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /tmp/ctftools-uninstall/uninstall_ctf.sh \
        >/tmp/ctf-uninstall/output.log 2>&1
}

setup_fixture
bash -n /tmp/ctftools-uninstall/uninstall_ctf.sh \
    || fail "uninstall_ctf.sh has invalid Bash syntax"

# Environment configuration must target the same user selected by install_ctf.sh.
create_user_fixture teamctf
write_managed_state teamctf
CTF_USER=teamctf run_uninstaller \
    || { cat /tmp/ctf-uninstall/output.log >&2; fail "custom-user uninstall failed"; }
assert_log_contains "pkill -u 1001"
assert_log_contains "pkill -9 -u 1001"
assert_log_contains "userdel -r -- teamctf"
assert_output_contains "/tmp/ctf-uninstall/homes/teamctf"
[[ ! -e /tmp/ctf-uninstall/users/teamctf ]] \
    || fail "custom user still exists after uninstall"
[[ ! -e /tmp/ctf-uninstall/homes/teamctf ]] \
    || fail "custom home still exists after uninstall"
[[ ! -e /var/lib/ctftools/managed-user ]] \
    || fail "managed state remains after a complete uninstall"

# A neighboring .env remains the fallback when CTF_USER is not exported.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture labctf /tmp/ctf-uninstall/homes/labctf 1002
write_managed_state labctf
printf 'CTF_USER=labctf\n' > /tmp/ctftools-uninstall/.env
env -u CTF_USER \
    PATH="/tmp/ctf-uninstall/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash /tmp/ctftools-uninstall/uninstall_ctf.sh \
    >/tmp/ctf-uninstall/output.log 2>&1 \
    || { cat /tmp/ctf-uninstall/output.log >&2; fail ".env fallback uninstall failed"; }
assert_log_contains "userdel -r -- labctf"

# .env must be parsed as literal data and never executed as root.
: > /tmp/ctf-uninstall/commands.log
rm -f /tmp/ctf-uninstall/env-executed
# The command substitution below is intentional literal test data.
# shellcheck disable=SC2016
printf 'CTF_USER=$(touch /tmp/ctf-uninstall/env-executed; printf missing)\n' \
    > /tmp/ctftools-uninstall/.env
if env -u CTF_USER \
        PATH="/tmp/ctf-uninstall/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /tmp/ctftools-uninstall/uninstall_ctf.sh \
        >/tmp/ctf-uninstall/output.log 2>&1; then
    fail "uninstaller accepted a command-like CTF_USER from .env"
fi
[[ ! -e /tmp/ctf-uninstall/env-executed ]] || fail "uninstaller executed .env as shell"
if grep -Eq '^(pkill|userdel) ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller ran a destructive command after malicious .env input"
fi
rm -f /tmp/ctftools-uninstall/.env

# An existing account without root-owned ctftools state is not managed.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture unmanaged /tmp/ctf-uninstall/homes/unmanaged 1003
if CTF_USER=unmanaged run_uninstaller; then
    fail "uninstaller accepted an unmanaged existing account"
fi
assert_output_contains "is not recorded as a ctftools-managed account"
[[ -e /tmp/ctf-uninstall/users/unmanaged \
        && -d /tmp/ctf-uninstall/homes/unmanaged ]] \
    || fail "uninstaller modified an unmanaged account"
if grep -Eq '^(pkill|userdel) ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller ran a destructive command for an unmanaged account"
fi

# userdel -r deletes a shared home even when another account still references it.
# The uninstaller must fail closed before invoking userdel in that case.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture alpha /tmp/ctf-uninstall/homes/shared 1101
create_user_fixture beta /tmp/ctf-uninstall/homes/shared 1102
chown 1101:1101 /tmp/ctf-uninstall/homes/shared
write_managed_state alpha
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
create_user_fixture aliasalpha /tmp/ctf-uninstall/homes/alias-shared 1201
create_user_fixture aliasbeta /tmp/ctf-uninstall/homes/alias-shared/. 1202
chown 1201:1201 /tmp/ctf-uninstall/homes/alias-shared
write_managed_state aliasalpha
if CTF_USER=aliasalpha run_uninstaller; then
    fail "uninstaller accepted an alias of a shared home"
fi
assert_output_contains "home directory overlaps account 'aliasbeta'"
[[ -d /tmp/ctf-uninstall/homes/alias-shared ]] \
    || fail "uninstaller removed the aliased shared home"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for an aliased shared home"
fi

# Reject both overlap directions: another account below the target home and the
# target home below another account's home.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture parent /tmp/ctf-uninstall/homes/parent 1301
create_user_fixture child /tmp/ctf-uninstall/homes/parent/child 1302
write_managed_state parent
if CTF_USER=parent run_uninstaller; then
    fail "uninstaller accepted another account nested below the target home"
fi
assert_output_contains "home directory overlaps account 'child'"

: > /tmp/ctf-uninstall/commands.log
write_managed_state child
if CTF_USER=child run_uninstaller; then
    fail "uninstaller accepted a target nested inside another account's home"
fi
assert_output_contains "home directory overlaps account 'parent'"

# A malformed passwd entry must never turn a system top-level directory into
# a recursive deletion target.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture dangerous /home 1401
write_managed_state dangerous
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
create_user_fixture wrongowner /tmp/ctf-uninstall/homes/wrongowner 1402
write_managed_state wrongowner
chown 0:0 /tmp/ctf-uninstall/homes/wrongowner
if CTF_USER=wrongowner run_uninstaller; then
    fail "uninstaller accepted a home owned by another UID"
fi
assert_output_contains "home directory is owned by UID 0, not 1402"
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
chown 1403:1403 /tmp/ctf-uninstall/homes/symlink-target
ln -s /tmp/ctf-uninstall/homes/symlink-target /tmp/ctf-uninstall/homes/symlink-home
chown -h 1403:1403 /tmp/ctf-uninstall/homes/symlink-home
printf '%s\n' /tmp/ctf-uninstall/homes/symlink-home \
    > /tmp/ctf-uninstall/users/symlinkuser
printf '1403\n' > /tmp/ctf-uninstall/uids/symlinkuser
write_managed_state symlinkuser
if CTF_USER=symlinkuser run_uninstaller; then
    fail "uninstaller accepted a symlink home"
fi
assert_output_contains "Refusing home with a symlink component for 'symlinkuser'"
[[ -e /tmp/ctf-uninstall/users/symlinkuser \
        && -L /tmp/ctf-uninstall/homes/symlink-home \
        && -d /tmp/ctf-uninstall/homes/symlink-target ]] \
    || fail "uninstaller partially removed the symlink-home fixture"
if grep -Fq 'userdel ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller called userdel for a symlink home"
fi

# The provenance record itself must remain root-controlled.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture tampered /tmp/ctf-uninstall/homes/tampered 1450
write_managed_state tampered
chmod 0666 /var/lib/ctftools/managed-user
if CTF_USER=tampered run_uninstaller; then
    fail "uninstaller accepted writable managed state"
fi
assert_output_contains "Managed-account state must be root-owned and not group/world-writable"
[[ -e /tmp/ctf-uninstall/users/tampered \
        && -d /tmp/ctf-uninstall/homes/tampered ]] \
    || fail "uninstaller modified an account with untrusted state"

# Duplicate numeric UIDs make pkill -u affect more than the selected account.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture dupealpha /tmp/ctf-uninstall/homes/dupealpha 1500
create_user_fixture dupebeta /tmp/ctf-uninstall/homes/dupebeta 1500
write_managed_state dupealpha
if CTF_USER=dupealpha run_uninstaller; then
    fail "uninstaller accepted a UID shared by another account"
fi
assert_output_contains "UID 1500 is also used by account 'dupebeta'"
if grep -Eq '^(pkill|userdel) ' /tmp/ctf-uninstall/commands.log; then
    fail "uninstaller ran a destructive command for a duplicate UID"
fi

# Postcondition failures must remain explicit, keep the state marker, and never
# become a successful no-op on the next run.
: > /tmp/ctf-uninstall/commands.log
create_user_fixture stuckuser /tmp/ctf-uninstall/homes/stuckuser 1601
write_managed_state stuckuser
if CTF_TEST_USERDEL_MODE=account-remains CTF_USER=stuckuser run_uninstaller; then
    fail "uninstaller succeeded while the account remained"
fi
assert_output_contains "User 'stuckuser' still exists after userdel"
[[ -e /var/lib/ctftools/managed-user ]] || fail "state was removed after a failed uninstall"

mkdir -p /tmp/ctf-uninstall/homes/stuckuser
chown 1601:1601 /tmp/ctf-uninstall/homes/stuckuser
if CTF_TEST_USERDEL_MODE=partial-nonzero CTF_USER=stuckuser run_uninstaller; then
    fail "uninstaller succeeded after partial userdel failure"
fi
assert_output_contains "Home directory still exists after userdel"
assert_output_contains "userdel exited with status 12"
[[ -e /var/lib/ctftools/managed-user ]] || fail "state was removed after partial deletion"
if CTF_USER=stuckuser run_uninstaller; then
    fail "partial deletion became a successful absent-user no-op"
fi
assert_output_contains "managed state remains but the account is missing"

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
