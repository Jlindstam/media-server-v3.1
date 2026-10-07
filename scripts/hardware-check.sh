#!/usr/bin/env bash
# Report whether this machine suits the media stack. Usage: hardware-check.sh [MEDIA_DIR]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

TARGET="${1:-$HOME/media}"
printf 'Hardware check\n'

# Architecture
arch=$(uname -m)
if [[ $arch == x86_64 ]]; then pass "Architecture" "$arch"; else warn "Architecture" "$arch (kit is built and tested for x86-64)"; fi

# CPU
cpu=$(lscpu 2>/dev/null | awk -F: '/Model name/ {sub(/^ +/,"",$2); print $2; exit}')
vendor=$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {sub(/^ +/,"",$2); print $2; exit}')
cores=$(nproc 2>/dev/null || echo "?")
if [[ $vendor == GenuineIntel ]]; then pass "CPU" "${cpu:-unknown} ($cores threads)"; else warn "CPU" "${cpu:-unknown}: not Intel, Quick Sync will be unavailable"; fi

# RAM
mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if (( mem_mb < 2048 )); then
  fail "RAM" "${mem_mb} MB: too little for this stack"
elif (( mem_mb < 3500 )); then
  warn "RAM" "${mem_mb} MB: very tight"
elif (( mem_mb < 6144 )); then
  pass "RAM" "${mem_mb} MB (a swap file will be added if none exists)"
else
  pass "RAM" "${mem_mb} MB"
fi

# GPU / Quick Sync
render=""
for d in /dev/dri/renderD*; do [[ -e $d ]] && { render=$d; break; }; done
if [[ -z $render ]]; then
  warn "Quick Sync" "no /dev/dri render device; Jellyfin will use software transcoding"
else
  node=$(basename "$render")
  gpu_vendor=$(cat "/sys/class/drm/$node/device/vendor" 2>/dev/null || echo "?")
  drv=$(basename "$(readlink "/sys/class/drm/$node/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
  if [[ $gpu_vendor == 0x8086 ]]; then
    pass "Quick Sync" "Intel GPU via $render (driver: $drv, render GID $(stat -c %g "$render"))"
  else
    warn "Quick Sync" "$render is not an Intel GPU (vendor $gpu_vendor); VAAPI may still work, untested"
  fi
fi

# Storage
probe="$TARGET"
while [[ ! -d $probe && $probe != "/" ]]; do probe=$(dirname "$probe"); done
free_gb=$(df -BG --output=avail "$probe" 2>/dev/null | tail -n1 | tr -dc '0-9')
fstype=$(df --output=fstype "$probe" 2>/dev/null | tail -n1 | tr -d ' ')
free_gb=${free_gb:-0}
if (( free_gb < 30 )); then
  fail "Storage" "${free_gb} GB free at $probe ($fstype)"
elif (( free_gb < 150 )); then
  warn "Storage" "${free_gb} GB free at $probe ($fstype): a small library will fill this quickly"
else
  pass "Storage" "${free_gb} GB free at $probe ($fstype)"
fi

# Network
iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [[ -z $iface ]]; then
  fail "Network" "no default route"
elif [[ $iface == wl* ]]; then
  warn "Network" "$iface is Wi-Fi; wired Ethernet is strongly recommended"
else
  speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "?")
  if [[ $speed =~ ^[0-9]+$ ]] && (( speed < 1000 )); then
    warn "Network" "$iface at ${speed} Mb/s"
  else
    pass "Network" "$iface (${speed} Mb/s)"
  fi
fi

# Tunnel device (Gluetun needs it)
if [[ ${USE_VPN:-1} != 0 ]]; then
  if [[ -e /dev/net/tun ]]; then pass "TUN device"; else warn "TUN device" "/dev/net/tun missing; try: sudo modprobe tun"; fi
fi

summary
