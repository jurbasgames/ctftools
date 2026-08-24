#!/bin/bash
# CTF Tools Installer
# Creates and records the configured CTF user, then installs tools in its home.
# Run with: sudo bash install_ctf.sh

set -euo pipefail
export PIP_NO_CACHE_DIR=1
export MAKEFLAGS="-j2"

# ── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="/var/lib/ctftools"
STATE_FILE="$STATE_DIR/managed-user"

if [[ $EUID -ne 0 ]]; then
    echo "Run this script with sudo: sudo bash $0"
    exit 1
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
            if [[ "$last" != "$first" ]]; then
                echo "[!] Unterminated quoted value in $SCRIPT_DIR/.env" >&2
                return 1
            fi
            raw="${raw:1:${#raw}-2}"
        fi
    fi
    CONFIG_VALUE="$raw"
}

load_env_defaults() {
    local file="$1" line trimmed key raw
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        trimmed="$(trim_whitespace "$line")"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(CTF_USER|CTF_PASS)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            raw="${BASH_REMATCH[3]}"
            parse_env_literal "$raw" || return 1
            if [[ "$key" == "CTF_USER" && -z "${CTF_USER:-}" ]]; then
                CTF_USER="$CONFIG_VALUE"
            elif [[ "$key" == "CTF_PASS" && -z "${CTF_PASS:-}" ]]; then
                CTF_PASS="$CONFIG_VALUE"
            fi
        fi
    done < "$file"
}

if [[ -z "${CTF_USER:-}" || -z "${CTF_PASS:-}" ]] \
        && [[ -e "$SCRIPT_DIR/.env" || -L "$SCRIPT_DIR/.env" ]]; then
    if [[ ! -f "$SCRIPT_DIR/.env" || -L "$SCRIPT_DIR/.env" ]]; then
        echo "[!] Refusing non-regular or symlink .env: $SCRIPT_DIR/.env" >&2
        exit 1
    fi
    load_env_defaults "$SCRIPT_DIR/.env"
fi

CTF_USER="${CTF_USER:-ctf}"
if [[ ! "$CTF_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ || ${#CTF_USER} -gt 32 ]]; then
    echo "[!] Invalid CTF_USER: '$CTF_USER'. Use a portable lowercase Linux account name." >&2
    exit 1
fi
if [[ -z "${CTF_PASS:-}" ]]; then
    echo "[!] Set CTF_PASS or create $SCRIPT_DIR/.env"
    exit 1
fi
if [[ "$CTF_PASS" == *$'\n'* || "$CTF_PASS" == *$'\r'* ]]; then
    echo "[!] CTF_PASS must not contain line breaks." >&2
    exit 1
fi
HOME_DIR="/home/$CTF_USER"
TOOLS_DIR="$HOME_DIR/tools"
VENV_DIR="$HOME_DIR/venv"

# ── Pinned versions ──────────────────────────────────────────────────────────
GHIDRA_VER="12.1.2"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VER}_build/ghidra_${GHIDRA_VER}_PUBLIC_20260605.zip"
GHIDRA_FALLBACK_URL="https://sourceforge.net/projects/ghidra.mirror/files/Ghidra_${GHIDRA_VER}_build/ghidra_${GHIDRA_VER}_PUBLIC_20260605.zip/download"
GHIDRA_SHA256="b62e81a0390618466c019c60d8c2f796ced2509c4c1aea4a37644a77272cf99d"
PWNDBG_TAG="2026.07.29"
PWNTOOLS_VER="4.15.0"
# pycryptodome: latest (no pin needed — stable API)
ROPGADGET_VER="7.7"
FFUF_VER="2.2.1"
FFUF_URL="https://github.com/ffuf/ffuf/releases/download/v${FFUF_VER}/ffuf_${FFUF_VER}_linux_amd64.tar.gz"
JOHN_VER="1.9.0-jumbo-1"
JOHN_URL="https://www.openwall.com/john/k/john-${JOHN_VER}.tar.xz"
BURP_URL="https://portswigger.net/burp/releases/download?product=community&type=Jar"
DIRBUSTER_VER="1.0-RC1"
DIRBUSTER_URL="https://downloads.sourceforge.net/project/dirbuster/DirBuster%20%28jar%20%2B%20lists%29/${DIRBUSTER_VER}/DirBuster-${DIRBUSTER_VER}.zip"
DIRBUSTER_SHA256="da80d17bd363bc60d3e7216a3c43329617cbd620ac55e55e2751bd3177d09ea1"
ROCKYOU_URL="https://gitlab.com/kalilinux/packages/wordlists/-/raw/kali/master/rockyou.txt.gz"
ROCKYOU_SHA256="ded2d962815e1256df8f3a0d25173c4b21b6eee636117c36999246725a6d8f9f"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
skip()  { echo "[-] $* — skipping (already done)"; }
die()   { echo "[!] $*" >&2; exit 1; }

as_ctf() { sudo -u "$CTF_USER" "$@"; }

as_ctf_cli() {
    sudo -u "$CTF_USER" env \
        HOME="$HOME_DIR" \
        USER="$CTF_USER" \
        LOGNAME="$CTF_USER" \
        TERM="${TERM:-xterm}" \
        PATH="$VENV_DIR/bin:$TOOLS_DIR:$PATH" \
        "$@"
}

verify_cli() {
    local label="$1"
    shift
    if as_ctf_cli "$@" >"$VERIFY_LOG" 2>&1; then
        ok "CLI check: $label"
    else
        echo "[!] CLI check failed: $label" >&2
        sed -n '1,10p' "$VERIFY_LOG" >&2
        VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    fi
}

verify_sha256() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ "$actual" != "$expected" ]]; then
        echo "[!] SHA256 mismatch for $file" >&2
        echo "    expected: $expected" >&2
        echo "    actual:   $actual" >&2
        return 1
    fi
}

