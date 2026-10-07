#!/usr/bin/env bash
# Pass/fail checks for the whole stack. Usage: health-check.sh [--fix]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env

FIX=0
for a in "$@"; do
  case $a in
    --fix) FIX=1 ;;
    -h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

printf 'Health check\n'

printf '\nContainers\n'
containers=(qbittorrent torlink jellyfin seerr radarr sonarr)
(( USE_VPN )) && containers=(gluetun "${containers[@]}")

for c in "${containers[@]}"; do
  state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  if [[ $state == running ]]; then pass "container: $c"; else fail "container: $c" "state: $state"; fi
done

if (( USE_VPN )); then
  printf '\nVPN\n'
  if container_healthy gluetun; then pass "Gluetun healthy"; else fail "Gluetun healthy" "see: docker logs gluetun --tail 100"; fi

  real_ip=$(curl -s -m 8 https://ipinfo.io/ip || true)
  vpn_ip=$(docker exec qbittorrent wget -qO- -T 8 https://ipinfo.io/ip 2>/dev/null || true)
  if [[ -z $vpn_ip ]]; then
    fail "Download traffic exits via VPN" "could not get an IP from inside qBittorrent's network"
  elif [[ -n $real_ip && $vpn_ip == "$real_ip" ]]; then
    fail "Download traffic exits via VPN" "LEAK: qBittorrent exits via your real IP ($real_ip). Stop torrenting."
  elif [[ -z $real_ip ]]; then
    warn "Download traffic exits via VPN" "exit IP $vpn_ip, but your real IP could not be fetched to compare"
  else
    pass "Download traffic exits via VPN" "exit IP $vpn_ip (home IP differs)"
  fi

  fp=$(forwarded_port)
  if [[ $fp =~ ^[0-9]+$ ]]; then
    pass "Proton forwarded port" "$fp"
  else
    fail "Proton forwarded port" "none yet. Needs a P2P server and NAT-PMP enabled when the config was generated."
  fi
else
  printf '\nVPN\n'
  warn "VPN disabled (USE_VPN=0)" "Download traffic uses your home IP. Re-run ./install.sh without --no-vpn to protect it."
fi

printf '\nqBittorrent\n'
if qb_up; then
  pass "qBittorrent API responding" "$(qb_api app/version)"
  if (( USE_VPN )); then
    lp=$(qb_listen_port)
    if [[ ! $fp =~ ^[0-9]+$ ]]; then
      warn "Listen port matches forwarded port" "no forwarded port to compare"
    elif [[ $lp == "$fp" ]]; then
      pass "Listen port matches forwarded port" "$lp"
    elif (( FIX )); then
      if qb_set_port "$fp"; then sleep 2; lp=$(qb_listen_port); fi
      if [[ $lp == "$fp" ]]; then pass "Listen port matches forwarded port" "fixed: now $lp"; else fail "Listen port matches forwarded port" "wanted $fp, have ${lp:-none}"; fi
    else
      fail "Listen port matches forwarded port" "forwarded $fp, qBittorrent listens on ${lp:-none}. Re-run with --fix."
    fi
  fi
else
  fail "qBittorrent API responding" "Check qBittorrent Web UI settings"
fi

printf '\nServices\n'
check_http() { # label url
  local code; code=$(http_code "$2")
  if [[ $code == 200 ]]; then pass "$1"; else fail "$1" "$2 returned HTTP $code"; fi
}
check_http "Jellyfin"  "http://127.0.0.1:8096/health"
check_http "Seerr"     "http://127.0.0.1:5055/api/v1/status"
check_http "Radarr"    "http://127.0.0.1:7878/ping"
check_http "Sonarr"    "http://127.0.0.1:8989/ping"
code=$(http_code "http://127.0.0.1:19117/")
if [[ $code != 000 && ${code:-0} -lt 500 ]]; then pass "TorLink++" "HTTP $code"; else fail "TorLink++" "http://127.0.0.1:19117/ returned HTTP $code"; fi

printf '\nStorage\n'
t1="$MEDIA/qbittorrent/downloads/.hl-test-$$"
t2="$MEDIA/Jellyfin/Movies/.hl-test-$$"
if echo test >"$t1" 2>/dev/null && ln "$t1" "$t2" 2>/dev/null && [[ "$(stat -c %i "$t1")" == "$(stat -c %i "$t2")" ]]; then
  pass "Hardlinks (downloads -> library)"
else
  fail "Hardlinks (downloads -> library)" "downloads and library must be on one filesystem"
fi
rm -f "$t1" "$t2"

pct=$(df --output=pcent "$MEDIA" 2>/dev/null | tail -n1 | tr -dc '0-9')
pct=${pct:-0}
if (( pct >= 95 )); then fail "Disk space" "${pct}% used"
elif (( pct >= 85 )); then warn "Disk space" "${pct}% used"
else pass "Disk space" "${pct}% used"; fi

mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]] && (( mem_mb < 6144 )); then
  warn "Swap" "none active with ${mem_mb} MB RAM"
else
  pass "Swap / RAM"
fi

printf '\nTranscoding\n'
if [[ -e /dev/dri/renderD128 ]]; then
  if docker exec jellyfin ls /dev/dri/renderD128 >/dev/null 2>&1; then
    if docker exec jellyfin /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128 >/dev/null 2>&1; then
      pass "Quick Sync (VAAPI) usable in Jellyfin"
    else
      warn "Quick Sync (VAAPI) usable in Jellyfin" "device visible but vainfo failed; check Jellyfin's Playback settings"
    fi
  else
    fail "Jellyfin sees /dev/dri" "docker-compose.qsv.yml not applied; re-run install.sh"
  fi
else
  warn "Quick Sync" "no /dev/dri on this host; software transcoding only"
fi

summary