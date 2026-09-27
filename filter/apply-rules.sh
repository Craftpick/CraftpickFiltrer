#!/usr/bin/env bash
# Applique les règles nftables de Craftpick Filter (--force pour recréer la table)
#
# Sécurité : le ruleset est d'abord validé avec `nft -c` (mode "check", sans effet)
# avant de toucher à la table existante. Si la validation échoue (ex: entrée
# malformée dans whitelist.txt), le script s'arrête sans rien casser — la table
# actuelle reste intacte plutôt que d'être supprimée puis jamais recréée.
set -euo pipefail
source /etc/craftpick-filter/config.conf
T=craftpick_filter

EXISTS=0
nft list table inet $T &>/dev/null && EXISTS=1
if (( EXISTS )) && [[ "${1:-}" != "--force" ]]; then
  exit 0
fi

if [[ ${PORTS,,} == "all" ]]; then
  DPORT=""     # aucun filtre de port => toute la machine, tous les services
else
  DPORT="tcp dport { ${PORTS//,/, } } "
fi

W4=(); W6=()
while IFS= read -r l || [[ -n $l ]]; do
  l="${l%%#*}"; l="${l//[[:space:]]/}"
  [[ -z $l ]] && continue
  if [[ $l == *:* ]]; then W6+=("$l"); else W4+=("$l"); fi
done < /etc/craftpick-filter/whitelist.txt
E4=""; E6=""
(( ${#W4[@]} )) && E4="elements = { $(IFS=,; echo "${W4[*]}") }"
(( ${#W6[@]} )) && E6="elements = { $(IFS=,; echo "${W6[*]}") }"

RULESET=$(cat <<NFT
table inet $T {
  counter newconns { }
  counter dropped { }

  set whitelist4 { type ipv4_addr; flags interval; $E4 }
  set whitelist6 { type ipv6_addr; flags interval; $E6 }
  set blacklist4 { type ipv4_addr; flags timeout; }
  set blacklist6 { type ipv6_addr; flags timeout; }
  set known4 { type ipv4_addr; flags timeout; timeout 24h; size 65535; }
  set known6 { type ipv6_addr; flags timeout; timeout 24h; size 65535; }
  set rate4 { type ipv4_addr; flags dynamic,timeout; timeout 1m; size 65535; }
  set rate6 { type ipv6_addr; flags dynamic,timeout; timeout 1m; size 65535; }
  set cc4 { type ipv4_addr; flags dynamic; size 65535; }
  set cc6 { type ipv6_addr; flags dynamic; size 65535; }

  chain lockdown { }

  chain input {
    type filter hook input priority -10; policy accept;
    iif "lo" accept
    ip saddr @whitelist4 accept
    ip6 saddr @whitelist6 accept
    ip saddr @blacklist4 counter name "dropped" drop
    ip6 saddr @blacklist6 counter name "dropped" drop

    ct state invalid counter name "dropped" drop
    tcp flags & (fin|syn|rst|ack) != syn ct state new counter name "dropped" drop
    tcp flags & (fin|syn) == (fin|syn) counter name "dropped" drop
    tcp flags & (syn|rst) == (syn|rst) counter name "dropped" drop
    icmp type echo-request limit rate over 10/second burst 20 packets counter name "dropped" drop
    icmpv6 type echo-request limit rate over 10/second burst 20 packets counter name "dropped" drop

    ${DPORT}ct state new counter name "newconns"
    ${DPORT}ct state new jump lockdown
    ${DPORT}ct state new add @rate4 { ip saddr limit rate over ${NFT_NEWCONN_RATE}/second burst ${NFT_NEWCONN_BURST} packets } counter name "dropped" drop
    ${DPORT}ct state new add @rate6 { ip6 saddr limit rate over ${NFT_NEWCONN_RATE}/second burst ${NFT_NEWCONN_BURST} packets } counter name "dropped" drop
    ${DPORT}ct state new add @cc4 { ip saddr ct count over ${NFT_MAX_CONN_PER_IP} } counter name "dropped" drop
    ${DPORT}ct state new add @cc6 { ip6 saddr ct count over ${NFT_MAX_CONN_PER_IP} } counter name "dropped" drop
  }
}
NFT
)

# --- validation à blanc : n'importe quelle erreur de syntaxe s'arrête ici,
#     sans avoir touché à la table nftables actuellement en place ---
if ! nft -c -f - <<< "$RULESET" 2>/tmp/craftpick-filter-nft-check.err; then
  echo "[craftpick-filter] ERREUR : ruleset nftables invalide, aucune modification appliquée." >&2
  cat /tmp/craftpick-filter-nft-check.err >&2
  exit 1
fi

(( EXISTS )) && nft delete table inet $T
nft -f - <<< "$RULESET"
