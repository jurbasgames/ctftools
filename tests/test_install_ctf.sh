#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${CTF_TEST_IMAGE:-ubuntu:24.04}"

if [[ "${CTF_TEST_IN_CONTAINER:-0}" != "1" ]]; then
    command -v docker >/dev/null || {
        echo "[FAIL] docker is required to run the isolated installer smoke test" >&2
        exit 1
    }

    exec docker run --rm \
        -e CTF_TEST_IN_CONTAINER=1 \
        -v "$REPO_DIR:/workspace:ro" \
        -w /workspace \
        "$IMAGE" \
        bash tests/test_install_ctf.sh
fi

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

assert_file_executable() {
    [[ -x "$1" ]] || fail "expected executable: $1"
}

assert_log_contains() {
    local needle="$1"
    grep -F -- "$needle" /tmp/ctf-test/commands.log >/dev/null \
        || fail "command log is missing: $needle"
}

setup_fixture() {
    rm -rf /tmp/ctf-test /tmp/ctftools-test /home/ctf /home/teamctf \
        /var/lib/ctftools
    mkdir -p /tmp/ctf-test/mockbin /tmp/ctftools-test/downloads
    cp /workspace/install_ctf.sh /tmp/ctftools-test/install_ctf.sh
    printf 'CTF_USER=ctf\nCTF_PASS=test-only\n' > /tmp/ctftools-test/.env
    printf 'test jar\n' > /tmp/ctftools-test/downloads/burpsuite.jar
    : > /tmp/ctftools-test/downloads/ffuf.tar.gz
    : > /tmp/ctftools-test/downloads/john.tar.xz
    : > /tmp/ctftools-test/downloads/dirbuster.zip
    : > /tmp/ctftools-test/downloads/rockyou.txt.gz

    cat > /tmp/ctf-test/mockbin/apt-get <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> /tmp/ctf-test/commands.log
EOF

    cat > /tmp/ctf-test/mockbin/apt-cache <<'EOF'
#!/usr/bin/env bash
printf 'apt-cache %s\n' "$*" >> /tmp/ctf-test/commands.log
case "$*" in
    "show openjdk-21-jdk") exit 1 ;;
    "show openjdk-17-jdk") exit 0 ;;
    *) exit 1 ;;
esac
EOF

    cat > /tmp/ctf-test/mockbin/debconf-set-selections <<'EOF'
#!/usr/bin/env bash
printf 'debconf-set-selections %s\n' "$(cat)" >> /tmp/ctf-test/commands.log
EOF

    cat > /tmp/ctf-test/mockbin/id <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-nG" && "${2:-}" == "ctf" ]] && printf 'ctf wireshark\n' && exit 0
if [[ "${1:-}" == "-u" ]]; then
    shift
    [[ "${1:-}" == "--" ]] && shift
    [[ "${1:-}" == "ctf" && -f /tmp/ctf-test/user-exists ]] \
        && printf '1001\n' && exit 0
    exit 1
fi
[[ "${1:-}" == "--" ]] && shift
[[ "${1:-}" == "ctf" && -f /tmp/ctf-test/user-exists ]] && exit 0
[[ "${1:-}" == "ctf" ]] && exit 1
exec /usr/bin/id "$@"
EOF

    cat > /tmp/ctf-test/mockbin/getent <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "passwd" && "${2:-}" == "ctf" \
    && -f /tmp/ctf-test/user-exists ]] || exit 2
printf 'ctf:x:1001:1001::/home/ctf:/bin/bash\n'
EOF

    cat > /tmp/ctf-test/mockbin/useradd <<'EOF'
#!/usr/bin/env bash
printf 'useradd %s\n' "$*" >> /tmp/ctf-test/commands.log
[[ "${CTF_TEST_STOP_USERADD:-0}" != "1" ]] || exit 77
mkdir -p /home/ctf
: > /home/ctf/.bashrc
touch /tmp/ctf-test/user-exists
EOF

    cat > /tmp/ctf-test/mockbin/usermod <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >> /tmp/ctf-test/commands.log
