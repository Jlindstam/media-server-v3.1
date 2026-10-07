#!/usr/bin/env bash
# Home media server bootstrap for Debian 13 (x86-64).
# Run as a normal user (not root) from inside the kit folder:  ./install.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/scripts/lib.sh"

ASSUME_YES=0
WG_CONF_SRC=""
WITH_TAILSCALE=0
WITH_VPN=1
MEDIA_DIR="${MEDIA_DIR:-$HOME/media}"

usage() {
  cat <<EOF
Usage: ./install.sh [options]
  --media DIR       media root (default: ~/media)
  --stack DIR       compose/stack folder (default: ~/stack)
  --wg-conf FILE    Proton WireGuard config to use (otherwise you are prompted)
  --no-vpn          disable Gluetun VPN and run torrent client directly on LAN
  --tailscale       also install Tailscale (you sign in interactively)
  --yes             do not ask for confirmation
  -h, --help        this help
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --media)     MEDIA_DIR="$2"; shift 2 ;;
    --stack)     STACK_DIR="$2"; shift 2 ;;
    --wg-conf)   WG_CONF_SRC="$2"; shift 2 ;;
    --no-vpn)    WITH_VPN=0; shift ;;
    --tailscale) WITH_TAILSCALE=1; shift ;;
    --yes)       ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
MEDIA_DIR="$(realpath -m "$MEDIA_DIR")"
STACK_DIR="$(realpath -m "$STACK_DIR")"

confirm() {
  (( ASSUME_YES )) && return 0
  local a; read -r -p "$1 [y/N] " a
  [[ $a == [yY]* ]]
}

# ---------------------------------------------------------------- preflight
preflight() {
  step "Preflight"
  [[ $EUID -ne 0 ]] || die "Run as a normal user, not root. The script uses sudo where needed."
  command -v sudo >/dev/null || die "sudo is required (apt install sudo, as root)."
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} != debian ]]; then
    confirm "This is ${PRETTY_NAME:-not Debian}; the kit targets Debian 13. Continue anyway?" || exit 1
  fi
  sudo -v
}

install_base_packages() {
  step "Base packages"
  sudo apt-get update
  sudo apt-get install -y curl wget ca-certificates gnupg git nano unzip util-linux
}

install_docker() {
  step "Docker"
  if ! { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; } && ! sudo docker compose version >/dev/null 2>&1; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    local codename
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    info "Docker and Compose already installed"
  fi
  sudo systemctl enable --now docker
  if ! id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$(id -un)"
  fi
  if ! docker info >/dev/null 2>&1; then
    if [[ -z ${INSTALL_REEXEC:-} ]] && getent group docker | grep -qw "$(id -un)"; then
      info "Activating the docker group and continuing..."
      export INSTALL_REEXEC=1
      exec sg docker -c "$(printf '%q ' "$0" "${ORIG_ARGS[@]}")"
    fi
    die "Docker is installed but not usable by $(id -un). Log out and back in, then re-run ./install.sh"
  fi
}

ensure_swap() {
  step "Swap"
  local mem_mb
  mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then info "Swap already active"; return 0; fi
  if (( mem_mb > 6144 )); then info "${mem_mb} MB RAM: swap not needed"; return 0; fi
  if [[ -e /swapfile ]]; then warn "/swapfile exists but is not active; leaving it alone"; return 0; fi
  info "Creating a 2 GB swap file (${mem_mb} MB RAM)"
  sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
}

# ---------------------------------------------------------------- files
ensure_env_var() {
  grep -q "^$1=" "$STACK_DIR/.env" 2>/dev/null || echo "$1=$2" >>"$STACK_DIR/.env"
}

