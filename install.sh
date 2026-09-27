#!/usr/bin/env bash
# =====================================================================
#  Craftpick Filtrer — installeur
#
#  Contrairement à l'ancienne version, ce script ne contient plus le code :
#  il clone (ou met à jour) https://github.com/Craftpick/CraftpickFiltrer
#  dans /opt/craftpick-filtrer, puis déploie ce code via des liens symboliques.
#  Résultat : une mise à jour se fait avec `git pull` (ou `install.sh --update`),
#  pas en re-téléchargeant et en ré-exécutant un installeur de 1000 lignes.
#
#  Usage :
#    sudo bash install.sh                 (API + Filter, sur cette machine)
#    sudo bash install.sh --api-only      (juste l'API)
#    sudo bash install.sh --filter-only   (juste le filtre)
#    sudo bash install.sh --update        (git pull + redémarre les services déjà installés)
#    sudo bash install.sh --uninstall
#
#  Variables optionnelles : CF_IFACE, CF_PORTS, CF_API_URL, CF_API_KEY, CF_API_PORT, REPO_URL
# =====================================================================
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Craftpick/CraftpickFiltrer.git}"
INSTALL_DIR="/opt/craftpick-filtrer"

ok()   { echo -e "\e[32m[✓]\e[0m $*"; }
info() { echo -e "\e[36m[i]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*"; }
die()  { echo -e "\e[31m[✗]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Lance le script en root (sudo)."

MODE="all"
case "${1:-}" in
  --uninstall)    exec bash "$(dirname "${BASH_SOURCE[0]}")/uninstall.sh" "${@:2}" ;;
  --api-only)     MODE="api" ;;
  --filter-only)  MODE="filter" ;;
  --update)       MODE="update" ;;
  "")             MODE="all" ;;
  *)              die "Option inconnue : $1 (--api-only, --filter-only, --update, --uninstall)" ;;
esac

echo -e "\e[1;35m"
cat <<'BANNER'
   ___         __ _        _    _       _____ _ _ _
  / __|_ _ __ _/ _| |_ _ __(_)__| |__   |  ___(_) | |_ _ __ ___ _ __
 | (__| '_/ _` |  _|  _| '_ \ / _| / /  | |_  | | | __| '__/ _ \ '__|
  \___|_| \__,_|_|  \__| .__/_\__|_\_\  |  _| | | | |_| | |  __/ |
                       |_|                |_|   |_|_|\__|_|  \___|_|
BANNER
echo -e "\e[0m"

# ---------------------------------------------------------------------
# 1. Récupérer/mettre à jour le code depuis GitHub
# ---------------------------------------------------------------------
command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git >/dev/null; }

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Mise à jour du code ($INSTALL_DIR)..."
  git -C "$INSTALL_DIR" pull --ff-only || {
    warn "Mise à jour impossible en l'état (historique local modifié) — reclonage propre."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  }
else
  info "Clonage de $REPO_URL dans $INSTALL_DIR..."
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi
SRC="$INSTALL_DIR"
ok "Code à jour dans $SRC"

if [[ $MODE == update ]]; then
  systemctl is-enabled --quiet craftpick-api 2>/dev/null && systemctl restart craftpick-api && ok "craftpick-api redémarré"
  systemctl is-enabled --quiet craftpick-filter 2>/dev/null && systemctl restart craftpick-filter && ok "craftpick-filter redémarré"
  exit 0
fi

