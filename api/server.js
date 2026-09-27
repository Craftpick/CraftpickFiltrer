#!/usr/bin/env node
'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const CONFIG_PATH = process.env.CRAFTPICK_API_CONFIG || '/etc/craftpick-api/config.json';
const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
const PORT = cfg.port || 8688;
const API_KEY = cfg.apiKey;
const DATA = cfg.dataDir || '/var/lib/craftpick-api';
const CMD_DIR = path.join(DATA, 'commands');
const LOG_FILE = '/var/log/craftpick-api.log';

// TLS optionnel : {"tls": {"enabled": true, "cert": "/chemin/fullchain.pem", "key": "/chemin/privkey.pem"}}
// dans config.json. Si absent ou illisible, on retombe sur du HTTP simple sans planter le service —
// mieux vaut une API up en HTTP qu'un service qui ne démarre pas à cause d'un chemin de certif erroné.
let tlsOptions = null;
let scheme = 'http';
if (cfg.tls && cfg.tls.enabled) {
  try {
    tlsOptions = { cert: fs.readFileSync(cfg.tls.cert), key: fs.readFileSync(cfg.tls.key) };
    scheme = 'https';
  } catch (e) {
    console.error(`[craftpick-api] TLS demandé mais illisible (${e.message}) — retour en HTTP.`);
  }
}

for (const d of [DATA, CMD_DIR]) fs.mkdirSync(d, { recursive: true });
for (const f of ['events.jsonl', 'attacks.jsonl', 'bans.jsonl']) {
  const p = path.join(DATA, f);
  if (!fs.existsSync(p)) fs.writeFileSync(p, '');
}
if (!fs.existsSync(path.join(DATA, 'servers.json'))) fs.writeFileSync(path.join(DATA, 'servers.json'), '{}');
if (!fs.existsSync(path.join(DATA, 'seq.json'))) fs.writeFileSync(path.join(DATA, 'seq.json'), '{}');

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch (e) { /* ignore */ }
}

// ---------- helpers fichiers (sync : trafic faible, pas de souci de concurrence) ----------
function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return fallback; }
}
function writeJSON(file, data) { fs.writeFileSync(file, JSON.stringify(data, null, 2)); }
function appendJSONL(file, obj) { fs.appendFileSync(file, JSON.stringify(obj) + '\n'); }
function readJSONL(file, limit) {
  if (!fs.existsSync(file)) return [];
  const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
  const slice = limit ? lines.slice(-limit) : lines;
  return slice.map(l => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean);
}
function safeName(name) { return String(name).replace(/[^a-zA-Z0-9._-]/g, '_'); }

function nextId(server) {
  const seq = readJSON(path.join(DATA, 'seq.json'), {});
  seq[server] = (seq[server] || 0) + 1;
  writeJSON(path.join(DATA, 'seq.json'), seq);
  return seq[server];
}
function cmdFile(server) { return path.join(CMD_DIR, `${safeName(server)}.json`); }
function getCommands(server) { return readJSON(cmdFile(server), []); }
function addCommand(server, action, extra) {
  const cmds = getCommands(server);
  const cmd = Object.assign({ id: nextId(server), action, created_at: new Date().toISOString() }, extra);
  cmds.push(cmd);
  writeJSON(cmdFile(server), cmds);
  log(`📤 Commande pour ${server} : ${action} ${JSON.stringify(extra)}`);
  return cmd;
}
function ackCommands(server, ids) {
  const remaining = getCommands(server).filter(c => !ids.includes(c.id));
  writeJSON(cmdFile(server), remaining);
}

function validIp(ip) {
  if (typeof ip !== 'string') return false;
  const v4 = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;
  const v6 = /^[0-9a-fA-F:]+(\/\d{1,3})?$/;
  return v4.test(ip) || (ip.includes(':') && v6.test(ip));
}
function validDuration(d) { return typeof d === 'string' && /^[0-9]+[smhd]$/.test(d); }

// ---------- HTTP ----------
function send(res, code, body, type) {
  type = type || 'application/json';
  const isJson = type === 'application/json';
  const payload = isJson ? JSON.stringify(body) : body;
  res.writeHead(code, {
    'Content-Type': type + (isJson ? '; charset=utf-8' : ''),
    'Access-Control-Allow-Origin': '*',
  });
  res.end(payload);
}
function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    let tooBig = false;
    req.on('data', (c) => {
      data += c;
      if (data.length > 1e6) { tooBig = true; req.destroy(); }
    });
    req.on('end', () => {
      if (tooBig) return resolve({});
      try { resolve(data ? JSON.parse(data) : {}); } catch (e) { resolve({}); }
    });
    req.on('error', () => resolve({}));
  });
}
function authOK(req) {
  const h = req.headers['authorization'] || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  return !!(m && m[1] === API_KEY);
}