create_layout() {
  step "Folders and stack files"
  local uid gid
  uid=$(id -u); gid=$(user_primary_gid)

  mkdir -p "$MEDIA_DIR/Jellyfin/Movies" "$MEDIA_DIR/Jellyfin/Shows" \
           "$MEDIA_DIR/qbittorrent/config" "$MEDIA_DIR/qbittorrent/downloads/radarr" "$MEDIA_DIR/qbittorrent/downloads/sonarr" \
           "$MEDIA_DIR/torlink/downloads" "$MEDIA_DIR/gluetun/wireguard" \
           "$MEDIA_DIR/radarr/config" "$MEDIA_DIR/sonarr/config" "$MEDIA_DIR/seerr/config" \
           "$MEDIA_DIR/jellyfin/config" "$MEDIA_DIR/jellyfin/cache" "$STACK_DIR"

  install -m 0644 "$SCRIPT_DIR/stack/docker-compose.yml" "$STACK_DIR/docker-compose.yml"
  if (( WITH_VPN )); then
    install -m 0644 "$SCRIPT_DIR/stack/docker-compose.vpn.yml" "$STACK_DIR/docker-compose.vpn.yml"
    rm -f "$STACK_DIR/docker-compose.novpn.yml"
  else
    install -m 0644 "$SCRIPT_DIR/stack/docker-compose.novpn.yml" "$STACK_DIR/docker-compose.novpn.yml"
    rm -f "$STACK_DIR/docker-compose.vpn.yml"
  fi
  if [[ ! -f "$STACK_DIR/versions.env" ]]; then
    install -m 0644 "$SCRIPT_DIR/versions.env" "$STACK_DIR/versions.env"
  else
    info "Keeping existing $STACK_DIR/versions.env (your pinned versions)"
  fi
  install -m 0644 "$SCRIPT_DIR/templates/qb-port-up.sh"   "$MEDIA_DIR/gluetun/qb-port-up.sh"
  install -m 0644 "$SCRIPT_DIR/templates/qb-port-down.sh" "$MEDIA_DIR/gluetun/qb-port-down.sh"

  local tz
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  touch "$STACK_DIR/.env"
  local old_media
  old_media=$(sed -n 's/^MEDIA=//p' "$STACK_DIR/.env" | head -n1)
  if [[ -n $old_media && $old_media != "$MEDIA_DIR" ]]; then
    die "$STACK_DIR/.env already points at MEDIA=$old_media but you asked for $MEDIA_DIR. Use the same --media, or edit .env deliberately."
  fi
  ensure_env_var MEDIA "$MEDIA_DIR"
  ensure_env_var PUID "$uid"
  ensure_env_var PGID "$gid"
  ensure_env_var TZ "${tz:-UTC}"
  
  # Remove existing USE_VPN line to set the new state
  sed -i '/^USE_VPN=/d' "$STACK_DIR/.env" 2>/dev/null || true
  echo "USE_VPN=$WITH_VPN" >>"$STACK_DIR/.env"

  if [[ -e /dev/dri/renderD128 ]]; then
    ensure_env_var RENDER_GID "$(stat -c %g /dev/dri/renderD128)"
    install -m 0644 "$SCRIPT_DIR/stack/docker-compose.qsv.yml" "$STACK_DIR/docker-compose.qsv.yml"
    info "Intel/VAAPI render device found: Jellyfin will get /dev/dri"
  else
    rm -f "$STACK_DIR/docker-compose.qsv.yml"
    warn "No /dev/dri found" "Jellyfin will transcode in software"
  fi

  local qbconf="$MEDIA_DIR/qbittorrent/config/qBittorrent/qBittorrent.conf"
  if [[ ! -f $qbconf ]]; then
    mkdir -p "$(dirname "$qbconf")"
    cat >"$qbconf" <<'EOF'
[LegalNotice]
Accepted=true

[Preferences]
Downloads\SavePath=/data/qbittorrent/downloads/
WebUI\LocalHostAuth=false
WebUI\Port=8080
EOF
  fi

  sudo chown -R "$uid:$gid" "$MEDIA_DIR"
}

# ---------------------------------------------------------------- VPN config
get_wg_conf() {
  (( WITH_VPN )) || return 0
  step "Proton VPN WireGuard config"
  local dest="$MEDIA_DIR/gluetun/wireguard/wg0.conf" reply problems
  if [[ -n $WG_CONF_SRC ]]; then
    [[ -f $WG_CONF_SRC ]] || die "wg0.conf not found: $WG_CONF_SRC"
    if ! [[ $WG_CONF_SRC -ef $dest ]]; then install -m 600 "$WG_CONF_SRC" "$dest"; fi
  fi
  while true; do
    if [[ -f $dest ]]; then
      sed -i 's/\r$//' "$dest"
      chmod 600 "$dest"
      if problems=$(validate_wg "$dest"); then break; fi
      warn "wg0.conf looks wrong" "$problems"
    fi
    if (( ASSUME_YES )) || [[ ! -t 0 ]]; then
      die "A valid Proton WireGuard config is required at $dest (or pass --wg-conf FILE)."
    fi
    cat <<EOF

  You need your own Proton VPN WireGuard config. In Proton's WireGuard config
  generator pick a P2P server and turn ON "NAT-PMP (Port Forwarding)", then
  download the file. Copy it to:

      $dest

  or type the path to it below. It contains a private key; never share it.
EOF
    read -r -p "  Press ENTER when it is in place, or type a path: " reply
    if [[ -n $reply ]]; then
      reply="${reply/#\~/$HOME}"
      if [[ -f $reply ]]; then install -m 600 "$reply" "$dest"; else warn "File not found" "$reply"; fi
    fi
  done
  if grep -Eiq 'NAT-PMP.*= *on' "$dest"; then
    info "  NAT-PMP is enabled in the config"
  else
    warn "Could not confirm NAT-PMP is enabled" "If no forwarded port appears, regenerate the config with NAT-PMP on"
  fi
}

