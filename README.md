# CTF Tools Installer

Bash scripts to set up and tear down a CTF environment on Linux (Ubuntu/Mint) lab machines. Creates an isolated `ctf` user and installs all tools under their home directory. Supports single-machine installs, offline bundles, and mass deployment via SSH or Ansible.

## Tools installed

| Tool | Version | Source |
|------|---------|--------|
| **Ghidra** | 12.1.2 | GitHub release (pinned) |
| **Burp Suite Community** | latest | portswigger.net (JAR) |
| **pwndbg** | 2026.07.29 | GitHub release tag (pinned) |
| **pwntools** | 4.15.0 | pip (pinned) |
| **pycryptodome** | latest | pip |
| **ROPgadget** | 7.7 | pip (pinned) |
| **ffuf** | 2.2.1 | GitHub release binary (pinned) |
| **John the Ripper** | 1.9.0-jumbo-1 | openwall.com (source compile) |
| **exiftool** | apt | system package |
| **Wireshark + tshark** | apt | system package |
| **steghide** | apt | system package |

## Requirements

- Ubuntu 22.04+ or Linux Mint 21+ (apt-based)
- `sudo` access
- Internet access (or a pre-built bundle — see below)
- ~3 GB free disk (Ghidra + Burp + JtR compile + apt packages)

## Scripts overview

| Script | Purpose |
|--------|---------|
| `install_ctf.sh` | Creates `ctf` user and installs all tools |
| `uninstall_ctf.sh` | Removes the `ctf` user and all their files |
| `make_bundle.sh` | Downloads Ghidra, Burp, ffuf, and JtR into `downloads/` and packs `bundle.tar.gz` |
| `scan.sh` | Nmap ping scan to find live lab machines, saves last octets to `ips.txt` |
| `deploy.sh` | Pushes the bundle to all machines in `ips.txt` via SSH and runs the install |
| `ansible/deploy.yml` | Ansible alternative to `deploy.sh` |

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
nano .env
```

```
CTF_USER=ctf                        # user that will be created on each machine
CTF_PASS=your_password_here         # password for the ctf user

LAB_USER=your_lab_user_here         # existing user on lab machines (for file transfer)
LAB_PASS=your_lab_password_here
SUDO_USER=your_sudo_user_here       # user with sudo rights on lab machines
SUDO_PASS=your_sudo_password_here
IP_PREFIX=xxx.xxx.xxx               # first three octets of the lab subnet
```

## Single machine install

```bash
sudo bash install_ctf.sh
```

If `downloads/ghidra.zip`, `downloads/burpsuite.jar`, `downloads/ffuf.tar.gz`, or `downloads/john.tar.xz` exist (from `make_bundle.sh`), the script uses those instead of downloading. Otherwise it fetches them from the internet.

John the Ripper is compiled from source during installation — this requires `gcc`, `make`, and dev headers (`libssl-dev`, `zlib1g-dev`, `libbz2-dev`, `libgmp-dev`), all installed automatically by the script.

## Uninstall

```bash
sudo bash uninstall_ctf.sh
```

Deletes the `ctf` user and their entire home directory. System packages (gdb, JDK, exiftool, wireshark, steghide, etc.) are left in place.

## Mass deployment

### 1. Build the bundle (run once)

Downloads Ghidra, Burp Suite, ffuf, and John the Ripper source, and packs everything into `bundle.tar.gz`:

```bash
bash make_bundle.sh
```

### 2. Scan the network

Finds live machines on the subnet defined in `.env` and saves their last octets to `ips.txt`:

```bash
sudo bash scan.sh
```

Review `ips.txt` before deploying — remove any machines you don't want to touch.

### 3a. Deploy via SSH

Requires `sshpass`: `sudo apt-get install -y sshpass`

```bash
bash deploy.sh
```

Copies `bundle.tar.gz` to each machine, extracts it, and runs `install_ctf.sh` with sudo. Prints a summary of successes and failures at the end.

### 3b. Deploy via Ansible

Requires Ansible installed and inventory already configured:

```bash
ansible-playbook ansible/deploy.yml
```

Expects `bundle.tar.gz` in the repo root.

## Logging in as the CTF user

From the desktop login screen, log in as `ctf` with the password set in `.env`.

Or from a terminal:
```bash
su - ctf
```

The Python venv activates automatically and all tools are available on PATH — no extra setup needed.

## Using the tools

**Ghidra** — reverse engineering
```bash
ghidra &
```
New project → import your binary → double-click it → CodeBrowser → decompiler panel on the right.

**Burp Suite** — web exploitation
```bash
burpsuite &
```
Temporary project → Proxy tab → Open Browser → traffic flows through Burp.

**pwndbg** — binary debugging
```bash
gdb ./binary
```
pwndbg loads automatically on top of GDB. Useful extra commands: `checksec`, `cyclic`, `vmmap`, `heap`, `stack`.

**pwntools** — exploit scripting
```python
from pwn import *
p = process('./binary')      # or remote('host', port)
p.sendline(b'your payload')
p.interactive()
```

**ROPgadget** — find ROP chains
```bash
ROPgadget --binary ./binary
```

**pycryptodome** — crypto challenges
```python
from Crypto.Cipher import AES
from Crypto.Util.number import long_to_bytes, bytes_to_long
```

**ffuf** — web fuzzing
```bash
ffuf -u http://target/FUZZ -w wordlist.txt
```

**John the Ripper** — password cracking
```bash
john --wordlist=/usr/share/wordlists/rockyou.txt hashes.txt
john --show hashes.txt
```

**Wireshark / tshark** — network analysis
```bash
wireshark &
tshark -i eth0 -f "tcp port 80"
```

**steghide** — steganography
```bash
steghide extract -sf image.jpg
```

**exiftool** — file metadata
```bash
exiftool suspicious_image.png
```

## How the environment works

Two lines in `/home/ctf/.bashrc` handle all of this automatically on login:

```bash
export PATH="$HOME/tools:$PATH"   # makes ghidra, burpsuite, ffuf, john etc. callable by name
source "$HOME/venv/bin/activate"  # activates the Python venv with pwntools/pycryptodome/ROPgadget
```
