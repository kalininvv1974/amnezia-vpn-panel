# Amnezia VPN Panel

[![License: MIT](https://img.shields.io/github/license/kalininvv1974/amnezia-vpn-panel)](LICENSE)
[![Release](https://img.shields.io/github/v/release/kalininvv1974/amnezia-vpn-panel?include_prereleases)](https://github.com/kalininvv1974/amnezia-vpn-panel/releases)
[![Stars](https://img.shields.io/github/stars/kalininvv1974/amnezia-vpn-panel?style=social)](https://github.com/kalininvv1974/amnezia-vpn-panel/stargazers)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-2ea44f)](#install-on-a-clean-ubuntudebian-server)

🌐 **Русский** — [README.ru.md](README.ru.md) · **English**

A web management panel for **AmneziaVPN / AmneziaWG 3.x** with an in-panel login form (username/password), client list, live traffic, QR codes and `.conf` download. wg-easy style UI, runs on nginx + Node.js.

> ⚠️ This panel does **not** install AmneziaVPN. Install AmneziaVPN with its own installer first (the `amnezia-awg*` container must be running), then use this panel as a convenient web interface to manage it.

## Features

- 🔐 **Login form inside the panel** (session cookie, PBKDF2) — no browser Basic Auth popup; the password is asked again each time the browser is reopened
- 📋 Client list: IP, status (Online/Offline/Disabled), download/upload speed and total traffic
- ➕ One-click client creation + automatic `amnezia-<name>.conf` download
- 📱 QR code of the config for the Amnezia app
- 🔌 Toggle clients on/off with a switch, delete clients
- 🌙 Dark/light theme with a toggle in the header
- 🌍 Server card: number of clients, location (GeoIP country), protocols

## Screenshots

| Dark theme | Light theme |
|---|---|
| ![Panel dark theme](docs/screenshots/panel-dark.png) | ![Panel light theme](docs/screenshots/panel-light.png) |

## Install on a clean Ubuntu/Debian server

**Quick way — one command (on the server, as root):**

```bash
wget -O install.sh https://raw.githubusercontent.com/kalininvv1974/amnezia-vpn-panel/main/install-amnezia-panel.sh
bash install.sh
```

If `wget` is not available — via `curl`:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/kalininvv1974/amnezia-vpn-panel/main/install-amnezia-panel.sh
bash install.sh
```

**Classic way — upload the script from your PC via scp:**

```bash
# 1. Copy the script to the server
scp install-amnezia-panel.sh root@YOUR_IP:/root/

# 2. Connect via SSH
ssh root@YOUR_IP

# 3. Run the installation
cd /root
bash install-amnezia-panel.sh
```

## What the script asks
1. **Server IP** — e.g. `203.0.113.10`
2. **API key** — internal key between the panel and the API (Enter = a random key is generated; you can type your own, ≥ 32 characters)
3. **Panel login** — Enter = `admin`
4. **Panel password** — Enter = a random one is generated (save it!)

## Prerequisites
- A working **AmneziaVPN** already installed (the `amnezia-awg*` container, shared key `awg0.conf`)
- Ubuntu 20.04+ or Debian 11+
- At least 1 GB RAM
- Open ports: `80/tcp` and the AmneziaVPN UDP port (default for the container — `31509/udp`)
- Internet access to download packages

## What gets installed
- Node.js 20
- `amnezia-api` (cloned from GitHub) — Node/Fastify, **systemd service** `amnezia-api.service`, listens on `127.0.0.1:4001` (externally reachable only through nginx)
- `amnezia-panel-auth` — a small auth service (**systemd**, `127.0.0.1:4002`): checks login/password (PBKDF2) and issues a session cookie
- Nginx — serves the panel on port 80 with the **login form inside the panel** and proxies `/api` (API access only with a valid session via `auth_request`)
- The `amnezia-awg*` (AmneziaWG) container is **not created or modified** — the script only copies `awg0.conf` and keys from the already running container

## After installation

Open in your browser:
```
http://YOUR_IP/
```
You will see the **login form** (login and password set during installation). The session is a session cookie: **the password is asked again every time the browser is reopened** (there's also a "Log out" button).

API docs (only after logging in to the panel):
```
http://YOUR_IP/api/docs
```

> The panel talks to the API via the `x-api-key` header on its own — you don't need to type it on every login.

## Servers with ispmanager (hosting panel)
If the server already runs ispmanager with its own sites:
- the panel lives in the shared nginx (as a regular `panel` vhost) — default server on port 80, login form inside the panel (session cookie). Sites on their own domains are not affected;
- the installer does **not** reinstall or remove nginx/nginx packages;
- the uninstaller removes only the panel (index.html, the `panel` vhost, the auth service) and does **not** touch ispmanager, its sites, or `/etc/nginx`.

## Files
- `install-amnezia-panel.sh` — installer (the panel is embedded in it as base64)
- `index.html` — panel source (for development; the installer uses the embedded version)
- `uninstall-amnezia-panel.sh` — removes the panel/API and panel settings from nginx (does not touch nginx itself)

## Troubleshooting

### Check service status
```bash
docker ps -a
systemctl status amnezia-api
journalctl -u amnezia-api -f
systemctl status nginx
```

### Restart services
```bash
systemctl restart amnezia-api
systemctl restart nginx
```

### Check the panel and API
```bash
# Panel page (expect 200)
curl -o /dev/null -w "%{http_code}\n" http://127.0.0.1/
# /api without a session (expect 401)
curl -o /dev/null -w "%{http_code}\n" http://127.0.0.1/api/server
# Login with password -> cookie (expect 200)
curl -s -c /tmp/s.txt -o /dev/null -w "%{http_code}\n" -X POST -H 'Content-Type: application/json' \
  -d '{"user":"LOGIN","password":"PASSWORD"}' http://127.0.0.1/api/auth/login
# /api with a session (expect 200)
curl -s -b /tmp/s.txt -o /dev/null -w "%{http_code}\n" http://127.0.0.1/api/server
rm -f /tmp/s.txt
# Direct API access (local only)
curl -s http://127.0.0.1:4001/clients -H "x-api-key: YOUR_API_KEY"
```

### Change the panel password
```bash
node -e '
  const fs = require("fs"), crypto = require("crypto");
  const pass = process.argv[1];
  const salt = crypto.randomBytes(16).toString("hex");
  const secret = crypto.randomBytes(32).toString("hex");
  const iterations = 100000;
  const hash = crypto.pbkdf2Sync(pass, salt, iterations, 32, "sha256").toString("hex");
  const old = JSON.parse(fs.readFileSync("/etc/amnezia-panel/auth.json", "utf8"));
  fs.writeFileSync("/etc/amnezia-panel/auth.json",
    JSON.stringify({ user: old.user, salt, hash, secret, iterations }));
' 'new_password'
chmod 600 /etc/amnezia-panel/auth.json
systemctl restart amnezia-panel-auth
```

### Change the internal API key
```bash
# New key (>= 32 characters)
nano /opt/amnezia-api/.env            # FASTIFY_API_KEY=new_key
systemctl restart amnezia-api
# Update the key in the panel
sed -i "s|old_key|new_key|g" /var/www/html/index.html
```

### Remove completely
```bash
bash uninstall-amnezia-panel.sh
```
The script removes the panel, the API and the panel settings in nginx; it does **not** touch the AmneziaVPN container.

## License

© 2026 Kalinin Vitaliy. **Amnezia VPN Panel** is licensed under the [MIT License](https://opensource.org/licenses/MIT).

Bundled components keep their own licenses:
- QR code library (in `index.html`) — Kazuhiko Arase, MIT
- [pako](https://github.com/nodeca/pako) — MIT/BSD (loaded from CDN)