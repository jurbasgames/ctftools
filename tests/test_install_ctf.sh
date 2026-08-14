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
    rm -rf /tmp/ctf-test /tmp/ctftools-test /home/ctf
    mkdir -p /tmp/ctf-test/mockbin /tmp/ctftools-test/downloads
    cp /workspace/install_ctf.sh /tmp/ctftools-test/install_ctf.sh
    printf 'CTF_USER=ctf\nCTF_PASS=test-only\n' > /tmp/ctftools-test/.env
    : > /tmp/ctftools-test/downloads/ghidra.zip
    : > /tmp/ctftools-test/downloads/burpsuite.jar
    : > /tmp/ctftools-test/downloads/ffuf.tar.gz
    : > /tmp/ctftools-test/downloads/john.tar.xz
    : > /tmp/ctftools-test/downloads/dirbuster.zip
    : > /tmp/ctftools-test/downloads/rockyou.txt.gz

    cat > /tmp/ctf-test/mockbin/apt-get <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> /tmp/ctf-test/commands.log
EOF

    cat > /tmp/ctf-test/mockbin/id <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "ctf" ]] && exit 1
exec /usr/bin/id "$@"
EOF

    cat > /tmp/ctf-test/mockbin/useradd <<'EOF'
#!/usr/bin/env bash
printf 'useradd %s\n' "$*" >> /tmp/ctf-test/commands.log
mkdir -p /home/ctf
: > /home/ctf/.bashrc
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
    chmod +x "$venv/bin/pip"
fi
EOF

    cat > /tmp/ctf-test/mockbin/unzip <<'EOF'
#!/usr/bin/env bash
dest="${@: -1}"
if [[ " $* " == *"dirbuster.zip"* ]]; then
    mkdir -p "$dest/DirBuster-1.0-RC1"
    : > "$dest/DirBuster-1.0-RC1/DirBuster-1.0-RC1.jar"
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
    printf '#!/usr/bin/env bash\necho John the Ripper 1.9.0-jumbo-1\n' > "$dest/run/john"
    chmod +x "$dest/src/configure" "$dest/run/john"
fi
EOF

    cat > /tmp/ctf-test/mockbin/make <<'EOF'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >> /tmp/ctf-test/commands.log
EOF

    cat > /tmp/ctf-test/mockbin/gzip <<'EOF'
#!/usr/bin/env bash
printf 'gzip %s\n' "$*" >> /tmp/ctf-test/commands.log
printf 'password\n123456\n'
EOF

    cat > /tmp/ctf-test/mockbin/sha256sum <<'EOF'
#!/usr/bin/env bash
printf 'sha256sum %s\n' "$*" >> /tmp/ctf-test/commands.log
case "$1" in
    *dirbuster*) hash=da80d17bd363bc60d3e7216a3c43329617cbd620ac55e55e2751bd3177d09ea1 ;;
    *rockyou*)   hash=ded2d962815e1256df8f3a0d25173c4b21b6eee636117c36999246725a6d8f9f ;;
    *)           hash=unexpected ;;
esac
printf '%s  %s\n' "$hash" "$1"
EOF

    chmod +x /tmp/ctf-test/mockbin/*
}

run_installer() {
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
assert_log_contains "pwntools==4.15.0"
assert_log_contains "ROPgadget==7.7"
assert_log_contains "sha256sum /tmp/dirbuster.zip"
assert_log_contains "sha256sum /tmp/rockyou.txt.gz"

# A second run must remain successful and must not duplicate shell setup.
printf 'CTF_USER=ctf\nCTF_PASS=test-only\n' > /tmp/ctftools-test/.env
run_installer || fail "installer is not idempotent on a second run"
[[ "$(grep -Fc '# CTF tools setup' /home/ctf/.bashrc)" == "1" ]] \
    || fail "installer duplicated the .bashrc setup block"

echo "[PASS] install_ctf.sh isolated smoke test"