EOF

    cat > /tmp/ctf-test/mockbin/chpasswd <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'chpasswd\n' >> /tmp/ctf-test/commands.log
EOF

    cat > /tmp/ctf-test/mockbin/chown <<'EOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> /tmp/ctf-test/commands.log
EOF

    cat > /tmp/ctf-test/mockbin/sudo <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] || exit 2
[[ "${2:-}" == "ctf" ]] || exit 3
printf 'sudo-user %s\n' "$2" >> /tmp/ctf-test/commands.log
shift 2
"$@"
EOF

    cat > /tmp/ctf-test/mockbin/git <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> /tmp/ctf-test/commands.log
target="${@: -1}"
mkdir -p "$target"
printf '#!/usr/bin/env bash\nexit 0\n' > "$target/setup.sh"
chmod +x "$target/setup.sh"
EOF

    cat > /tmp/ctf-test/mockbin/wget <<'EOF'
#!/usr/bin/env bash
printf 'wget %s\n' "$*" >> /tmp/ctf-test/commands.log
dest=''
url=''
while (($#)); do
    case "$1" in
        -O) dest="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    https://github.com/NationalSecurityAgency/ghidra/*)
        exit 8
        ;;
    https://sourceforge.net/projects/ghidra.mirror/*)
        [[ "${CTF_TEST_GHIDRA_ALL_FAIL:-0}" != "1" ]] || exit 9
        printf 'test ghidra zip\n' > "$dest"
        ;;
    *)
        exit 9
        ;;
esac
EOF

    cat > /tmp/ctf-test/mockbin/python3 <<'EOF'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >> /tmp/ctf-test/commands.log
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    venv="$3"
    mkdir -p "$venv/bin"
    cat > "$venv/bin/pip" <<'PIP'
#!/usr/bin/env bash
printf 'pip %s\n' "$*" >> /tmp/ctf-test/commands.log
PIP
    cat > "$venv/bin/python" <<'PYTHON'
#!/usr/bin/env bash
printf 'venv-python %s\n' "$*" >> /tmp/ctf-test/commands.log
PYTHON
    cat > "$venv/bin/ROPgadget" <<'ROPGADGET'
#!/usr/bin/env bash
printf 'ROPgadget %s\n' "$*" >> /tmp/ctf-test/commands.log
ROPGADGET
    chmod +x "$venv/bin/pip" "$venv/bin/python" "$venv/bin/ROPgadget"
fi
EOF

    cat > /tmp/ctf-test/mockbin/unzip <<'EOF'
#!/usr/bin/env bash
dest="${@: -1}"
if [[ " $* " == *"dirbuster.zip"* ]]; then
    mkdir -p "$dest/DirBuster-1.0-RC1"
    printf 'test jar\n' > "$dest/DirBuster-1.0-RC1/DirBuster-1.0-RC1.jar"
else
    mkdir -p "$dest/ghidra_12.1.2_PUBLIC"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/ghidra_12.1.2_PUBLIC/ghidraRun"
    chmod +x "$dest/ghidra_12.1.2_PUBLIC/ghidraRun"
fi
EOF

    cat > /tmp/ctf-test/mockbin/tar <<'EOF'
