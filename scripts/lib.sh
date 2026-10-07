#!/usr/bin/env bash
# Shared helpers for the media-server kit. Source this file; do not run it.

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_OFF=""
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

STACK_DIR="${STACK_DIR:-$HOME/stack}"

info() { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

_detail() { if [[ -n "${1:-}" ]]; then printf '      %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; fi; return 0; }
pass() { printf '  %-46s %sPASS%s\n' "$1" "$C_GRN" "$C_OFF"; _detail "${2:-}"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn() { printf '  %-46s %sWARN%s\n' "$1" "$C_YEL" "$C_OFF"; _detail "${2:-}"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { printf '  %-46s %sFAIL%s\n' "$1" "$C_RED" "$C_OFF"; _detail "${2:-}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

summary() {
  printf '\n  %d passed, %d warnings, %d failed\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  [[ $FAIL_COUNT -eq 0 ]]
}

# Load STACK_DIR/.env (MEDIA, PUID, PGID, TZ, RENDER_GID, USE_VPN) if present.
load_env() {
  if [[ -f "$STACK_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$STACK_DIR/.env"
    set +a
  fi
  MEDIA="${MEDIA:-$HOME/media}"
  USE_VPN="${USE_VPN:-1}"
}

# docker compose wrapper: pinned versions + env + optional override files.
dc() {
  local files=(-f "$STACK_DIR/docker-compose.yml")
  if [[ -f "$STACK_DIR/docker-compose.vpn.yml" ]]; then files+=(-f "$STACK_DIR/docker-compose.vpn.yml"); fi
  if [[ -f "$STACK_DIR/docker-compose.novpn.yml" ]]; then files+=(-f "$STACK_DIR/docker-compose.novpn.yml"); fi
  if [[ -f "$STACK_DIR/docker-compose.qsv.yml" ]]; then files+=(-f "$STACK_DIR/docker-compose.qsv.yml"); fi
  if [[ -f "$STACK_DIR/docker-compose.override.yml" ]]; then files+=(-f "$STACK_DIR/docker-compose.override.yml"); fi
  docker compose --project-directory "$STACK_DIR" \
    --env-file "$STACK_DIR/versions.env" --env-file "$STACK_DIR/.env" \
    "${files[@]}" "$@"
}

wait_for() {
  local timeout=$1; shift
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  return 1
}

container_healthy() {
  [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null)" == "healthy" ]]
}

http_code() { curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; }
http_ok()   { [[ "$(http_code "$1")" == "200" ]]; }

forwarded_port() {
  if (( USE_VPN )); then
    docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true
  fi
}
has_forwarded_port() { [[ "$(forwarded_port)" =~ ^[0-9]+$ ]]; }

qb_api() {
  if (( USE_VPN )); then
    docker exec gluetun wget -qO- -T 8 "http://127.0.0.1:8080/api/v2/$1" 2>/dev/null
  else
    # From the host, Docker's port proxy makes the request look non-local, so the localhost
    # auth bypass would not apply. Call the API from inside the container instead.
    docker exec qbittorrent wget -qO- -T 8 "http://127.0.0.1:8080/api/v2/$1" 2>/dev/null
  fi
}
qb_up()  { [[ "$(qb_api app/version)" == v* ]]; }
qb_listen_port() { qb_api app/preferences | grep -o '"listen_port":[0-9]*' | cut -d: -f2 || true; }

vpn_iface() {
  if (( USE_VPN )); then
    local i
    i=$(docker exec gluetun sh -c "ip -o link show | grep -oE '(wg|tun)[0-9]+' | head -n1" 2>/dev/null || true)
    printf '%s' "${i:-wg0}"
  fi
}

qb_set_port() {
  if (( USE_VPN )); then
    docker exec gluetun /bin/sh /gluetun/qb-port-up.sh "$1" "$(vpn_iface)" >/dev/null 2>&1
  fi
}

validate_wg() {
  local f=$1 bad=0 pat
  for pat in '^\[Interface\]' '^PrivateKey *=' '^Address *=' '^\[Peer\]' '^PublicKey *=' '^Endpoint *='; do
    if ! grep -Eq "$pat" "$f"; then echo "missing: ${pat//\\/}"; bad=1; fi
  done
  if ! grep -Eq '^PrivateKey *= *[A-Za-z0-9+/]{43}=' "$f"; then echo "PrivateKey is not a valid WireGuard key"; bad=1; fi
  return $bad
}

user_primary_gid() { getent passwd "$(id -un)" | cut -d: -f4; }

lan_ip() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -z $ip ]]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  fi
  printf '%s' "${ip:-SERVER-IP}"
}