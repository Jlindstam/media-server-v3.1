#!/usr/bin/env bash
# Archive configs and stack files (including the WireGuard key, so keep the archive private).
# Usage: backup.sh [DEST_DIR] [--full]     default DEST_DIR: ~/backups
#   --full   also include Jellyfin metadata/images (large; otherwise it re-scrapes)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env

DEST="$HOME/backups"; FULL=0
for a in "$@"; do
  case $a in
    --full) FULL=1 ;;
    *) DEST="$a" ;;
  esac
done

umask 077
mkdir -p "$DEST"
out="$DEST/media-server-config-$(date +%F-%H%M).tar.gz"

media_parent=$(dirname "$MEDIA"); media_name=$(basename "$MEDIA")
stack_parent=$(dirname "$STACK_DIR"); stack_name=$(basename "$STACK_DIR")

members=()
for d in radarr/config sonarr/config seerr/config qbittorrent/config jellyfin/config gluetun; do
  if [[ -e "$MEDIA/$d" ]]; then members+=("$media_name/$d"); fi
done

excludes=(--exclude='*/cache')
if (( ! FULL )); then
  excludes+=(--exclude='*/jellyfin/config/metadata' --exclude='*/jellyfin/config/transcodes' --exclude='*/jellyfin/config/log')
fi

tar czf "$out" "${excludes[@]}" -C "$media_parent" "${members[@]}" -C "$stack_parent" "$stack_name"
echo "Backup written: $out ($(du -h "$out" | cut -f1))"

# Keep the newest 8 archives.
ls -1t "$DEST"/media-server-config-*.tar.gz 2>/dev/null | tail -n +9 | xargs -r rm -f
echo "Copy it off this machine (another PC, cloud, or external drive)."