#!/usr/bin/env bash
printf 'tar %s\n' "$*" >> /tmp/ctf-test/commands.log
args=" $* "
if [[ "$args" == *" ffuf "* ]]; then
    dest=""
    while (($#)); do
        if [[ "$1" == "-C" ]]; then dest="$2"; break; fi
        shift
    done
    printf '#!/usr/bin/env bash\necho ffuf 2.2.1\n' > "$dest/ffuf"
    chmod +x "$dest/ffuf"
else
    dest=""
    while (($#)); do
        if [[ "$1" == "-C" ]]; then dest="$2"; break; fi
        shift
    done
    mkdir -p "$dest/src" "$dest/run"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/src/configure"
    printf '%s\n' \
        'JTR_ALIGN( 64 ) typedef struct __blake2s_state' \
        'JTR_ALIGN( 64 ) typedef struct __blake2b_state' \
        'JTR_ALIGN( 64 ) typedef struct __blake2sp_state' \
        'JTR_ALIGN( 64 ) typedef struct __blake2bp_state' \
        > "$dest/src/blake2.h"
    printf '#!/usr/bin/env bash\necho John the Ripper 1.9.0-jumbo-1\n' > "$dest/run/john"
    chmod +x "$dest/src/configure" "$dest/run/john"
fi
EOF

    cat > /tmp/ctf-test/mockbin/make <<'EOF'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >> /tmp/ctf-test/commands.log
if [[ "$PWD" == */john-jumbo/src ]]; then
    content=$(<blake2.h)
    [[ "$content" != *'JTR_ALIGN( 64 ) typedef struct'* ]] || exit 90
    [[ "$content" == *'typedef struct JTR_ALIGN( 64 ) __blake2s_state'* ]] || exit 91
    [[ "$content" == *'typedef struct JTR_ALIGN( 64 ) __blake2b_state'* ]] || exit 92
    [[ "$content" == *'typedef struct JTR_ALIGN( 64 ) __blake2sp_state'* ]] || exit 93
    [[ "$content" == *'typedef struct JTR_ALIGN( 64 ) __blake2bp_state'* ]] || exit 94
fi
EOF

    for command in gdb exiftool tshark steghide java jar; do
        cat > "/tmp/ctf-test/mockbin/$command" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> /tmp/ctf-test/commands.log
if [[ "${CTF_VERIFY_FAIL:-}" == "$(basename "$0")" ]]; then
    exit 42
fi
if [[ "$(basename "$0")" == "jar" && "${1:-}" == "tf" && "$({ cat "$2" 2>/dev/null || true; })" == 'corrupt jar' ]]; then
    exit 43
fi
exit 0
EOF
    done

    cat > /tmp/ctf-test/mockbin/gzip <<'EOF'
#!/usr/bin/env bash
printf 'gzip %s\n' "$*" >> /tmp/ctf-test/commands.log
printf 'password\n123456\n'
EOF

    cat > /tmp/ctf-test/mockbin/sha256sum <<'EOF'
#!/usr/bin/env bash
printf 'sha256sum %s\n' "$*" >> /tmp/ctf-test/commands.log
case "$1" in
    *ghidra*)    hash=b62e81a0390618466c019c60d8c2f796ced2509c4c1aea4a37644a77272cf99d ;;
    *dirbuster*) hash=da80d17bd363bc60d3e7216a3c43329617cbd620ac55e55e2751bd3177d09ea1 ;;
    *rockyou*)   hash=ded2d962815e1256df8f3a0d25173c4b21b6eee636117c36999246725a6d8f9f ;;
    *)           hash=unexpected ;;
