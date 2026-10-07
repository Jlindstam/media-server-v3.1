================================================================================

Home Media Server Kit (v3)

================================================================================

Bootstrap for a Docker media server on Debian 13 (x86-64): Jellyfin, Seerr,
Radarr, Sonarr, TorLink++, qBittorrent behind optional Gluetun and Proton VPN,
optional Tailscale.

When enabled, only qBittorrent and TorLink++ run through the VPN. Everything
else stays on the normal Docker/LAN network. When VPN is disabled (--no-vpn),
all containers run directly on the standard Docker network.

Quick start

Install Debian 13 normally (minimal, SSH on, a normal user with sudo).

Copy this folder to the server.

If using VPN: Generate a Proton WireGuard config yourself: pick a P2P server
and turn on NAT-PMP (Port Forwarding).

Run:

./install.sh                       # prompts for VPN setup / WireGuard file
./install.sh --no-vpn              # install without VPN (standalone LAN network)
./install.sh --wg-conf ~/wg0.conf  # pass WireGuard config up front
./install.sh --tailscale           # also install Tailscale

Options: --media DIR, --stack DIR, --no-vpn, --yes (no prompts; needs --wg-conf or --no-vpn).

Re-running is safe. It keeps your .env, your pinned versions.env, and an
existing qBittorrent config.

Note for VirtualBox Users: If accessing Web UIs from a browser inside the VM
desktop, use http://localhost:PORT or http://127.0.0.1:PORT. If accessing from
the host machine browser, ensure the VM network is set to Bridged Adapter or
configure port forwarding in VirtualBox settings.

What the installer does

Preflight, base packages, Docker Engine + Compose from Docker's apt repo.

Hardware report (CPU, RAM, Quick Sync, disk, network).

Adds a 2 GB swap file when RAM is 6 GB or less and no swap exists.

Creates ~/media and ~/stack, writes .env (UID/GID, timezone, render group
detected from /dev/dri/renderD128, and USE_VPN).

Adds docker-compose.qsv.yml only if the host has a GPU render device.

If VPN is enabled: Validates your WireGuard file (keys, endpoint, line endings),
starts Gluetun, waits for the tunnel and a forwarded port.

Starts the rest of the services, creates the radarr and sonarr qBittorrent
categories.

Runs health-check.sh --fix.

Scripts

scripts/health-check.sh [--fix]:
Containers, VPN exit IP vs. home IP (if VPN enabled), forwarded port,
qBittorrent port match, service endpoints, hardlinks, disk, swap,
Quick Sync. --fix sets qBittorrent's port if it differs. Exit code 1 on
any FAIL.

scripts/killswitch-test.sh [--yes]:
Takes the tunnel interface down inside Gluetun (container stays up) and
checks qBittorrent's network is blocked by hostname and by raw IP, then
restores the VPN. (Skipped if running --no-vpn).

scripts/hardware-check.sh [MEDIA_DIR]:
Hardware report only.

scripts/pin-versions.sh:
Rewrites versions.env with the exact image digests of the running
containers.

scripts/backup.sh [DEST] [--full]:
Archives configs, wg0.conf (if present), and stack files. Keeps the
newest 8.

Pinning versions

versions.env ships with floating tags so a fresh kit works anywhere. For a
reproducible kit:

Run the install on a server and confirm everything works.

Run scripts/pin-versions.sh.

Copy ~/stack/versions.env back into the kit folder.

From then on the kit installs those exact images. To upgrade, put a tag back
for one service, test, then pin again.

Layout

media-server-v3.1/
install.sh
versions.env
stack/        docker-compose.yml (core), docker-compose.vpn.yml / docker-compose.novpn.yml
              (qBittorrent + TorLink++, behind Gluetun or direct), docker-compose.qsv.yml
templates/    qb-port-up.sh, qb-port-down.sh
scripts/      lib.sh, hardware-check.sh, health-check.sh,
killswitch-test.sh, pin-versions.sh, backup.sh

Local changes go in ~/stack/docker-compose.override.yml; install.sh overwrites
docker-compose.yml.

Still manual (first-run wiring)

The apps keep their setup in their own databases, so these steps are done once
in each UI:

qBittorrent (http://localhost:8080):
Get the temporary password:
docker logs qbittorrent 2>&1 | grep -i password
Log in as admin, then set a permanent password under Tools > Options > Web UI.

Jellyfin (http://localhost:8096):
Run the setup wizard. Set media libraries to /media/Movies and /media/Shows.
Enable QuickSync under Dashboard > Playback if GPU passthrough is enabled.

Radarr (http://localhost:7878) & Sonarr (http://localhost:8989):

Root Folders: /data/Jellyfin/Movies and /data/Jellyfin/Shows.

Download Client: Add qBittorrent using Host qbittorrent (or gluetun if using
VPN) on Port 8080, with Category radarr or sonarr.

Indexer: Add TorLink++ using http://torlink:9117 (or http://gluetun:9117
if using VPN) along with your TorLink API key.

Seerr (http://localhost:5055):
Connect Jellyfin (http://jellyfin:8096), Radarr (http://radarr:7878), and
Sonarr (http://sonarr:8989). Keep automatic approval off.

Known limits

What was tested: verified working end-to-end inside a Debian 13 VM; script
syntax; YAML validity; WireGuard config validation, CRLF cleanup and refusal
of bad files; health-check.sh pass, mismatch, --fix, and VPN-leak paths;
killswitch-test.sh blocked and leak paths; pin-versions.sh; backup.sh;
installer argument parsing.

What was checked against current documentation: Proton port forwarding with
Gluetun's custom provider (VPN_PORT_FORWARDING_PROVIDER=protonvpn), the
{{PORT}} / {{VPN_INTERFACE}} command placeholders, the forwarded-port status
file path, Proton's NAT-PMP (Port Forwarding) config comment, qBittorrent's
WebUI\LocalHostAuth key, Seerr's non-root (UID 1000) container and init: true,
and Jellyfin's /dev/dri + render-group setup with jellyfin-ffmpeg/vainfo.

qBittorrent pre-seeding: install.sh writes WebUI\LocalHostAuth=false before
first start so port sync works. If your version ignores it, health-check.sh
fails and names the setting to turn on in the UI.

Kill-switch test needs ip inside the Gluetun image. If it is missing, the test
reports SKIP instead of guessing.

Seerr runs as your host user (user: PUID:PGID) so its config folder permissions
always match, instead of assuming UID 1000.

~/media/Jellyfin (library) and ~/media/jellyfin (Jellyfin config) differ only
by case. That is fine on Linux filesystems but breaks on exFAT/NTFS, so keep
~/media on ext4/xfs/btrfs.

No remote ports are opened. Use Tailscale for access away from home.

wg0.conf and backups contain secrets. Do not put them in a shared copy of
the kit.