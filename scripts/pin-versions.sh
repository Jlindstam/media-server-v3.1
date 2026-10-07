#!/usr/bin/env bash
# Rewrite versions.env with the exact image digests of the RUNNING containers.
# Run this on a server where everything works, then keep the pinned file in the kit.
# Usage: pin-versions.sh [path/to/versions.env]   (default: $STACK_DIR/versions.env)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env

OUT="${1:-$STACK_DIR/versions.env}"
[[ -f $OUT ]] && cp "$OUT" "$OUT.bak"

declare -A VARS=(
  [gluetun]=GLUETUN_IMAGE
  [qbittorrent]=QBITTORRENT_IMAGE
  [torlink]=TORLINK_IMAGE
  [jellyfin]=JELLYFIN_IMAGE
  [seerr]=SEERR_IMAGE
  [radarr]=RADARR_IMAGE
  [sonarr]=SONARR_IMAGE
)

{
  echo "# Pinned by scripts/pin-versions.sh on $(date +%F)."
  echo "# Digests lock the exact images that were running. To upgrade one service,"
  echo "# put a tag back, test it, then run pin-versions.sh again."
  echo
  for c in gluetun qbittorrent torlink jellyfin seerr radarr sonarr; do
    if [[ $c == gluetun ]] && (( ! USE_VPN )); then
      # VPN off: keep the existing Gluetun line so turning the VPN on later still works.
      grep '^GLUETUN_IMAGE=' "$OUT.bak" 2>/dev/null || echo "GLUETUN_IMAGE=qmcgaw/gluetun:v3"
      continue
    fi
    id=$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null) || { echo "container $c is not running" >&2; exit 1; }
    ref=$(docker inspect -f '{{.Config.Image}}' "$c")
    digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$id" | head -n1)
    ver=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$id" 2>/dev/null || true)
    if [[ -z $ver || $ver == "<no value>" ]]; then
      ver=$(docker image inspect -f '{{index .Config.Labels "build_version"}}' "$id" 2>/dev/null || true)
    fi
    [[ $ver == "<no value>" ]] && ver=""
    if [[ -z $digest ]]; then
      echo "warning: no registry digest for $c ($ref); keeping the tag" >&2
      digest="$ref"
    fi
    printf '%s=%s  # %s %s\n' "${VARS[$c]}" "$digest" "$ref" "${ver:+(${ver%%$'\n'*})}"
  done
} >"$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "Wrote $OUT (previous copy: $OUT.bak)"
cat "$OUT"
