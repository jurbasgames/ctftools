#!/bin/bash
# CTF Bundle Maker
# Downloads Ghidra, Burp Suite, ffuf, John, DirBuster, and rockyou.txt into downloads/
# and packs everything into bundle.tar.gz ready to be deployed to lab machines.
#
# Run with: bash make_bundle.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOADS_DIR="$SCRIPT_DIR/downloads"
BUNDLE="$SCRIPT_DIR/bundle.tar.gz"

# Pinned versions (must match install_ctf.sh)
GHIDRA_VER="12.1.2"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VER}_build/ghidra_${GHIDRA_VER}_PUBLIC_20260605.zip"
FFUF_VER="2.2.1"
FFUF_URL="https://github.com/ffuf/ffuf/releases/download/v${FFUF_VER}/ffuf_${FFUF_VER}_linux_amd64.tar.gz"
JOHN_VER="1.9.0-jumbo-1"
JOHN_URL="https://www.openwall.com/john/k/john-${JOHN_VER}.tar.xz"
DIRBUSTER_VER="1.0-RC1"
DIRBUSTER_URL="https://downloads.sourceforge.net/project/dirbuster/DirBuster%20%28jar%20%2B%20lists%29/${DIRBUSTER_VER}/DirBuster-${DIRBUSTER_VER}.zip"
DIRBUSTER_SHA256="da80d17bd363bc60d3e7216a3c43329617cbd620ac55e55e2751bd3177d09ea1"
ROCKYOU_URL="https://gitlab.com/kalilinux/packages/wordlists/-/raw/kali/master/rockyou.txt.gz"
ROCKYOU_SHA256="ded2d962815e1256df8f3a0d25173c4b21b6eee636117c36999246725a6d8f9f"

info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }

verify_sha256() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    [[ "$actual" == "$expected" ]] || {
        echo "[!] SHA256 mismatch for $file" >&2
        rm -f "$file"
        exit 1
    }
}

mkdir -p "$DOWNLOADS_DIR"

# ── Ghidra ────────────────────────────────────────────────────────────────────
if [[ -f "$DOWNLOADS_DIR/ghidra.zip" ]]; then
    echo "[-] downloads/ghidra.zip already exists — skipping"
else
    info "Downloading Ghidra ${GHIDRA_VER}..."
    wget -q --show-progress -O "$DOWNLOADS_DIR/ghidra.zip" "$GHIDRA_URL"
    ok "Ghidra saved to downloads/ghidra.zip"
fi

# ── Burp Suite ────────────────────────────────────────────────────────────────
if [[ -f "$DOWNLOADS_DIR/burpsuite.jar" ]]; then
    echo "[-] downloads/burpsuite.jar already exists — skipping"
else
    info "Downloading Burp Suite Community JAR..."
    wget -q --show-progress \
        -O "$DOWNLOADS_DIR/burpsuite.jar" \
        "https://portswigger.net/burp/releases/download?product=community&type=Jar"
    ok "Burp Suite saved to downloads/burpsuite.jar"
fi

# ── ffuf ──────────────────────────────────────────────────────────────────────
if [[ -f "$DOWNLOADS_DIR/ffuf.tar.gz" ]]; then
    echo "[-] downloads/ffuf.tar.gz already exists — skipping"
else
    info "Downloading ffuf v${FFUF_VER}..."
    wget -q --show-progress -O "$DOWNLOADS_DIR/ffuf.tar.gz" "$FFUF_URL"
    ok "ffuf saved to downloads/ffuf.tar.gz"
fi

# ── John the Ripper ───────────────────────────────────────────────────────────
if [[ -f "$DOWNLOADS_DIR/john.tar.xz" ]]; then
    echo "[-] downloads/john.tar.xz already exists — skipping"
else
    info "Downloading John the Ripper ${JOHN_VER} source..."
    wget -q --show-progress -O "$DOWNLOADS_DIR/john.tar.xz" "$JOHN_URL"
    ok "John the Ripper saved to downloads/john.tar.xz"
fi

# ── DirBuster ─────────────────────────────────────────────────────────────────
if [[ -f "$DOWNLOADS_DIR/dirbuster.zip" ]]; then
    echo "[-] downloads/dirbuster.zip already exists — verifying"
else
    info "Downloading DirBuster ${DIRBUSTER_VER}..."
    wget -q --show-progress -O "$DOWNLOADS_DIR/dirbuster.zip" "$DIRBUSTER_URL"
fi
verify_sha256 "$DOWNLOADS_DIR/dirbuster.zip" "$DIRBUSTER_SHA256"
ok "DirBuster saved to downloads/dirbuster.zip"

# ── rockyou.txt ────────────────────────────────────────────────────────────────
if [[ -f "$DOWNLOADS_DIR/rockyou.txt.gz" ]]; then
    echo "[-] downloads/rockyou.txt.gz already exists — verifying"
else
    info "Downloading rockyou.txt from Kali wordlists..."
    wget -q --show-progress -O "$DOWNLOADS_DIR/rockyou.txt.gz" "$ROCKYOU_URL"
fi
verify_sha256 "$DOWNLOADS_DIR/rockyou.txt.gz" "$ROCKYOU_SHA256"
ok "rockyou.txt.gz saved to downloads/rockyou.txt.gz"

# ── Pack bundle ───────────────────────────────────────────────────────────────
info "Packing bundle.tar.gz..."
tar -czf "$BUNDLE" \
    -C "$SCRIPT_DIR" \
    install_ctf.sh \
    uninstall_ctf.sh \
    .env \
    downloads/

ok "Bundle created: $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
echo ""
echo "================================================================"
echo " Run deploy.sh to push this bundle to all lab machines."
echo "================================================================"
