# Craftpick Filtrer

Anti-DDoS maison pour VPS, en deux services :

- **Craftpick Filter** — démon bash + nftables. Protection couche 4 (TCP : nouvelles
  connexions, connexions simultanées, SYN flood) et couche 7 (HTTP : floods de
  requêtes via connexions persistantes/keep-alive, invisibles pour un filtre TCP).
  Apprend le trafic normal de la machine (baseline) et détecte les pics.
- **Craftpick API** — petit serveur Node.js (aucune dépendance externe) qui reçoit
  les alertes d'attaque exportées par le(s) Craftpick Filter, et permet de
  piloter à distance : ban, unban, whitelist, lockdown.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/Craftpick/CraftpickFiltrer/main/install.sh | sudo bash
```

Ou, si tu préfères avoir le code en local avant de l'exécuter :

```bash
git clone https://github.com/Craftpick/CraftpickFiltrer.git
cd CraftpickFiltrer
sudo bash install.sh
```

Dans les deux cas, le script s'assure que le code est cloné dans `/opt/craftpick-filtrer`
(clonage si absent, `git pull` sinon), puis déploie les fichiers par liens symboliques
et crée les services systemd. **Mettre à jour plus tard ne redemande jamais de
tout retélécharger** :

```bash
sudo bash /opt/craftpick-filtrer/install.sh --update
```

### Options d'installation

| Commande | Effet |
|---|---|
| `install.sh` | Installe l'API et le Filter sur cette machine |
| `install.sh --api-only` | Installe uniquement Craftpick API |
| `install.sh --filter-only` | Installe uniquement Craftpick Filter |
| `install.sh --update` | `git pull` + redémarre les services déjà installés |
| `install.sh --uninstall` | Désinstalle tout (`--keep-data` pour garder config/données) |

Variables d'environnement pour une install non interactive :
`CF_IFACE`, `CF_PORTS` (ou `all`), `CF_API_URL`, `CF_API_KEY`, `CF_API_PORT`.

Si tes serveurs sont sur des machines différentes : installe l'API une fois
avec `--api-only`, puis sur chaque VPS `--filter-only` en donnant `CF_API_URL`
et `CF_API_KEY` (affichés à la fin de l'install de l'API, récupérables ensuite
avec `craftpick-api key`).

## Structure du dépôt

```
CraftpickFiltrer/
├── install.sh                       installeur (clone/update + déploiement)
├── uninstall.sh
├── filter/
│   ├── craftpick-filterd            démon d'analyse (couche 4 + couche 7)
│   ├── craftpick-filter             CLI (status, ban, whitelist, logs...)
│   ├── apply-rules.sh               génère et valide les règles nftables
│   ├── config.conf.example
│   ├── whitelist.txt.example
│   └── systemd/craftpick-filter.service
└── api/
    ├── server.js                    serveur HTTP/HTTPS (Node.js natif)
    ├── craftpick-api                CLI (status, ban à distance, logs...)
    ├── config.json.example
    └── systemd/craftpick-api.service