// ---------- anti-bruteforce sur la clé API ----------
// Le port n'est protégé que par cette clé (voir /docs) : sans ça, un script qui essaie
// des clés en boucle a un temps illimité. On bloque une IP après trop d'échecs.
const AUTH_MAX_FAILURES = 10;          // tentatives ratées tolérées sur la fenêtre
const AUTH_WINDOW_MS = 5 * 60 * 1000;  // fenêtre glissante (5 min)
const AUTH_BLOCK_MS = 15 * 60 * 1000;  // durée du blocage une fois le seuil dépassé
const authFailures = new Map();        // ip -> { count, firstAt, blockedUntil }

function clientIp(req) {
  let ip = req.socket.remoteAddress || '';
  if (ip.startsWith('::ffff:')) ip = ip.slice(7);
  return ip;
}
function authGate(req) {
  const ip = clientIp(req);
  const now = Date.now();
  const rec = authFailures.get(ip);
  if (rec && rec.blockedUntil && now < rec.blockedUntil) {
    return { blocked: true, ip, now, retryAfter: Math.ceil((rec.blockedUntil - now) / 1000) };
  }
  return { blocked: false, ip, now };
}
function recordAuthFailure(ip, now) {
  let rec = authFailures.get(ip);
  if (!rec || now - rec.firstAt > AUTH_WINDOW_MS) rec = { count: 0, firstAt: now, blockedUntil: 0 };
  rec.count += 1;
  if (rec.count >= AUTH_MAX_FAILURES) {
    rec.blockedUntil = now + AUTH_BLOCK_MS;
    log(`🔒 IP ${ip} bloquée ${Math.round(AUTH_BLOCK_MS / 60000)} min après ${rec.count} échecs d'authentification`);
  }
  authFailures.set(ip, rec);
}
function recordAuthSuccess(ip) { authFailures.delete(ip); }
// purge périodique pour ne pas laisser grossir la map indéfiniment
setInterval(() => {
  const now = Date.now();
  for (const [ip, rec] of authFailures) {
    if ((!rec.blockedUntil || now > rec.blockedUntil) && now - rec.firstAt > AUTH_WINDOW_MS) authFailures.delete(ip);
  }
}, 60 * 1000).unref();

function touchServer(name) {
  const servers = readJSON(path.join(DATA, 'servers.json'), {});
  servers[name] = servers[name] || {};
  servers[name].lastSeen = new Date().toISOString();
  writeJSON(path.join(DATA, 'servers.json'), servers);
}

function handleEvent(body) {
  if (!body || !body.event || !body.server) return;
  appendJSONL(path.join(DATA, 'events.jsonl'), Object.assign({}, body, { received_at: new Date().toISOString() }));
  const servers = readJSON(path.join(DATA, 'servers.json'), {});
  servers[body.server] = servers[body.server] || {};
  servers[body.server].lastSeen = new Date().toISOString();

  if (body.event === 'attack_started') {
    servers[body.server].openAttack = body;
    log(`⚠️  Attaque en cours sur ${body.server} [${body.attack_id || '?'}] : ${(body.types || []).join(',')}`);
  } else if (body.event === 'attack_ended') {
    servers[body.server].openAttack = null;
    appendJSONL(path.join(DATA, 'attacks.jsonl'), body);
    log(`✅ Attaque terminée sur ${body.server} [${body.attack_id || '?'}] — ${body.duration_s || '?'}s, ${body.banned_count || 0} IP bannies`);
  } else if (body.event === 'ban') {
    appendJSONL(path.join(DATA, 'bans.jsonl'), body);
    log(`⛔ Ban rapporté par ${body.server} : ${body.ip} (${body.reason || ''})`);
  } else if (body.event === 'test') {
    log(`🔧 Test reçu de ${body.server}`);
  }
  writeJSON(path.join(DATA, 'servers.json'), servers);
}

