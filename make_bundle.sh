#!/bin/bash
# CTF Bundle Maker
# Downloads Ghidra, Burp Suite, ffuf, and John the Ripper into downloads/
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

info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }

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
