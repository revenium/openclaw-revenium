#!/usr/bin/env bash
# Revenium NemoClaw Install — Host Compatibility Preflight (NON-DESTRUCTIVE).
#
# Does NOT install anything, does NOT sudo, does NOT modify the system.
# It checks THIS host against NemoClaw's documented requirements and the
# real OS gating found in NVIDIA/NemoClaw scripts/install.sh, then prints a
# compatibility verdict so we know whether this host can be the spike target.
#
# Documented NemoClaw requirements (sources in README.md):
#   - Linux only (no macOS; Windows via WSL2 only)
#   - Docker access (installer manages docker group / systemd on Linux)
#   - >= 8 GB RAM (OOM-killer risk below; >=8 GB swap mitigates)
#   - >= 20 GB free disk
#   - Optional NVIDIA GPU passthrough via: sudo nvidia-ctk runtime configure --runtime=docker
#   - Installer config dir: ~/.nemoclaw/
set -u

pass=0; warn=0; fail=0
line() { printf '%-34s %s\n' "$1" "$2"; }
ok()   { line "$1" "✓ $2"; pass=$((pass+1)); }
wn()   { line "$1" "⚠ $2"; warn=$((warn+1)); }
no()   { line "$1" "✗ $2"; fail=$((fail+1)); }

echo "=================================================="
echo " NemoClaw host compatibility probe"
echo "=================================================="

OS="$(uname -s)"
ARCH="$(uname -m)"
echo
echo "Host: $OS $ARCH"
echo "--------------------------------------------------"

# 1. OS — the hard gate. OpenShell sandboxes require a Linux kernel.
case "$OS" in
  Linux)
    if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
      wn "Operating system" "Linux (WSL2) — supported, but sandbox hardening varies"
    else
      ok "Operating system" "Linux — supported"
    fi
    ;;
  Darwin)
    no "Operating system" "macOS — UNSUPPORTED by NemoClaw (Linux-only stack)"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    no "Operating system" "Windows shell — needs WSL2 Linux, not Git-Bash"
    ;;
  *)
    no "Operating system" "$OS — unknown / unsupported"
    ;;
esac

# 2. Docker — required runtime for OpenShell sandboxes.
#    On Linux, absence is RECOVERABLE: NemoClaw's installer installs Docker,
#    starts the service, and adds the user to the docker group. So a missing
#    Docker on Linux is a warn (installer will handle it), not a hard fail.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "Docker" "installed and daemon reachable ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  else
    wn "Docker" "installed but daemon not reachable"
  fi
elif [ "$OS" = "Linux" ]; then
  wn "Docker" "not installed (installer-recoverable on Linux)"
else
  no "Docker" "not installed"
fi

# 3. RAM >= 8 GB
ram_gb=""
if [ "$OS" = "Linux" ] && [ -r /proc/meminfo ]; then
  kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  ram_gb=$(( kb / 1024 / 1024 ))
elif [ "$OS" = "Darwin" ]; then
  bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  ram_gb=$(( bytes / 1024 / 1024 / 1024 ))
fi
if [ -n "$ram_gb" ]; then
  if [ "$ram_gb" -ge 8 ]; then ok "RAM" "${ram_gb} GB (>= 8 GB)"; else wn "RAM" "${ram_gb} GB (< 8 GB — OOM risk)"; fi
else
  wn "RAM" "could not determine"
fi

# 4. Free disk >= 20 GB (on $HOME)
avail_gb=$(df -Pg "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
if [ -z "$avail_gb" ]; then
  # df -g unsupported; fall back to -k
  avail_gb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')
fi
if [ -n "$avail_gb" ]; then
  if [ "$avail_gb" -ge 20 ]; then ok "Free disk (\$HOME)" "${avail_gb} GB (>= 20 GB)"; else wn "Free disk (\$HOME)" "${avail_gb} GB (< 20 GB)"; fi
else
  wn "Free disk" "could not determine"
fi

# 5. NVIDIA GPU (optional — enables sandbox GPU passthrough)
if command -v nvidia-smi >/dev/null 2>&1; then
  ok "NVIDIA GPU" "nvidia-smi present (GPU passthrough possible)"
else
  wn "NVIDIA GPU" "no nvidia-smi (optional — CPU/remote inference only)"
fi

# 6. Node.js (installer bootstraps via nvm if absent, but note current)
if command -v node >/dev/null 2>&1; then
  ok "Node.js" "$(node --version)"
else
  wn "Node.js" "absent (installer would bootstrap via nvm on Linux)"
fi

# 7. NemoClaw config dir presence (informational)
if [ -d "$HOME/.nemoclaw" ]; then
  ok "~/.nemoclaw" "exists (prior NemoClaw install detected)"
else
  line "~/.nemoclaw" "· not present (no prior install)"
fi

echo "--------------------------------------------------"
echo "Summary: ${pass} pass, ${warn} warn, ${fail} fail"
echo
if [ "$fail" -gt 0 ]; then
  echo "VERDICT: INCOMPATIBLE — this host cannot run a full NemoClaw bootstrap."
  echo "         A Linux host (bare-metal/VM/WSL2) with Docker is required."
  exit 1
elif [ "$warn" -gt 0 ]; then
  echo "VERDICT: USABLE WITH CAVEATS — review warnings above."
  exit 0
else
  echo "VERDICT: COMPATIBLE — host meets NemoClaw bootstrap requirements."
  exit 0
fi