function buildDocsHtml() {
  const keyHint = API_KEY.slice(0, 6) + '…' + API_KEY.slice(-4);
  return `<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><title>Craftpick API — Documentation</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body{font-family:system-ui,-apple-system,sans-serif;max-width:920px;margin:2rem auto;padding:0 1rem;line-height:1.55;color:#1a1a1a;background:#fafafa}
  h1{color:#6d28d9} h2{border-bottom:2px solid #eee;padding-bottom:.35rem;margin-top:2.5rem}
  code,pre{background:#1e1e2e;color:#e2e2f5;padding:.15rem .45rem;border-radius:5px;font-size:.92em}
  pre{padding:1rem;overflow-x:auto;line-height:1.4}
  .m{font-weight:700;display:inline-block;width:4.4rem}
  .get{color:#0969da}.post{color:#1a7f37}
  table{border-collapse:collapse;width:100%;margin:.5rem 0}
  td,th{border:1px solid #ddd;padding:.45rem .65rem;text-align:left;font-size:.95em}
  th{background:#f0f0f5}
  .warn{background:#fff3cd;border:1px solid #ffe69c;border-radius:6px;padding:.7rem 1rem;margin:1rem 0}
</style></head><body>
<h1>🛡️ Craftpick API</h1>
<p>Réception des attaques exportées par <strong>Craftpick Filter</strong> et pilotage à distance : ban, unban, whitelist, lockdown.</p>

<div class="warn">Toutes les routes (sauf <code>/health</code> et <code>/docs</code>) exigent l'en-tête :<br>
<code>Authorization: Bearer ${keyHint}</code><br>
La clé complète n'est affichée qu'une fois, à l'installation. Pour la retrouver : <code>craftpick-api key</code> sur cette machine.</div>

<h2>Reçu depuis Craftpick Filter</h2>
<table><tr><th>Méthode</th><th>Route</th><th>Description</th></tr>
<tr><td class="post m">POST</td><td>/events</td><td>attack_started / attack_ended / ban / test</td></tr>
<tr><td class="get m">GET</td><td>/commands?server=NOM</td><td>Commandes en attente pour ce serveur</td></tr>
<tr><td class="post m">POST</td><td>/commands/ack</td><td><code>{"server":"NOM","ack":[1,2]}</code></td></tr>
</table>

<h2>Pilotage à distance</h2>
<table><tr><th>Méthode</th><th>Route</th><th>Body JSON</th></tr>
<tr><td class="post m">POST</td><td>/servers/NOM/ban</td><td><code>{"ip":"1.2.3.4","duration":"2h"}</code></td></tr>
<tr><td class="post m">POST</td><td>/servers/NOM/unban</td><td><code>{"ip":"1.2.3.4"}</code></td></tr>
<tr><td class="post m">POST</td><td>/servers/NOM/whitelist</td><td><code>{"ip":"5.6.7.8"}</code></td></tr>
<tr><td class="post m">POST</td><td>/servers/NOM/lockdown</td><td><code>{"state":"on"}</code> ou <code>"off"</code></td></tr>
<tr><td class="post m">POST</td><td>/servers/NOM/reset-baseline</td><td><code>{}</code></td></tr>
</table>
<p>La commande est déposée en file et exécutée au prochain sondage du serveur concerné (≤ 10&nbsp;s par défaut).</p>

<h2>Consultation</h2>
<table><tr><th>Méthode</th><th>Route</th><th>Description</th></tr>
<tr><td class="get m">GET</td><td>/servers</td><td>Serveurs connus + dernière activité + attaque en cours</td></tr>
<tr><td class="get m">GET</td><td>/servers/NOM/attacks</td><td>Historique des attaques (50 dernières)</td></tr>
<tr><td class="get m">GET</td><td>/servers/NOM/bans</td><td>Historique des bans rapportés (100 derniers)</td></tr>
<tr><td class="get m">GET</td><td>/events?limit=100</td><td>Flux brut des derniers événements</td></tr>
<tr><td class="get m">GET</td><td>/health</td><td>Vérification de santé (sans authentification)</td></tr>
</table>

<h2>Exemples</h2>
<pre>curl -H "Authorization: Bearer VOTRE_CLE" \\
  -X POST ${scheme}://IP:${PORT}/servers/craftpickmc/ban \\
  -H "Content-Type: application/json" \\
  -d '{"ip":"1.2.3.4","duration":"6h"}'

curl -H "Authorization: Bearer VOTRE_CLE" ${scheme}://IP:${PORT}/servers</pre>
</body></html>`;
}