# ---------------------------------------------------------------- start
start_vpn() {
  if (( ! WITH_VPN )); then
    info "VPN disabled by user flag (--no-vpn)"
    return 0
  fi
  step "Starting the VPN (Gluetun)"
  dc pull gluetun
  dc up -d gluetun
  info "Waiting for the tunnel to come up (up to 2 minutes)..."
  if ! wait_for 120 container_healthy gluetun; then
    docker logs --tail 40 gluetun || true
    die "Gluetun did not become healthy. Check the log above (expired key? wrong server?)."
  fi
  info "Waiting for a Proton forwarded port (up to 2 minutes)..."
  if wait_for 120 has_forwarded_port; then
    info "  forwarded port: $(forwarded_port)"
  else
    warn "No forwarded port yet" "Downloads still work but with fewer peers. See health-check output."
  fi
}

start_stack() {
  step "Starting services"
  dc pull
  dc up -d --remove-orphans

  info "Waiting for services (up to 3 minutes each)..."
  wait_for 180 http_ok "http://127.0.0.1:7878/ping" || true
  wait_for 180 http_ok "http://127.0.0.1:8989/ping" || true
  wait_for 180 http_ok "http://127.0.0.1:8096/health" || true
  wait_for 180 http_ok "http://127.0.0.1:5055/api/v1/status" || true
  if wait_for 120 qb_up; then
    if (( ! WITH_VPN )); then
      # A previous VPN install can leave qBittorrent bound to the (now missing) tunnel interface.
      docker exec qbittorrent wget -qO- -T 8 \
        --post-data 'json={"current_network_interface":"","listen_port":6881,"random_port":false}' \
        http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null 2>&1 || true
    fi
    local c
    for c in radarr sonarr; do
      if (( WITH_VPN )); then
        docker exec gluetun wget -qO- -T 8 \
          --post-data "category=$c&savePath=/data/qbittorrent/downloads/$c" \
          http://127.0.0.1:8080/api/v2/torrents/createCategory >/dev/null 2>&1 || true
      else
        docker exec qbittorrent wget -qO- -T 8 \
          --post-data "category=$c&savePath=/data/qbittorrent/downloads/$c" \
          http://127.0.0.1:8080/api/v2/torrents/createCategory >/dev/null 2>&1 || true
      fi
    done
  fi
}

install_tailscale() {
  (( WITH_TAILSCALE )) || return 0
  step "Tailscale"
  if ! command -v tailscale >/dev/null; then curl -fsSL https://tailscale.com/install.sh | sh; fi
  sudo tailscale up
  info "Tailscale IP: $(tailscale ip -4 2>/dev/null | head -n1)"
}

final_report() {
  step "Verification"
  local rc=0
  "$SCRIPT_DIR/scripts/health-check.sh" --fix || rc=$?
  local ip; ip=$(lan_ip)
  local download_host="gluetun"
  local indexer_host="http://gluetun:9117"
  if (( ! WITH_VPN )); then
    download_host="qbittorrent"
    indexer_host="http://torlink:9117"
  fi
  cat <<EOF

========================================
  INSTALL $( ((rc == 0)) && echo COMPLETE || echo "FINISHED WITH PROBLEMS (see FAIL lines above)" )
========================================
  Jellyfin     http://$ip:8096
  Seerr        http://$ip:5055
  Radarr       http://$ip:7878
  Sonarr       http://$ip:8989
  qBittorrent  http://$ip:8080
  TorLink++    http://$ip:19117

  Still manual (first-run wiring inside each app):
   1. qBittorrent: look up the temporary password with
        docker logs qbittorrent 2>&1 | grep -i password
      then set a permanent username and password.
   2. Jellyfin: run the setup wizard. Libraries: /media/Movies and /media/Shows.
      Enable Intel QuickSync under Dashboard > Playback > Transcoding.
   3. Radarr / Sonarr: root folders /data/Jellyfin/Movies and /data/Jellyfin/Shows;
      download client host "$download_host", port 8080, categories radarr / sonarr;
      indexer $indexer_host with your own TorLink API key.
   4. Seerr: connect Jellyfin (http://jellyfin:8096), Radarr (http://radarr:7878),
      Sonarr (http://sonarr:8989). Keep automatic approval off.

  Afterwards:
EOF
  if (( WITH_VPN )); then
    echo "    scripts/killswitch-test.sh      verify the VPN kill switch"
  else
    echo "  NOTE: no VPN. Downloads use your home IP. Re-run ./install.sh (without --no-vpn) to add one."
  fi
  cat <<EOF
    scripts/pin-versions.sh         lock the working image versions
    scripts/backup.sh               archive configs
========================================
EOF
  return "$rc"
}

main() {
  preflight
  install_base_packages
  install_docker
  step "Hardware"
  USE_VPN="$WITH_VPN" "$SCRIPT_DIR/scripts/hardware-check.sh" "$MEDIA_DIR" || true
  confirm "Continue with the install?" || exit 1
  ensure_swap
  create_layout
  get_wg_conf
  load_env
  start_vpn
  start_stack
  install_tailscale
  final_report
}

main