# ---------------------------------------------------------------------
# 2. Craftpick API
# ---------------------------------------------------------------------
install_api() {
  info "═══ Craftpick API ═══"

  need_node() { command -v node >/dev/null && [[ $(node -e 'console.log(process.versions.node.split(".")[0])') -ge 16 ]]; }
  if ! need_node; then
    info "Installation de Node.js..."
    if curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource.sh 2>/dev/null; then
      bash /tmp/nodesource.sh >/dev/null 2>&1 && apt-get install -y -qq nodejs >/dev/null
    else
      apt-get update -qq && apt-get install -y -qq nodejs npm >/dev/null
    fi
  fi
  need_node || die "Node.js >= 16 requis et introuvable après tentative d'installation."
  ok "Node.js $(node -v) disponible"

  mkdir -p /etc/craftpick-api /var/lib/craftpick-api/commands

  local NEW_INSTALL=0 PORT="${CF_API_PORT:-8688}" API_KEY
  if [[ ! -f /etc/craftpick-api/config.json ]]; then
    API_KEY=$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')
    node -e "
      const fs = require('fs');
      const ex = JSON.parse(fs.readFileSync('$SRC/api/config.json.example', 'utf8'));
      ex.port = $PORT; ex.apiKey = '$API_KEY';
      fs.writeFileSync('/etc/craftpick-api/config.json', JSON.stringify(ex, null, 2));
    "
    chmod 600 /etc/craftpick-api/config.json
    NEW_INSTALL=1
  else
    PORT=$(node -e "console.log(require('/etc/craftpick-api/config.json').port)")
    API_KEY=$(node -e "console.log(require('/etc/craftpick-api/config.json').apiKey)")
    ok "Configuration existante conservée (port $PORT)"
  fi

  ln -sf "$SRC/api/craftpick-api" /usr/local/bin/craftpick-api
  chmod 755 "$SRC/api/craftpick-api" "$SRC/api/server.js"
  cp "$SRC/api/systemd/craftpick-api.service" /etc/systemd/system/craftpick-api.service

  systemctl daemon-reload
  systemctl enable --now craftpick-api >/dev/null 2>&1
  systemctl restart craftpick-api
  sleep 1
  systemctl is-active --quiet craftpick-api || die "craftpick-api n'a pas démarré : journalctl -u craftpick-api -n 50"

  local IP; IP=$(hostname -I 2>/dev/null | awk '{print $1}'); IP="${IP:-127.0.0.1}"
  echo
  ok "Craftpick API installée et lancée en arrière-plan (systemd)"
  echo -e "  \e[1mDocumentation\e[0m : http://${IP}:${PORT}/docs"
  if (( NEW_INSTALL )); then
    echo -e "  \e[1mClé API\e[0m      : \e[33m${API_KEY}\e[0m"
    warn "Cette clé ne sera plus jamais réaffichée en clair — note-la maintenant (ou: craftpick-api key)."
  fi
  API_URL_FOR_FILTER="http://127.0.0.1:${PORT}/events"
  API_KEY_FOR_FILTER="$API_KEY"
}

