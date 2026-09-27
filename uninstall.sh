#!/usr/bin/env bash
# Désinstalle Craftpick Filter et/ou Craftpick API.
# Usage : sudo bash uninstall.sh [--keep-data]
set -euo pipefail

ok()   { echo -e "\e[32m[✓]\e[0m $*"; }
info() { echo -e "\e[36m[i]\e[0m $*"; }

[[ $EUID -eq 0 ]] || { echo "Lance le script en root (sudo)." >&2; exit 1; }
KEEP_DATA=0
[[ "${1:-}" == "--keep-data" ]] && KEEP_DATA=1

for svc in craftpick-filter craftpick-api; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

nft delete table inet craftpick_filter 2>/dev/null || true

rm -f /etc/systemd/system/craftpick-filter.service /etc/systemd/system/craftpick-api.service
rm -f /usr/local/bin/craftpick-filter /usr/local/bin/craftpick-filterd /usr/local/bin/craftpick-api
rm -f /usr/local/lib/craftpick-filter/apply-rules.sh
rm -f /etc/sysctl.d/99-craftpick-filter.conf /etc/logrotate.d/craftpick-filter
systemctl daemon-reload

ok "Services et liens supprimés."

if (( ! KEEP_DATA )); then
  rm -rf /opt/craftpick-filtrer
  rm -rf /etc/craftpick-filter /etc/craftpick-api
  rm -rf /var/lib/craftpick-filter /var/lib/craftpick-api
  ok "Code, configuration et données supprimés."
else
  info "Code, configuration (/etc/craftpick-filter, /etc/craftpick-api) et données (/var/lib/craftpick-*) conservés."
  info "Pour tout supprimer plus tard : sudo bash uninstall.sh (sans --keep-data)."
fi

ok "Craftpick Filtrer désinstallé."
