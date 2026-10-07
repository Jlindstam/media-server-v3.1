#!/usr/bin/env bash
# Controlled VPN-failure test: takes the tunnel interface down INSIDE Gluetun while it
# stays running, then checks that qBittorrent's network cannot reach the internet.
# Usage: killswitch-test.sh [--yes]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
(( USE_VPN )) || die "This install runs without a VPN (USE_VPN=0), so there is no kill switch to test."

if [[ ${1:-} != "--yes" ]]; then
  read -r -p "This briefly cuts the VPN tunnel (downloads pause for ~1 minute). Continue? [y/N] " a
  [[ $a == [yY]* ]] || exit 0
fi

container_healthy gluetun || die "Gluetun is not healthy; fix that first (scripts/health-check.sh)"

real_ip=$(curl -s -m 8 https://ipinfo.io/ip || true)
iface=$(vpn_iface)
printf 'Kill-switch test (tunnel interface: %s)\n' "$iface"

if ! docker exec gluetun ip link set "$iface" down >/dev/null 2>&1; then
  warn "Bring tunnel down" "could not run 'ip link set $iface down' inside Gluetun; test skipped"
  summary; exit 2
fi

# Two probes: one by hostname, one by raw IP (no DNS involved).
by_name=$(docker exec qbittorrent wget -T 5 -qO- https://ipinfo.io/ip 2>/dev/null || true)
by_ip=$(docker exec qbittorrent wget -T 5 -qO- http://1.1.1.1/ 2>/dev/null || true)
still_down=0
if docker exec gluetun ip -o link show "$iface" 2>/dev/null | grep -q 'DOWN'; then still_down=1; fi

leaked=0
if [[ -n $by_name || -n $by_ip ]]; then leaked=1; fi

if (( leaked && still_down )); then
  fail "No traffic with tunnel down" "LEAK: traffic got out while the tunnel was down (real IP: ${real_ip:-unknown})"
elif (( leaked )); then
  warn "No traffic with tunnel down" "Gluetun re-established the tunnel during the test; result inconclusive, run again"
else
  pass "No traffic with tunnel down" "hostname and raw-IP probes both blocked"
fi

# Restore: bring the interface back, or restart Gluetun if it does not recover.
docker exec gluetun ip link set "$iface" up >/dev/null 2>&1 || true
if ! wait_for 60 container_healthy gluetun; then
  info "  Restarting Gluetun to recover..."
  dc restart gluetun >/dev/null 2>&1 || docker restart gluetun >/dev/null
  wait_for 120 container_healthy gluetun || true
fi
wait_for 120 has_forwarded_port || true
fp=$(forwarded_port)
if [[ $fp =~ ^[0-9]+$ ]] && qb_up; then qb_set_port "$fp" || true; fi

if container_healthy gluetun; then pass "VPN restored" "forwarded port ${fp:-none}"; else fail "VPN restored" "Gluetun is not healthy: docker logs gluetun --tail 100"; fi

summary