# ── 1. Create and record the managed user ─────────────────────────────────────
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

write_managed_state() {
    local tmp
    assert_state_storage_safe
    install -d -o root -g root -m 0755 "$STATE_DIR" || return 1
    tmp="$(mktemp "$STATE_DIR/.managed-user.XXXXXX")" || return 1
    if ! printf '%s\t%s\t%s\n' "$CTF_USER" "$TARGET_UID" "$HOME_DIR" > "$tmp" \
            || ! chown root:root "$tmp" || ! chmod 0600 "$tmp" \
            || ! mv -fT -- "$tmp" "$STATE_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

info "Creating user '$CTF_USER'..."
if id -- "$CTF_USER" &>/dev/null; then
    if ! load_managed_state; then
        die "User '$CTF_USER' already exists but is not recorded as ctftools-managed. Refusing to modify it."
    fi
    TARGET_UID="$(id -u -- "$CTF_USER")"
    TARGET_HOME_RAW="$(getent passwd "$CTF_USER" | cut -d: -f6)"
    TARGET_HOME_LEX="$(realpath -ms -- "$TARGET_HOME_RAW")"
    TARGET_HOME_PHYS="$(realpath -m -- "$TARGET_HOME_RAW")"
    if [[ "$MANAGED_USER" != "$CTF_USER" || "$MANAGED_UID" != "$TARGET_UID" \
            || "$MANAGED_HOME" != "$TARGET_HOME_LEX" \
            || "$TARGET_HOME_PHYS" != "$TARGET_HOME_LEX" ]]; then
        die "Existing account does not match the root-owned ctftools state."
    fi
    HOME_DIR="$MANAGED_HOME"
    TOOLS_DIR="$HOME_DIR/tools"
    VENV_DIR="$HOME_DIR/venv"
    skip "User '$CTF_USER' already exists and matches managed state"
else
    if load_managed_state; then
        die "Managed state already belongs to '$MANAGED_USER'; refusing to create '$CTF_USER'."
    fi
    useradd -m -d "$HOME_DIR" -s /bin/bash -- "$CTF_USER"
    TARGET_UID="$(id -u -- "$CTF_USER")"
    TARGET_HOME_RAW="$(getent passwd "$CTF_USER" | cut -d: -f6)"
    TARGET_HOME_LEX="$(realpath -ms -- "$TARGET_HOME_RAW")"
    TARGET_HOME_PHYS="$(realpath -m -- "$TARGET_HOME_RAW")"
    if [[ "$TARGET_HOME_LEX" != "$HOME_DIR" || "$TARGET_HOME_PHYS" != "$HOME_DIR" ]]; then
        userdel -r -- "$CTF_USER" 2>/dev/null || true
        die "New account home does not match the expected path '$HOME_DIR'."
    fi
    if ! write_managed_state; then
        userdel -r -- "$CTF_USER" 2>/dev/null || true
        die "Could not persist root-owned managed-account state. Account creation was rolled back."
    fi
    ok "User '$CTF_USER' created and recorded as ctftools-managed"
fi
printf '%s:%s\n' "$CTF_USER" "$CTF_PASS" | chpasswd
ok "Password set"

mkdir -p "$TOOLS_DIR"
chown "$CTF_USER:$CTF_USER" "$TOOLS_DIR"

# ── 2. System packages ────────────────────────────────────────────────────────
info "Installing apt packages..."
apt-get update -qq
printf '%s\n' 'wireshark-common wireshark-common/install-setuid boolean true' | debconf-set-selections
# openjdk-21 só existe em releases recentes; fallback para o disponível
JDK_PKG="openjdk-21-jdk"
if ! apt-cache show "$JDK_PKG" >/dev/null 2>&1; then
    JDK_PKG="openjdk-17-jdk"
    apt-cache show "$JDK_PKG" >/dev/null 2>&1 || JDK_PKG="default-jdk"
fi
info "JDK package: $JDK_PKG"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gdb git wget curl unzip xz-utils \
    python3 python3-pip python3-venv \
    libimage-exiftool-perl \
    "$JDK_PKG" \
    wireshark tshark \
    steghide gzip \
    libssl-dev zlib1g-dev libbz2-dev libgmp-dev
# usermod -aG wireshark "$CTF_USER"
ok "apt packages installed"

# ── 3. pwndbg ─────────────────────────────────────────────────────────────────
PWNDBG_DIR="$TOOLS_DIR/pwndbg"
info "Installing pwndbg ${PWNDBG_TAG}..."
if [[ -d "$PWNDBG_DIR" ]]; then
    skip "pwndbg directory already exists at $PWNDBG_DIR"
else
    as_ctf git clone --depth=1 --branch "$PWNDBG_TAG" https://github.com/pwndbg/pwndbg "$PWNDBG_DIR"
    # setup.sh must run as root to install system deps, but configures gdb for ctf user
    # Must cd into the pwndbg dir first — uv looks for pyproject.toml in the cwd
    (cd "$PWNDBG_DIR" && HOME="$HOME_DIR" SUDO_USER="$CTF_USER" bash setup.sh)
    ok "pwndbg ${PWNDBG_TAG} installed"
fi

# ── 4. Ghidra ─────────────────────────────────────────────────────────────────
info "Installing Ghidra ${GHIDRA_VER}..."
if [[ -n "$(find "$TOOLS_DIR" -maxdepth 1 -type d -name "ghidra_*" 2>/dev/null)" ]]; then
    skip "Ghidra already installed in $TOOLS_DIR"
else
    GHIDRA_ZIP="/tmp/ghidra.zip"
    GHIDRA_PART="${GHIDRA_ZIP}.part"
    GHIDRA_READY=0
    rm -f "$GHIDRA_ZIP" "$GHIDRA_PART"

    if [[ -f "$SCRIPT_DIR/downloads/ghidra.zip" ]]; then
        info "Using bundled downloads/ghidra.zip..."
        cp "$SCRIPT_DIR/downloads/ghidra.zip" "$GHIDRA_PART"
        if verify_sha256 "$GHIDRA_PART" "$GHIDRA_SHA256"; then
            GHIDRA_READY=1
        else
            echo "[!] Bundled Ghidra archive is invalid; trying network sources" >&2
            rm -f "$GHIDRA_PART"
        fi
    fi

    if (( ! GHIDRA_READY )); then
        info "Downloading Ghidra ${GHIDRA_VER} from GitHub..."
        if wget -q --show-progress --timeout=30 --tries=1 -O "$GHIDRA_PART" "$GHIDRA_URL" \
                && verify_sha256 "$GHIDRA_PART" "$GHIDRA_SHA256"; then
            GHIDRA_READY=1
        else
            rm -f "$GHIDRA_PART"
            info "GitHub download failed; trying SourceForge mirror..."
        fi
    fi

    if (( ! GHIDRA_READY )); then
        if wget -q --show-progress --timeout=30 --tries=1 -O "$GHIDRA_PART" "$GHIDRA_FALLBACK_URL" \
                && verify_sha256 "$GHIDRA_PART" "$GHIDRA_SHA256"; then
            GHIDRA_READY=1
        else
            rm -f "$GHIDRA_PART"
        fi
    fi

    if (( GHIDRA_READY )); then
        mv -f "$GHIDRA_PART" "$GHIDRA_ZIP"
        unzip -q "$GHIDRA_ZIP" -d "$TOOLS_DIR"
        rm -f "$GHIDRA_ZIP"

        # Wrapper script — finds ghidraRun inside whichever versioned dir was extracted
        cat > "$TOOLS_DIR/ghidra" <<'EOF'
#!/bin/bash
GHIDRA_RUN=$(find "$(dirname "$(readlink -f "$0")")" -maxdepth 2 -name "ghidraRun" | head -1)
exec "$GHIDRA_RUN" "$@"
EOF
        chmod +x "$TOOLS_DIR/ghidra"
        chown -R "$CTF_USER:$CTF_USER" "$TOOLS_DIR"/ghidra_* "$TOOLS_DIR/ghidra"
        ok "Ghidra ${GHIDRA_VER} installed in $TOOLS_DIR"
    else
        echo "[!] Ghidra download failed from all sources; continuing without Ghidra" >&2
    fi
fi

# ── 5. Burp Suite Community ───────────────────────────────────────────────────
BURP_JAR="$TOOLS_DIR/burpsuite.jar"
BURP_PART="$BURP_JAR.part"
info "Installing Burp Suite Community..."
if [[ -f "$BURP_JAR" ]] && jar tf "$BURP_JAR" >/dev/null 2>&1; then
    skip "Burp Suite JAR already exists at $BURP_JAR"
else
    if [[ -f "$BURP_JAR" ]]; then
        info "Existing Burp Suite JAR is invalid; replacing it..."
    fi
    rm -f "$BURP_PART"
    if [[ -f "$SCRIPT_DIR/downloads/burpsuite.jar" ]]; then
        info "Using bundled downloads/burpsuite.jar..."
        cp "$SCRIPT_DIR/downloads/burpsuite.jar" "$BURP_PART"
    else
        info "Downloading Burp Suite Community JAR..."
        wget -q --show-progress \
            -O "$BURP_PART" \
            "$BURP_URL"
    fi

    if ! jar tf "$BURP_PART" >/dev/null 2>&1; then
        rm -f "$BURP_PART"
        echo "[!] Invalid Burp Suite JAR" >&2
        exit 1
    fi
    mv -f "$BURP_PART" "$BURP_JAR"

    # Wrapper script so 'burpsuite' is on PATH
    cat > "$TOOLS_DIR/burpsuite" <<'EOF'
#!/bin/bash
java -jar "$(dirname "$(readlink -f "$0")")/burpsuite.jar" "$@"
EOF
    chmod +x "$TOOLS_DIR/burpsuite"
    chown "$CTF_USER:$CTF_USER" "$BURP_JAR" "$TOOLS_DIR/burpsuite"
    ok "Burp Suite installed at $BURP_JAR"
fi

# ── 6. Python venv + pip packages ────────────────────────────────────────────
info "Setting up Python venv and installing pip packages..."
if [[ -d "$VENV_DIR" ]]; then
    skip "venv already exists at $VENV_DIR"
else
    as_ctf python3 -m venv "$VENV_DIR"
    ok "venv created at $VENV_DIR"
fi

info "Installing pwntools ${PWNTOOLS_VER}, pycryptodome, ROPgadget ${ROPGADGET_VER}..."
as_ctf "$VENV_DIR/bin/pip" install --quiet --no-cache-dir --upgrade pip
as_ctf "$VENV_DIR/bin/pip" install --quiet --no-cache-dir \
    "pwntools==${PWNTOOLS_VER}" \
    pycryptodome \
    "ROPgadget==${ROPGADGET_VER}"
ok "Python packages installed"

# ── 7. ffuf ───────────────────────────────────────────────────────────────────
FFUF_BIN="$TOOLS_DIR/ffuf"
info "Installing ffuf v${FFUF_VER}..."
if [[ -x "$FFUF_BIN" ]]; then
    skip "ffuf already installed at $FFUF_BIN"
else
    if [[ -f "$SCRIPT_DIR/downloads/ffuf.tar.gz" ]]; then
        info "Using bundled downloads/ffuf.tar.gz..."
        cp "$SCRIPT_DIR/downloads/ffuf.tar.gz" /tmp/ffuf.tar.gz
    else
        info "Downloading ffuf v${FFUF_VER}..."
        wget -q --show-progress -O /tmp/ffuf.tar.gz "$FFUF_URL"
    fi
    tar -xzf /tmp/ffuf.tar.gz -C "$TOOLS_DIR" ffuf
    rm /tmp/ffuf.tar.gz
    chmod +x "$FFUF_BIN"
    chown "$CTF_USER:$CTF_USER" "$FFUF_BIN"
    ok "ffuf v${FFUF_VER} installed"
fi

# ── 8. John the Ripper (jumbo) ────────────────────────────────────────────────
JOHN_DIR="$TOOLS_DIR/john-jumbo"
JOHN_RUN="$JOHN_DIR/run/john"
info "Installing John the Ripper ${JOHN_VER}..."
if [[ -x "$JOHN_RUN" ]]; then
    skip "John the Ripper already installed at $JOHN_RUN"
else
    if [[ -f "$SCRIPT_DIR/downloads/john.tar.xz" ]]; then
        info "Using bundled downloads/john.tar.xz..."
        cp "$SCRIPT_DIR/downloads/john.tar.xz" /tmp/john.tar.xz
    else
        info "Downloading John the Ripper ${JOHN_VER} source..."
        wget -q --show-progress -O /tmp/john.tar.xz "$JOHN_URL"
    fi

    info "Compiling John the Ripper (this takes a few minutes)..."
    mkdir -p "$JOHN_DIR"
    tar -xf /tmp/john.tar.xz -C "$JOHN_DIR" --strip-components=1
    rm /tmp/john.tar.xz

    # Upstream 8152ac071bce: fix BLAKE2 alignment errors on GCC 11+.
    JOHN_BLAKE2="$JOHN_DIR/src/blake2.h"
    OLD_ALIGNMENTS=(
        "JTR_ALIGN( 64 ) typedef struct __blake2s_state"
        "JTR_ALIGN( 64 ) typedef struct __blake2b_state"
        "JTR_ALIGN( 64 ) typedef struct __blake2sp_state"
        "JTR_ALIGN( 64 ) typedef struct __blake2bp_state"
    )
    NEW_ALIGNMENTS=(
        "typedef struct JTR_ALIGN( 64 ) __blake2s_state"
        "typedef struct JTR_ALIGN( 64 ) __blake2b_state"
        "typedef struct JTR_ALIGN( 64 ) __blake2sp_state"
        "typedef struct JTR_ALIGN( 64 ) __blake2bp_state"
    )
    for i in "${!OLD_ALIGNMENTS[@]}"; do
        count=$(grep -Fc -- "${OLD_ALIGNMENTS[$i]}" "$JOHN_BLAKE2" || true)
        if [[ "$count" != 1 ]]; then
            echo "[!] Unexpected John blake2.h: found $count copies of '${OLD_ALIGNMENTS[$i]}'" >&2
            exit 1
        fi
        sed -i "s/${OLD_ALIGNMENTS[$i]}/${NEW_ALIGNMENTS[$i]}/" "$JOHN_BLAKE2"
    done

    (
        cd "$JOHN_DIR/src"
        ./configure --quiet
        make -sj"$(nproc)"
    )
    chown -R "$CTF_USER:$CTF_USER" "$JOHN_DIR"
    ok "John the Ripper ${JOHN_VER} installed"
fi

# Always refresh the wrapper so installations made by older versions recover.
cat > "$TOOLS_DIR/john" <<'EOF'
#!/bin/bash
exec "$(dirname "$(readlink -f "$0")")/john-jumbo/run/john" "$@"
EOF
chmod +x "$TOOLS_DIR/john"
chown "$CTF_USER:$CTF_USER" "$TOOLS_DIR/john"

# ── 9. DirBuster ──────────────────────────────────────────────────────────────
DIRBUSTER_DIR="$TOOLS_DIR/dirbuster-app"
DIRBUSTER_JAR="$DIRBUSTER_DIR/DirBuster-${DIRBUSTER_VER}.jar"
DIRBUSTER_BIN="$TOOLS_DIR/dirbuster"
info "Installing DirBuster ${DIRBUSTER_VER}..."
if [[ -f "$DIRBUSTER_JAR" ]]; then
    skip "DirBuster ${DIRBUSTER_VER} already exists at $DIRBUSTER_DIR"
else
    if [[ -f "$SCRIPT_DIR/downloads/dirbuster.zip" ]]; then
        info "Using bundled downloads/dirbuster.zip..."
        cp "$SCRIPT_DIR/downloads/dirbuster.zip" /tmp/dirbuster.zip
    else
        info "Downloading DirBuster ${DIRBUSTER_VER}..."
        wget -q --show-progress -O /tmp/dirbuster.zip "$DIRBUSTER_URL"
    fi
    verify_sha256 /tmp/dirbuster.zip "$DIRBUSTER_SHA256"

    DIRBUSTER_TMP=$(mktemp -d)
    unzip -q /tmp/dirbuster.zip -d "$DIRBUSTER_TMP"
    rm /tmp/dirbuster.zip
    mv "$DIRBUSTER_TMP/DirBuster-${DIRBUSTER_VER}" "$DIRBUSTER_DIR"
    rmdir "$DIRBUSTER_TMP"
    chown -R "$CTF_USER:$CTF_USER" "$DIRBUSTER_DIR"
    ok "DirBuster ${DIRBUSTER_VER} installed"
fi

cat > "$DIRBUSTER_BIN" <<'EOF'
#!/bin/bash
BASE="$(dirname "$(readlink -f "$0")")"
exec java -jar "$BASE/dirbuster-app/DirBuster-1.0-RC1.jar" "$@"
EOF
chmod +x "$DIRBUSTER_BIN"
chown "$CTF_USER:$CTF_USER" "$DIRBUSTER_BIN"

# ── 10. rockyou.txt ───────────────────────────────────────────────────────────
WORDLISTS_DIR="$TOOLS_DIR/wordlists"
ROCKYOU_TXT="$WORDLISTS_DIR/rockyou.txt"
info "Installing rockyou.txt..."
if [[ -s "$ROCKYOU_TXT" ]]; then
    skip "rockyou.txt already exists at $ROCKYOU_TXT"
else
    if [[ -f "$SCRIPT_DIR/downloads/rockyou.txt.gz" ]]; then
        info "Using bundled downloads/rockyou.txt.gz..."
        cp "$SCRIPT_DIR/downloads/rockyou.txt.gz" /tmp/rockyou.txt.gz
    else
        info "Downloading rockyou.txt from Kali wordlists..."
        wget -q --show-progress -O /tmp/rockyou.txt.gz "$ROCKYOU_URL"
    fi
    verify_sha256 /tmp/rockyou.txt.gz "$ROCKYOU_SHA256"

    mkdir -p "$WORDLISTS_DIR"
    gzip -dc /tmp/rockyou.txt.gz > "$ROCKYOU_TXT.part"
    mv "$ROCKYOU_TXT.part" "$ROCKYOU_TXT"
    rm /tmp/rockyou.txt.gz
    chown -R "$CTF_USER:$CTF_USER" "$WORDLISTS_DIR"
    ok "rockyou.txt installed at $ROCKYOU_TXT"
fi

# ── 11. Configure .bashrc ─────────────────────────────────────────────────────
BASHRC="$HOME_DIR/.bashrc"
MARKER="# CTF tools setup"
info "Configuring .bashrc..."
if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
    skip ".bashrc already configured"
else
    cat >> "$BASHRC" <<EOF

$MARKER
export PATH="\$HOME/tools:\$PATH"
source "\$HOME/venv/bin/activate"
EOF
    ok ".bashrc configured"
fi

# ── 12. Final ownership fix ───────────────────────────────────────────────────
chown -R "$CTF_USER:$CTF_USER" "$HOME_DIR"

# ── 13. Verify the installed CLI as the CTF user ─────────────────────────────
info "Verifying installed tools as '$CTF_USER'..."
VERIFY_FAILURES=0
VERIFY_LOG=$(mktemp)

verify_cli "GDB" gdb --version
verify_cli "pwndbg" gdb -q -batch -ex 'pi import pwndbg'
verify_cli "ExifTool" exiftool -ver
verify_cli "TShark" tshark --version
verify_cli "Steghide" steghide --version
verify_cli "Java" java -version
verify_cli "pwntools" "$VENV_DIR/bin/python" -c 'import pwn'
verify_cli "PyCryptodome" "$VENV_DIR/bin/python" -c 'from Crypto.Cipher import AES'
verify_cli "ROPgadget" "$VENV_DIR/bin/ROPgadget" --version
verify_cli "ffuf" "$TOOLS_DIR/ffuf" -V
verify_cli "John the Ripper" "$TOOLS_DIR/john" --list=build-info
if [[ -x "$TOOLS_DIR/ghidra" ]] && compgen -G "$TOOLS_DIR/ghidra*/ghidraRun" >/dev/null; then
    verify_cli "Ghidra launcher" bash -c "targets=(\"\$1\"/ghidra*/ghidraRun); test -x \"\${targets[0]}\" && test -x \"\$1/ghidra\"" _ "$TOOLS_DIR"
else
    info "CLI check skipped: Ghidra is not installed"
fi
verify_cli "Burp Suite assets" bash -c "test -x \"\$1/burpsuite\" && jar tf \"\$1/burpsuite.jar\" >/dev/null" _ "$TOOLS_DIR"
verify_cli "DirBuster assets" bash -c "test -x \"\$1/dirbuster\" && jar tf \"\$1/dirbuster-app/DirBuster-1.0-RC1.jar\" >/dev/null" _ "$TOOLS_DIR"
verify_cli "rockyou.txt" test -s "$ROCKYOU_TXT"

rm -f "$VERIFY_LOG"
if (( VERIFY_FAILURES > 0 )); then
    echo "[!] $VERIFY_FAILURES CLI verification check(s) failed for $CTF_USER" >&2
    exit 1
fi
ok "CLI verification passed for $CTF_USER"

apt-get clean
rm -rf /var/lib/apt/lists/*

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " Installation complete!"
echo "  User:     $CTF_USER"
echo "  Tools:    $TOOLS_DIR"
echo ""
echo "  Switch to the CTF user with:  su - $CTF_USER"
echo "  Verify tools:"
echo "    exiftool -ver"
echo "    gdb --version"
echo "    python3 -c \"import pwn; print('pwntools ok')\""
echo "    python3 -c \"from Crypto.Cipher import AES; print('pycryptodome ok')\""
echo "    ROPgadget --version"
echo "    tshark --version"
echo "    steghide --version"
echo "    john --list=build-info"
echo "    ffuf -V"
echo "    dirbuster -h"
echo "    wc -l ~/tools/wordlists/rockyou.txt"
if [[ -x "$TOOLS_DIR/ghidra" ]]; then
    echo "    ghidra &"
fi
echo "    burpsuite &"
echo "================================================================"
