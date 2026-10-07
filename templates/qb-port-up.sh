#!/bin/sh
# Called by Gluetun when Proton assigns a forwarded port: $1 = port, $2 = VPN interface.
PORT="$1"
IFACE="$2"
wget -O- -nv --retry-connrefused \
  --post-data "json={\"listen_port\":${PORT},\"current_network_interface\":\"${IFACE}\",\"random_port\":false,\"upnp\":false}" \
  http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1
