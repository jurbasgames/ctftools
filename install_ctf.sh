#!/bin/bash
# CTF Tools Installer
# Creates user 'ctf' and installs tools in their home directory.
# Run with: sudo bash install_ctf.sh

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
else
    echo "[!] .env file not found at $SCRIPT_DIR/.env"
    exit 1
fi

CTF_USER="${CTF_USER:-ctf}"
TOOLS_DIR="/home/$CTF_USER/tools"
VENV_DIR="/home/$CTF_USER/venv"

# ── Pinned versions ──────────────────────────────────────────────────────────
GHIDRA_VER="12.1.2"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VER}_build/ghidra_${GHIDRA_VER}_PUBLIC_20260605.zip"
PWNDBG_TAG="2026.07.29"
PWNTOOLS_VER="4.15.0"
PYCRYPTODOME_VER="latest"
ROPGADGET_VER="7.7"
FFUF_VER="2.2.1"
FFUF_URL="https://github.com/ffuf/ffuf/releases/download/v${FFUF_VER}/ffuf_${FFUF_VER}_linux_amd64.tar.gz"
JOHN_VER="1.9.0-jumbo-1"
JOHN_URL="https://www.openwall.com/john/k/john-${JOHN_VER}.tar.xz"
BURP_URL="https://portswigger.net/burp/releases/download?product=community&type=Jar"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
skip()  { echo "[-] $* — skipping (already done)"; }

as_ctf() { sudo -u "$CTF_USER" "$@"; }

# ── 0. Root check ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Run this script with sudo: sudo bash $0"
    exit 1
fi

# ── 1. Create user ────────────────────────────────────────────────────────────
info "Creating user '$CTF_USER'..."
if id "$CTF_USER" &>/dev/null; then
    skip "User '$CTF_USER' already exists"
else
    useradd -m -s /bin/bash "$CTF_USER"
    ok "User '$CTF_USER' created"
fi
echo "$CTF_USER:$CTF_PASS" | chpasswd
ok "Password set"

mkdir -p "$TOOLS_DIR"
chown "$CTF_USER:$CTF_USER" "$TOOLS_DIR"

# ── 2. System packages ────────────────────────────────────────────────────────
info "Installing apt packages..."
apt-get update -qq
apt-get install -y \
    gdb git wget curl unzip xz-utils \
    python3 python3-pip python3-venv \
    libimage-exiftool-perl \
    openjdk-21-jdk \
    wireshark tshark \
    steghide \
    libssl-dev zlib1g-dev libbz2-dev libgmp-dev
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
    (cd "$PWNDBG_DIR" && HOME="/home/$CTF_USER" SUDO_USER="$CTF_USER" bash setup.sh)
    ok "pwndbg ${PWNDBG_TAG} installed"
fi

# ── 4. Ghidra ─────────────────────────────────────────────────────────────────
info "Installing Ghidra ${GHIDRA_VER}..."
if [[ -n "$(find "$TOOLS_DIR" -maxdepth 1 -type d -name "ghidra_*" 2>/dev/null)" ]]; then
    skip "Ghidra already installed in $TOOLS_DIR"
else
    if [[ -f "$SCRIPT_DIR/downloads/ghidra.zip" ]]; then
        info "Using bundled downloads/ghidra.zip..."
        cp "$SCRIPT_DIR/downloads/ghidra.zip" /tmp/ghidra.zip
    else
        info "Downloading Ghidra ${GHIDRA_VER} from GitHub..."
        wget -q --show-progress -O /tmp/ghidra.zip "$GHIDRA_URL"
    fi
    unzip -q /tmp/ghidra.zip -d "$TOOLS_DIR"
    rm /tmp/ghidra.zip

    # Wrapper script — finds ghidraRun inside whichever versioned dir was extracted
    cat > "$TOOLS_DIR/ghidra" <<'EOF'
#!/bin/bash
GHIDRA_RUN=$(find "$(dirname "$(readlink -f "$0")")" -maxdepth 2 -name "ghidraRun" | head -1)
exec "$GHIDRA_RUN" "$@"
EOF
    chmod +x "$TOOLS_DIR/ghidra"
    chown -R "$CTF_USER:$CTF_USER" "$TOOLS_DIR"/ghidra_* "$TOOLS_DIR/ghidra"
    ok "Ghidra ${GHIDRA_VER} installed in $TOOLS_DIR"
fi

# ── 5. Burp Suite Community ───────────────────────────────────────────────────
BURP_JAR="$TOOLS_DIR/burpsuite.jar"
info "Installing Burp Suite Community..."
if [[ -f "$BURP_JAR" ]]; then
    skip "Burp Suite JAR already exists at $BURP_JAR"
else
    if [[ -f "$SCRIPT_DIR/downloads/burpsuite.jar" ]]; then
        info "Using bundled downloads/burpsuite.jar..."
        cp "$SCRIPT_DIR/downloads/burpsuite.jar" "$BURP_JAR"
    else
        info "Downloading Burp Suite Community JAR..."
        wget -q --show-progress \
            -O "$BURP_JAR" \
            "$BURP_URL"
    fi

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
as_ctf "$VENV_DIR/bin/pip" install --quiet --upgrade pip
as_ctf "$VENV_DIR/bin/pip" install --quiet \
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
JOHN_DIR="$TOOLS_DIR/john"
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

    (
        cd "$JOHN_DIR/src"
        ./configure --quiet
        make -sj"$(nproc)"
    )
    chown -R "$CTF_USER:$CTF_USER" "$JOHN_DIR"

    # Wrapper so 'john' is on PATH
    cat > "$TOOLS_DIR/john" <<'EOF'
#!/bin/bash
exec "$(dirname "$(readlink -f "$0")")/john/run/john" "$@"
EOF
    chmod +x "$TOOLS_DIR/john"
    ok "John the Ripper ${JOHN_VER} installed"
fi

# ── 9. Configure .bashrc ──────────────────────────────────────────────────────
BASHRC="/home/$CTF_USER/.bashrc"
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

# ── 10. Final ownership fix ───────────────────────────────────────────────────
chown -R "$CTF_USER:$CTF_USER" "/home/$CTF_USER"

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
echo "    python3 -c \"import ROPgadget; print('ropgadget ok')\""
echo "    tshark --version"
echo "    steghide --help"
echo "    john --list=build-info"
echo "    ffuf -V"
echo "    ghidra &"
echo "    burpsuite &"
echo "================================================================"