# ---------------------------------------------------------------------
# 3. Craftpick Filter
# ---------------------------------------------------------------------
install_filter() {
  info "═══ Craftpick Filter ═══"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nftables jq curl iproute2 >/dev/null
  modprobe nf_conntrack 2>/dev/null || true
  ok "Dépendances installées"

  mkdir -p /etc/craftpick-filter /usr/local/lib/craftpick-filter /var/lib/craftpick-filter/spool /run/craftpick-filter

  local DEF_IF; DEF_IF=$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

  if [[ ! -f /etc/craftpick-filter/config.conf ]]; then
    local IN_IF="${CF_IFACE:-}" IN_PORTS="${CF_PORTS:-}" IN_API="${CF_API_URL:-${API_URL_FOR_FILTER:-}}" IN_KEY="${CF_API_KEY:-${API_KEY_FOR_FILTER:-}}"
    if [[ -t 0 ]]; then
      [[ -z $IN_IF    ]] && read -rp "Interface réseau [$DEF_IF] : " IN_IF
      [[ -z $IN_PORTS ]] && read -rp "Ports à protéger, séparés par des virgules, ou 'all' pour toute la machine [all] : " IN_PORTS
      if [[ -z $IN_API ]]; then
        read -rp "URL de l'API d'export (vide = désactivé) : " IN_API
        [[ -n $IN_API ]] && read -rp "Clé API (envoyée en Bearer) : " IN_KEY
      fi
    fi
    IN_IF="${IN_IF:-$DEF_IF}"
    IN_PORTS="${IN_PORTS:-all}"; IN_PORTS="${IN_PORTS//[[:space:]]/}"
    if [[ ${IN_PORTS,,} != "all" ]]; then
      [[ $IN_PORTS =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Format de ports invalide : $IN_PORTS"
    fi
    [[ -d /sys/class/net/$IN_IF ]] || die "Interface introuvable : $IN_IF"

    sed \
      -e "s#^SERVER_NAME=.*#SERVER_NAME=\"$(hostname -s)\"#" \
      -e "s#^INTERFACE=.*#INTERFACE=\"$IN_IF\"#" \
      -e "s#^PORTS=.*#PORTS=\"$IN_PORTS\"#" \
      -e "s#^API_URL=.*#API_URL=\"$IN_API\"#" \
      -e "s#^API_KEY=.*#API_KEY=\"$IN_KEY\"#" \
      "$SRC/filter/config.conf.example" > /etc/craftpick-filter/config.conf
    chmod 600 /etc/craftpick-filter/config.conf
    ok "Configuration créée : /etc/craftpick-filter/config.conf"
  else
    ok "Configuration existante conservée"
  fi

  if [[ ! -f /etc/craftpick-filter/whitelist.txt ]]; then
    cp "$SRC/filter/whitelist.txt.example" /etc/craftpick-filter/whitelist.txt
    local SSH_IP="${SSH_CLIENT:-}"; SSH_IP="${SSH_IP%% *}"
    [[ -n $SSH_IP ]] && echo "$SSH_IP   # IP SSH de l'installation" >> /etc/craftpick-filter/whitelist.txt
    [[ -n $SSH_IP ]] && ok "Ton IP SSH ($SSH_IP) a été ajoutée à la whitelist"
  fi

  cat > /etc/sysctl.d/99-craftpick-filter.conf <<'SYSCTL'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.netfilter.nf_conntrack_max = 262144
SYSCTL
  sysctl --system >/dev/null 2>&1 || true
  ok "Paramètres kernel appliqués (SYN cookies, backlog, anti-spoof)"

  chmod 755 "$SRC/filter/craftpick-filter" "$SRC/filter/craftpick-filterd" "$SRC/filter/apply-rules.sh"
  ln -sf "$SRC/filter/craftpick-filter"  /usr/local/bin/craftpick-filter
  ln -sf "$SRC/filter/craftpick-filterd" /usr/local/bin/craftpick-filterd
  ln -sf "$SRC/filter/apply-rules.sh"    /usr/local/lib/craftpick-filter/apply-rules.sh
  cp "$SRC/filter/systemd/craftpick-filter.service" /etc/systemd/system/craftpick-filter.service

  cat > /etc/logrotate.d/craftpick-filter <<'ROTATE'
/var/log/craftpick-filter.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  copytruncate
}
ROTATE

  systemctl daemon-reload
  systemctl enable --now craftpick-filter >/dev/null 2>&1
  systemctl restart craftpick-filter
  sleep 1
  systemctl is-active --quiet craftpick-filter || die "craftpick-filter n'a pas démarré : journalctl -u craftpick-filter -n 50"

  ok "Craftpick Filter installé et actif"
  info "Phase d'apprentissage du trafic normal : ~2 min avant la détection des pics"
  info "Config    : /etc/craftpick-filter/config.conf"
  info "Whitelist : /etc/craftpick-filter/whitelist.txt"
}

[[ $MODE == all || $MODE == api    ]] && install_api
[[ $MODE == all || $MODE == filter ]] && install_filter

echo
ok "Installation terminée."
info "Mettre à jour plus tard : sudo bash $INSTALL_DIR/install.sh --update  (ou relance ce script)"
info "Commandes : craftpick-filter status | craftpick-api status | craftpick-filter logs | craftpick-api logs"