esac
printf '%s  %s\n' "$hash" "$1"
EOF

    chmod +x /tmp/ctf-test/mockbin/*
}

run_installer() {
    CTF_TEST_GHIDRA_ALL_FAIL="${CTF_TEST_GHIDRA_ALL_FAIL:-0}" \
        CTF_TEST_STOP_USERADD="${CTF_TEST_STOP_USERADD:-0}" \
        PATH="/tmp/ctf-test/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /tmp/ctftools-test/install_ctf.sh >/tmp/ctf-test/install.log 2>&1
}

run_installer_from_stdin() {
    (
        cd /tmp/ctftools-test
        CTF_USER=ctf CTF_PASS=ctf \
            PATH="/tmp/ctf-test/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            bash < install_ctf.sh
    ) >/tmp/ctf-test/install.log 2>&1
}

setup_fixture

# A real parse check happens before entering the mocked execution path.
bash -n /tmp/ctftools-test/install_ctf.sh || fail "install_ctf.sh has invalid Bash syntax"

# Each missing environment value must be filled independently from .env. The
# password override must not make the installer forget CTF_USER from the file.
printf 'CTF_USER=teamctf\nCTF_PASS=file-only\n' > /tmp/ctftools-test/.env
: > /tmp/ctf-test/commands.log
if env -u CTF_USER CTF_PASS=override CTF_TEST_STOP_USERADD=1 \
        PATH="/tmp/ctf-test/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /tmp/ctftools-test/install_ctf.sh >/tmp/ctf-test/install.log 2>&1; then
    fail "config contract probe unexpectedly completed the installer"
fi
assert_log_contains "useradd -m -d /home/teamctf -s /bin/bash -- teamctf"

# .env is data, not shell. Command substitutions must remain inert and then be
# rejected as an invalid literal username.
rm -f /tmp/ctf-test/env-executed
# The command substitution below is intentional literal test data.
# shellcheck disable=SC2016
printf 'CTF_USER=$(touch /tmp/ctf-test/env-executed; printf ctf)\nCTF_PASS=file-only\n' \
    > /tmp/ctftools-test/.env
: > /tmp/ctf-test/commands.log
if env -u CTF_USER -u CTF_PASS CTF_TEST_STOP_USERADD=1 \
        PATH="/tmp/ctf-test/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash /tmp/ctftools-test/install_ctf.sh >/tmp/ctf-test/install.log 2>&1; then
    fail "installer accepted a command-like CTF_USER from .env"
fi
[[ ! -e /tmp/ctf-test/env-executed ]] || fail "installer executed .env as shell"
if grep -Fq 'useradd ' /tmp/ctf-test/commands.log; then
    fail "installer reached useradd for an invalid literal username"
fi

# Installer and uninstaller must enforce the same portable username grammar.
rm -f /tmp/ctftools-test/.env
: > /tmp/ctf-test/commands.log
if CTF_USER=TeamCTF CTF_PASS=test-only CTF_TEST_STOP_USERADD=1 run_installer; then
    fail "installer accepted an unsupported username"
fi
if grep -Fq 'useradd ' /tmp/ctf-test/commands.log; then
    fail "installer called useradd for an unsupported username"
fi

# A pre-existing account without root-owned ctftools state must not have its
# password or files changed.
mkdir -p /home/ctf
: > /home/ctf/.bashrc
: > /tmp/ctf-test/user-exists
: > /tmp/ctf-test/commands.log
if CTF_USER=ctf CTF_PASS=test-only run_installer; then
    fail "installer accepted an unmanaged existing account"
fi
grep -F "is not recorded as ctftools-managed" /tmp/ctf-test/install.log >/dev/null \
    || fail "installer did not explain the unmanaged-account refusal"
if grep -Fq 'chpasswd' /tmp/ctf-test/commands.log; then
    fail "installer changed the password of an unmanaged account"
fi

setup_fixture

# The curl-pipe path must work with environment variables and no .env file.
rm /tmp/ctftools-test/.env
run_installer_from_stdin || {
    cat /tmp/ctf-test/install.log >&2
    fail "stdin installer did not accept CTF_USER/CTF_PASS without .env"
}

assert_file_executable /home/ctf/tools/ghidra
assert_file_executable /home/ctf/tools/burpsuite
assert_file_executable /home/ctf/tools/ffuf
assert_file_executable /home/ctf/tools/john
assert_file_executable /home/ctf/tools/dirbuster
[[ -s /home/ctf/tools/wordlists/rockyou.txt ]] \
    || fail "expected non-empty rockyou.txt"

assert_log_contains "git clone --depth=1 --branch 2026.07.29"
assert_log_contains "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.2_build/ghidra_12.1.2_PUBLIC_20260605.zip"
assert_log_contains "https://sourceforge.net/projects/ghidra.mirror/files/Ghidra_12.1.2_build/ghidra_12.1.2_PUBLIC_20260605.zip/download"
assert_log_contains "sha256sum /tmp/ghidra.zip.part"
[[ ! -e /tmp/ghidra.zip.part ]] || fail "installer left a partial Ghidra download behind"
assert_log_contains "apt-cache show openjdk-21-jdk"
assert_log_contains "apt-cache show openjdk-17-jdk"
grep -F 'apt-get install -y' /tmp/ctf-test/commands.log | grep -F 'openjdk-17-jdk' >/dev/null \
    || fail "installer did not fall back to openjdk-17-jdk"
if grep -F 'apt-get install -y' /tmp/ctf-test/commands.log | grep -Fq 'openjdk-21-jdk'; then
    fail "installer kept unavailable openjdk-21-jdk"
fi
assert_log_contains "pwntools==4.15.0"
assert_log_contains "ROPgadget==7.7"
assert_log_contains "sha256sum /tmp/dirbuster.zip"
assert_log_contains "sha256sum /tmp/rockyou.txt.gz"
assert_log_contains "debconf-set-selections wireshark-common wireshark-common/install-setuid boolean true"
if grep -Fq "usermod -aG wireshark ctf" /tmp/ctf-test/commands.log; then
    fail "installer added ctf to the wireshark group"
fi
grep -F '[+] CLI verification passed for ctf' /tmp/ctf-test/install.log >/dev/null \
    || fail "installer did not run the final CLI verification as ctf"

# A second run must remain successful, repair an old John wrapper, and avoid
# duplicating shell setup.
cat > /home/ctf/tools/john <<'EOF'
#!/bin/bash
exec "$(dirname "$(readlink -f "$0")")/john/run/john" "$@"
EOF
chmod +x /home/ctf/tools/john
printf 'corrupt jar\n' > /home/ctf/tools/burpsuite.jar
printf 'CTF_USER=ctf\nCTF_PASS=test-only\n' > /tmp/ctftools-test/.env
run_installer || fail "installer is not idempotent on a second run"
[[ "$(grep -Fc 'useradd -m -d /home/ctf -s /bin/bash -- ctf' /tmp/ctf-test/commands.log)" == "1" ]] \
    || fail "installer recreated the existing ctf user"
[[ "$(grep -Fc 'chpasswd' /tmp/ctf-test/commands.log)" == "2" ]] \
    || fail "installer did not update the existing ctf user password"
[[ "$(grep -Fc '# CTF tools setup' /home/ctf/.bashrc)" == "1" ]] \
    || fail ".bashrc setup marker was duplicated"
[[ "$(< /home/ctf/tools/burpsuite.jar)" == 'test jar' ]] \
    || fail "installer did not replace the corrupt Burp JAR"
[[ ! -e /home/ctf/tools/burpsuite.jar.part ]] \
    || fail "installer left a partial Burp download behind"
assert_log_contains "sudo-user ctf"
[[ "$(cat /var/lib/ctftools/managed-user)" == $'ctf\t1001\t/home/ctf' ]] \
    || fail "installer did not persist the managed account identity"
[[ "$(stat -c '%u:%a' /var/lib/ctftools/managed-user)" == "0:600" ]] \
    || fail "managed account state is not root-owned mode 0600"

# If both Ghidra sources fail, only Ghidra is skipped and the installer keeps
# the remaining tools usable.
rm -rf /home/ctf/tools/ghidra_12.1.2_PUBLIC /home/ctf/tools/ghidra
if ! CTF_TEST_GHIDRA_ALL_FAIL=1 run_installer; then
    cat /tmp/ctf-test/install.log >&2
    fail "installer stopped when all Ghidra sources failed"
fi
[[ ! -e /home/ctf/tools/ghidra ]] || fail "installer created a Ghidra wrapper after all downloads failed"
assert_file_executable /home/ctf/tools/ffuf
assert_file_executable /home/ctf/tools/john
grep -F '[!] Ghidra download failed from all sources; continuing without Ghidra' /tmp/ctf-test/install.log >/dev/null \
    || fail "installer did not report that Ghidra was skipped"
if grep -Fq '    ghidra &' /tmp/ctf-test/install.log; then
    fail "installer suggested launching Ghidra after skipping it"
fi

# The final verification must fail closed and identify a broken CLI.
if CTF_VERIFY_FAIL=gdb run_installer; then
    fail "installer succeeded even though the GDB CLI check was forced to fail"
fi
grep -F '[!] CLI check failed: GDB' /tmp/ctf-test/install.log >/dev/null \
    || fail "installer did not identify the failed GDB CLI check"

echo "[PASS] install_ctf.sh isolated smoke test"