```

Les fichiers déployés (`/usr/local/bin/craftpick-filter`, etc.) sont des
**liens symboliques** vers ce dépôt cloné dans `/opt/craftpick-filtrer` — un
`git pull` suivi d'un redémarrage de service suffit pour appliquer une mise à
jour de code, sans re-générer la configuration existante.

## Craftpick Filter — CLI

| Commande | Description |
|---|---|
| `status` | État du service + métriques temps réel (pps, connexions, req/s HTTP, IP bannies) |
| `bans` | Liste des IP bannies |
| `ban <ip> [durée]` | Bannir une IP (ex: `2h`, `30m`, `1d`) |
| `unban <ip>` | Débannir une IP |
| `whitelist <ip\|cidr>` | Ne jamais filtrer ni bannir cette IP |
| `lockdown on\|off` | Forcer/couper le mode lockdown |
| `reload` | Recharger la config et les règles nftables (validées avant application) |
| `test-api` | Envoyer un événement de test à l'API |
| `reset-baseline` | Réapprendre le trafic normal |
| `logs` | Suivre les logs |

### Configuration (`/etc/craftpick-filter/config.conf`)

Voir [`filter/config.conf.example`](filter/config.conf.example) pour la liste
complète et commentée. Points clés :

- `PORTS="all"` protège tous les ports de la machine ; sinon liste séparée par virgules.
- Détection couche 4 : `SPIKE_FACTOR`, `MIN_CPS`, `MIN_CONNS`, `MIN_PPS`, `SYN_RECV_MAX`.
- Détection couche 7 (HTTP) : `HTTP_ENABLE`, `HTTP_LOG_PATHS` (auto-détecte nginx/apache),
  `HTTP_PER_IP_RPS_MAX(_ATTACK)`, `HTTP_SPIKE_FACTOR`, `HTTP_MIN_RPS`. Un flood via
  connexions gardées ouvertes (keep-alive) échappe au comptage TCP — cette couche
  lit directement les logs d'accès pour bannir l'IP responsable par le débit réel
  de requêtes, quel que soit le nombre de connexions ouvertes.
- `AUTO_BAN`, `PER_IP_MAX_CONN(_ATTACK)`, `LOCKDOWN`, `LOCKDOWN_CPS` pour la mitigation.

Après modification : `craftpick-filter reload`.

## Craftpick API

Doc interactive servie sur `http://<ip>:8688/docs` (accès libre, la clé n'y
est jamais affichée en clair). Toutes les autres routes exigent
`Authorization: Bearer <clé>`.

| Méthode | Route | Description |
|---|---|---|
| POST | `/events` | Reçu depuis Craftpick Filter : `attack_started` / `attack_ended` / `ban` / `test` |
| GET | `/commands?server=NOM` | Commandes en attente pour ce serveur |
| POST | `/commands/ack` | Accusé de réception des commandes exécutées |
| POST | `/servers/NOM/ban` | `{"ip":"1.2.3.4","duration":"2h"}` |
| POST | `/servers/NOM/unban` | `{"ip":"1.2.3.4"}` |
| POST | `/servers/NOM/whitelist` | `{"ip":"5.6.7.8"}` |
| POST | `/servers/NOM/lockdown` | `{"state":"on"}` ou `"off"` |
| POST | `/servers/NOM/reset-baseline` | `{}` |
| GET | `/servers` | Serveurs connus, dernière activité, attaque en cours |
| GET | `/servers/NOM/attacks` | Historique des attaques |
| GET | `/servers/NOM/bans` | Historique des bans rapportés |
| GET | `/events?limit=100` | Flux brut des derniers événements |
| GET | `/health` | Sans authentification |

### Sécurité

- **Anti-bruteforce** : après 10 échecs d'authentification depuis une même IP
  en 5 minutes, cette IP est bloquée 15 minutes (HTTP 429), même avec la bonne
  clé ensuite. Protège la clé API contre un essai en boucle.
- **TLS optionnel** : renseigne `tls.enabled`, `tls.cert`, `tls.key` dans
  `/etc/craftpick-api/config.json` pour servir en HTTPS (ex: avec des
  certificats Let's Encrypt existants). En cas de chemin de certificat
  invalide, le service retombe automatiquement en HTTP plutôt que de planter.
- Le port de l'API n'est protégé que par la clé Bearer et (en option) TLS :
  s'il doit être joignable depuis l'extérieur, restreins-le par pare-feu à tes
  IP de confiance ou passe par un VPN/reverse proxy.

### CLI

| Commande | Description |
|---|---|
| `status` | État du service + serveurs connus |
| `key` / `regenerate-key` | Afficher / régénérer la clé API |
| `servers` | Détail JSON des serveurs connus |
| `attacks <serveur>` | Historique des attaques |
| `ban\|unban\|whitelist <serveur> <ip>` | Piloter un serveur à distance |
| `lockdown <serveur> on\|off` | Forcer le lockdown à distance |
| `logs` | Suivre les logs |

## Licence

MIT — voir [LICENSE](LICENSE).