const requestHandler = async (req, res) => {
  let u;
  try { u = new URL(req.url, `http://${req.headers.host || 'localhost'}`); }
  catch (e) { return send(res, 400, { error: 'url invalide' }); }
  const parts = u.pathname.split('/').filter(Boolean);

  try {
    if (u.pathname === '/' || u.pathname === '/docs') return send(res, 200, buildDocsHtml(), 'text/html');
    if (u.pathname === '/health') return send(res, 200, { status: 'ok', time: new Date().toISOString() });

    const gate = authGate(req);
    if (gate.blocked) {
      res.setHeader('Retry-After', String(gate.retryAfter));
      return send(res, 429, { error: 'trop de tentatives, réessaie plus tard', retry_after_s: gate.retryAfter });
    }
    if (!authOK(req)) { recordAuthFailure(gate.ip, gate.now); return send(res, 401, { error: 'unauthorized' }); }
    recordAuthSuccess(gate.ip);

    if (u.pathname === '/events' && req.method === 'POST') {
      const body = await readBody(req);
      handleEvent(body);
      return send(res, 200, { ok: true });
    }

    if (u.pathname === '/commands' && req.method === 'GET') {
      const srv = u.searchParams.get('server');
      if (!srv) return send(res, 400, { error: 'paramètre server manquant' });
      touchServer(srv);
      return send(res, 200, { commands: getCommands(srv) });
    }
    if (u.pathname === '/commands/ack' && req.method === 'POST') {
      const body = await readBody(req);
      if (!body.server || !Array.isArray(body.ack)) return send(res, 400, { error: 'server/ack manquant' });
      ackCommands(body.server, body.ack);
      return send(res, 200, { ok: true });
    }

    if (parts[0] === 'servers' && parts[1] && parts[2] && req.method === 'POST') {
      const srv = decodeURIComponent(parts[1]);
      const action = parts[2];
      const body = await readBody(req);
      let cmd;
      switch (action) {
        case 'ban':
          if (!validIp(body.ip)) return send(res, 400, { error: 'ip invalide' });
          if (body.duration && !validDuration(body.duration)) return send(res, 400, { error: 'duration invalide (ex: 30m, 2h, 1d)' });
          cmd = addCommand(srv, 'ban', { ip: body.ip, duration: body.duration || '1h' });
          break;
        case 'unban':
          if (!validIp(body.ip)) return send(res, 400, { error: 'ip invalide' });
          cmd = addCommand(srv, 'unban', { ip: body.ip });
          break;
        case 'whitelist':
          if (!validIp(body.ip)) return send(res, 400, { error: 'ip invalide' });
          cmd = addCommand(srv, 'whitelist', { ip: body.ip });
          break;
        case 'lockdown':
          if (!['on', 'off'].includes(body.state)) return send(res, 400, { error: 'state doit être "on" ou "off"' });
          cmd = addCommand(srv, 'lockdown', { state: body.state });
          break;
        case 'reset-baseline':
          cmd = addCommand(srv, 'reset_baseline', {});
          break;
        default:
          return send(res, 404, { error: 'action inconnue', hint: 'ban | unban | whitelist | lockdown | reset-baseline' });
      }
      return send(res, 200, { ok: true, command: cmd });
    }

    if (parts[0] === 'servers' && parts.length === 1 && req.method === 'GET') {
      return send(res, 200, readJSON(path.join(DATA, 'servers.json'), {}));
    }
    if (parts[0] === 'servers' && parts[1] && parts[2] === 'attacks' && req.method === 'GET') {
      const srv = decodeURIComponent(parts[1]);
      return send(res, 200, readJSONL(path.join(DATA, 'attacks.jsonl')).filter((a) => a.server === srv).slice(-50));
    }
    if (parts[0] === 'servers' && parts[1] && parts[2] === 'bans' && req.method === 'GET') {
      const srv = decodeURIComponent(parts[1]);
      return send(res, 200, readJSONL(path.join(DATA, 'bans.jsonl')).filter((b) => b.server === srv).slice(-100));
    }
    if (parts[0] === 'events' && req.method === 'GET') {
      const limit = parseInt(u.searchParams.get('limit') || '100', 10);
      return send(res, 200, readJSONL(path.join(DATA, 'events.jsonl'), limit));
    }

    return send(res, 404, { error: 'route inconnue', hint: 'voir /docs' });
  } catch (e) {
    log('Erreur : ' + e.message);
    return send(res, 500, { error: 'erreur interne' });
  }
};

const server = tlsOptions ? https.createServer(tlsOptions, requestHandler) : http.createServer(requestHandler);

server.listen(PORT, () => log(`Craftpick API démarrée sur le port ${PORT} (${scheme})`));

process.on('SIGTERM', () => { log('Arrêt (SIGTERM)'); server.close(() => process.exit(0)); });
process.on('SIGINT', () => { log('Arrêt (SIGINT)'); server.close(() => process.exit(0)); });
