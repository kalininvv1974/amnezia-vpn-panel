#!/bin/bash
###############################################################################
# Amnezia VPN Panel - Установка на Ubuntu/Debian
# Запускать от root:  bash install-amnezia-panel.sh
#
# ПОРЯДОК: пользователь СНАЧАЛА ставит amnezia-vpn через свой инсталлятор,
#          потом запускает ЭТОТ скрипт для установки панели.
#
# Скрипт НЕ пересоздаёт контейнер amnezia-awg2 — он его только читает
# (берёт awg0.conf и ключи из работающего контейнера).
###############################################################################

set -e

# Сохраняем путь к скрипту ДО любых cd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Amnezia VPN Panel Installer v2.1"
echo "=========================================="

# --- 0. API ключ (внутренний ключ панель↔API) ---

# --- 1. Запрос параметров ---
echo ""
echo "Введите IP сервера:"
read SERVER_IP
[ -z "$SERVER_IP" ] && { echo "IP обязателен"; exit 1; }

echo ""
echo "Введите API ключ (Enter — сгенерировать случайный):"
read -r API_KEY_INPUT
if [ -n "$API_KEY_INPUT" ]; then
    API_KEY="$API_KEY_INPUT"
else
    if command -v openssl &>/dev/null; then
        API_KEY="$(openssl rand -hex 16)"
    else
        API_KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \t\n')"
    fi
    echo "  Сгенерирован случайный API-ключ: $API_KEY"
fi
if [ "${#API_KEY}" -lt 32 ]; then
    echo "ОШИБКА: API ключ должен быть длиной >= 32 символов"
    exit 1
fi
if ! echo "$API_KEY" | grep -Eq '^[A-Za-z0-9+/=_-]+$'; then
    echo "ОШИБКА: API ключ содержит недопустимые символы (разрешены A-Z a-z 0-9 + / = _ -)"
    exit 1
fi

echo ""
echo "Введите логин для входа в панель (Enter — admin):"
read -r PANEL_USER
[ -z "$PANEL_USER" ] && PANEL_USER="admin"
case "$PANEL_USER" in
    *:*|*\\*|*/*) echo "ОШИБКА: логин не может содержать ':' '/' '\\'"; exit 1;;
esac

echo ""
echo "Введите пароль для панели (Enter — сгенерировать случайный):"
read -rs PANEL_PASS
echo ""
if [ -z "$PANEL_PASS" ]; then
    echo "  Генерируем случайный пароль..."
    if command -v openssl &>/dev/null; then
        PANEL_PASS="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)"
    else
        PANEL_PASS="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)"
    fi
fi
case "$PANEL_PASS" in
    *:*) echo "ОШИБКА: пароль не может содержать ':'"; exit 1;;
esac
[ "${#PANEL_PASS}" -lt 8 ] && { echo "ОШИБКА: пароль слишком короткий (минимум 8 символов)"; exit 1; }

# --- 2. Проверка что amnezia-vpn уже установлен пользователем ---
echo ""
echo "[Проверка] amnezia-vpn..."
if ! docker ps -a --format '{{.Names}}' | grep -q 'amnezia-awg'; then
    echo ""
    echo "ОШИБКА: контейнер amnezia-awg* не найден!"
    echo "Сначала установите amnezia-vpn через ваш инсталлятор,"
    echo "дождитесь работы awg0, потом запустите этот скрипт."
    exit 1
fi
AWG_CONTAINER=$(docker ps -a --format '{{.Names}}' | grep 'amnezia-awg' | head -1)
echo "Найден контейнер: $AWG_CONTAINER"

# --- 3. Обновление системы + базовые пакеты ---
echo ""
echo "[1/7] Установка базовых пакетов..."
apt-get update -qq
apt-get install -y -qq curl wget git ca-certificates gnupg lsb-release

# --- 4. Установка Node.js ---
echo ""
echo "[2/7] Установка Node.js..."
if ! command -v node &> /dev/null || [ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 20 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs
fi
node -v

# --- 5. Установка Nginx ---
echo ""
echo "[3/7] Установка Nginx..."
mkdir -p /etc/nginx /var/www/html

# (a) установить nginx, если бинарь отсутствует
if ! command -v nginx &> /dev/null; then
    # ispmanager перехватил nginx — свой не ставим, пусть пользователь восстановит
    if dpkg -s ispmanager-pkg-nginx &>/dev/null; then
        echo "ОШИБКА: установлен ispmanager-pkg-nginx, но nginx-бинар не найден."
        echo "Восстановите его вручную:"
        echo "  apt-get install --reinstall -y ispmanager-pkg-nginx"
        exit 1
    fi
    # nginx.conf нужен до nginx (dpkg bug: postinst запускает nginx -t до создания конфига)
    curl -fsSL https://nl.archive.ubuntu.com/ubuntu/pool/main/n/nginx/nginx-common_1.24.0-2ubuntu7.17_all.deb -o /tmp/nginx-common.deb 2>&1 | tail -3
    dpkg -x /tmp/nginx-common.deb /tmp/nginx-extract/ 2>&1 | tail -3
    cp -n /tmp/nginx-extract/etc/nginx/nginx.conf /etc/nginx/nginx.conf 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends nginx
fi

# (b) nginx установлен, но /etc/nginx/nginx.conf отсутствует
#     (бывает после uninstall: бинарь остался, каталог /etc/nginx удалён) — восстановить
if [ ! -f /etc/nginx/nginx.conf ]; then
    # на сервере с ispmanager конфиг принадлежит ispmanager — не чиним своими пакетами
    if dpkg -s ispmanager-pkg-nginx &>/dev/null; then
        echo "ОШИБКА: /etc/nginx/nginx.conf отсутствует, но обнаружен ispmanager."
        echo "Восстановите nginx ispmanager вручную:"
        echo "  apt-get install --reinstall -y ispmanager-pkg-nginx"
        exit 1
    fi
    echo "  nginx.conf отсутствует, восстанавливаю из пакета..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall nginx-common 2>&1 | tail -3 || true
    if [ ! -f /etc/nginx/nginx.conf ]; then
        curl -fsSL https://nl.archive.ubuntu.com/ubuntu/pool/main/n/nginx/nginx-common_1.24.0-2ubuntu7.17_all.deb -o /tmp/nginx-common.deb 2>/dev/null || true
        dpkg -x /tmp/nginx-common.deb /tmp/nginx-extract/ 2>/dev/null || true
        cp /tmp/nginx-extract/etc/nginx/nginx.conf /etc/nginx/nginx.conf 2>/dev/null || true
    fi
fi
[ -f /etc/nginx/nginx.conf ] || { echo "ОШИБКА: нет /etc/nginx/nginx.conf — установите nginx вручную: apt-get install -y nginx"; exit 1; }
nginx -v 2>&1

# --- 6. Клонирование и сборка amnezia-api ---
echo ""
echo "[4/7] Установка amnezia-api..."
cd /opt
if [ ! -d "amnezia-api" ]; then
    git clone https://github.com/kyoresuas/amnezia-api.git
    cd amnezia-api
    npm install --no-audit --no-fund
else
    cd amnezia-api
    git pull 2>/dev/null || true
    npm install --no-audit --no-fund
fi

# Сборка (выход в build/, не dist/)
echo "  Сборка TypeScript..."
npx tsc --project tsconfig.build.json 2>&1 | tail -5
echo "  Замена path aliases..."
npx tsconfig-replace-paths --project tsconfig.build.json --src ./src 2>&1 | tail -3
[ -f build/main.js ] || { echo "ОШИБКА: build/main.js не создан"; exit 1; }

# --- 7. Копирование конфига и ключей из amnezia-awg контейнера ---
echo ""
echo "[5/7] Копирование awg0.conf и ключей из контейнера..."
mkdir -p /opt/amnezia/awg

docker exec "$AWG_CONTAINER" sh -c 'ls /opt/amnezia/awg/ 2>/dev/null || ls /etc/amnezia/amneziawg/ 2>/dev/null' > /tmp/awg_files.txt
cat /tmp/awg_files.txt
echo "---"

# Ищем где лежит awg0.conf
AWG_CONF_PATH=$(docker exec "$AWG_CONTAINER" sh -c 'ls /opt/amnezia/awg/awg0.conf 2>/dev/null && echo "FOUND:/opt/amnezia/awg/awg0.conf" || ls /etc/amnezia/amneziawg/awg0.conf 2>/dev/null && echo "FOUND:/etc/amnezia/amneziawg/awg0.conf"')
AWG_CONF_PATH=$(echo "$AWG_CONF_PATH" | grep FOUND | head -1 | cut -d: -f2-)
if [ -z "$AWG_CONF_PATH" ]; then
    echo "ОШИБКА: awg0.conf не найден в контейнере $AWG_CONTAINER"
    docker exec "$AWG_CONTAINER" find / -name "awg0.conf" 2>/dev/null
    exit 1
fi
echo "awg0.conf: $AWG_CONF_PATH"

docker exec "$AWG_CONTAINER" cat "$AWG_CONF_PATH" > /opt/amnezia/awg/awg0.conf
echo "awg0.conf скопирован ($(wc -l < /opt/amnezia/awg/awg0.conf) строк)"

# Ключи
docker exec "$AWG_CONTAINER" cat /opt/amnezia/awg/wireguard_server_private_key.key > /opt/amnezia/awg/wireguard_server_private.key 2>/dev/null || true
docker exec "$AWG_CONTAINER" cat /opt/amnezia/awg/wireguard_server_public_key.key > /opt/amnezia/awg/wireguard_server_public.key 2>/dev/null || true
docker exec "$AWG_CONTAINER" cat /opt/amnezia/awg/wireguard_psk.key > /opt/amnezia/awg/wireguard_psk.key 2>/dev/null || true
chmod 600 /opt/amnezia/awg/*.key 2>/dev/null || true

# --- 8. Создание .env ---
echo ""
echo "[6/7] Настройка .env и systemd сервиса..."

# API_KEY должен быть >= 32 символов, иначе API не стартует.
# Наш ключ длиной 36 символов — ОК.

cat > /opt/amnezia-api/.env << EOF
FASTIFY_ROUTES=127.0.0.1:4001
FASTIFY_API_KEY=${API_KEY}
CORS_ORIGINS=http://${SERVER_IP},http://localhost
PROTOCOLS_ENABLED=amneziawg3
SERVER_ID=4b90100e-f40f-4ef8-a0c0-8c0cdd08556e
SERVER_NAME=AmneziaVPN
SERVER_REGION=Server-1
SERVER_MAX_PEERS=200
SERVER_PUBLIC_HOST=${SERVER_IP}
AMNEZIAWG3_CONFIG_PATH=/opt/amnezia/awg/awg0.conf
EOF

# Скрипт запуска
cat > /usr/local/bin/amnezia-api-start.sh << 'EOF'
#!/bin/bash
set -a
. /opt/amnezia-api/.env
set +a
cd /opt/amnezia-api
exec node build/main.js
EOF
chmod +x /usr/local/bin/amnezia-api-start.sh

# systemd сервис
cat > /etc/systemd/system/amnezia-api.service << EOF
[Unit]
Description=Amnezia API
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/amnezia-api-start.sh
Restart=always
RestartSec=5
User=root
EnvironmentFile=/opt/amnezia-api/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable amnezia-api
systemctl restart amnezia-api
sleep 3

if ! systemctl is-active --quiet amnezia-api; then
    echo "ОШИБКА: amnezia-api не запустился. Лог:"
    journalctl -u amnezia-api --no-pager -n 20
    exit 1
fi
echo "  amnezia-api активен (systemd)"

# --- 9. Nginx + панель ---
echo ""
echo "[7/7] Установка панели и Nginx..."

mkdir -p /var/www/html /etc/amnezia-panel /opt/amnezia/panel-auth

# Вход через форму в панели (не браузерный Basic Auth):
# маленький auth-сервис на 127.0.0.1:4002 проверяет пароль (PBKDF2) и выдаёт
# session-cookie. nginx пропускает /api/* только с валидной сессией (auth_request).
# Пароль просится заново при каждом новом открытии браузера.
if command -v node &>/dev/null; then
    node -e '
        const fs = require("fs"), crypto = require("crypto");
        const [user, pass] = [process.argv[1], process.argv[2]];
        const salt = crypto.randomBytes(16).toString("hex");
        const secret = crypto.randomBytes(32).toString("hex");
        const iterations = 100000;
        const hash = crypto.pbkdf2Sync(pass, salt, iterations, 32, "sha256").toString("hex");
        fs.writeFileSync("/etc/amnezia-panel/auth.json",
            JSON.stringify({ user, salt, hash, secret, iterations }));
    ' "$PANEL_USER" "$PANEL_PASS" || { echo "ОШИБКА: не удалось создать auth.json (node)"; exit 1; }
    chmod 600 /etc/amnezia-panel/auth.json
else
    echo "ОШИБКА: node не найден, а auth-сервис панели требует node"
    exit 1
fi

# Auth-сервис (Node, без внешних зависимостей)
cat > /opt/amnezia/panel-auth/server.js << 'AUTHSRV'
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

const CFG = process.env.AUTH_CFG || '/etc/amnezia-panel/auth.json';
const COOKIE = 'pnl_session';
const TTL_MS = 12 * 3600 * 1000;
const PORT = parseInt(process.env.PORT || '4002', 10);

let cfg;
try { cfg = JSON.parse(fs.readFileSync(CFG, 'utf8')); }
catch (e) { console.error('auth: no config:', e.message); process.exit(1); }

function json(res, code, obj, headers) {
    const h = Object.assign({ 'Content-Type': 'application/json' }, headers || {});
    res.writeHead(code, h);
    res.end(JSON.stringify(obj));
}
function readBody(req, cb) {
    let d = '';
    req.on('data', c => { d += c; if (d.length > 1e6) req.destroy(); });
    req.on('end', () => cb(d));
}
function verify(user, pass) {
    if (user !== cfg.user) return false;
    const hash = crypto.pbkdf2Sync(String(pass), cfg.salt, cfg.iterations, 32, 'sha256');
    const a = Buffer.from(hash);
    const b = Buffer.from(cfg.hash, 'hex');
    return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function token() {
    const payload = Buffer.from(JSON.stringify({ exp: Date.now() + TTL_MS })).toString('base64url');
    const sig = crypto.createHmac('sha256', cfg.secret).update(payload).digest('base64url');
    return payload + '.' + sig;
}
function checkToken(t) {
    if (!t) return false;
    const i = t.lastIndexOf('.');
    if (i < 0) return false;
    const payload = t.slice(0, i);
    const sig = t.slice(i + 1);
    const exp = crypto.createHmac('sha256', cfg.secret).update(payload).digest('base64url');
    const a = Buffer.from(sig);
    const b = Buffer.from(exp);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
    try {
        const d = JSON.parse(Buffer.from(payload, 'base64url').toString());
        return typeof d.exp === 'number' && d.exp > Date.now();
    } catch (e) { return false; }
}
function getCookie(req, name) {
    const raw = req.headers.cookie || '';
    for (const part of raw.split(';')) {
        const p = part.trim();
        if (p.startsWith(name + '=')) return p.slice(name.length + 1);
    }
    return '';
}
function sessionCookie(t) {
    return COOKIE + '=' + t + '; Path=/; HttpOnly; SameSite=Strict';
}

// --- GeoIP: страна сервера по его внешнему IP (карточка Location) ---
// Запрос уходит С СЕРВЕРА, поэтому сервис возвращает расположение сервера,
// а не клиента. Результат кэшируется на 6 часов.
const GEO_SERVICES = [
    { url: 'https://ipwho.is/', pick: j =>
        (j && j.success !== false && j.country) ? { country: j.country, code: j.country_code } : null },
    { url: 'http://ip-api.com/json/', pick: j =>
        (j && j.status === 'success' && j.country) ? { country: j.country, code: j.countryCode } : null },
    { url: 'https://ipapi.co/json/', pick: j =>
        (j && j.country_name) ? { country: j.country_name, code: j.country } : null }
];
const GEO_TTL_MS = 6 * 3600 * 1000;
let geoCache = null, geoTs = 0, geoBusy = false;

function httpGet(url, timeoutMs) {
    return new Promise(resolve => {
        const mod = url.indexOf('https:') === 0 ? require('https') : require('http');
        let done = false;
        const finish = v => { if (!done) { done = true; resolve(v); } };
        let req;
        try {
            req = mod.get(url, { headers: { 'User-Agent': 'amnezia-vpn-panel' }, timeout: timeoutMs }, res => {
                let d = '';
                res.on('data', c => { if (d.length < 2e6) d += c; });
                res.on('end', () => finish(d));
            });
        } catch (e) { return finish(''); }
        req.on('timeout', () => { try { req.destroy(); } catch (e) {} finish(''); });
        req.on('error', () => finish(''));
    });
}
async function refreshGeo() {
    if (geoBusy) return geoCache;
    geoBusy = true;
    try {
        for (const s of GEO_SERVICES) {
            const body = await httpGet(s.url, 5000);
            if (!body) continue;
            try {
                const j = JSON.parse(body);
                const r = s.pick(j);
                if (r) { geoCache = Object.assign({ source: s.url }, r); geoTs = Date.now(); return geoCache; }
            } catch (e) {}
        }
    } finally { geoBusy = false; }
    return geoCache;
}
function geoReply() {
    const fresh = geoCache && (Date.now() - geoTs) < GEO_TTL_MS;
    if (!fresh) refreshGeo(); // фоновая перепроверка
    return {
        country: (geoCache && geoCache.country) || '',
        code: (geoCache && geoCache.code) || '',
        detected: !!(geoCache && geoCache.country)
    };
}

const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    const valid = checkToken(getCookie(req, COOKIE));

    if (url === '/_auth' || url === '/status') {
        return valid ? json(res, 200, { ok: true }) : json(res, 401, { error: 'unauthorized' });
    }
    if (url === '/login') {
        return readBody(req, body => {
            let u = '', p = '';
            try { const d = JSON.parse(body || '{}'); u = d.user; p = d.password; } catch (e) {}
            if (verify(u, p)) {
                return json(res, 200, { ok: true }, { 'Set-Cookie': sessionCookie(token()) });
            }
            return json(res, 401, { error: 'invalid credentials' });
        });
    }
    if (url === '/logout') {
        return json(res, 200, { ok: true }, { 'Set-Cookie': COOKIE + '=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0' });
    }
    if (url === '/geo') {
        return json(res, 200, geoReply());
    }
    json(res, 404, { error: 'not found' });
});

server.listen(PORT, '127.0.0.1', () => {
    console.log('panel-auth on 127.0.0.1:' + PORT);
    refreshGeo(); // прогреваем geo-кэш для карточки Location
});
AUTHSRV

# systemd-сервис auth
cat > /etc/systemd/system/amnezia-panel-auth.service << EOF
[Unit]
Description=Amnezia VPN Panel Auth
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node /opt/amnezia/panel-auth/server.js
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable amnezia-panel-auth >/dev/null 2>&1
systemctl restart amnezia-panel-auth
sleep 1
if ! systemctl is-active --quiet amnezia-panel-auth; then
    echo "ОШИБКА: amnezia-panel-auth не запустился. Лог:"
    journalctl -u amnezia-panel-auth --no-pager -n 20
    exit 1
fi
echo "  Auth-сервис активен (127.0.0.1:4002)"

# Регион сервера по его внешнему IP (карточка Server -> Location)
SERVER_COUNTRY=""
if command -v node >/dev/null 2>&1; then
    for GEO_URL in "https://ipwho.is/" "http://ip-api.com/json/" "https://ipapi.co/json/"; do
        GEO_JSON="$(curl -fsS --max-time 8 "$GEO_URL" 2>/dev/null || true)"
        [ -n "$GEO_JSON" ] && break
    done
    if [ -n "$GEO_JSON" ]; then
        SERVER_COUNTRY="$(printf '%s' "$GEO_JSON" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(d);process.stdout.write(j&&j.country_name?j.country_name:j&&j.country?j.country:"")}catch(e){process.stdout.write("")}})')"
    else
        echo "  ВНИМАНИЕ: geoip-сервисы недоступны с этого сервера."
        echo "           Локация определится автоматически при открытии панели (рантайм)."
    fi
fi
if [ -n "$SERVER_COUNTRY" ]; then
    echo "  Регион сервера (geoip): $SERVER_COUNTRY"
fi

# Панель вшита в скрипт (base64) - работает даже без index.html рядом
PANEL_B64="PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InJ1Ij4KPGhlYWQ+CiAgICA8bWV0YSBjaGFyc2V0PSJVVEYtOCI+CiAgICA8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEuMCI+CiAgICA8dGl0bGU+QW1uZXppYSBWUE4gUGFuZWw8L3RpdGxlPgogICAgPGxpbmsgcmVsPSJpY29uIiB0eXBlPSJpbWFnZS9zdmcreG1sIiBocmVmPSJkYXRhOmltYWdlL3N2Zyt4bWwsJTNDc3ZnJTIweG1sbnMlM0QlMjdodHRwJTNBJTJGJTJGd3d3LnczLm9yZyUyRjIwMDAlMkZzdmclMjclMjB2aWV3Qm94JTNEJTI3MCUyMDAlMjA2NCUyMDY0JTI3JTNFJTNDcmVjdCUyMHdpZHRoJTNEJTI3NjQlMjclMjBoZWlnaHQlM0QlMjc2NCUyNyUyMHJ4JTNEJTI3MTQlMjclMjBmaWxsJTNEJTI3JTIzRkY4ODAwJTI3JTJGJTNFJTNDcGF0aCUyMGQlM0QlMjdNMzIlMjA4bDIzJTIwOXYxNWMwJTIwMTMtOCUyMDIxLTIzJTIwMjZDMTclMjA1MyUyMDklMjA0NSUyMDklMjAzMlYxN1olMjclMjBmaWxsJTNEJTI3JTIzMUExQTJFJTI3JTJGJTNFJTNDY2lyY2xlJTIwY3glM0QlMjczMiUyNyUyMGN5JTNEJTI3MzElMjclMjByJTNEJTI3MTAlMjclMjBmaWxsJTNEJTI3JTIzRkY4ODAwJTI3JTJGJTNFJTNDcmVjdCUyMHglM0QlMjcyOC41JTI3JTIweSUzRCUyNzM2JTI3JTIwd2lkdGglM0QlMjc3JTI3JTIwaGVpZ2h0JTNEJTI3MTIlMjclMjByeCUzRCUyNzEuNSUyNyUyMGZpbGwlM0QlMjclMjNGRjg4MDAlMjclMkYlM0UlM0MlMkZzdmclM0UiPgogICAgPGxpbmsgcmVsPSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSJkYXRhOmltYWdlL3N2Zyt4bWwsJTNDc3ZnJTIweG1sbnMlM0QlMjdodHRwJTNBJTJGJTJGd3d3LnczLm9yZyUyRjIwMDAlMkZzdmclMjclMjB2aWV3Qm94JTNEJTI3MCUyMDAlMjA2NCUyMDY0JTI3JTNFJTNDcmVjdCUyMHdpZHRoJTNEJTI3NjQlMjclMjBoZWlnaHQlM0QlMjc2NCUyNyUyMHJ4JTNEJTI3MTQlMjclMjBmaWxsJTNEJTI3JTIzRkY4ODAwJTI3JTJGJTNFJTNDcGF0aCUyMGQlM0QlMjdNMzIlMjA4bDIzJTIwOXYxNWMwJTIwMTMtOCUyMDIxLTIzJTIwMjZDMTclMjA1MyUyMDklMjA0NSUyMDklMjAzMlYxN1olMjclMjBmaWxsJTNEJTI3JTIzMUExQTJFJTI3JTJGJTNFJTNDY2lyY2xlJTIwY3glM0QlMjczMiUyNyUyMGN5JTNEJTI3MzElMjclMjByJTNEJTI3MTAlMjclMjBmaWxsJTNEJTI3JTIzRkY4ODAwJTI3JTJGJTNFJTNDcmVjdCUyMHglM0QlMjcyOC41JTI3JTIweSUzRCUyNzM2JTI3JTIwd2lkdGglM0QlMjc3JTI3JTIwaGVpZ2h0JTNEJTI3MTIlMjclMjByeCUzRCUyNzEuNSUyNyUyMGZpbGwlM0QlMjclMjNGRjg4MDAlMjclMkYlM0UlM0MlMkZzdmclM0UiPgogICAgPHNjcmlwdD4KdmFyIHFyY29kZT1mdW5jdGlvbigpe3ZhciB0PWZ1bmN0aW9uKHQscil7dmFyIGU9dCxuPWdbcl0sbz1udWxsLGk9MCxhPW51bGwsdT1bXSxmPXt9LGM9ZnVuY3Rpb24odCxyKXtvPWZ1bmN0aW9uKHQpe2Zvcih2YXIgcj1uZXcgQXJyYXkodCksZT0wO2U8dDtlKz0xKXtyW2VdPW5ldyBBcnJheSh0KTtmb3IodmFyIG49MDtuPHQ7bis9MSlyW2VdW25dPW51bGx9cmV0dXJuIHJ9KGk9NCplKzE3KSxsKDAsMCksbChpLTcsMCksbCgwLGktNykscygpLGgoKSxkKHQsciksZT49NyYmdih0KSxudWxsPT1hJiYoYT1wKGUsbix1KSksdyhhLHIpfSxsPWZ1bmN0aW9uKHQscil7Zm9yKHZhciBlPS0xO2U8PTc7ZSs9MSlpZighKHQrZTw9LTF8fGk8PXQrZSkpZm9yKHZhciBuPS0xO248PTc7bis9MSlyK248PS0xfHxpPD1yK258fChvW3QrZV1bcituXT0wPD1lJiZlPD02JiYoMD09bnx8Nj09bil8fDA8PW4mJm48PTYmJigwPT1lfHw2PT1lKXx8Mjw9ZSYmZTw9NCYmMjw9biYmbjw9NCl9LGg9ZnVuY3Rpb24oKXtmb3IodmFyIHQ9ODt0PGktODt0Kz0xKW51bGw9PW9bdF1bNl0mJihvW3RdWzZdPXQlMj09MCk7Zm9yKHZhciByPTg7cjxpLTg7cis9MSludWxsPT1vWzZdW3JdJiYob1s2XVtyXT1yJTI9PTApfSxzPWZ1bmN0aW9uKCl7Zm9yKHZhciB0PUIuZ2V0UGF0dGVyblBvc2l0aW9uKGUpLHI9MDtyPHQubGVuZ3RoO3IrPTEpZm9yKHZhciBuPTA7bjx0Lmxlbmd0aDtuKz0xKXt2YXIgaT10W3JdLGE9dFtuXTtpZihudWxsPT1vW2ldW2FdKWZvcih2YXIgdT0tMjt1PD0yO3UrPTEpZm9yKHZhciBmPS0yO2Y8PTI7Zis9MSlvW2krdV1bYStmXT0tMj09dXx8Mj09dXx8LTI9PWZ8fDI9PWZ8fDA9PXUmJjA9PWZ9fSx2PWZ1bmN0aW9uKHQpe2Zvcih2YXIgcj1CLmdldEJDSFR5cGVOdW1iZXIoZSksbj0wO248MTg7bis9MSl7dmFyIGE9IXQmJjE9PShyPj5uJjEpO29bTWF0aC5mbG9vcihuLzMpXVtuJTMraS04LTNdPWF9Zm9yKG49MDtuPDE4O24rPTEpe2E9IXQmJjE9PShyPj5uJjEpO29bbiUzK2ktOC0zXVtNYXRoLmZsb29yKG4vMyldPWF9fSxkPWZ1bmN0aW9uKHQscil7Zm9yKHZhciBlPW48PDN8cixhPUIuZ2V0QkNIVHlwZUluZm8oZSksdT0wO3U8MTU7dSs9MSl7dmFyIGY9IXQmJjE9PShhPj51JjEpO3U8Nj9vW3VdWzhdPWY6dTw4P29bdSsxXVs4XT1mOm9baS0xNSt1XVs4XT1mfWZvcih1PTA7dTwxNTt1Kz0xKXtmPSF0JiYxPT0oYT4+dSYxKTt1PDg/b1s4XVtpLXUtMV09Zjp1PDk/b1s4XVsxNS11LTErMV09ZjpvWzhdWzE1LXUtMV09Zn1vW2ktOF1bOF09IXR9LHc9ZnVuY3Rpb24odCxyKXtmb3IodmFyIGU9LTEsbj1pLTEsYT03LHU9MCxmPUIuZ2V0TWFza0Z1bmN0aW9uKHIpLGM9aS0xO2M+MDtjLT0yKWZvcig2PT1jJiYoYy09MSk7Oyl7Zm9yKHZhciBnPTA7ZzwyO2crPTEpaWYobnVsbD09b1tuXVtjLWddKXt2YXIgbD0hMTt1PHQubGVuZ3RoJiYobD0xPT0odFt1XT4+PmEmMSkpLGYobixjLWcpJiYobD0hbCksb1tuXVtjLWddPWwsLTE9PShhLT0xKSYmKHUrPTEsYT03KX1pZigobis9ZSk8MHx8aTw9bil7bi09ZSxlPS1lO2JyZWFrfX19LHA9ZnVuY3Rpb24odCxyLGUpe2Zvcih2YXIgbj1BLmdldFJTQmxvY2tzKHQsciksbz1iKCksaT0wO2k8ZS5sZW5ndGg7aSs9MSl7dmFyIGE9ZVtpXTtvLnB1dChhLmdldE1vZGUoKSw0KSxvLnB1dChhLmdldExlbmd0aCgpLEIuZ2V0TGVuZ3RoSW5CaXRzKGEuZ2V0TW9kZSgpLHQpKSxhLndyaXRlKG8pfXZhciB1PTA7Zm9yKGk9MDtpPG4ubGVuZ3RoO2krPTEpdSs9bltpXS5kYXRhQ291bnQ7aWYoby5nZXRMZW5ndGhJbkJpdHMoKT44KnUpdGhyb3ciY29kZSBsZW5ndGggb3ZlcmZsb3cuICgiK28uZ2V0TGVuZ3RoSW5CaXRzKCkrIj4iKzgqdSsiKSI7Zm9yKG8uZ2V0TGVuZ3RoSW5CaXRzKCkrNDw9OCp1JiZvLnB1dCgwLDQpO28uZ2V0TGVuZ3RoSW5CaXRzKCklOCE9MDspby5wdXRCaXQoITEpO2Zvcig7IShvLmdldExlbmd0aEluQml0cygpPj04KnV8fChvLnB1dCgyMzYsOCksby5nZXRMZW5ndGhJbkJpdHMoKT49OCp1KSk7KW8ucHV0KDE3LDgpO3JldHVybiBmdW5jdGlvbih0LHIpe2Zvcih2YXIgZT0wLG49MCxvPTAsaT1uZXcgQXJyYXkoci5sZW5ndGgpLGE9bmV3IEFycmF5KHIubGVuZ3RoKSx1PTA7dTxyLmxlbmd0aDt1Kz0xKXt2YXIgZj1yW3VdLmRhdGFDb3VudCxjPXJbdV0udG90YWxDb3VudC1mO249TWF0aC5tYXgobixmKSxvPU1hdGgubWF4KG8sYyksaVt1XT1uZXcgQXJyYXkoZik7Zm9yKHZhciBnPTA7ZzxpW3VdLmxlbmd0aDtnKz0xKWlbdV1bZ109MjU1JnQuZ2V0QnVmZmVyKClbZytlXTtlKz1mO3ZhciBsPUIuZ2V0RXJyb3JDb3JyZWN0UG9seW5vbWlhbChjKSxoPWsoaVt1XSxsLmdldExlbmd0aCgpLTEpLm1vZChsKTtmb3IoYVt1XT1uZXcgQXJyYXkobC5nZXRMZW5ndGgoKS0xKSxnPTA7ZzxhW3VdLmxlbmd0aDtnKz0xKXt2YXIgcz1nK2guZ2V0TGVuZ3RoKCktYVt1XS5sZW5ndGg7YVt1XVtnXT1zPj0wP2guZ2V0QXQocyk6MH19dmFyIHY9MDtmb3IoZz0wO2c8ci5sZW5ndGg7Zys9MSl2Kz1yW2ddLnRvdGFsQ291bnQ7dmFyIGQ9bmV3IEFycmF5KHYpLHc9MDtmb3IoZz0wO2c8bjtnKz0xKWZvcih1PTA7dTxyLmxlbmd0aDt1Kz0xKWc8aVt1XS5sZW5ndGgmJihkW3ddPWlbdV1bZ10sdys9MSk7Zm9yKGc9MDtnPG87Zys9MSlmb3IodT0wO3U8ci5sZW5ndGg7dSs9MSlnPGFbdV0ubGVuZ3RoJiYoZFt3XT1hW3VdW2ddLHcrPTEpO3JldHVybiBkfShvLG4pfTtmLmFkZERhdGE9ZnVuY3Rpb24odCxyKXt2YXIgZT1udWxsO3N3aXRjaChyPXJ8fCJCeXRlIil7Y2FzZSJOdW1lcmljIjplPU0odCk7YnJlYWs7Y2FzZSJBbHBoYW51bWVyaWMiOmU9eCh0KTticmVhaztjYXNlIkJ5dGUiOmU9bSh0KTticmVhaztjYXNlIkthbmppIjplPUwodCk7YnJlYWs7ZGVmYXVsdDp0aHJvdyJtb2RlOiIrcn11LnB1c2goZSksYT1udWxsfSxmLmlzRGFyaz1mdW5jdGlvbih0LHIpe2lmKHQ8MHx8aTw9dHx8cjwwfHxpPD1yKXRocm93IHQrIiwiK3I7cmV0dXJuIG9bdF1bcl19LGYuZ2V0TW9kdWxlQ291bnQ9ZnVuY3Rpb24oKXtyZXR1cm4gaX0sZi5tYWtlPWZ1bmN0aW9uKCl7aWYoZTwxKXtmb3IodmFyIHQ9MTt0PDQwO3QrKyl7Zm9yKHZhciByPUEuZ2V0UlNCbG9ja3ModCxuKSxvPWIoKSxpPTA7aTx1Lmxlbmd0aDtpKyspe3ZhciBhPXVbaV07by5wdXQoYS5nZXRNb2RlKCksNCksby5wdXQoYS5nZXRMZW5ndGgoKSxCLmdldExlbmd0aEluQml0cyhhLmdldE1vZGUoKSx0KSksYS53cml0ZShvKX12YXIgZz0wO2ZvcihpPTA7aTxyLmxlbmd0aDtpKyspZys9cltpXS5kYXRhQ291bnQ7aWYoby5nZXRMZW5ndGhJbkJpdHMoKTw9OCpnKWJyZWFrfWU9dH1jKCExLGZ1bmN0aW9uKCl7Zm9yKHZhciB0PTAscj0wLGU9MDtlPDg7ZSs9MSl7YyghMCxlKTt2YXIgbj1CLmdldExvc3RQb2ludChmKTsoMD09ZXx8dD5uKSYmKHQ9bixyPWUpfXJldHVybiByfSgpKX0sZi5jcmVhdGVUYWJsZVRhZz1mdW5jdGlvbih0LHIpe3Q9dHx8Mjt2YXIgZT0iIjtlKz0nPHRhYmxlIHN0eWxlPSInLGUrPSIgYm9yZGVyLXdpZHRoOiAwcHg7IGJvcmRlci1zdHlsZTogbm9uZTsiLGUrPSIgYm9yZGVyLWNvbGxhcHNlOiBjb2xsYXBzZTsiLGUrPSIgcGFkZGluZzogMHB4OyBtYXJnaW46ICIrKHI9dm9pZCAwPT09cj80KnQ6cikrInB4OyIsZSs9JyI+JyxlKz0iPHRib2R5PiI7Zm9yKHZhciBuPTA7bjxmLmdldE1vZHVsZUNvdW50KCk7bis9MSl7ZSs9Ijx0cj4iO2Zvcih2YXIgbz0wO288Zi5nZXRNb2R1bGVDb3VudCgpO28rPTEpZSs9Jzx0ZCBzdHlsZT0iJyxlKz0iIGJvcmRlci13aWR0aDogMHB4OyBib3JkZXItc3R5bGU6IG5vbmU7IixlKz0iIGJvcmRlci1jb2xsYXBzZTogY29sbGFwc2U7IixlKz0iIHBhZGRpbmc6IDBweDsgbWFyZ2luOiAwcHg7IixlKz0iIHdpZHRoOiAiK3QrInB4OyIsZSs9IiBoZWlnaHQ6ICIrdCsicHg7IixlKz0iIGJhY2tncm91bmQtY29sb3I6ICIsZSs9Zi5pc0RhcmsobixvKT8iIzAwMDAwMCI6IiNmZmZmZmYiLGUrPSI7IixlKz0nIi8+JztlKz0iPC90cj4ifXJldHVybiBlKz0iPC90Ym9keT4iLGUrPSI8L3RhYmxlPiJ9LGYuY3JlYXRlU3ZnVGFnPWZ1bmN0aW9uKHQscixlLG4pe3ZhciBvPXt9OyJvYmplY3QiPT10eXBlb2YgYXJndW1lbnRzWzBdJiYodD0obz1hcmd1bWVudHNbMF0pLmNlbGxTaXplLHI9by5tYXJnaW4sZT1vLmFsdCxuPW8udGl0bGUpLHQ9dHx8MixyPXZvaWQgMD09PXI/NCp0OnIsKGU9InN0cmluZyI9PXR5cGVvZiBlP3t0ZXh0OmV9OmV8fHt9KS50ZXh0PWUudGV4dHx8bnVsbCxlLmlkPWUudGV4dD9lLmlkfHwicXJjb2RlLWRlc2NyaXB0aW9uIjpudWxsLChuPSJzdHJpbmciPT10eXBlb2Ygbj97dGV4dDpufTpufHx7fSkudGV4dD1uLnRleHR8fG51bGwsbi5pZD1uLnRleHQ/bi5pZHx8InFyY29kZS10aXRsZSI6bnVsbDt2YXIgaSxhLHUsYyxnPWYuZ2V0TW9kdWxlQ291bnQoKSp0KzIqcixsPSIiO2ZvcihjPSJsIit0KyIsMCAwLCIrdCsiIC0iK3QrIiwwIDAsLSIrdCsieiAiLGwrPSc8c3ZnIHZlcnNpb249IjEuMSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIicsbCs9by5zY2FsYWJsZT8iIjonIHdpZHRoPSInK2crJ3B4IiBoZWlnaHQ9IicrZysncHgiJyxsKz0nIHZpZXdCb3g9IjAgMCAnK2crIiAiK2crJyIgJyxsKz0nIHByZXNlcnZlQXNwZWN0UmF0aW89InhNaW5ZTWluIG1lZXQiJyxsKz1uLnRleHR8fGUudGV4dD8nIHJvbGU9ImltZyIgYXJpYS1sYWJlbGxlZGJ5PSInK3koW24uaWQsZS5pZF0uam9pbigiICIpLnRyaW0oKSkrJyInOiIiLGwrPSI+IixsKz1uLnRleHQ/Jzx0aXRsZSBpZD0iJyt5KG4uaWQpKyciPicreShuLnRleHQpKyI8L3RpdGxlPiI6IiIsbCs9ZS50ZXh0Pyc8ZGVzY3JpcHRpb24gaWQ9IicreShlLmlkKSsnIj4nK3koZS50ZXh0KSsiPC9kZXNjcmlwdGlvbj4iOiIiLGwrPSc8cmVjdCB3aWR0aD0iMTAwJSIgaGVpZ2h0PSIxMDAlIiBmaWxsPSJ3aGl0ZSIgY3g9IjAiIGN5PSIwIi8+JyxsKz0nPHBhdGggZD0iJyxhPTA7YTxmLmdldE1vZHVsZUNvdW50KCk7YSs9MSlmb3IodT1hKnQrcixpPTA7aTxmLmdldE1vZHVsZUNvdW50KCk7aSs9MSlmLmlzRGFyayhhLGkpJiYobCs9Ik0iKyhpKnQrcikrIiwiK3UrYyk7cmV0dXJuIGwrPSciIHN0cm9rZT0idHJhbnNwYXJlbnQiIGZpbGw9ImJsYWNrIi8+JyxsKz0iPC9zdmc+In0sZi5jcmVhdGVEYXRhVVJMPWZ1bmN0aW9uKHQscil7dD10fHwyLHI9dm9pZCAwPT09cj80KnQ6cjt2YXIgZT1mLmdldE1vZHVsZUNvdW50KCkqdCsyKnIsbj1yLG89ZS1yO3JldHVybiBJKGUsZSwoZnVuY3Rpb24ocixlKXtpZihuPD1yJiZyPG8mJm48PWUmJmU8byl7dmFyIGk9TWF0aC5mbG9vcigoci1uKS90KSxhPU1hdGguZmxvb3IoKGUtbikvdCk7cmV0dXJuIGYuaXNEYXJrKGEsaSk/MDoxfXJldHVybiAxfSkpfSxmLmNyZWF0ZUltZ1RhZz1mdW5jdGlvbih0LHIsZSl7dD10fHwyLHI9dm9pZCAwPT09cj80KnQ6cjt2YXIgbj1mLmdldE1vZHVsZUNvdW50KCkqdCsyKnIsbz0iIjtyZXR1cm4gbys9IjxpbWciLG8rPScgc3JjPSInLG8rPWYuY3JlYXRlRGF0YVVSTCh0LHIpLG8rPSciJyxvKz0nIHdpZHRoPSInLG8rPW4sbys9JyInLG8rPScgaGVpZ2h0PSInLG8rPW4sbys9JyInLGUmJihvKz0nIGFsdD0iJyxvKz15KGUpLG8rPSciJyksbys9Ii8+In07dmFyIHk9ZnVuY3Rpb24odCl7Zm9yKHZhciByPSIiLGU9MDtlPHQubGVuZ3RoO2UrPTEpe3ZhciBuPXQuY2hhckF0KGUpO3N3aXRjaChuKXtjYXNlIjwiOnIrPSImbHQ7IjticmVhaztjYXNlIj4iOnIrPSImZ3Q7IjticmVhaztjYXNlIiYiOnIrPSImYW1wOyI7YnJlYWs7Y2FzZSciJzpyKz0iJnF1b3Q7IjticmVhaztkZWZhdWx0OnIrPW59fXJldHVybiByfTtyZXR1cm4gZi5jcmVhdGVBU0NJST1mdW5jdGlvbih0LHIpe2lmKCh0PXR8fDEpPDIpcmV0dXJuIGZ1bmN0aW9uKHQpe3Q9dm9pZCAwPT09dD8yOnQ7dmFyIHIsZSxuLG8saSxhPTEqZi5nZXRNb2R1bGVDb3VudCgpKzIqdCx1PXQsYz1hLXQsZz17IuKWiOKWiCI6IuKWiCIsIuKWiCAiOiLiloAiLCIg4paIIjoi4paEIiwiICAiOiIgIn0sbD17IuKWiOKWiCI6IuKWgCIsIuKWiCAiOiLiloAiLCIg4paIIjoiICIsIiAgIjoiICJ9LGg9IiI7Zm9yKHI9MDtyPGE7cis9Mil7Zm9yKG49TWF0aC5mbG9vcigoci11KS8xKSxvPU1hdGguZmxvb3IoKHIrMS11KS8xKSxlPTA7ZTxhO2UrPTEpaT0i4paIIix1PD1lJiZlPGMmJnU8PXImJnI8YyYmZi5pc0RhcmsobixNYXRoLmZsb29yKChlLXUpLzEpKSYmKGk9IiAiKSx1PD1lJiZlPGMmJnU8PXIrMSYmcisxPGMmJmYuaXNEYXJrKG8sTWF0aC5mbG9vcigoZS11KS8xKSk/aSs9IiAiOmkrPSLilogiLGgrPXQ8MSYmcisxPj1jP2xbaV06Z1tpXTtoKz0iXG4ifXJldHVybiBhJTImJnQ+MD9oLnN1YnN0cmluZygwLGgubGVuZ3RoLWEtMSkrQXJyYXkoYSsxKS5qb2luKCLiloAiKTpoLnN1YnN0cmluZygwLGgubGVuZ3RoLTEpfShyKTt0LT0xLHI9dm9pZCAwPT09cj8yKnQ6cjt2YXIgZSxuLG8saSxhPWYuZ2V0TW9kdWxlQ291bnQoKSp0KzIqcix1PXIsYz1hLXIsZz1BcnJheSh0KzEpLmpvaW4oIuKWiOKWiCIpLGw9QXJyYXkodCsxKS5qb2luKCIgICIpLGg9IiIscz0iIjtmb3IoZT0wO2U8YTtlKz0xKXtmb3Iobz1NYXRoLmZsb29yKChlLXUpL3QpLHM9IiIsbj0wO248YTtuKz0xKWk9MSx1PD1uJiZuPGMmJnU8PWUmJmU8YyYmZi5pc0RhcmsobyxNYXRoLmZsb29yKChuLXUpL3QpKSYmKGk9MCkscys9aT9nOmw7Zm9yKG89MDtvPHQ7bys9MSloKz1zKyJcbiJ9cmV0dXJuIGguc3Vic3RyaW5nKDAsaC5sZW5ndGgtMSl9LGYucmVuZGVyVG8yZENvbnRleHQ9ZnVuY3Rpb24odCxyKXtyPXJ8fDI7Zm9yKHZhciBlPWYuZ2V0TW9kdWxlQ291bnQoKSxuPTA7bjxlO24rKylmb3IodmFyIG89MDtvPGU7bysrKXQuZmlsbFN0eWxlPWYuaXNEYXJrKG4sbyk/ImJsYWNrIjoid2hpdGUiLHQuZmlsbFJlY3QobipyLG8qcixyLHIpfSxmfTt0LnN0cmluZ1RvQnl0ZXM9KHQuc3RyaW5nVG9CeXRlc0Z1bmNzPXtkZWZhdWx0OmZ1bmN0aW9uKHQpe2Zvcih2YXIgcj1bXSxlPTA7ZTx0Lmxlbmd0aDtlKz0xKXt2YXIgbj10LmNoYXJDb2RlQXQoZSk7ci5wdXNoKDI1NSZuKX1yZXR1cm4gcn19KS5kZWZhdWx0LHQuY3JlYXRlU3RyaW5nVG9CeXRlcz1mdW5jdGlvbih0LHIpe3ZhciBlPWZ1bmN0aW9uKCl7Zm9yKHZhciBlPVModCksbj1mdW5jdGlvbigpe3ZhciB0PWUucmVhZCgpO2lmKC0xPT10KXRocm93ImVvZiI7cmV0dXJuIHR9LG89MCxpPXt9Ozspe3ZhciBhPWUucmVhZCgpO2lmKC0xPT1hKWJyZWFrO3ZhciB1PW4oKSxmPW4oKTw8OHxuKCk7aVtTdHJpbmcuZnJvbUNoYXJDb2RlKGE8PDh8dSldPWYsbys9MX1pZihvIT1yKXRocm93IG8rIiAhPSAiK3I7cmV0dXJuIGl9KCksbj0iPyIuY2hhckNvZGVBdCgwKTtyZXR1cm4gZnVuY3Rpb24odCl7Zm9yKHZhciByPVtdLG89MDtvPHQubGVuZ3RoO28rPTEpe3ZhciBpPXQuY2hhckNvZGVBdChvKTtpZihpPDEyOClyLnB1c2goaSk7ZWxzZXt2YXIgYT1lW3QuY2hhckF0KG8pXTsibnVtYmVyIj09dHlwZW9mIGE/KDI1NSZhKT09YT9yLnB1c2goYSk6KHIucHVzaChhPj4+OCksci5wdXNoKDI1NSZhKSk6ci5wdXNoKG4pfX1yZXR1cm4gcn19O3ZhciByLGUsbixvLGksYT0xLHU9MixmPTQsYz04LGc9e0w6MSxNOjAsUTozLEg6Mn0sbD0wLGg9MSxzPTIsdj0zLGQ9NCx3PTUscD02LHk9NyxCPShyPVtbXSxbNiwxOF0sWzYsMjJdLFs2LDI2XSxbNiwzMF0sWzYsMzRdLFs2LDIyLDM4XSxbNiwyNCw0Ml0sWzYsMjYsNDZdLFs2LDI4LDUwXSxbNiwzMCw1NF0sWzYsMzIsNThdLFs2LDM0LDYyXSxbNiwyNiw0Niw2Nl0sWzYsMjYsNDgsNzBdLFs2LDI2LDUwLDc0XSxbNiwzMCw1NCw3OF0sWzYsMzAsNTYsODJdLFs2LDMwLDU4LDg2XSxbNiwzNCw2Miw5MF0sWzYsMjgsNTAsNzIsOTRdLFs2LDI2LDUwLDc0LDk4XSxbNiwzMCw1NCw3OCwxMDJdLFs2LDI4LDU0LDgwLDEwNl0sWzYsMzIsNTgsODQsMTEwXSxbNiwzMCw1OCw4NiwxMTRdLFs2LDM0LDYyLDkwLDExOF0sWzYsMjYsNTAsNzQsOTgsMTIyXSxbNiwzMCw1NCw3OCwxMDIsMTI2XSxbNiwyNiw1Miw3OCwxMDQsMTMwXSxbNiwzMCw1Niw4MiwxMDgsMTM0XSxbNiwzNCw2MCw4NiwxMTIsMTM4XSxbNiwzMCw1OCw4NiwxMTQsMTQyXSxbNiwzNCw2Miw5MCwxMTgsMTQ2XSxbNiwzMCw1NCw3OCwxMDIsMTI2LDE1MF0sWzYsMjQsNTAsNzYsMTAyLDEyOCwxNTRdLFs2LDI4LDU0LDgwLDEwNiwxMzIsMTU4XSxbNiwzMiw1OCw4NCwxMTAsMTM2LDE2Ml0sWzYsMjYsNTQsODIsMTEwLDEzOCwxNjZdLFs2LDMwLDU4LDg2LDExNCwxNDIsMTcwXV0sZT0xMzM1LG49Nzk3MyxpPWZ1bmN0aW9uKHQpe2Zvcih2YXIgcj0wOzAhPXQ7KXIrPTEsdD4+Pj0xO3JldHVybiByfSwobz17fSkuZ2V0QkNIVHlwZUluZm89ZnVuY3Rpb24odCl7Zm9yKHZhciByPXQ8PDEwO2kociktaShlKT49MDspcl49ZTw8aShyKS1pKGUpO3JldHVybiAyMTUyMl4odDw8MTB8cil9LG8uZ2V0QkNIVHlwZU51bWJlcj1mdW5jdGlvbih0KXtmb3IodmFyIHI9dDw8MTI7aShyKS1pKG4pPj0wOylyXj1uPDxpKHIpLWkobik7cmV0dXJuIHQ8PDEyfHJ9LG8uZ2V0UGF0dGVyblBvc2l0aW9uPWZ1bmN0aW9uKHQpe3JldHVybiByW3QtMV19LG8uZ2V0TWFza0Z1bmN0aW9uPWZ1bmN0aW9uKHQpe3N3aXRjaCh0KXtjYXNlIGw6cmV0dXJuIGZ1bmN0aW9uKHQscil7cmV0dXJuKHQrciklMj09MH07Y2FzZSBoOnJldHVybiBmdW5jdGlvbih0LHIpe3JldHVybiB0JTI9PTB9O2Nhc2UgczpyZXR1cm4gZnVuY3Rpb24odCxyKXtyZXR1cm4gciUzPT0wfTtjYXNlIHY6cmV0dXJuIGZ1bmN0aW9uKHQscil7cmV0dXJuKHQrciklMz09MH07Y2FzZSBkOnJldHVybiBmdW5jdGlvbih0LHIpe3JldHVybihNYXRoLmZsb29yKHQvMikrTWF0aC5mbG9vcihyLzMpKSUyPT0wfTtjYXNlIHc6cmV0dXJuIGZ1bmN0aW9uKHQscil7cmV0dXJuIHQqciUyK3QqciUzPT0wfTtjYXNlIHA6cmV0dXJuIGZ1bmN0aW9uKHQscil7cmV0dXJuKHQqciUyK3QqciUzKSUyPT0wfTtjYXNlIHk6cmV0dXJuIGZ1bmN0aW9uKHQscil7cmV0dXJuKHQqciUzKyh0K3IpJTIpJTI9PTB9O2RlZmF1bHQ6dGhyb3ciYmFkIG1hc2tQYXR0ZXJuOiIrdH19LG8uZ2V0RXJyb3JDb3JyZWN0UG9seW5vbWlhbD1mdW5jdGlvbih0KXtmb3IodmFyIHI9ayhbMV0sMCksZT0wO2U8dDtlKz0xKXI9ci5tdWx0aXBseShrKFsxLEMuZ2V4cChlKV0sMCkpO3JldHVybiByfSxvLmdldExlbmd0aEluQml0cz1mdW5jdGlvbih0LHIpe2lmKDE8PXImJnI8MTApc3dpdGNoKHQpe2Nhc2UgYTpyZXR1cm4gMTA7Y2FzZSB1OnJldHVybiA5O2Nhc2UgZjpjYXNlIGM6cmV0dXJuIDg7ZGVmYXVsdDp0aHJvdyJtb2RlOiIrdH1lbHNlIGlmKHI8Mjcpc3dpdGNoKHQpe2Nhc2UgYTpyZXR1cm4gMTI7Y2FzZSB1OnJldHVybiAxMTtjYXNlIGY6cmV0dXJuIDE2O2Nhc2UgYzpyZXR1cm4gMTA7ZGVmYXVsdDp0aHJvdyJtb2RlOiIrdH1lbHNle2lmKCEocjw0MSkpdGhyb3cidHlwZToiK3I7c3dpdGNoKHQpe2Nhc2UgYTpyZXR1cm4gMTQ7Y2FzZSB1OnJldHVybiAxMztjYXNlIGY6cmV0dXJuIDE2O2Nhc2UgYzpyZXR1cm4gMTI7ZGVmYXVsdDp0aHJvdyJtb2RlOiIrdH19fSxvLmdldExvc3RQb2ludD1mdW5jdGlvbih0KXtmb3IodmFyIHI9dC5nZXRNb2R1bGVDb3VudCgpLGU9MCxuPTA7bjxyO24rPTEpZm9yKHZhciBvPTA7bzxyO28rPTEpe2Zvcih2YXIgaT0wLGE9dC5pc0RhcmsobixvKSx1PS0xO3U8PTE7dSs9MSlpZighKG4rdTwwfHxyPD1uK3UpKWZvcih2YXIgZj0tMTtmPD0xO2YrPTEpbytmPDB8fHI8PW8rZnx8MD09dSYmMD09Znx8YT09dC5pc0Rhcmsobit1LG8rZikmJihpKz0xKTtpPjUmJihlKz0zK2ktNSl9Zm9yKG49MDtuPHItMTtuKz0xKWZvcihvPTA7bzxyLTE7bys9MSl7dmFyIGM9MDt0LmlzRGFyayhuLG8pJiYoYys9MSksdC5pc0RhcmsobisxLG8pJiYoYys9MSksdC5pc0RhcmsobixvKzEpJiYoYys9MSksdC5pc0RhcmsobisxLG8rMSkmJihjKz0xKSwwIT1jJiY0IT1jfHwoZSs9Myl9Zm9yKG49MDtuPHI7bis9MSlmb3Iobz0wO288ci02O28rPTEpdC5pc0RhcmsobixvKSYmIXQuaXNEYXJrKG4sbysxKSYmdC5pc0RhcmsobixvKzIpJiZ0LmlzRGFyayhuLG8rMykmJnQuaXNEYXJrKG4sbys0KSYmIXQuaXNEYXJrKG4sbys1KSYmdC5pc0RhcmsobixvKzYpJiYoZSs9NDApO2ZvcihvPTA7bzxyO28rPTEpZm9yKG49MDtuPHItNjtuKz0xKXQuaXNEYXJrKG4sbykmJiF0LmlzRGFyayhuKzEsbykmJnQuaXNEYXJrKG4rMixvKSYmdC5pc0RhcmsobiszLG8pJiZ0LmlzRGFyayhuKzQsbykmJiF0LmlzRGFyayhuKzUsbykmJnQuaXNEYXJrKG4rNixvKSYmKGUrPTQwKTt2YXIgZz0wO2ZvcihvPTA7bzxyO28rPTEpZm9yKG49MDtuPHI7bis9MSl0LmlzRGFyayhuLG8pJiYoZys9MSk7cmV0dXJuIGUrPU1hdGguYWJzKDEwMCpnL3Ivci01MCkvNSoxMH0sbyksQz1mdW5jdGlvbigpe2Zvcih2YXIgdD1uZXcgQXJyYXkoMjU2KSxyPW5ldyBBcnJheSgyNTYpLGU9MDtlPDg7ZSs9MSl0W2VdPTE8PGU7Zm9yKGU9ODtlPDI1NjtlKz0xKXRbZV09dFtlLTRdXnRbZS01XV50W2UtNl1edFtlLThdO2ZvcihlPTA7ZTwyNTU7ZSs9MSlyW3RbZV1dPWU7dmFyIG49e2dsb2c6ZnVuY3Rpb24odCl7aWYodDwxKXRocm93Imdsb2coIit0KyIpIjtyZXR1cm4gclt0XX0sZ2V4cDpmdW5jdGlvbihyKXtmb3IoO3I8MDspcis9MjU1O2Zvcig7cj49MjU2OylyLT0yNTU7cmV0dXJuIHRbcl19fTtyZXR1cm4gbn0oKTtmdW5jdGlvbiBrKHQscil7aWYodm9pZCAwPT09dC5sZW5ndGgpdGhyb3cgdC5sZW5ndGgrIi8iK3I7dmFyIGU9ZnVuY3Rpb24oKXtmb3IodmFyIGU9MDtlPHQubGVuZ3RoJiYwPT10W2VdOyllKz0xO2Zvcih2YXIgbj1uZXcgQXJyYXkodC5sZW5ndGgtZStyKSxvPTA7bzx0Lmxlbmd0aC1lO28rPTEpbltvXT10W28rZV07cmV0dXJuIG59KCksbj17Z2V0QXQ6ZnVuY3Rpb24odCl7cmV0dXJuIGVbdF19LGdldExlbmd0aDpmdW5jdGlvbigpe3JldHVybiBlLmxlbmd0aH0sbXVsdGlwbHk6ZnVuY3Rpb24odCl7Zm9yKHZhciByPW5ldyBBcnJheShuLmdldExlbmd0aCgpK3QuZ2V0TGVuZ3RoKCktMSksZT0wO2U8bi5nZXRMZW5ndGgoKTtlKz0xKWZvcih2YXIgbz0wO288dC5nZXRMZW5ndGgoKTtvKz0xKXJbZStvXV49Qy5nZXhwKEMuZ2xvZyhuLmdldEF0KGUpKStDLmdsb2codC5nZXRBdChvKSkpO3JldHVybiBrKHIsMCl9LG1vZDpmdW5jdGlvbih0KXtpZihuLmdldExlbmd0aCgpLXQuZ2V0TGVuZ3RoKCk8MClyZXR1cm4gbjtmb3IodmFyIHI9Qy5nbG9nKG4uZ2V0QXQoMCkpLUMuZ2xvZyh0LmdldEF0KDApKSxlPW5ldyBBcnJheShuLmdldExlbmd0aCgpKSxvPTA7bzxuLmdldExlbmd0aCgpO28rPTEpZVtvXT1uLmdldEF0KG8pO2ZvcihvPTA7bzx0LmdldExlbmd0aCgpO28rPTEpZVtvXV49Qy5nZXhwKEMuZ2xvZyh0LmdldEF0KG8pKStyKTtyZXR1cm4gayhlLDApLm1vZCh0KX19O3JldHVybiBufXZhciBBPWZ1bmN0aW9uKCl7dmFyIHQ9W1sxLDI2LDE5XSxbMSwyNiwxNl0sWzEsMjYsMTNdLFsxLDI2LDldLFsxLDQ0LDM0XSxbMSw0NCwyOF0sWzEsNDQsMjJdLFsxLDQ0LDE2XSxbMSw3MCw1NV0sWzEsNzAsNDRdLFsyLDM1LDE3XSxbMiwzNSwxM10sWzEsMTAwLDgwXSxbMiw1MCwzMl0sWzIsNTAsMjRdLFs0LDI1LDldLFsxLDEzNCwxMDhdLFsyLDY3LDQzXSxbMiwzMywxNSwyLDM0LDE2XSxbMiwzMywxMSwyLDM0LDEyXSxbMiw4Niw2OF0sWzQsNDMsMjddLFs0LDQzLDE5XSxbNCw0MywxNV0sWzIsOTgsNzhdLFs0LDQ5LDMxXSxbMiwzMiwxNCw0LDMzLDE1XSxbNCwzOSwxMywxLDQwLDE0XSxbMiwxMjEsOTddLFsyLDYwLDM4LDIsNjEsMzldLFs0LDQwLDE4LDIsNDEsMTldLFs0LDQwLDE0LDIsNDEsMTVdLFsyLDE0NiwxMTZdLFszLDU4LDM2LDIsNTksMzddLFs0LDM2LDE2LDQsMzcsMTddLFs0LDM2LDEyLDQsMzcsMTNdLFsyLDg2LDY4LDIsODcsNjldLFs0LDY5LDQzLDEsNzAsNDRdLFs2LDQzLDE5LDIsNDQsMjBdLFs2LDQzLDE1LDIsNDQsMTZdLFs0LDEwMSw4MV0sWzEsODAsNTAsNCw4MSw1MV0sWzQsNTAsMjIsNCw1MSwyM10sWzMsMzYsMTIsOCwzNywxM10sWzIsMTE2LDkyLDIsMTE3LDkzXSxbNiw1OCwzNiwyLDU5LDM3XSxbNCw0NiwyMCw2LDQ3LDIxXSxbNyw0MiwxNCw0LDQzLDE1XSxbNCwxMzMsMTA3XSxbOCw1OSwzNywxLDYwLDM4XSxbOCw0NCwyMCw0LDQ1LDIxXSxbMTIsMzMsMTEsNCwzNCwxMl0sWzMsMTQ1LDExNSwxLDE0NiwxMTZdLFs0LDY0LDQwLDUsNjUsNDFdLFsxMSwzNiwxNiw1LDM3LDE3XSxbMTEsMzYsMTIsNSwzNywxM10sWzUsMTA5LDg3LDEsMTEwLDg4XSxbNSw2NSw0MSw1LDY2LDQyXSxbNSw1NCwyNCw3LDU1LDI1XSxbMTEsMzYsMTIsNywzNywxM10sWzUsMTIyLDk4LDEsMTIzLDk5XSxbNyw3Myw0NSwzLDc0LDQ2XSxbMTUsNDMsMTksMiw0NCwyMF0sWzMsNDUsMTUsMTMsNDYsMTZdLFsxLDEzNSwxMDcsNSwxMzYsMTA4XSxbMTAsNzQsNDYsMSw3NSw0N10sWzEsNTAsMjIsMTUsNTEsMjNdLFsyLDQyLDE0LDE3LDQzLDE1XSxbNSwxNTAsMTIwLDEsMTUxLDEyMV0sWzksNjksNDMsNCw3MCw0NF0sWzE3LDUwLDIyLDEsNTEsMjNdLFsyLDQyLDE0LDE5LDQzLDE1XSxbMywxNDEsMTEzLDQsMTQyLDExNF0sWzMsNzAsNDQsMTEsNzEsNDVdLFsxNyw0NywyMSw0LDQ4LDIyXSxbOSwzOSwxMywxNiw0MCwxNF0sWzMsMTM1LDEwNyw1LDEzNiwxMDhdLFszLDY3LDQxLDEzLDY4LDQyXSxbMTUsNTQsMjQsNSw1NSwyNV0sWzE1LDQzLDE1LDEwLDQ0LDE2XSxbNCwxNDQsMTE2LDQsMTQ1LDExN10sWzE3LDY4LDQyXSxbMTcsNTAsMjIsNiw1MSwyM10sWzE5LDQ2LDE2LDYsNDcsMTddLFsyLDEzOSwxMTEsNywxNDAsMTEyXSxbMTcsNzQsNDZdLFs3LDU0LDI0LDE2LDU1LDI1XSxbMzQsMzcsMTNdLFs0LDE1MSwxMjEsNSwxNTIsMTIyXSxbNCw3NSw0NywxNCw3Niw0OF0sWzExLDU0LDI0LDE0LDU1LDI1XSxbMTYsNDUsMTUsMTQsNDYsMTZdLFs2LDE0NywxMTcsNCwxNDgsMTE4XSxbNiw3Myw0NSwxNCw3NCw0Nl0sWzExLDU0LDI0LDE2LDU1LDI1XSxbMzAsNDYsMTYsMiw0NywxN10sWzgsMTMyLDEwNiw0LDEzMywxMDddLFs4LDc1LDQ3LDEzLDc2LDQ4XSxbNyw1NCwyNCwyMiw1NSwyNV0sWzIyLDQ1LDE1LDEzLDQ2LDE2XSxbMTAsMTQyLDExNCwyLDE0MywxMTVdLFsxOSw3NCw0Niw0LDc1LDQ3XSxbMjgsNTAsMjIsNiw1MSwyM10sWzMzLDQ2LDE2LDQsNDcsMTddLFs4LDE1MiwxMjIsNCwxNTMsMTIzXSxbMjIsNzMsNDUsMyw3NCw0Nl0sWzgsNTMsMjMsMjYsNTQsMjRdLFsxMiw0NSwxNSwyOCw0NiwxNl0sWzMsMTQ3LDExNywxMCwxNDgsMTE4XSxbMyw3Myw0NSwyMyw3NCw0Nl0sWzQsNTQsMjQsMzEsNTUsMjVdLFsxMSw0NSwxNSwzMSw0NiwxNl0sWzcsMTQ2LDExNiw3LDE0NywxMTddLFsyMSw3Myw0NSw3LDc0LDQ2XSxbMSw1MywyMywzNyw1NCwyNF0sWzE5LDQ1LDE1LDI2LDQ2LDE2XSxbNSwxNDUsMTE1LDEwLDE0NiwxMTZdLFsxOSw3NSw0NywxMCw3Niw0OF0sWzE1LDU0LDI0LDI1LDU1LDI1XSxbMjMsNDUsMTUsMjUsNDYsMTZdLFsxMywxNDUsMTE1LDMsMTQ2LDExNl0sWzIsNzQsNDYsMjksNzUsNDddLFs0Miw1NCwyNCwxLDU1LDI1XSxbMjMsNDUsMTUsMjgsNDYsMTZdLFsxNywxNDUsMTE1XSxbMTAsNzQsNDYsMjMsNzUsNDddLFsxMCw1NCwyNCwzNSw1NSwyNV0sWzE5LDQ1LDE1LDM1LDQ2LDE2XSxbMTcsMTQ1LDExNSwxLDE0NiwxMTZdLFsxNCw3NCw0NiwyMSw3NSw0N10sWzI5LDU0LDI0LDE5LDU1LDI1XSxbMTEsNDUsMTUsNDYsNDYsMTZdLFsxMywxNDUsMTE1LDYsMTQ2LDExNl0sWzE0LDc0LDQ2LDIzLDc1LDQ3XSxbNDQsNTQsMjQsNyw1NSwyNV0sWzU5LDQ2LDE2LDEsNDcsMTddLFsxMiwxNTEsMTIxLDcsMTUyLDEyMl0sWzEyLDc1LDQ3LDI2LDc2LDQ4XSxbMzksNTQsMjQsMTQsNTUsMjVdLFsyMiw0NSwxNSw0MSw0NiwxNl0sWzYsMTUxLDEyMSwxNCwxNTIsMTIyXSxbNiw3NSw0NywzNCw3Niw0OF0sWzQ2LDU0LDI0LDEwLDU1LDI1XSxbMiw0NSwxNSw2NCw0NiwxNl0sWzE3LDE1MiwxMjIsNCwxNTMsMTIzXSxbMjksNzQsNDYsMTQsNzUsNDddLFs0OSw1NCwyNCwxMCw1NSwyNV0sWzI0LDQ1LDE1LDQ2LDQ2LDE2XSxbNCwxNTIsMTIyLDE4LDE1MywxMjNdLFsxMyw3NCw0NiwzMiw3NSw0N10sWzQ4LDU0LDI0LDE0LDU1LDI1XSxbNDIsNDUsMTUsMzIsNDYsMTZdLFsyMCwxNDcsMTE3LDQsMTQ4LDExOF0sWzQwLDc1LDQ3LDcsNzYsNDhdLFs0Myw1NCwyNCwyMiw1NSwyNV0sWzEwLDQ1LDE1LDY3LDQ2LDE2XSxbMTksMTQ4LDExOCw2LDE0OSwxMTldLFsxOCw3NSw0NywzMSw3Niw0OF0sWzM0LDU0LDI0LDM0LDU1LDI1XSxbMjAsNDUsMTUsNjEsNDYsMTZdXSxyPWZ1bmN0aW9uKHQscil7dmFyIGU9e307cmV0dXJuIGUudG90YWxDb3VudD10LGUuZGF0YUNvdW50PXIsZX0sZT17fTtyZXR1cm4gZS5nZXRSU0Jsb2Nrcz1mdW5jdGlvbihlLG4pe3ZhciBvPWZ1bmN0aW9uKHIsZSl7c3dpdGNoKGUpe2Nhc2UgZy5MOnJldHVybiB0WzQqKHItMSkrMF07Y2FzZSBnLk06cmV0dXJuIHRbNCooci0xKSsxXTtjYXNlIGcuUTpyZXR1cm4gdFs0KihyLTEpKzJdO2Nhc2UgZy5IOnJldHVybiB0WzQqKHItMSkrM107ZGVmYXVsdDpyZXR1cm59fShlLG4pO2lmKHZvaWQgMD09PW8pdGhyb3ciYmFkIHJzIGJsb2NrIEAgdHlwZU51bWJlcjoiK2UrIi9lcnJvckNvcnJlY3Rpb25MZXZlbDoiK247Zm9yKHZhciBpPW8ubGVuZ3RoLzMsYT1bXSx1PTA7dTxpO3UrPTEpZm9yKHZhciBmPW9bMyp1KzBdLGM9b1szKnUrMV0sbD1vWzMqdSsyXSxoPTA7aDxmO2grPTEpYS5wdXNoKHIoYyxsKSk7cmV0dXJuIGF9LGV9KCksYj1mdW5jdGlvbigpe3ZhciB0PVtdLHI9MCxlPXtnZXRCdWZmZXI6ZnVuY3Rpb24oKXtyZXR1cm4gdH0sZ2V0QXQ6ZnVuY3Rpb24ocil7dmFyIGU9TWF0aC5mbG9vcihyLzgpO3JldHVybiAxPT0odFtlXT4+PjctciU4JjEpfSxwdXQ6ZnVuY3Rpb24odCxyKXtmb3IodmFyIG49MDtuPHI7bis9MSllLnB1dEJpdCgxPT0odD4+PnItbi0xJjEpKX0sZ2V0TGVuZ3RoSW5CaXRzOmZ1bmN0aW9uKCl7cmV0dXJuIHJ9LHB1dEJpdDpmdW5jdGlvbihlKXt2YXIgbj1NYXRoLmZsb29yKHIvOCk7dC5sZW5ndGg8PW4mJnQucHVzaCgwKSxlJiYodFtuXXw9MTI4Pj4+ciU4KSxyKz0xfX07cmV0dXJuIGV9LE09ZnVuY3Rpb24odCl7dmFyIHI9YSxlPXQsbj17Z2V0TW9kZTpmdW5jdGlvbigpe3JldHVybiByfSxnZXRMZW5ndGg6ZnVuY3Rpb24odCl7cmV0dXJuIGUubGVuZ3RofSx3cml0ZTpmdW5jdGlvbih0KXtmb3IodmFyIHI9ZSxuPTA7bisyPHIubGVuZ3RoOyl0LnB1dChvKHIuc3Vic3RyaW5nKG4sbiszKSksMTApLG4rPTM7bjxyLmxlbmd0aCYmKHIubGVuZ3RoLW49PTE/dC5wdXQobyhyLnN1YnN0cmluZyhuLG4rMSkpLDQpOnIubGVuZ3RoLW49PTImJnQucHV0KG8oci5zdWJzdHJpbmcobixuKzIpKSw3KSl9fSxvPWZ1bmN0aW9uKHQpe2Zvcih2YXIgcj0wLGU9MDtlPHQubGVuZ3RoO2UrPTEpcj0xMCpyK2kodC5jaGFyQXQoZSkpO3JldHVybiByfSxpPWZ1bmN0aW9uKHQpe2lmKCIwIjw9dCYmdDw9IjkiKXJldHVybiB0LmNoYXJDb2RlQXQoMCktIjAiLmNoYXJDb2RlQXQoMCk7dGhyb3ciaWxsZWdhbCBjaGFyIDoiK3R9O3JldHVybiBufSx4PWZ1bmN0aW9uKHQpe3ZhciByPXUsZT10LG49e2dldE1vZGU6ZnVuY3Rpb24oKXtyZXR1cm4gcn0sZ2V0TGVuZ3RoOmZ1bmN0aW9uKHQpe3JldHVybiBlLmxlbmd0aH0sd3JpdGU6ZnVuY3Rpb24odCl7Zm9yKHZhciByPWUsbj0wO24rMTxyLmxlbmd0aDspdC5wdXQoNDUqbyhyLmNoYXJBdChuKSkrbyhyLmNoYXJBdChuKzEpKSwxMSksbis9MjtuPHIubGVuZ3RoJiZ0LnB1dChvKHIuY2hhckF0KG4pKSw2KX19LG89ZnVuY3Rpb24odCl7aWYoIjAiPD10JiZ0PD0iOSIpcmV0dXJuIHQuY2hhckNvZGVBdCgwKS0iMCIuY2hhckNvZGVBdCgwKTtpZigiQSI8PXQmJnQ8PSJaIilyZXR1cm4gdC5jaGFyQ29kZUF0KDApLSJBIi5jaGFyQ29kZUF0KDApKzEwO3N3aXRjaCh0KXtjYXNlIiAiOnJldHVybiAzNjtjYXNlIiQiOnJldHVybiAzNztjYXNlIiUiOnJldHVybiAzODtjYXNlIioiOnJldHVybiAzOTtjYXNlIisiOnJldHVybiA0MDtjYXNlIi0iOnJldHVybiA0MTtjYXNlIi4iOnJldHVybiA0MjtjYXNlIi8iOnJldHVybiA0MztjYXNlIjoiOnJldHVybiA0NDtkZWZhdWx0OnRocm93ImlsbGVnYWwgY2hhciA6Iit0fX07cmV0dXJuIG59LG09ZnVuY3Rpb24ocil7dmFyIGU9ZixuPXQuc3RyaW5nVG9CeXRlcyhyKSxvPXtnZXRNb2RlOmZ1bmN0aW9uKCl7cmV0dXJuIGV9LGdldExlbmd0aDpmdW5jdGlvbih0KXtyZXR1cm4gbi5sZW5ndGh9LHdyaXRlOmZ1bmN0aW9uKHQpe2Zvcih2YXIgcj0wO3I8bi5sZW5ndGg7cis9MSl0LnB1dChuW3JdLDgpfX07cmV0dXJuIG99LEw9ZnVuY3Rpb24ocil7dmFyIGU9YyxuPXQuc3RyaW5nVG9CeXRlc0Z1bmNzLlNKSVM7aWYoIW4pdGhyb3cic2ppcyBub3Qgc3VwcG9ydGVkLiI7IWZ1bmN0aW9uKCl7dmFyIHQ9bigi5Y+LIik7aWYoMiE9dC5sZW5ndGh8fDM4NzI2IT0odFswXTw8OHx0WzFdKSl0aHJvdyJzamlzIG5vdCBzdXBwb3J0ZWQuIn0oKTt2YXIgbz1uKHIpLGk9e2dldE1vZGU6ZnVuY3Rpb24oKXtyZXR1cm4gZX0sZ2V0TGVuZ3RoOmZ1bmN0aW9uKHQpe3JldHVybn5+KG8ubGVuZ3RoLzIpfSx3cml0ZTpmdW5jdGlvbih0KXtmb3IodmFyIHI9byxlPTA7ZSsxPHIubGVuZ3RoOyl7dmFyIG49KDI1NSZyW2VdKTw8OHwyNTUmcltlKzFdO2lmKDMzMDg4PD1uJiZuPD00MDk1NiluLT0zMzA4ODtlbHNle2lmKCEoNTc0MDg8PW4mJm48PTYwMzUxKSl0aHJvdyJpbGxlZ2FsIGNoYXIgYXQgIisoZSsxKSsiLyIrbjtuLT00OTQ3Mn1uPTE5Mioobj4+PjgmMjU1KSsoMjU1Jm4pLHQucHV0KG4sMTMpLGUrPTJ9aWYoZTxyLmxlbmd0aCl0aHJvdyJpbGxlZ2FsIGNoYXIgYXQgIisoZSsxKX19O3JldHVybiBpfSxEPWZ1bmN0aW9uKCl7dmFyIHQ9W10scj17d3JpdGVCeXRlOmZ1bmN0aW9uKHIpe3QucHVzaCgyNTUmcil9LHdyaXRlU2hvcnQ6ZnVuY3Rpb24odCl7ci53cml0ZUJ5dGUodCksci53cml0ZUJ5dGUodD4+PjgpfSx3cml0ZUJ5dGVzOmZ1bmN0aW9uKHQsZSxuKXtlPWV8fDAsbj1ufHx0Lmxlbmd0aDtmb3IodmFyIG89MDtvPG47bys9MSlyLndyaXRlQnl0ZSh0W28rZV0pfSx3cml0ZVN0cmluZzpmdW5jdGlvbih0KXtmb3IodmFyIGU9MDtlPHQubGVuZ3RoO2UrPTEpci53cml0ZUJ5dGUodC5jaGFyQ29kZUF0KGUpKX0sdG9CeXRlQXJyYXk6ZnVuY3Rpb24oKXtyZXR1cm4gdH0sdG9TdHJpbmc6ZnVuY3Rpb24oKXt2YXIgcj0iIjtyKz0iWyI7Zm9yKHZhciBlPTA7ZTx0Lmxlbmd0aDtlKz0xKWU+MCYmKHIrPSIsIikscis9dFtlXTtyZXR1cm4gcis9Il0ifX07cmV0dXJuIHJ9LFM9ZnVuY3Rpb24odCl7dmFyIHI9dCxlPTAsbj0wLG89MCxpPXtyZWFkOmZ1bmN0aW9uKCl7Zm9yKDtvPDg7KXtpZihlPj1yLmxlbmd0aCl7aWYoMD09bylyZXR1cm4tMTt0aHJvdyJ1bmV4cGVjdGVkIGVuZCBvZiBmaWxlLi8iK299dmFyIHQ9ci5jaGFyQXQoZSk7aWYoZSs9MSwiPSI9PXQpcmV0dXJuIG89MCwtMTt0Lm1hdGNoKC9eXHMkLyl8fChuPW48PDZ8YSh0LmNoYXJDb2RlQXQoMCkpLG8rPTYpfXZhciBpPW4+Pj5vLTgmMjU1O3JldHVybiBvLT04LGl9fSxhPWZ1bmN0aW9uKHQpe2lmKDY1PD10JiZ0PD05MClyZXR1cm4gdC02NTtpZig5Nzw9dCYmdDw9MTIyKXJldHVybiB0LTk3KzI2O2lmKDQ4PD10JiZ0PD01NylyZXR1cm4gdC00OCs1MjtpZig0Mz09dClyZXR1cm4gNjI7aWYoNDc9PXQpcmV0dXJuIDYzO3Rocm93ImM6Iit0fTtyZXR1cm4gaX0sST1mdW5jdGlvbih0LHIsZSl7Zm9yKHZhciBuPWZ1bmN0aW9uKHQscil7dmFyIGU9dCxuPXIsbz1uZXcgQXJyYXkodCpyKSxpPXtzZXRQaXhlbDpmdW5jdGlvbih0LHIsbil7b1tyKmUrdF09bn0sd3JpdGU6ZnVuY3Rpb24odCl7dC53cml0ZVN0cmluZygiR0lGODdhIiksdC53cml0ZVNob3J0KGUpLHQud3JpdGVTaG9ydChuKSx0LndyaXRlQnl0ZSgxMjgpLHQud3JpdGVCeXRlKDApLHQud3JpdGVCeXRlKDApLHQud3JpdGVCeXRlKDApLHQud3JpdGVCeXRlKDApLHQud3JpdGVCeXRlKDApLHQud3JpdGVCeXRlKDI1NSksdC53cml0ZUJ5dGUoMjU1KSx0LndyaXRlQnl0ZSgyNTUpLHQud3JpdGVTdHJpbmcoIiwiKSx0LndyaXRlU2hvcnQoMCksdC53cml0ZVNob3J0KDApLHQud3JpdGVTaG9ydChlKSx0LndyaXRlU2hvcnQobiksdC53cml0ZUJ5dGUoMCk7dmFyIHI9YSgyKTt0LndyaXRlQnl0ZSgyKTtmb3IodmFyIG89MDtyLmxlbmd0aC1vPjI1NTspdC53cml0ZUJ5dGUoMjU1KSx0LndyaXRlQnl0ZXMocixvLDI1NSksbys9MjU1O3Qud3JpdGVCeXRlKHIubGVuZ3RoLW8pLHQud3JpdGVCeXRlcyhyLG8sci5sZW5ndGgtbyksdC53cml0ZUJ5dGUoMCksdC53cml0ZVN0cmluZygiOyIpfX0sYT1mdW5jdGlvbih0KXtmb3IodmFyIHI9MTw8dCxlPTErKDE8PHQpLG49dCsxLGk9dSgpLGE9MDthPHI7YSs9MSlpLmFkZChTdHJpbmcuZnJvbUNoYXJDb2RlKGEpKTtpLmFkZChTdHJpbmcuZnJvbUNoYXJDb2RlKHIpKSxpLmFkZChTdHJpbmcuZnJvbUNoYXJDb2RlKGUpKTt2YXIgZixjLGcsbD1EKCksaD0oZj1sLGM9MCxnPTAse3dyaXRlOmZ1bmN0aW9uKHQscil7aWYodD4+PnIhPTApdGhyb3cibGVuZ3RoIG92ZXIiO2Zvcig7YytyPj04OylmLndyaXRlQnl0ZSgyNTUmKHQ8PGN8ZykpLHItPTgtYyx0Pj4+PTgtYyxnPTAsYz0wO2d8PXQ8PGMsYys9cn0sZmx1c2g6ZnVuY3Rpb24oKXtjPjAmJmYud3JpdGVCeXRlKGcpfX0pO2gud3JpdGUocixuKTt2YXIgcz0wLHY9U3RyaW5nLmZyb21DaGFyQ29kZShvW3NdKTtmb3Iocys9MTtzPG8ubGVuZ3RoOyl7dmFyIGQ9U3RyaW5nLmZyb21DaGFyQ29kZShvW3NdKTtzKz0xLGkuY29udGFpbnModitkKT92Kz1kOihoLndyaXRlKGkuaW5kZXhPZih2KSxuKSxpLnNpemUoKTw0MDk1JiYoaS5zaXplKCk9PTE8PG4mJihuKz0xKSxpLmFkZCh2K2QpKSx2PWQpfXJldHVybiBoLndyaXRlKGkuaW5kZXhPZih2KSxuKSxoLndyaXRlKGUsbiksaC5mbHVzaCgpLGwudG9CeXRlQXJyYXkoKX0sdT1mdW5jdGlvbigpe3ZhciB0PXt9LHI9MCxlPXthZGQ6ZnVuY3Rpb24obil7aWYoZS5jb250YWlucyhuKSl0aHJvdyJkdXAga2V5OiIrbjt0W25dPXIscis9MX0sc2l6ZTpmdW5jdGlvbigpe3JldHVybiByfSxpbmRleE9mOmZ1bmN0aW9uKHIpe3JldHVybiB0W3JdfSxjb250YWluczpmdW5jdGlvbihyKXtyZXR1cm4gdm9pZCAwIT09dFtyXX19O3JldHVybiBlfTtyZXR1cm4gaX0odCxyKSxvPTA7bzxyO28rPTEpZm9yKHZhciBpPTA7aTx0O2krPTEpbi5zZXRQaXhlbChpLG8sZShpLG8pKTt2YXIgYT1EKCk7bi53cml0ZShhKTtmb3IodmFyIHU9ZnVuY3Rpb24oKXt2YXIgdD0wLHI9MCxlPTAsbj0iIixvPXt9LGk9ZnVuY3Rpb24odCl7bis9U3RyaW5nLmZyb21DaGFyQ29kZShhKDYzJnQpKX0sYT1mdW5jdGlvbih0KXtpZih0PDApO2Vsc2V7aWYodDwyNilyZXR1cm4gNjUrdDtpZih0PDUyKXJldHVybiB0LTI2Kzk3O2lmKHQ8NjIpcmV0dXJuIHQtNTIrNDg7aWYoNjI9PXQpcmV0dXJuIDQzO2lmKDYzPT10KXJldHVybiA0N310aHJvdyJuOiIrdH07cmV0dXJuIG8ud3JpdGVCeXRlPWZ1bmN0aW9uKG4pe2Zvcih0PXQ8PDh8MjU1Jm4scis9OCxlKz0xO3I+PTY7KWkodD4+PnItNiksci09Nn0sby5mbHVzaD1mdW5jdGlvbigpe2lmKHI+MCYmKGkodDw8Ni1yKSx0PTAscj0wKSxlJTMhPTApZm9yKHZhciBvPTMtZSUzLGE9MDthPG87YSs9MSluKz0iPSJ9LG8udG9TdHJpbmc9ZnVuY3Rpb24oKXtyZXR1cm4gbn0sb30oKSxmPWEudG9CeXRlQXJyYXkoKSxjPTA7YzxmLmxlbmd0aDtjKz0xKXUud3JpdGVCeXRlKGZbY10pO3JldHVybiB1LmZsdXNoKCksImRhdGE6aW1hZ2UvZ2lmO2Jhc2U2NCwiK3V9O3JldHVybiB0fSgpO3FyY29kZS5zdHJpbmdUb0J5dGVzRnVuY3NbIlVURi04Il09ZnVuY3Rpb24odCl7cmV0dXJuIGZ1bmN0aW9uKHQpe2Zvcih2YXIgcj1bXSxlPTA7ZTx0Lmxlbmd0aDtlKyspe3ZhciBuPXQuY2hhckNvZGVBdChlKTtuPDEyOD9yLnB1c2gobik6bjwyMDQ4P3IucHVzaCgxOTJ8bj4+NiwxMjh8NjMmbik6bjw1NTI5Nnx8bj49NTczNDQ/ci5wdXNoKDIyNHxuPj4xMiwxMjh8bj4+NiY2MywxMjh8NjMmbik6KGUrKyxuPTY1NTM2KygoMTAyMyZuKTw8MTB8MTAyMyZ0LmNoYXJDb2RlQXQoZSkpLHIucHVzaCgyNDB8bj4+MTgsMTI4fG4+PjEyJjYzLDEyOHxuPj42JjYzLDEyOHw2MyZuKSl9cmV0dXJuIHJ9KHQpfSxmdW5jdGlvbih0KXsiZnVuY3Rpb24iPT10eXBlb2YgZGVmaW5lJiZkZWZpbmUuYW1kP2RlZmluZShbXSx0KToib2JqZWN0Ij09dHlwZW9mIGV4cG9ydHMmJihtb2R1bGUuZXhwb3J0cz10KCkpfSgoZnVuY3Rpb24oKXtyZXR1cm4gcXJjb2RlfSkpCgogICAgLy8gQWRhcHRlcjogUVJDb2RlLnRvQ2FudmFzKHRleHQsIG9wdHMsIGNiKQogICAgdmFyIFFSQ29kZSA9IHsKICAgICAgICB0b0NhbnZhczogZnVuY3Rpb24odGV4dCwgb3B0cywgY2IpIHsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIHZhciBzaXplID0gKG9wdHMgJiYgb3B0cy53aWR0aCkgfHwgMzAwOwogICAgICAgICAgICAgICAgdmFyIG1hcmdpbiA9IChvcHRzICYmIG9wdHMubWFyZ2luICE9PSB1bmRlZmluZWQpID8gb3B0cy5tYXJnaW4gOiAyOwogICAgICAgICAgICAgICAgdmFyIGVjbCA9IChvcHRzICYmIG9wdHMuZXJyb3JDb3JyZWN0aW9uTGV2ZWwpIHx8ICdNJzsKICAgICAgICAgICAgICAgIHZhciBxID0gcXJjb2RlKDAsIGVjbCk7CiAgICAgICAgICAgICAgICBxLmFkZERhdGEodGV4dCk7CiAgICAgICAgICAgICAgICBxLm1ha2UoKTsKICAgICAgICAgICAgICAgIHZhciBjb3VudCA9IHEuZ2V0TW9kdWxlQ291bnQoKTsKICAgICAgICAgICAgICAgIHZhciBjZWxsU2l6ZSA9IE1hdGguZmxvb3Ioc2l6ZSAvIChjb3VudCArIG1hcmdpbiAqIDIpKTsKICAgICAgICAgICAgICAgIHZhciBjYW52YXNTaXplID0gY2VsbFNpemUgKiAoY291bnQgKyBtYXJnaW4gKiAyKTsKICAgICAgICAgICAgICAgIHZhciBjYW52YXMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdjYW52YXMnKTsKICAgICAgICAgICAgICAgIGNhbnZhcy53aWR0aCA9IGNhbnZhc1NpemU7CiAgICAgICAgICAgICAgICBjYW52YXMuaGVpZ2h0ID0gY2FudmFzU2l6ZTsKICAgICAgICAgICAgICAgIHZhciBjdHggPSBjYW52YXMuZ2V0Q29udGV4dCgnMmQnKTsKICAgICAgICAgICAgICAgIGN0eC5maWxsU3R5bGUgPSAnI2ZmZic7CiAgICAgICAgICAgICAgICBjdHguZmlsbFJlY3QoMCwgMCwgY2FudmFzU2l6ZSwgY2FudmFzU2l6ZSk7CiAgICAgICAgICAgICAgICBjdHguZmlsbFN0eWxlID0gJyMwMDAnOwogICAgICAgICAgICAgICAgZm9yICh2YXIgciA9IDA7IHIgPCBjb3VudDsgcisrKSB7CiAgICAgICAgICAgICAgICAgICAgZm9yICh2YXIgYyA9IDA7IGMgPCBjb3VudDsgYysrKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChxLmlzRGFyayhyLCBjKSkgewogICAgICAgICAgICAgICAgICAgICAgICAgICAgY3R4LmZpbGxSZWN0KChjICsgbWFyZ2luKSAqIGNlbGxTaXplLCAociArIG1hcmdpbikgKiBjZWxsU2l6ZSwgY2VsbFNpemUsIGNlbGxTaXplKTsKICAgICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGNiKG51bGwsIGNhbnZhcyk7CiAgICAgICAgICAgIH0gY2F0Y2ggKGUpIHsgY2IoZSk7IH0KICAgICAgICB9CiAgICB9OwoKICAgIDwvc2NyaXB0PgogICAgPHNjcmlwdCBzcmM9Imh0dHBzOi8vY2RuLmpzZGVsaXZyLm5ldC9ucG0vcGFrb0AyLjEuMC9kaXN0L3Bha28ubWluLmpzIj48L3NjcmlwdD4KICAgIDxzdHlsZT4KICAgICAgICA6cm9vdCB7CiAgICAgICAgICAgIC0tYmc6ICMwYTBiMGU7CiAgICAgICAgICAgIC0tYmctZ2xvdzogcmdiYSg3MCw4MCwxMjAsMC4yMik7CiAgICAgICAgICAgIC0tYmctZWxldjogIzE1MTgxZTsKICAgICAgICAgICAgLS1iZy1jYXJkLWJvdHRvbTogIzEyMTQxYTsKICAgICAgICAgICAgLS1ib3JkZXI6IHJnYmEoMjU1LDI1NSwyNTUsMC4wOCk7CiAgICAgICAgICAgIC0tYm9yZGVyLXN0cm9uZzogcmdiYSgyNTUsMjU1LDI1NSwwLjE1KTsKICAgICAgICAgICAgLS10b3BiYXItYmc6IHJnYmEoMTMsMTUsMTksMC44Mik7CiAgICAgICAgICAgIC0taW5wdXQtYmc6IHJnYmEoMCwwLDAsMC4zNSk7CiAgICAgICAgICAgIC0taW5zZXQtYmc6IHJnYmEoMCwwLDAsMC4zKTsKICAgICAgICAgICAgLS1yb3ctaG92ZXI6IHJnYmEoMjU1LDI1NSwyNTUsMC4wMyk7CiAgICAgICAgICAgIC0tYXZhdGFyLWE6ICMyNDI4MzM7CiAgICAgICAgICAgIC0tYXZhdGFyLWI6ICMxOTFjMjM7CiAgICAgICAgICAgIC0tZG90LXJpbmc6ICMxNTE4MWU7CiAgICAgICAgICAgIC0tY29kZS1iZzogcmdiYSgyNTUsMjU1LDI1NSwwLjA2KTsKICAgICAgICAgICAgLS1zd2l0Y2gtb2ZmOiAjM2EzZjRhOwogICAgICAgICAgICAtLWJ0bi1naG9zdC1iZzogcmdiYSgyNTUsMjU1LDI1NSwwLjAzKTsKICAgICAgICAgICAgLS1idG4tZ2hvc3QtaG92ZXI6IHJnYmEoMjU1LDI1NSwyNTUsMC4wOCk7CiAgICAgICAgICAgIC0tb3ZlcmxheS1iZzogcmFkaWFsLWdyYWRpZW50KDEwMDBweCA1MDBweCBhdCA1MCUgLTIwJSwgcmdiYSg3MCw4MCwxMjAsMC4zNSksIHRyYW5zcGFyZW50IDYwJSksIHJnYmEoOCw5LDEyLDAuOTYpOwogICAgICAgICAgICAtLW1vZGFsLXNoYWRvdzogMCAzMHB4IDgwcHggcmdiYSgwLDAsMCwwLjYpOwogICAgICAgICAgICAtLW1zZy1zdWNjZXNzLWJnOiByZ2JhKDUyLDIxMSwxNTMsMC4xMik7CiAgICAgICAgICAgIC0tbXNnLXN1Y2Nlc3MtZmc6ICM2ZWU3Yjc7CiAgICAgICAgICAgIC0tbXNnLXN1Y2Nlc3MtYmQ6IHJnYmEoNTIsMjExLDE1MywwLjM1KTsKICAgICAgICAgICAgLS1tc2ctZXJyb3ItYmc6IHJnYmEoMjU1LDkyLDkyLDAuMTIpOwogICAgICAgICAgICAtLW1zZy1lcnJvci1mZzogI2ZmOGY4ZjsKICAgICAgICAgICAgLS1tc2ctZXJyb3ItYmQ6IHJnYmEoMjU1LDkyLDkyLDAuMzUpOwogICAgICAgICAgICAtLW1zZy1pbmZvLWJnOiByZ2JhKDI1NSwxMzYsMCwwLjEyKTsKICAgICAgICAgICAgLS1tc2ctaW5mby1mZzogI2ZmYjQ1ZTsKICAgICAgICAgICAgLS1tc2ctaW5mby1iZDogcmdiYSgyNTUsMTM2LDAsMC4zNSk7CiAgICAgICAgICAgIC0tYmFkZ2UtYWN0aXZlLWJnOiByZ2JhKDUyLDIxMSwxNTMsMC4xMyk7CiAgICAgICAgICAgIC0tYmFkZ2UtYWN0aXZlLWZnOiAjNmVlN2I3OwogICAgICAgICAgICAtLWJhZGdlLWFjdGl2ZS1iZDogcmdiYSg1MiwyMTEsMTUzLDAuNCk7CiAgICAgICAgICAgIC0tYmFkZ2UtZGlzYWJsZWQtYmc6IHJnYmEoMjU1LDkyLDkyLDAuMTIpOwogICAgICAgICAgICAtLWJhZGdlLWRpc2FibGVkLWZnOiAjZmY4ZjhmOwogICAgICAgICAgICAtLWJhZGdlLWRpc2FibGVkLWJkOiByZ2JhKDI1NSw5Miw5MiwwLjM1KTsKICAgICAgICAgICAgLS1hY2NlbnQ6ICNmODA7CiAgICAgICAgICAgIC0tYWNjZW50LWhvdmVyOiAjZmY5ODMwOwogICAgICAgICAgICAtLWFjY2VudC1zb2Z0OiByZ2JhKDI1NSwxMzYsMCwwLjE0KTsKICAgICAgICAgICAgLS10ZXh0OiAjZTdlOWVlOwogICAgICAgICAgICAtLW11dGVkOiAjOWFhMWFkOwogICAgICAgICAgICAtLWRhbmdlcjogI2ZmNWM1YzsKICAgICAgICAgICAgLS1zdWNjZXNzOiAjMzRkMzk5OwogICAgICAgICAgICAtLXJhZGl1czogMTBweDsKICAgICAgICB9CiAgICAgICAgaHRtbFtkYXRhLXRoZW1lPSJsaWdodCJdIHsKICAgICAgICAgICAgLS1iZzogI2VjZWVmMjsKICAgICAgICAgICAgLS1iZy1nbG93OiByZ2JhKDExMCwxMzAsMTkwLDAuMTQpOwogICAgICAgICAgICAtLWJnLWVsZXY6ICNmZmZmZmY7CiAgICAgICAgICAgIC0tYmctY2FyZC1ib3R0b206ICNmN2Y4ZmI7CiAgICAgICAgICAgIC0tYm9yZGVyOiByZ2JhKDIwLDI1LDQwLDAuMDgpOwogICAgICAgICAgICAtLWJvcmRlci1zdHJvbmc6IHJnYmEoMjAsMjUsNDAsMC4xNik7CiAgICAgICAgICAgIC0tdG9wYmFyLWJnOiByZ2JhKDI1NSwyNTUsMjU1LDAuODIpOwogICAgICAgICAgICAtLWlucHV0LWJnOiAjZmZmZmZmOwogICAgICAgICAgICAtLWluc2V0LWJnOiAjZjJmNGY4OwogICAgICAgICAgICAtLXJvdy1ob3ZlcjogcmdiYSgyMCwyNSw0MCwwLjA0NSk7CiAgICAgICAgICAgIC0tYXZhdGFyLWE6ICNlOGVjZjI7CiAgICAgICAgICAgIC0tYXZhdGFyLWI6ICNkZGUyZWE7CiAgICAgICAgICAgIC0tZG90LXJpbmc6ICNmZmZmZmY7CiAgICAgICAgICAgIC0tY29kZS1iZzogcmdiYSgyMCwyNSw0MCwwLjA2KTsKICAgICAgICAgICAgLS1zd2l0Y2gtb2ZmOiAjYzljZmRhOwogICAgICAgICAgICAtLWJ0bi1naG9zdC1iZzogcmdiYSgyMCwyNSw0MCwwLjA0KTsKICAgICAgICAgICAgLS1idG4tZ2hvc3QtaG92ZXI6IHJnYmEoMjAsMjUsNDAsMC4wOCk7CiAgICAgICAgICAgIC0tb3ZlcmxheS1iZzogcmFkaWFsLWdyYWRpZW50KDkwMHB4IDQ1MHB4IGF0IDUwJSAtMjAlLCByZ2JhKDExMCwxMzAsMTkwLDAuMjApLCB0cmFuc3BhcmVudCA2MCUpLCByZ2JhKDIzOCwyNDAsMjQ2LDAuOTYpOwogICAgICAgICAgICAtLW1vZGFsLXNoYWRvdzogMCAyMHB4IDUwcHggcmdiYSgzMCw0MCw3MCwwLjI1KTsKICAgICAgICAgICAgLS1tc2ctc3VjY2Vzcy1iZzogcmdiYSgyNCwxMjgsNTYsMC4xMCk7CiAgICAgICAgICAgIC0tbXNnLXN1Y2Nlc3MtZmc6ICMxNDcwM2M7CiAgICAgICAgICAgIC0tbXNnLXN1Y2Nlc3MtYmQ6IHJnYmEoMjQsMTI4LDU2LDAuMzApOwogICAgICAgICAgICAtLW1zZy1lcnJvci1iZzogcmdiYSgxOTcsMzQsMzEsMC4wOCk7CiAgICAgICAgICAgIC0tbXNnLWVycm9yLWZnOiAjYzUyMjFmOwogICAgICAgICAgICAtLW1zZy1lcnJvci1iZDogcmdiYSgxOTcsMzQsMzEsMC4zMCk7CiAgICAgICAgICAgIC0tbXNnLWluZm8tYmc6IHJnYmEoMjU1LDEzNiwwLDAuMTIpOwogICAgICAgICAgICAtLW1zZy1pbmZvLWZnOiAjYTM1YzAwOwogICAgICAgICAgICAtLW1zZy1pbmZvLWJkOiByZ2JhKDI1NSwxMzYsMCwwLjM1KTsKICAgICAgICAgICAgLS1iYWRnZS1hY3RpdmUtYmc6IHJnYmEoMjQsMTI4LDU2LDAuMTIpOwogICAgICAgICAgICAtLWJhZGdlLWFjdGl2ZS1mZzogIzE0NzAzYzsKICAgICAgICAgICAgLS1iYWRnZS1hY3RpdmUtYmQ6IHJnYmEoMjQsMTI4LDU2LDAuMzUpOwogICAgICAgICAgICAtLWJhZGdlLWRpc2FibGVkLWJnOiByZ2JhKDE5NywzNCwzMSwwLjA4KTsKICAgICAgICAgICAgLS1iYWRnZS1kaXNhYmxlZC1mZzogI2M1MjIxZjsKICAgICAgICAgICAgLS1iYWRnZS1kaXNhYmxlZC1iZDogcmdiYSgxOTcsMzQsMzEsMC4zMCk7CiAgICAgICAgICAgIC0tdGV4dDogIzFkMjEyYjsKICAgICAgICAgICAgLS1tdXRlZDogIzVjNjM3MDsKICAgICAgICAgICAgLS1kYW5nZXI6ICNkOTMwMjU7CiAgICAgICAgICAgIC0tc3VjY2VzczogIzE4ODAzODsKICAgICAgICB9CiAgICAgICAgKiB7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogMDsgcGFkZGluZzogMDsgfQogICAgICAgIGJvZHkgewogICAgICAgICAgICBmb250LWZhbWlseTogLWFwcGxlLXN5c3RlbSwgIlNlZ29lIFVJIiwgUm9ib3RvLCBzeXN0ZW0tdWksIHNhbnMtc2VyaWY7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJhZGlhbC1ncmFkaWVudCgxMTAwcHggNTUwcHggYXQgNTAlIC0xMCUsIHZhcigtLWJnLWdsb3cpLCB0cmFuc3BhcmVudCA2MCUpLCB2YXIoLS1iZyk7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10ZXh0KTsKICAgICAgICAgICAgbWluLWhlaWdodDogMTAwdmg7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAgIGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47CiAgICAgICAgICAgIHBhZGRpbmctYm90dG9tOiA0OHB4OwogICAgICAgIH0KICAgICAgICAuY29udGFpbmVyIHsgbWF4LXdpZHRoOiAxMDgwcHg7IG1hcmdpbjogMCBhdXRvOyBwYWRkaW5nOiAwIDIwcHg7IH0KCiAgICAgICAgLyogLS0tINCS0LXRgNGF0L3Rj9GPINC/0LDQvdC10LvRjCAo0LrQsNC6INCyIHdnLWVhc3kpIC0tLSAqLwogICAgICAgIC50b3BiYXIgewogICAgICAgICAgICBwb3NpdGlvbjogc3RpY2t5OyB0b3A6IDA7IHotaW5kZXg6IDUwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS10b3BiYXItYmcpOwogICAgICAgICAgICBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoMTJweCk7CiAgICAgICAgICAgIGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgICAgICAgICBtYXJnaW4tYm90dG9tOiAyOHB4OwogICAgICAgIH0KICAgICAgICAudG9wYmFyLWlubmVyIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBoZWlnaHQ6IDYycHg7IGdhcDogMTJweDsgfQogICAgICAgIC5icmFuZCB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTJweDsgfQogICAgICAgIC5icmFuZC1sb2dvIHsKICAgICAgICAgICAgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgYm9yZGVyLXJhZGl1czogOXB4OwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsICNmZjhhMDAsICNmNjApOwogICAgICAgICAgICBjb2xvcjogI2ZmZjsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAycHggMTJweCByZ2JhKDI1NSwxMzYsMCwwLjM1KTsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7CiAgICAgICAgfQogICAgICAgIC5icmFuZC1sb2dvIHN2ZyB7IHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IH0KICAgICAgICAuYnJhbmQtdGl0bGUgeyBmb250LXNpemU6IDEuMDVyZW07IGZvbnQtd2VpZ2h0OiA2MDA7IGxldHRlci1zcGFjaW5nOiAwLjJweDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgfQogICAgICAgIC50b3BiYXItYWN0aW9ucyB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4OyB9CgogICAgICAgIC5jYXJkIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4MGRlZywgdmFyKC0tYmctZWxldiksIHZhcigtLWJnLWNhcmQtYm90dG9tKSk7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDE0cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDIycHg7CiAgICAgICAgICAgIG1hcmdpbi1ib3R0b206IDIwcHg7CiAgICAgICAgfQogICAgICAgIC5jYXJkIGgyIHsgY29sb3I6IHZhcigtLXRleHQpOyBmb250LXNpemU6IDAuOTVyZW07IGZvbnQtd2VpZ2h0OiA2MDA7IGxldHRlci1zcGFjaW5nOiAwLjNweDsgbWFyZ2luLWJvdHRvbTogMTRweDsgfQogICAgICAgIGlucHV0LCB0ZXh0YXJlYSB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBwYWRkaW5nOiAxMXB4IDE0cHg7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlci1zdHJvbmcpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1pbnB1dC1iZyk7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10ZXh0KTsKICAgICAgICAgICAgZm9udC1zaXplOiAwLjk1cmVtOyBmb250LWZhbWlseTogaW5oZXJpdDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYm9yZGVyLWNvbG9yIC4xNXMgZWFzZSwgYm94LXNoYWRvdyAuMTVzIGVhc2U7CiAgICAgICAgfQogICAgICAgIGlucHV0OmZvY3VzLCB0ZXh0YXJlYTpmb2N1cyB7IG91dGxpbmU6IG5vbmU7IGJvcmRlci1jb2xvcjogdmFyKC0tYWNjZW50KTsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHZhcigtLWFjY2VudC1zb2Z0KTsgfQogICAgICAgIC5hZGQtY2FyZCB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IHBhZGRpbmc6IDE2cHggMThweDsgfQogICAgICAgIC5hZGQtY2FyZCAuYnRuLXByaW1hcnkgeyBmb250LXNpemU6IDAuOTVyZW07IHBhZGRpbmc6IDEycHggMjJweDsgfQogICAgICAgIHRleHRhcmVhIHsgZm9udC1mYW1pbHk6IG1vbm9zcGFjZTsgZm9udC1zaXplOiAwLjg1cmVtOyBtaW4taGVpZ2h0OiA4MHB4OyByZXNpemU6IHZlcnRpY2FsOyB9CiAgICAgICAgYnV0dG9uIHsKICAgICAgICAgICAgcGFkZGluZzogMTBweCAxOHB4OyBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cyk7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAwLjlyZW07IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIGZvbnQtZmFtaWx5OiBpbmhlcml0OyBsZXR0ZXItc3BhY2luZzogMC4ycHg7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjE1cyBlYXNlLCBjb2xvciAuMTVzIGVhc2UsIGJvcmRlci1jb2xvciAuMTVzIGVhc2UsIHRyYW5zZm9ybSAuMDVzIGVhc2U7CiAgICAgICAgfQogICAgICAgIGJ1dHRvbjphY3RpdmUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMXB4KTsgfQogICAgICAgIC5idG4tcHJpbWFyeSB7IGJhY2tncm91bmQ6IHZhcigtLWFjY2VudCk7IGNvbG9yOiAjZmZmOyBib3gtc2hhZG93OiAwIDJweCAxNHB4IHJnYmEoMjU1LDEzNiwwLDAuMzUpOyB9CiAgICAgICAgLmJ0bi1wcmltYXJ5OmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tYWNjZW50LWhvdmVyKTsgfQogICAgICAgIC5idG4tZGFuZ2VyIHsgYmFja2dyb3VuZDogdmFyKC0tZGFuZ2VyKTsgY29sb3I6ICNmZmY7IH0KICAgICAgICAuYnRuLWRhbmdlcjpob3ZlciB7IGZpbHRlcjogYnJpZ2h0bmVzcygxLjEyKTsgfQogICAgICAgIC5idG4tc3VjY2VzcyB7IGJhY2tncm91bmQ6IHZhcigtLXN1Y2Nlc3MpOyBjb2xvcjogI2ZmZjsgfQogICAgICAgIC5idG4tc3VjY2Vzczpob3ZlciB7IGZpbHRlcjogYnJpZ2h0bmVzcygxLjA4KTsgfQogICAgICAgIC5idG4tZ2hvc3QgeyBiYWNrZ3JvdW5kOiB2YXIoLS1idG4tZ2hvc3QtYmcpOyBjb2xvcjogdmFyKC0tdGV4dCk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlci1zdHJvbmcpOyB9CiAgICAgICAgLmJ0bi1naG9zdDpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWJ0bi1naG9zdC1ob3Zlcik7IH0KICAgICAgICAuYnRuLXNtIHsgcGFkZGluZzogNnB4IDE0cHg7IGZvbnQtc2l6ZTogMC44MnJlbTsgYm9yZGVyLXJhZGl1czogOHB4OyB9CiAgICAgICAgLmJ0bi1pY29uLXRoZW1lIHsKICAgICAgICAgICAgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgcGFkZGluZzogMDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1idG4tZ2hvc3QtYmcpOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1ib3JkZXItc3Ryb25nKTsKICAgICAgICAgICAgY29sb3I6IHZhcigtLW11dGVkKTsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgIH0KICAgICAgICAuYnRuLWljb24tdGhlbWU6aG92ZXIgeyBjb2xvcjogdmFyKC0tdGV4dCk7IGJhY2tncm91bmQ6IHZhcigtLWJ0bi1naG9zdC1ob3Zlcik7IH0KICAgICAgICAuYnRuLWljb24tdGhlbWUgc3ZnIHsgd2lkdGg6IDE3cHg7IGhlaWdodDogMTdweDsgZGlzcGxheTogbm9uZTsgfQogICAgICAgIGh0bWxbZGF0YS10aGVtZT0iZGFyayJdIC5idG4taWNvbi10aGVtZSAuaWNvbi1zdW4geyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIGh0bWxbZGF0YS10aGVtZT0ibGlnaHQiXSAuYnRuLWljb24tdGhlbWUgLmljb24tbW9vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgdGFibGUgeyB3aWR0aDogMTAwJTsgYm9yZGVyLWNvbGxhcHNlOiBjb2xsYXBzZTsgfQogICAgICAgIHRoLCB0ZCB7IHBhZGRpbmc6IDEwcHggOHB4OyB0ZXh0LWFsaWduOiBsZWZ0OyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tYm9yZGVyKTsgZm9udC1zaXplOiAwLjlyZW07IH0KICAgICAgICB0aCB7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IHdoaXRlLXNwYWNlOiBub3dyYXA7IGZvbnQtc2l6ZTogMC44cmVtOyB0ZXh0LXRyYW5zZm9ybTogdXBwZXJjYXNlOyBsZXR0ZXItc3BhY2luZzogMC41cHg7IH0KICAgICAgICAuYmFkZ2UgeyBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IHBhZGRpbmc6IDNweCAxMXB4OyBib3JkZXItcmFkaXVzOiAyMHB4OyBmb250LXNpemU6IDAuNzJyZW07IGZvbnQtd2VpZ2h0OiA2MDA7IGxldHRlci1zcGFjaW5nOiAwLjJweDsgfQogICAgICAgIC5iYWRnZS1hY3RpdmUgeyBiYWNrZ3JvdW5kOiB2YXIoLS1iYWRnZS1hY3RpdmUtYmcpOyBjb2xvcjogdmFyKC0tYmFkZ2UtYWN0aXZlLWZnKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYmFkZ2UtYWN0aXZlLWJkKTsgfQogICAgICAgIC5iYWRnZS1vZmZsaW5lIHsgYmFja2dyb3VuZDogdmFyKC0tYnRuLWdob3N0LWJnKTsgY29sb3I6IHZhcigtLW11dGVkKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYm9yZGVyLXN0cm9uZyk7IH0KICAgICAgICAuYmFkZ2UtZGlzYWJsZWQgeyBiYWNrZ3JvdW5kOiB2YXIoLS1iYWRnZS1kaXNhYmxlZC1iZyk7IGNvbG9yOiB2YXIoLS1iYWRnZS1kaXNhYmxlZC1mZyk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJhZGdlLWRpc2FibGVkLWJkKTsgfQogICAgICAgIC50ZXh0LW11dGVkIHsgY29sb3I6IHZhcigtLW11dGVkKTsgZm9udC1zaXplOiAwLjg1cmVtOyB9CiAgICAgICAgLmluZm8tZ3JpZCB7IGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogcmVwZWF0KDQsIDFmcik7IGdhcDogMTRweDsgfQogICAgICAgIC5pbmZvLWl0ZW0gewogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1pbnNldC1iZyk7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDEycHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDE4cHggMTJweDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogY2VudGVyOwogICAgICAgIH0KICAgICAgICAuaW5mby12YWx1ZSB7IGZvbnQtc2l6ZTogMS43cmVtOyBmb250LXdlaWdodDogNzAwOyBjb2xvcjogdmFyKC0tYWNjZW50KTsgfQogICAgICAgIC5pbmZvLWxhYmVsIHsgZm9udC1zaXplOiAwLjdyZW07IGNvbG9yOiB2YXIoLS1tdXRlZCk7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7IGxldHRlci1zcGFjaW5nOiAwLjZweDsgbWFyZ2luLXRvcDogNnB4OyB9CiAgICAgICAgLmFjdGlvbi1idXR0b25zIHsgZGlzcGxheTogZmxleDsgZ2FwOiA2cHg7IGZsZXgtd3JhcDogd3JhcDsgfQogICAgICAgIC5jbGllbnQtcm93IHsKICAgICAgICAgICAgcGFkZGluZzogMTRweCAxMnB4OwogICAgICAgICAgICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsKICAgICAgICAgICAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMjAwcHgsIDJmcikgMWZyIDFmciBhdXRvIGF1dG87CiAgICAgICAgICAgIGdhcDogMTZweDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5jbGllbnQtcm93Omxhc3QtY2hpbGQgeyBib3JkZXItYm90dG9tOiBub25lOyB9CiAgICAgICAgLmNsaWVudC1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1yb3ctaG92ZXIpOyB9CiAgICAgICAgLmNsaWVudC1pZCB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTJweDsgbWluLXdpZHRoOiAwOyB9CiAgICAgICAgLmNsaWVudC1hdmF0YXIgewogICAgICAgICAgICB3aWR0aDogNDBweDsgaGVpZ2h0OiA0MHB4OyBib3JkZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsIHZhcigtLWF2YXRhci1hKSwgdmFyKC0tYXZhdGFyLWIpKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYm9yZGVyLXN0cm9uZyk7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBmbGV4LXNocmluazogMDsgY29sb3I6IHZhcigtLW11dGVkKTsgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgIH0KICAgICAgICAuY2xpZW50LWF2YXRhciAub25saW5lLWRvdCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgYm90dG9tOiAtMnB4OyByaWdodDogLTJweDsKICAgICAgICAgICAgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tc3VjY2Vzcyk7CiAgICAgICAgICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWRvdC1yaW5nKTsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNTAlOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAwIHJnYmEoNTIsMjExLDE1MywwLjcpOwogICAgICAgIH0KICAgICAgICAuY2xpZW50LWF2YXRhciAub25saW5lLWRvdC5wdWxzZSB7IGFuaW1hdGlvbjogcHVsc2UgMS41cyBlYXNlLW91dCBpbmZpbml0ZTsgfQogICAgICAgIEBrZXlmcmFtZXMgcHVsc2UgewogICAgICAgICAgICAwJSB7IGJveC1zaGFkb3c6IDAgMCAwIDAgcmdiYSg1MiwyMTEsMTUzLDAuNyk7IH0KICAgICAgICAgICAgNzAlIHsgYm94LXNoYWRvdzogMCAwIDAgMTBweCByZ2JhKDUyLDIxMSwxNTMsMCk7IH0KICAgICAgICAgICAgMTAwJSB7IGJveC1zaGFkb3c6IDAgMCAwIDAgcmdiYSg1MiwyMTEsMTUzLDApOyB9CiAgICAgICAgfQogICAgICAgIC5jbGllbnQtbWV0YSB7IG1pbi13aWR0aDogMDsgfQogICAgICAgIC5jbGllbnQtbmFtZSB7IGZvbnQtd2VpZ2h0OiA2MDA7IGZvbnQtc2l6ZTogMC45NXJlbTsgdGV4dC1hbGlnbjogbGVmdDsgY29sb3I6IHZhcigtLXRleHQpOyB9CiAgICAgICAgLmNsaWVudC1zdWIgeyBjb2xvcjogdmFyKC0tbXV0ZWQpOyBmb250LXNpemU6IDAuNzhyZW07IHRleHQtYWxpZ246IGxlZnQ7IG1hcmdpbi10b3A6IDNweDsgfQogICAgICAgIC5jbGllbnQtc3ViIGNvZGUgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tdGV4dCk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNvZGUtYmcpOwogICAgICAgICAgICBwYWRkaW5nOiAxcHggNnB4OyBib3JkZXItcmFkaXVzOiA1cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMC43NXJlbTsKICAgICAgICB9CiAgICAgICAgLnRyYWZmaWMtY2VsbCB7IHRleHQtYWxpZ246IGxlZnQ7IGZvbnQtc2l6ZTogMC44NXJlbTsgbGluZS1oZWlnaHQ6IDEuMzsgfQogICAgICAgIC50cmFmZmljLXJhdGUgeyBjb2xvcjogdmFyKC0tdGV4dCk7IGZvbnQtd2VpZ2h0OiA2MDA7IH0KICAgICAgICAudHJhZmZpYy10b3RhbCB7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IGZvbnQtc2l6ZTogMC43NXJlbTsgfQogICAgICAgIC50cmFmZmljLXJhdGUudXAgeyBjb2xvcjogdmFyKC0tYWNjZW50KTsgfQogICAgICAgIC5zd2l0Y2ggeyBwb3NpdGlvbjogcmVsYXRpdmU7IGRpc3BsYXk6IGlubGluZS1ibG9jazsgd2lkdGg6IDQycHg7IGhlaWdodDogMjRweDsgfQogICAgICAgIC5zd2l0Y2ggaW5wdXQgeyBvcGFjaXR5OiAwOyB3aWR0aDogMDsgaGVpZ2h0OiAwOyB9CiAgICAgICAgLnNsaWRlci1zdyB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgY3Vyc29yOiBwb2ludGVyOyB0b3A6IDA7IGxlZnQ6IDA7IHJpZ2h0OiAwOyBib3R0b206IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLXN3aXRjaC1vZmYpOyBib3JkZXItcmFkaXVzOiAyNHB4OyB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4yczsKICAgICAgICB9CiAgICAgICAgLnNsaWRlci1zdzpiZWZvcmUgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7IGNvbnRlbnQ6ICIiOwogICAgICAgICAgICBoZWlnaHQ6IDE4cHg7IHdpZHRoOiAxOHB4OyBsZWZ0OiAzcHg7IGJvdHRvbTogM3B4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiA1MCU7IHRyYW5zaXRpb246IHRyYW5zZm9ybSAuMnM7CiAgICAgICAgfQogICAgICAgIC5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCArIC5zbGlkZXItc3cgeyBiYWNrZ3JvdW5kOiB2YXIoLS1zdWNjZXNzKTsgfQogICAgICAgIC5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCArIC5zbGlkZXItc3c6YmVmb3JlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDE4cHgpOyB9CiAgICAgICAgLmljb24tYnRuIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYnRuLWdob3N0LWJnKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYm9yZGVyLXN0cm9uZyk7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1tdXRlZCk7CiAgICAgICAgICAgIHdpZHRoOiAzNHB4OyBoZWlnaHQ6IDM0cHg7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOXB4OyBjdXJzb3I6IHBvaW50ZXI7IHBhZGRpbmc6IDA7CiAgICAgICAgfQogICAgICAgIC5pY29uLWJ0bjpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWJ0bi1naG9zdC1ob3Zlcik7IGNvbG9yOiB2YXIoLS10ZXh0KTsgfQogICAgICAgIC5pY29uLWJ0bi5kYW5nZXI6aG92ZXIgeyBjb2xvcjogdmFyKC0tZGFuZ2VyKTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1kYW5nZXIpOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSw5Miw5MiwwLjEpOyB9CiAgICAgICAgLmljb24tYnRuIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IH0KICAgICAgICAuYWN0aW9uLWJ1dHRvbnMgeyBkaXNwbGF5OiBmbGV4OyBnYXA6IDZweDsgfQogICAgICAgICNtc2cgeyBwYWRkaW5nOiAxMnB4IDE2cHg7IGJvcmRlci1yYWRpdXM6IDEwcHg7IG1hcmdpbi1ib3R0b206IDE2cHg7IGZvbnQtc2l6ZTogMC45cmVtOyBib3JkZXI6IDFweCBzb2xpZCB0cmFuc3BhcmVudDsgfQogICAgICAgICNtc2cuc3VjY2VzcyB7IGJhY2tncm91bmQ6IHZhcigtLW1zZy1zdWNjZXNzLWJnKTsgY29sb3I6IHZhcigtLW1zZy1zdWNjZXNzLWZnKTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1tc2ctc3VjY2Vzcy1iZCk7IH0KICAgICAgICAjbXNnLmVycm9yIHsgYmFja2dyb3VuZDogdmFyKC0tbXNnLWVycm9yLWJnKTsgY29sb3I6IHZhcigtLW1zZy1lcnJvci1mZyk7IGJvcmRlci1jb2xvcjogdmFyKC0tbXNnLWVycm9yLWJkKTsgfQogICAgICAgICNtc2cuaW5mbyB7IGJhY2tncm91bmQ6IHZhcigtLW1zZy1pbmZvLWJnKTsgY29sb3I6IHZhcigtLW1zZy1pbmZvLWZnKTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1tc2ctaW5mby1iZCk7IH0KICAgICAgICAubG9hZGluZyB7IHRleHQtYWxpZ246IGNlbnRlcjsgcGFkZGluZzogMjBweDsgY29sb3I6IHZhcigtLW11dGVkKTsgfQogICAgICAgICNsb2dpbi1vdmVybGF5IHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tb3ZlcmxheS1iZyk7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICB6LWluZGV4OiAxMDAwMDsgcGFkZGluZzogMjBweDsKICAgICAgICB9CiAgICAgICAgI2xvZ2luLWNhcmQgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCB2YXIoLS1iZy1lbGV2KSwgdmFyKC0tYmctY2FyZC1ib3R0b20pKTsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYm9yZGVyLXN0cm9uZyk7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDE4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDQwcHggMzZweDsKICAgICAgICAgICAgbWF4LXdpZHRoOiAzODBweDsgd2lkdGg6IDEwMCU7IHRleHQtYWxpZ246IGNlbnRlcjsKICAgICAgICAgICAgYm94LXNoYWRvdzogdmFyKC0tbW9kYWwtc2hhZG93KTsKICAgICAgICB9CiAgICAgICAgI2xvZ2luLWNhcmQgLmxvZ28gewogICAgICAgICAgICB3aWR0aDogNjJweDsgaGVpZ2h0OiA2MnB4OyBib3JkZXItcmFkaXVzOiAxNnB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCAjZmY4YTAwLCAjZjYwKTsKICAgICAgICAgICAgY29sb3I6ICNmZmY7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgZm9udC1zaXplOiAxLjdyZW07IG1hcmdpbi1ib3R0b206IDE4cHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgNHB4IDE4cHggcmdiYSgyNTUsMTM2LDAsMC40KTsKICAgICAgICB9CiAgICAgICAgI2xvZ2luLWNhcmQgaDIgeyBjb2xvcjogdmFyKC0tdGV4dCk7IG1hcmdpbi1ib3R0b206IDZweDsgZm9udC1zaXplOiAxLjE1cmVtOyB9CiAgICAgICAgI2xvZ2luLWNhcmQgcCB7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IGZvbnQtc2l6ZTogMC44NXJlbTsgbWFyZ2luLWJvdHRvbTogMjJweDsgfQogICAgICAgICNsb2dpbi1jYXJkIGlucHV0IHsgbWFyZ2luLWJvdHRvbTogMTJweDsgdGV4dC1hbGlnbjogbGVmdDsgfQogICAgICAgICNsb2dpbi1jYXJkIC5idG4tcHJpbWFyeSB7IHdpZHRoOiAxMDAlOyB9CiAgICAgICAgI2xvZ2luLWVycm9yIHsgY29sb3I6IHZhcigtLWRhbmdlcik7IGZvbnQtc2l6ZTogMC44NXJlbTsgbWFyZ2luLWJvdHRvbTogMTJweDsgbWluLWhlaWdodDogMS4yZW07IH0KICAgICAgICAjYnRuLWxvZ291dCB7IGJhY2tncm91bmQ6IHZhcigtLWJ0bi1naG9zdC1iZyk7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlci1zdHJvbmcpOyB9CiAgICAgICAgI2J0bi1sb2dvdXQ6aG92ZXIgeyBjb2xvcjogdmFyKC0tZGFuZ2VyKTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1kYW5nZXIpOyB9CgogICAgICAgIC8qIC0tLSDQnNC+0LTQsNC70YzQvdC+0LUg0L7QutC90L4g0LTQvtCx0LDQstC70LXQvdC40Y8g0LrQu9C40LXQvdGC0LAgKNC60LDQuiDQsiB3Zy1lYXN5KSAtLS0gKi8KICAgICAgICAubW9kYWwtb3ZlcmxheSB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDk1MDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsMC41NSk7CiAgICAgICAgICAgIGJhY2tkcm9wLWZpbHRlcjogYmx1cig0cHgpOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgcGFkZGluZzogMjBweDsKICAgICAgICB9CiAgICAgICAgLm1vZGFsLWNhcmQgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgbWF4LXdpZHRoOiA0MjBweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4MGRlZywgdmFyKC0tYmctZWxldiksIHZhcigtLWJnLWNhcmQtYm90dG9tKSk7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlci1zdHJvbmcpOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAxNnB4OwogICAgICAgICAgICBwYWRkaW5nOiAyOHB4OwogICAgICAgICAgICBib3gtc2hhZG93OiB2YXIoLS1tb2RhbC1zaGFkb3cpOwogICAgICAgIH0KICAgICAgICAubW9kYWwtY2FyZCBoMyB7IGZvbnQtc2l6ZTogMS4xcmVtOyBtYXJnaW4tYm90dG9tOiA2cHg7IH0KICAgICAgICAubW9kYWwtY2FyZCBwIHsgY29sb3I6IHZhcigtLW11dGVkKTsgZm9udC1zaXplOiAwLjg1cmVtOyBtYXJnaW4tYm90dG9tOiAxOHB4OyB9CiAgICAgICAgLm1vZGFsLWNhcmQgaW5wdXQgeyBtYXJnaW4tYm90dG9tOiAxOHB4OyB9CiAgICAgICAgLm1vZGFsLWFjdGlvbnMgeyBkaXNwbGF5OiBmbGV4OyBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOyBnYXA6IDEwcHg7IH0KCiAgICAgICAgQG1lZGlhIChtYXgtd2lkdGg6IDcwMHB4KSB7CiAgICAgICAgICAgIC5pbmZvLWdyaWQgeyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHJlcGVhdCgyLCAxZnIpOyB9CiAgICAgICAgICAgIC5jbGllbnQtcm93IHsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnI7IGdhcDogOHB4OyB9CiAgICAgICAgICAgIC50cmFmZmljLWNlbGwgeyB0ZXh0LWFsaWduOiBsZWZ0OyB9CiAgICAgICAgICAgIC5icmFuZC10aXRsZSB7IGZvbnQtc2l6ZTogMC45NXJlbTsgfQogICAgICAgIH0KCiAgICAgICAgLyogLS0tINCk0YPRgtC10YAgKNC60LDQuiDQsiB3Zy1lYXN5KSAtLS0gKi8KICAgICAgICAuZm9vdGVyIHsKICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICB6LWluZGV4OiAxMDAwMTsKICAgICAgICAgICAgbWFyZ2luLXRvcDogYXV0bzsKICAgICAgICAgICAgdGV4dC1hbGlnbjogY2VudGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tbXV0ZWQpOwogICAgICAgICAgICBmb250LXNpemU6IDAuOHJlbTsKICAgICAgICAgICAgbGluZS1oZWlnaHQ6IDEuNzsKICAgICAgICAgICAgcGFkZGluZzogMTBweCAxNnB4IDI0cHg7CiAgICAgICAgfQogICAgICAgIC5mb290ZXIgYSB7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IH0KICAgICAgICAuZm9vdGVyIGE6aG92ZXIgeyBjb2xvcjogdmFyKC0tdGV4dCk7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CiAgICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5PgogICAgPGhlYWRlciBjbGFzcz0idG9wYmFyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjb250YWluZXIgdG9wYmFyLWlubmVyIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iYnJhbmQiPgogICAgICAgICAgICAgICAgPGRpdiBjbGFzcz0iYnJhbmQtbG9nbyI+CiAgICAgICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48Y2lyY2xlIGN4PSIxMiIgY3k9IjQuNSIgcj0iMi41Ii8+PGNpcmNsZSBjeD0iNC41IiBjeT0iMTkuNSIgcj0iMi41Ii8+PGNpcmNsZSBjeD0iMTkuNSIgY3k9IjE5LjUiIHI9IjIuNSIvPjxwYXRoIGQ9Ik0xMSA3IDUuMiAxN00xMyA3bDUuOCAxME03IDE5LjVoMTAiLz48L3N2Zz4KICAgICAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImJyYW5kLXRpdGxlIj5BbW5lemlhIFZQTiBQYW5lbDwvc3Bhbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InRvcGJhci1hY3Rpb25zIj4KICAgICAgICAgICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1pY29uLXRoZW1lIiBpZD0iYnRuLXRoZW1lIiB0aXRsZT0i0KHQvNC10L3QuNGC0Ywg0YLQtdC80YMiPgogICAgICAgICAgICAgICAgICAgIDxzdmcgY2xhc3M9Imljb24tc3VuIiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iNC41Ii8+PHBhdGggZD0iTTEyIDIuNVY1TTEyIDE5djIuNU00LjggNC44bDEuNyAxLjdNMTcuNSAxNy41bDEuNyAxLjdNMi41IDEySDVNMTkgMTJoMi41TTQuOCAxOS4ybDEuNy0xLjdNMTcuNSA2LjVsMS43LTEuNyIvPjwvc3ZnPgogICAgICAgICAgICAgICAgICAgIDxzdmcgY2xhc3M9Imljb24tbW9vbiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik0yMC41IDEzLjVBOC41IDguNSAwIDAgMSAxMC41IDMuNSA4LjUgOC41IDAgMSAwIDIwLjUgMTMuNXoiLz48L3N2Zz4KICAgICAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXNtIiBpZD0iYnRuLWxvZ291dCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+0JLRi9C50YLQuDwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgIDwvaGVhZGVyPgogICAgPGRpdiBjbGFzcz0iY29udGFpbmVyIj4KICAgICAgICAKICAgICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBpZD0ic2VydmVyLWNhcmQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgICAgICA8aDI+U2VydmVyPC9oMj4KICAgICAgICAgICAgPGRpdiBpZD0iaW5mby1ncmlkIiBjbGFzcz0iaW5mby1ncmlkIj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICAKICAgICAgICA8ZGl2IGlkPSJtc2ctYm94Ij48L2Rpdj4KICAgICAgICAKICAgICAgICA8ZGl2IGlkPSJtYWluLXNlY3Rpb24iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJjYXJkIGFkZC1jYXJkIj4KICAgICAgICAgICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1wcmltYXJ5IiBpZD0iYnRuLWFkZCI+KyBBZGQgQ2xpZW50PC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAKICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgICAgICAgICA8aDI+Q2xpZW50cyAoPHNwYW4gaWQ9ImNsaWVudHMtY291bnQiPjA8L3NwYW4+KTwvaDI+CiAgICAgICAgICAgICAgICA8ZGl2IGlkPSJjbGllbnRzLWxpc3QiPjwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxmb290ZXIgY2xhc3M9ImZvb3RlciI+CiAgICAgICAgQW1uZXppYSBWUE4gUGFuZWwgwqkgPHNwYW4gaWQ9ImZvb3Rlci15ZWFyIj48L3NwYW4+IGJ5IEthbGluaW4gVml0YWxpeSBpcyBsaWNlbnNlZCB1bmRlciB0aGUKICAgICAgICA8YSBocmVmPSJodHRwczovL29wZW5zb3VyY2Uub3JnL2xpY2Vuc2VzL01JVCI+TUlUIExpY2Vuc2U8L2E+CiAgICA8L2Zvb3Rlcj4KCiAgICA8ZGl2IGlkPSJhZGQtbW9kYWwtb3ZlcmxheSIgY2xhc3M9Im1vZGFsLW92ZXJsYXkiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgIDxkaXYgY2xhc3M9Im1vZGFsLWNhcmQiPgogICAgICAgICAgICA8aDM+QWRkIENsaWVudDwvaDM+CiAgICAgICAgICAgIDxwPkVudGVyIGEgbmFtZSBmb3IgdGhlIG5ldyBjbGllbnQ8L3A+CiAgICAgICAgICAgIDxpbnB1dCB0eXBlPSJ0ZXh0IiBpZD0ibmFtZS1pbnB1dCIgcGxhY2Vob2xkZXI9Ik5ldyBjbGllbnQgbmFtZS4uLiI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9Im1vZGFsLWFjdGlvbnMiPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLWdob3N0IiBpZD0iYnRuLWFkZC1jYW5jZWwiPkNhbmNlbDwvYnV0dG9uPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXByaW1hcnkiIGlkPSJidG4tYWRkLXN1Ym1pdCI+KyBBZGQgQ2xpZW50PC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0ibG9naW4tb3ZlcmxheSI+CiAgICAgICAgPGRpdiBpZD0ibG9naW4tY2FyZCI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImxvZ28iPiYjMTI4Mjc0OzwvZGl2PgogICAgICAgICAgICA8aDI+QW1uZXppYSBWUE4gUGFuZWw8L2gyPgogICAgICAgICAgICA8cD7QktC+0LnQtNC40YLQtSwg0YfRgtC+0LHRiyDQv9GA0L7QtNC+0LvQttC40YLRjDwvcD4KICAgICAgICAgICAgPGlucHV0IHR5cGU9InRleHQiIGlkPSJsb2dpbi11c2VyIiBwbGFjZWhvbGRlcj0i0JvQvtCz0LjQvSIgYXV0b2NvbXBsZXRlPSJ1c2VybmFtZSIgLz4KICAgICAgICAgICAgPGlucHV0IHR5cGU9InBhc3N3b3JkIiBpZD0ibG9naW4tcGFzcyIgcGxhY2Vob2xkZXI9ItCf0LDRgNC+0LvRjCIgYXV0b2NvbXBsZXRlPSJjdXJyZW50LXBhc3N3b3JkIiAvPgogICAgICAgICAgICA8ZGl2IGlkPSJsb2dpbi1lcnJvciI+PC9kaXY+CiAgICAgICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1wcmltYXJ5IiBpZD0iYnRuLWxvZ2luIj7QktC+0LnRgtC4PC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIAogICAgPHNjcmlwdD4KICAgIChmdW5jdGlvbigpIHsKICAgICAgICB2YXIgYXBpS2V5ID0gJ1BMQUNFSE9MREVSJzsKICAgICAgICAvLyDQmtC70Y7RhyDQv9C10YDQtdC00LDRkdGC0YHRjyDQsiBVUkwgKD9rZXk9Li4uKTogbmdpbngg0L7RgtC00LDRkdGCINC/0LDQvdC10LvRjCDRgtC+0LvRjNC60L4g0YEg0LLQtdGA0L3Ri9C8INC60LvRjtGH0L7QvCwKICAgICAgICAvLyDQsCDRgdC60YDQuNC/0YIg0LjRgdC/0L7Qu9GM0LfRg9C10YIg0LrQu9GO0Ycg0LjQtyBVUkwg0LTQu9GPINC30LDQv9GA0L7RgdC+0LIg0LogQVBJIChmYWxsYmFjayAtINC30LDRiNC40YLRi9C5INC60LvRjtGHKS4KICAgICAgICB0cnkgewogICAgICAgICAgICB2YXIgcWsgPSAod2luZG93LmxvY2F0aW9uLnNlYXJjaC5tYXRjaCgvWz8mXWtleT0oW14mXSspLykgfHwgW10pWzFdOwogICAgICAgICAgICBpZiAocWspIGFwaUtleSA9IGRlY29kZVVSSUNvbXBvbmVudChxayk7CiAgICAgICAgfSBjYXRjaChlKSB7fQogICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdhaycsIGFwaUtleSk7CiAgICAgICAgCiAgICAgICAgLy8g0KDQtdCz0LjQvtC9INGB0LXRgNCy0LXRgNCwINC/0L4g0LXQs9C+INCy0L3QtdGI0L3QtdC80YMgSVAgKNGD0YHRgtCw0L3QvtCy0YnQuNC6INC30LDQvNC10L3Rj9C10YIg0YLQvtC60LXQvSDQvdCwINGB0YLRgNCw0L3RgykKICAgICAgICB2YXIgc2VydmVyQ291bnRyeSA9ICdfX1NFUlZFUl9DT1VOVFJZX18nOwogICAgICAgIGlmICghc2VydmVyQ291bnRyeSB8fCBzZXJ2ZXJDb3VudHJ5LmluZGV4T2YoJ19fU0VSVkVSX0NPVU5UUllfXycpID09PSAwKSBzZXJ2ZXJDb3VudHJ5ID0gJyc7CiAgICAgICAgCiAgICAgICAgdmFyIGVscyA9IHsKICAgICAgICAgICAgc2VydmVyQ2FyZDogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlcnZlci1jYXJkJyksCiAgICAgICAgICAgIGluZm9HcmlkOiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5mby1ncmlkJyksCiAgICAgICAgICAgIG1haW5TZWN0aW9uOiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbWFpbi1zZWN0aW9uJyksCiAgICAgICAgICAgIGNsaWVudHNDb3VudDogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NsaWVudHMtY291bnQnKSwKICAgICAgICAgICAgY2xpZW50c0xpc3Q6IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbGllbnRzLWxpc3QnKSwKICAgICAgICAgICAgbmFtZUlucHV0OiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmFtZS1pbnB1dCcpLAogICAgICAgICAgICBtc2dCb3g6IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc2ctYm94JykKICAgICAgICB9OwogICAgICAgIHZhciBsb2dnZWRJbiA9IGZhbHNlOwoKICAgICAgICAvLyDQk9C+0LQg0LIg0YTRg9GC0LXRgNC1ICjRgtC10LrRg9GJ0LjQuSkKICAgICAgICB2YXIgZm9vdGVyWWVhciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb290ZXIteWVhcicpOwogICAgICAgIGlmIChmb290ZXJZZWFyKSBmb290ZXJZZWFyLnRleHRDb250ZW50ID0gbmV3IERhdGUoKS5nZXRGdWxsWWVhcigpOwoKICAgICAgICAvLyAtLS0g0KLQtdC80LA6INGB0LLQtdGC0LvQsNGPL9GC0ZHQvNC90LDRjyAo0L/QtdGA0LXQutC70Y7Rh9Cw0YLQtdC70Ywg0LIg0YjQsNC/0LrQtSwg0LrQsNC6INCyIHdnLWVhc3kpIC0tLQogICAgICAgIHZhciBidG5UaGVtZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdGhlbWUnKTsKICAgICAgICBmdW5jdGlvbiBhcHBseVRoZW1lKHQpIHsKICAgICAgICAgICAgdmFyIHRoID0gKHQgPT09ICdsaWdodCcpID8gJ2xpZ2h0JyA6ICdkYXJrJzsKICAgICAgICAgICAgZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LnNldEF0dHJpYnV0ZSgnZGF0YS10aGVtZScsIHRoKTsKICAgICAgICAgICAgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ3BubF90aGVtZScsIHRoKTsgfSBjYXRjaChlKSB7fQogICAgICAgIH0KICAgICAgICB2YXIgc2F2ZWRUaGVtZSA9IG51bGw7CiAgICAgICAgdHJ5IHsgc2F2ZWRUaGVtZSA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKCdwbmxfdGhlbWUnKTsgfSBjYXRjaChlKSB7fQogICAgICAgIGlmIChzYXZlZFRoZW1lICE9PSAnbGlnaHQnICYmIHNhdmVkVGhlbWUgIT09ICdkYXJrJykgewogICAgICAgICAgICBzYXZlZFRoZW1lID0gKHdpbmRvdy5tYXRjaE1lZGlhICYmIHdpbmRvdy5tYXRjaE1lZGlhKCcocHJlZmVycy1jb2xvci1zY2hlbWU6IGxpZ2h0KScpLm1hdGNoZXMpID8gJ2xpZ2h0JyA6ICdkYXJrJzsKICAgICAgICB9CiAgICAgICAgYXBwbHlUaGVtZShzYXZlZFRoZW1lKTsKICAgICAgICBpZiAoYnRuVGhlbWUpIGJ0blRoZW1lLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZnVuY3Rpb24oKSB7CiAgICAgICAgICAgIGFwcGx5VGhlbWUoZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LmdldEF0dHJpYnV0ZSgnZGF0YS10aGVtZScpID09PSAnbGlnaHQnID8gJ2RhcmsnIDogJ2xpZ2h0Jyk7CiAgICAgICAgfSk7CiAgICAgICAgCiAgICAgICAgZnVuY3Rpb24gZXNjKHMpIHsKICAgICAgICAgICAgcmV0dXJuIFN0cmluZyhzKS5yZXBsYWNlKC8mL2csJyZhbXA7JykucmVwbGFjZSgvPC9nLCcmbHQ7JykucmVwbGFjZSgvPi9nLCcmZ3Q7JykucmVwbGFjZSgvIi9nLCcmcXVvdDsnKTsKICAgICAgICB9CiAgICAgICAgCiAgICAgICAgZnVuY3Rpb24gbXNnKHRleHQsIHR5cGUpIHsKICAgICAgICAgICAgZWxzLm1zZ0JveC5pbm5lckhUTUwgPSAnPGRpdiBpZD0ibXNnIiBjbGFzcz0iJyArICh0eXBlIHx8ICdpbmZvJykgKyAnIj4nICsgZXNjKHRleHQpICsgJzwvZGl2Pic7CiAgICAgICAgICAgIHNldFRpbWVvdXQoZnVuY3Rpb24oKSB7IGVscy5tc2dCb3guaW5uZXJIVE1MID0gJyc7IH0sIDUwMDApOwogICAgICAgIH0KICAgICAgICAKICAgICAgICBmdW5jdGlvbiBmbXQoYikgewogICAgICAgICAgICBpZiAoIWIpIHJldHVybiAnMCBCJzsKICAgICAgICAgICAgdmFyIGsgPSAxMDI0LCBzID0gWydCJywnS0InLCdNQicsJ0dCJywnVEInXTsKICAgICAgICAgICAgdmFyIGkgPSBNYXRoLmZsb29yKE1hdGgubG9nKGIpIC8gTWF0aC5sb2coaykpOwogICAgICAgICAgICByZXR1cm4gKGIgLyBNYXRoLnBvdyhrLCBpKSkudG9GaXhlZChiIDwgMTAgKiBNYXRoLnBvdyhrLCBpKSA/IDIgOiAxKSArICcgJyArIHNbaV07CiAgICAgICAgfQoKICAgICAgICBmdW5jdGlvbiBmbXRSYXRlKGIpIHsKICAgICAgICAgICAgaWYgKCFiKSByZXR1cm4gJzAgQic7CiAgICAgICAgICAgIHJldHVybiBmbXQoYik7CiAgICAgICAgfQogICAgICAgIAogICAgICAgIGZ1bmN0aW9uIGZtdFRpbWUodHMpIHsKICAgICAgICAgICAgaWYgKCF0cyB8fCB0cyA9PT0gMCkgcmV0dXJuICfigJQnOwogICAgICAgICAgICB2YXIgZCA9IE1hdGguZmxvb3IoRGF0ZS5ub3coKSAvIDEwMDApIC0gdHM7CiAgICAgICAgICAgIGlmIChkIDwgNjApIHJldHVybiBkICsgJ3MgYWdvJzsKICAgICAgICAgICAgaWYgKGQgPCAzNjAwKSByZXR1cm4gTWF0aC5mbG9vcihkLzYwKSArICdtIGFnbyc7CiAgICAgICAgICAgIGlmIChkIDwgODY0MDApIHJldHVybiBNYXRoLmZsb29yKGQvMzYwMCkgKyAnaCBhZ28nOwogICAgICAgICAgICBpZiAoZCA8IDYwNDgwMCkgcmV0dXJuIE1hdGguZmxvb3IoZC84NjQwMCkgKyAnZCBhZ28nOwogICAgICAgICAgICByZXR1cm4gbmV3IERhdGUodHMgKiAxMDAwKS50b0xvY2FsZURhdGVTdHJpbmcoKTsKICAgICAgICB9CiAgICAgICAgCiAgICAgICAgZnVuY3Rpb24gZG93bmxvYWRUZXh0KHRleHQsIGZpbGVuYW1lKSB7CiAgICAgICAgICAgIHZhciBibG9iID0gbmV3IEJsb2IoW3RleHRdLCB7IHR5cGU6ICd0ZXh0L3BsYWluO2NoYXJzZXQ9dXRmLTgnIH0pOwogICAgICAgICAgICB2YXIgdXJsID0gVVJMLmNyZWF0ZU9iamVjdFVSTChibG9iKTsKICAgICAgICAgICAgdmFyIGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdhJyk7CiAgICAgICAgICAgIGEuaHJlZiA9IHVybDsKICAgICAgICAgICAgYS5kb3dubG9hZCA9IGZpbGVuYW1lOwogICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKGEpOwogICAgICAgICAgICBhLmNsaWNrKCk7CiAgICAgICAgICAgIHNldFRpbWVvdXQoZnVuY3Rpb24oKSB7IGRvY3VtZW50LmJvZHkucmVtb3ZlQ2hpbGQoYSk7IFVSTC5yZXZva2VPYmplY3RVUkwodXJsKTsgfSwgMTAwKTsKICAgICAgICB9CiAgICAgICAgCiAgICAgICAgYXN5bmMgZnVuY3Rpb24gYXBpKGVwLCBvcHQpIHsKICAgICAgICAgICAgb3B0ID0gb3B0IHx8IHt9OwogICAgICAgICAgICB2YXIgciA9IGF3YWl0IGZldGNoKCcvYXBpJyArIGVwLCB7CiAgICAgICAgICAgICAgICBtZXRob2Q6IG9wdC5tZXRob2QgfHwgJ0dFVCcsCiAgICAgICAgICAgICAgICBjcmVkZW50aWFsczogJ3NhbWUtb3JpZ2luJywKICAgICAgICAgICAgICAgIGhlYWRlcnM6IHsgJ3gtYXBpLWtleSc6IGFwaUtleSwgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJyB9LAogICAgICAgICAgICAgICAgYm9keTogb3B0LmJvZHkKICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIGlmIChyLnN0YXR1cyA9PT0gNDAxKSB7CiAgICAgICAgICAgICAgICBzaG93TG9naW4oKTsKICAgICAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcign0KHQtdGB0YHQuNGPINC40YHRgtC10LrQu9CwIOKAlCDQstC+0LnQtNC40YLQtSDQt9Cw0L3QvtCy0L4nKTsKICAgICAgICAgICAgfQogICAgICAgICAgICB2YXIgZCA9IGF3YWl0IHIuanNvbigpLmNhdGNoKGZ1bmN0aW9uKCkgeyByZXR1cm4ge21lc3NhZ2U6ICdQYXJzZSBlcnJvcid9OyB9KTsKICAgICAgICAgICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3IoZC5tZXNzYWdlIHx8ICgnRXJyb3IgJyArIHIuc3RhdHVzKSk7CiAgICAgICAgICAgIHJldHVybiBkOwogICAgICAgIH0KICAgICAgICAKICAgICAgICBhc3luYyBmdW5jdGlvbiBsb2FkR2VvKCkgewogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgdmFyIHIgPSBhd2FpdCBmZXRjaCgnL2FwaS9nZW8nLCB7IGNyZWRlbnRpYWxzOiAnc2FtZS1vcmlnaW4nIH0pOwogICAgICAgICAgICAgICAgaWYgKHIub2spIHsKICAgICAgICAgICAgICAgICAgICB2YXIgZCA9IGF3YWl0IHIuanNvbigpLmNhdGNoKGZ1bmN0aW9uKCkgeyByZXR1cm4gbnVsbDsgfSk7CiAgICAgICAgICAgICAgICAgICAgaWYgKGQgJiYgZC5jb3VudHJ5KSByZXR1cm4gZC5jb3VudHJ5OwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9IGNhdGNoKGUpIHt9CiAgICAgICAgICAgIHJldHVybiAnJzsKICAgICAgICB9CgogICAgICAgIGFzeW5jIGZ1bmN0aW9uIGxvYWRTZXJ2ZXIoKSB7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICB2YXIgcyA9IGF3YWl0IGFwaSgnL3NlcnZlcicpOwogICAgICAgICAgICAgICAgdmFyIHJlZ2lvbiA9IChhd2FpdCBsb2FkR2VvKCkpIHx8IHNlcnZlckNvdW50cnkgfHwgcy5yZWdpb24gfHwgJz8nOwogICAgICAgICAgICAgICAgdmFyIGl0ZW1zID0gWwogICAgICAgICAgICAgICAgICAgIFsnQ2xpZW50cycsIHMudG90YWxQZWVycyB8fCAwXSwKICAgICAgICAgICAgICAgICAgICBbJ01heCcsIHMubWF4UGVlcnMgfHwgJz8nXSwKICAgICAgICAgICAgICAgICAgICBbJ0xvY2F0aW9uJywgcmVnaW9uXSwKICAgICAgICAgICAgICAgICAgICBbJ1Byb3RvY29scycsIChzLnByb3RvY29scyB8fCBbXSkuam9pbignLCcpXQogICAgICAgICAgICAgICAgXTsKICAgICAgICAgICAgICAgIGVscy5pbmZvR3JpZC5pbm5lckhUTUwgPSBpdGVtcy5tYXAoZnVuY3Rpb24oaSkgewogICAgICAgICAgICAgICAgICAgIHJldHVybiAnPGRpdiBjbGFzcz0iaW5mby1pdGVtIj48ZGl2IGNsYXNzPSJpbmZvLXZhbHVlIj4nICsgZXNjKGlbMV0pICsgJzwvZGl2PjxkaXYgY2xhc3M9ImluZm8tbGFiZWwiPicgKyBlc2MoaVswXSkgKyAnPC9kaXY+PC9kaXY+JzsKICAgICAgICAgICAgICAgIH0pLmpvaW4oJycpOwogICAgICAgICAgICAgICAgZWxzLnNlcnZlckNhcmQuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgICAgICAgICAgICAgICBlbHMubWFpblNlY3Rpb24uc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgICAgICAgICAgIH0gY2F0Y2goZSkgeyBtc2coJ1NlcnZlciBlcnJvcjogJyArIGUubWVzc2FnZSwgJ2Vycm9yJyk7IH0KICAgICAgICB9CiAgICAgICAgCiAgICAgICAgZnVuY3Rpb24gc3RhdHVzSW5mbyhwKSB7CiAgICAgICAgICAgIGlmIChwLnN0YXR1cyA9PT0gJ2Rpc2FibGVkJykgcmV0dXJuIFsnRGlzYWJsZWQnLCAnYmFkZ2UtZGlzYWJsZWQnXTsKICAgICAgICAgICAgaWYgKHAub25saW5lKSByZXR1cm4gWydPbmxpbmUnLCAnYmFkZ2UtYWN0aXZlJ107CiAgICAgICAgICAgIHJldHVybiBbJ09mZmxpbmUnLCAnYmFkZ2Utb2ZmbGluZSddOwogICAgICAgIH0KCiAgICAgICAgZnVuY3Rpb24gcmVuZGVyQ2xpZW50cyhjbGllbnRzKSB7CiAgICAgICAgICAgIGlmICghY2xpZW50cyB8fCAhY2xpZW50cy5sZW5ndGgpIHsKICAgICAgICAgICAgICAgIGVscy5jbGllbnRzTGlzdC5pbm5lckhUTUwgPSAnPHAgY2xhc3M9InRleHQtbXV0ZWQiPk5vIGNsaWVudHM8L3A+JzsKICAgICAgICAgICAgICAgIGVscy5jbGllbnRzQ291bnQudGV4dENvbnRlbnQgPSAnMCc7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZWxzLmNsaWVudHNDb3VudC50ZXh0Q29udGVudCA9IGNsaWVudHMubGVuZ3RoOwoKICAgICAgICAgICAgY2xpZW50cyA9IGNsaWVudHMuc2xpY2UoKS5zb3J0KGZ1bmN0aW9uKGEsIGIpIHsKICAgICAgICAgICAgICAgIHJldHVybiAoYS51c2VybmFtZSB8fCAnJykubG9jYWxlQ29tcGFyZShiLnVzZXJuYW1lIHx8ICcnKTsKICAgICAgICAgICAgfSk7CgogICAgICAgICAgICB2YXIgZXhpc3RpbmcgPSB7fTsKICAgICAgICAgICAgQXJyYXkuZnJvbShlbHMuY2xpZW50c0xpc3QucXVlcnlTZWxlY3RvckFsbCgnLmNsaWVudC1yb3cnKSkuZm9yRWFjaChmdW5jdGlvbihyb3cpIHsKICAgICAgICAgICAgICAgIGlmIChyb3cuZGF0YXNldC5uYW1lKSBleGlzdGluZ1tyb3cuZGF0YXNldC5uYW1lXSA9IHJvdzsKICAgICAgICAgICAgfSk7CgogICAgICAgICAgICB2YXIgc2VlbiA9IHt9OwogICAgICAgICAgICB2YXIgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgICAgICAgICAgdmFyIG5vdyA9IERhdGUubm93KCk7CgogICAgICAgICAgICBjbGllbnRzLmZvckVhY2goZnVuY3Rpb24oYykgewogICAgICAgICAgICAgICAgdmFyIHAgPSAoYy5wZWVycyAmJiBjLnBlZXJzWzBdKSB8fCB7fTsKICAgICAgICAgICAgICAgIHZhciB0ID0gcC50cmFmZmljIHx8IHt9OwogICAgICAgICAgICAgICAgdmFyIGlwcyA9IChwLmFsbG93ZWRJcHMgfHwgW10pLmpvaW4oJywgJyk7CiAgICAgICAgICAgICAgICB2YXIga2V5ID0gYy51c2VybmFtZTsKICAgICAgICAgICAgICAgIHZhciBlbmFibGVkID0gcC5zdGF0dXMgIT09ICdkaXNhYmxlZCc7CgogICAgICAgICAgICAgICAgdmFyIHByZXYgPSB3aW5kb3cuX3RyYWZmaWNQcmV2IHx8ICh3aW5kb3cuX3RyYWZmaWNQcmV2ID0ge30pOwogICAgICAgICAgICAgICAgdmFyIHJlY3YgPSB0LnJlY2VpdmVkIHx8IDA7CiAgICAgICAgICAgICAgICB2YXIgc2VudCA9IHQuc2VudCB8fCAwOwogICAgICAgICAgICAgICAgdmFyIHJhdGVEb3duID0gMCwgcmF0ZVVwID0gMDsKICAgICAgICAgICAgICAgIGlmIChwcmV2W2tleV0pIHsKICAgICAgICAgICAgICAgICAgICB2YXIgZHQgPSAobm93IC0gcHJldltrZXldLnRzKSAvIDEwMDA7CiAgICAgICAgICAgICAgICAgICAgaWYgKGR0ID4gMCAmJiBkdCA8IDYwKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHJhdGVEb3duID0gTWF0aC5tYXgoMCwgKHJlY3YgLSBwcmV2W2tleV0ucikgLyBkdCk7CiAgICAgICAgICAgICAgICAgICAgICAgIHJhdGVVcCA9IE1hdGgubWF4KDAsIChzZW50IC0gcHJldltrZXldLnMpIC8gZHQpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIHByZXZba2V5XSA9IHsgcjogcmVjdiwgczogc2VudCwgdHM6IG5vdyB9OwoKICAgICAgICAgICAgICAgIGlmIChleGlzdGluZ1trZXldKSB7CiAgICAgICAgICAgICAgICAgICAgc2VlbltrZXldID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICB2YXIgcm93ID0gZXhpc3Rpbmdba2V5XTsKICAgICAgICAgICAgICAgICAgICB2YXIgcmQgPSByb3cucXVlcnlTZWxlY3RvcignLnJhdGUtZG93bicpOwogICAgICAgICAgICAgICAgICAgIGlmIChyZCkgcmQudGV4dENvbnRlbnQgPSAnXHUyMTkzICcgKyBmbXRSYXRlKHJhdGVEb3duKSArICcvcyc7CiAgICAgICAgICAgICAgICAgICAgdmFyIHRkID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy50b3RhbC1kb3duJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHRkKSB0ZC50ZXh0Q29udGVudCA9IGZtdChyZWN2KTsKICAgICAgICAgICAgICAgICAgICB2YXIgcnUgPSByb3cucXVlcnlTZWxlY3RvcignLnJhdGUtdXAnKTsKICAgICAgICAgICAgICAgICAgICBpZiAocnUpIHJ1LnRleHRDb250ZW50ID0gJ1x1MjE5MSAnICsgZm10UmF0ZShyYXRlVXApICsgJy9zJzsKICAgICAgICAgICAgICAgICAgICB2YXIgdHUgPSByb3cucXVlcnlTZWxlY3RvcignLnRvdGFsLXVwJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHR1KSB0dS50ZXh0Q29udGVudCA9IGZtdChzZW50KTsKICAgICAgICAgICAgICAgICAgICB2YXIgc3ViID0gcm93LnF1ZXJ5U2VsZWN0b3IoJy5jbGllbnQtc3ViJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHN1Yikgc3ViLmlubmVySFRNTCA9ICc8Y29kZT4nICsgZXNjKGlwcykgKyAnPC9jb2RlPiBcdTAwYjcgJyArIGVzYyhmbXRUaW1lKHAubGFzdEhhbmRzaGFrZSkpOwogICAgICAgICAgICAgICAgICAgIHZhciBzdyA9IHJvdy5xdWVyeVNlbGVjdG9yKCdpbnB1dFt0eXBlPWNoZWNrYm94XScpOwogICAgICAgICAgICAgICAgICAgIGlmIChzdykgc3cuY2hlY2tlZCA9IGVuYWJsZWQ7CiAgICAgICAgICAgICAgICAgICAgdmFyIGF2YXRhciA9IHJvdy5xdWVyeVNlbGVjdG9yKCcuY2xpZW50LWF2YXRhcicpOwogICAgICAgICAgICAgICAgICAgIGlmIChhdmF0YXIpIHsKICAgICAgICAgICAgICAgICAgICAgICAgdmFyIGhhcyA9IGF2YXRhci5xdWVyeVNlbGVjdG9yKCcub25saW5lLWRvdCcpOwogICAgICAgICAgICAgICAgICAgICAgICB2YXIgc2hvdWxkU2hvdyA9IHAub25saW5lICYmIGVuYWJsZWQ7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChzaG91bGRTaG93ICYmICFoYXMpIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhciBkb3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBkb3QuY2xhc3NOYW1lID0gJ29ubGluZS1kb3QgcHVsc2UnOwogICAgICAgICAgICAgICAgICAgICAgICAgICAgYXZhdGFyLmFwcGVuZENoaWxkKGRvdCk7CiAgICAgICAgICAgICAgICAgICAgICAgIH0gZWxzZSBpZiAoIXNob3VsZFNob3cgJiYgaGFzKSB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBoYXMucmVtb3ZlKCk7CiAgICAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAgIHZhciBwZWVySWQgPSBwLmlkIHx8ICcnOwogICAgICAgICAgICAgICAgICAgIHZhciByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgICAgICAgICByb3cuY2xhc3NOYW1lID0gJ2NsaWVudC1yb3cnOwogICAgICAgICAgICAgICAgICAgIHJvdy5kYXRhc2V0Lm5hbWUgPSBrZXk7CiAgICAgICAgICAgICAgICAgICAgcm93LmRhdGFzZXQucGVlcklkID0gcGVlcklkOwogICAgICAgICAgICAgICAgICAgIHJvdy5pbm5lckhUTUwgPQogICAgICAgICAgICAgICAgICAgICAgICAnPGRpdiBjbGFzcz0iY2xpZW50LWlkIj4nICsKICAgICAgICAgICAgICAgICAgICAgICAgICAgICc8ZGl2IGNsYXNzPSJjbGllbnQtYXZhdGFyIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgd2lkdGg9IjIwIiBoZWlnaHQ9IjIwIiBmaWxsPSJjdXJyZW50Q29sb3IiPjxwYXRoIGQ9Ik0xMiAxMmMyLjIxIDAgNC0xLjc5IDQtNHMtMS43OS00LTQtNC00IDEuNzktNCA0IDEuNzkgNCA0IDR6bTAgMmMtMi42NyAwLTggMS4zNC04IDR2MmgxNnYtMmMwLTIuNjYtNS4zMy00LTgtNHoiLz48L3N2Zz4nICsgKHAub25saW5lICYmIGVuYWJsZWQgPyAnPHNwYW4gY2xhc3M9Im9ubGluZS1kb3QgcHVsc2UiPjwvc3Bhbj4nIDogJycpICsgJzwvZGl2PicgKwogICAgICAgICAgICAgICAgICAgICAgICAgICAgJzxkaXYgY2xhc3M9ImNsaWVudC1tZXRhIj4nICsKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAnPGRpdiBjbGFzcz0iY2xpZW50LW5hbWUiPicgKyBlc2MoYy51c2VybmFtZSkgKyAnPC9kaXY+JyArCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgJzxkaXYgY2xhc3M9ImNsaWVudC1zdWIiPjxjb2RlPicgKyBlc2MoaXBzKSArICc8L2NvZGU+IFx1MDBiNyAnICsgZXNjKGZtdFRpbWUocC5sYXN0SGFuZHNoYWtlKSkgKyAnPC9kaXY+JyArCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAnPC9kaXY+JyArCiAgICAgICAgICAgICAgICAgICAgICAgICc8L2Rpdj4nICsKICAgICAgICAgICAgICAgICAgICAgICAgJzxkaXYgY2xhc3M9InRyYWZmaWMtY2VsbCI+PGRpdiBjbGFzcz0idHJhZmZpYy1yYXRlIHJhdGUtZG93biI+XHUyMTkzICcgKyBlc2MoZm10UmF0ZShyYXRlRG93bikpICsgJy9zPC9kaXY+PGRpdiBjbGFzcz0idHJhZmZpYy10b3RhbCI+JyArIGVzYyhmbXQocmVjdikpICsgJzwvZGl2PjwvZGl2PicgKwogICAgICAgICAgICAgICAgICAgICAgICAnPGRpdiBjbGFzcz0idHJhZmZpYy1jZWxsIj48ZGl2IGNsYXNzPSJ0cmFmZmljLXJhdGUgcmF0ZS11cCB1cCI+XHUyMTkxICcgKyBlc2MoZm10UmF0ZShyYXRlVXApKSArICcvczwvZGl2PjxkaXYgY2xhc3M9InRyYWZmaWMtdG90YWwiPicgKyBlc2MoZm10KHNlbnQpKSArICc8L2Rpdj48L2Rpdj4nICsKICAgICAgICAgICAgICAgICAgICAgICAgJzxsYWJlbCBjbGFzcz0ic3dpdGNoIj48aW5wdXQgdHlwZT0iY2hlY2tib3giIGRhdGEtYWN0PSJ0b2dnbGUiIGRhdGEtbmFtZT0iJyArIGVzYyhrZXkpICsgJyInICsgKGVuYWJsZWQgPyAnIGNoZWNrZWQnIDogJycpICsgJz48c3BhbiBjbGFzcz0ic2xpZGVyLXN3Ij48L3NwYW4+PC9sYWJlbD4nICsKICAgICAgICAgICAgICAgICAgICAgICAgJzxkaXYgY2xhc3M9ImFjdGlvbi1idXR0b25zIj4nICsKICAgICAgICAgICAgICAgICAgICAgICAgICAgICc8YnV0dG9uIGNsYXNzPSJpY29uLWJ0biIgZGF0YS1hY3Q9InFyIiBkYXRhLW5hbWU9IicgKyBlc2Moa2V5KSArICciIHRpdGxlPSJRUiI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxyZWN0IHg9IjMiIHk9IjMiIHdpZHRoPSI3IiBoZWlnaHQ9IjciLz48cmVjdCB4PSIxNCIgeT0iMyIgd2lkdGg9IjciIGhlaWdodD0iNyIvPjxyZWN0IHg9IjMiIHk9IjE0IiB3aWR0aD0iNyIgaGVpZ2h0PSI3Ii8+PHBhdGggZD0iTTE0IDE0aDN2M2gtM3pNMTcgMTdoM3YzaC0zek0xNCAyMGgzIi8+PC9zdmc+PC9idXR0b24+JyArCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iaWNvbi1idG4iIGRhdGEtYWN0PSJjZmciIGRhdGEtbmFtZT0iJyArIGVzYyhrZXkpICsgJyIgdGl0bGU9IkNvbmZpZyI+PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik0xMiAzdjEybTAgMGwtNC00bTQgNGw0LTRNNSAyMWgxNCIvPjwvc3ZnPjwvYnV0dG9uPicgKwogICAgICAgICAgICAgICAgICAgICAgICAgICAgJzxidXR0b24gY2xhc3M9Imljb24tYnRuIGRhbmdlciIgZGF0YS1hY3Q9ImRlbCIgZGF0YS1uYW1lPSInICsgZXNjKGtleSkgKyAnIiB0aXRsZT0iRGVsZXRlIj48c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiI+PHBhdGggZD0iTTMgNmgxOE04IDZWNGEyIDIgMCAwMTItMmg0YTIgMiAwIDAxMiAydjJtMyAwdjE0YTIgMiAwIDAxLTIgMkg3YTIgMiAwIDAxLTItMlY2aDE0eiIvPjwvc3ZnPjwvYnV0dG9uPicgKwogICAgICAgICAgICAgICAgICAgICAgICAnPC9kaXY+JzsKICAgICAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgICAgICAgICAgICAgc2VlbltrZXldID0gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSk7CgogICAgICAgICAgICBPYmplY3Qua2V5cyhleGlzdGluZykuZm9yRWFjaChmdW5jdGlvbihrZXkpIHsKICAgICAgICAgICAgICAgIGlmICghc2VlbltrZXldKSB7CiAgICAgICAgICAgICAgICAgICAgaWYgKHdpbmRvdy5fdHJhZmZpY1ByZXYpIGRlbGV0ZSB3aW5kb3cuX3RyYWZmaWNQcmV2W2tleV07CiAgICAgICAgICAgICAgICAgICAgZXhpc3Rpbmdba2V5XS5yZW1vdmUoKTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSk7CgogICAgICAgICAgICBlbHMuY2xpZW50c0xpc3QuYXBwZW5kQ2hpbGQoZnJhZyk7CgogICAgICAgICAgICBBcnJheS5mcm9tKGVscy5jbGllbnRzTGlzdC5xdWVyeVNlbGVjdG9yQWxsKCdbZGF0YS1hY3RdJykpLmZvckVhY2goZnVuY3Rpb24oYnRuKSB7CiAgICAgICAgICAgICAgICBpZiAoYnRuLmRhdGFzZXQuYm91bmQpIHJldHVybjsKICAgICAgICAgICAgICAgIGJ0bi5kYXRhc2V0LmJvdW5kID0gJzEnOwogICAgICAgICAgICAgICAgdmFyIGFjdCA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtYWN0Jyk7CiAgICAgICAgICAgICAgICB2YXIgbmFtZSA9IGJ0bi5nZXRBdHRyaWJ1dGUoJ2RhdGEtbmFtZScpOwogICAgICAgICAgICAgICAgaWYgKGFjdCA9PT0gJ3RvZ2dsZScpIHsKICAgICAgICAgICAgICAgICAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignY2hhbmdlJywgZnVuY3Rpb24oKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHZhciByb3cgPSBidG4uY2xvc2VzdCgnLmNsaWVudC1yb3cnKTsKICAgICAgICAgICAgICAgICAgICAgICAgdmFyIHBlZXJJZCA9IHJvdyA/IHJvdy5kYXRhc2V0LnBlZXJJZCA6IG5hbWU7CiAgICAgICAgICAgICAgICAgICAgICAgIHRvZ2dsZUNsaWVudChwZWVySWQsIGJ0bi5jaGVja2VkKTsKICAgICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgYnRuLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZnVuY3Rpb24oKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHZhciByb3cgPSBidG4uY2xvc2VzdCgnLmNsaWVudC1yb3cnKTsKICAgICAgICAgICAgICAgICAgICAgICAgdmFyIHBlZXJJZCA9IHJvdyA/IHJvdy5kYXRhc2V0LnBlZXJJZCA6ICcnOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAoYWN0ID09PSAnY2ZnJykgZG93bmxvYWRDb25maWcobmFtZSwgbmFtZSk7CiAgICAgICAgICAgICAgICAgICAgICAgIGVsc2UgaWYgKGFjdCA9PT0gJ3FyJykgc2hvd1FyKG5hbWUsIG5hbWUpOwogICAgICAgICAgICAgICAgICAgICAgICBlbHNlIGlmIChhY3QgPT09ICdkZWwnKSBkZWxldGVDbGllbnQocGVlcklkLCBuYW1lKTsKICAgICAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSk7CiAgICAgICAgfQogICAgICAgIAogICAgICAgIGFzeW5jIGZ1bmN0aW9uIGxvYWRDbGllbnRzKCkgewogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgdmFyIGQgPSBhd2FpdCBhcGkoJy9jbGllbnRzJyk7CiAgICAgICAgICAgICAgICByZW5kZXJDbGllbnRzKGQuaXRlbXMgfHwgW10pOwogICAgICAgICAgICB9IGNhdGNoKGUpIHsgZWxzLmNsaWVudHNMaXN0LmlubmVySFRNTCA9ICc8cCBjbGFzcz0idGV4dC1tdXRlZCI+RXJyb3I6ICcgKyBlc2MoZS5tZXNzYWdlKSArICc8L3A+JzsgfQogICAgICAgIH0KICAgICAgICAKICAgICAgICBhc3luYyBmdW5jdGlvbiBjcmVhdGVDbGllbnQoKSB7CiAgICAgICAgICAgIHZhciBuYW1lID0gZWxzLm5hbWVJbnB1dC52YWx1ZS50cmltKCk7CiAgICAgICAgICAgIGlmICghbmFtZSkgeyBtc2coJ0VudGVyIGNsaWVudCBuYW1lJywgJ2Vycm9yJyk7IHJldHVybjsgfQogICAgICAgICAgICBtc2coJ0NyZWF0aW5nLi4uJywgJ2luZm8nKTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIHZhciBkID0gYXdhaXQgYXBpKCcvY2xpZW50cycsIHsKICAgICAgICAgICAgICAgICAgICBtZXRob2Q6ICdQT1NUJywKICAgICAgICAgICAgICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudE5hbWU6IG5hbWUsIHByb3RvY29sOiAnYW1uZXppYXdnMycgfSkKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgdmFyIHZwblVybCA9IGQuY2xpZW50LmNvbmZpZzsKICAgICAgICAgICAgICAgIC8vIFN0b3JlIGZvciBsYXRlciB1c2UgKHVzZSBuYW1lLCBub3QgaWQg4oCUIGdldFN0b3JlZFZwblVybCBsb29rcyB1cCBieSB1c2VybmFtZSkKICAgICAgICAgICAgICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKCd2cG5fJyArIG5hbWUsIHZwblVybCk7IH0gY2F0Y2goZSkge30KICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgLy8gQXV0by1kb3dubG9hZCAuY29uZgogICAgICAgICAgICAgICAgdnBuVG9Db25mKHZwblVybCkudGhlbihmdW5jdGlvbihjb25mKSB7CiAgICAgICAgICAgICAgICAgICAgdmFyIHNhZmVOYW1lID0gbmFtZS5yZXBsYWNlKC9bXmEtejAtOV8tXS9naSwgJ18nKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgICAgIGRvd25sb2FkVGV4dChjb25mLCAnYW1uZXppYS0nICsgc2FmZU5hbWUgKyAnLmNvbmYnKTsKICAgICAgICAgICAgICAgICAgICBtc2coJ0NsaWVudCBjcmVhdGVkISBDb25maWcgZG93bmxvYWRlZC4nLCAnc3VjY2VzcycpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgIGVscy5uYW1lSW5wdXQudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgIGNsb3NlQWRkTW9kYWwoKTsKICAgICAgICAgICAgICAgIGxvYWRDbGllbnRzKCk7CiAgICAgICAgICAgIH0gY2F0Y2goZSkgeyBtc2coZS5tZXNzYWdlLCAnZXJyb3InKTsgfQogICAgICAgIH0KICAgICAgICAKICAgICAgICBhc3luYyBmdW5jdGlvbiB0b2dnbGVDbGllbnQobmFtZSwgZW5hYmxlZCkgewogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgYXdhaXQgYXBpKCcvY2xpZW50cycsIHsKICAgICAgICAgICAgICAgICAgICBtZXRob2Q6ICdQQVRDSCcsCiAgICAgICAgICAgICAgICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoeyBjbGllbnRJZDogbmFtZSwgcHJvdG9jb2w6ICdhbW5lemlhd2czJywgc3RhdHVzOiBlbmFibGVkID8gJ2FjdGl2ZScgOiAnZGlzYWJsZWQnIH0pCiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSBjYXRjaChlKSB7IG1zZyhlLm1lc3NhZ2UsICdlcnJvcicpOyB9CiAgICAgICAgICAgIGxvYWRDbGllbnRzKCk7CiAgICAgICAgfQoKICAgICAgICBhc3luYyBmdW5jdGlvbiBkZWxldGVDbGllbnQoaWQsIG5hbWUpIHsKICAgICAgICAgICAgaWYgKCFjb25maXJtKCdEZWxldGUgIicgKyBuYW1lICsgJyI/JykpIHJldHVybjsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGF3YWl0IGFwaSgnL2NsaWVudHMnLCB7CiAgICAgICAgICAgICAgICAgICAgbWV0aG9kOiAnREVMRVRFJywKICAgICAgICAgICAgICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudElkOiBpZCwgcHJvdG9jb2w6ICdhbW5lemlhd2czJyB9KQogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICB0cnkgeyBsb2NhbFN0b3JhZ2UucmVtb3ZlSXRlbSgndnBuXycgKyBuYW1lKTsgfSBjYXRjaChlKSB7fQogICAgICAgICAgICAgICAgbXNnKCdEZWxldGVkJywgJ3N1Y2Nlc3MnKTsKICAgICAgICAgICAgICAgIGxvYWRDbGllbnRzKCk7CiAgICAgICAgICAgIH0gY2F0Y2goZSkgeyBtc2coZS5tZXNzYWdlLCAnZXJyb3InKTsgfQogICAgICAgIH0KICAgICAgICAKICAgICAgICBmdW5jdGlvbiBnZXRTdG9yZWRWcG5VcmwobmFtZSkgewogICAgICAgICAgICB0cnkgeyByZXR1cm4gbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ3Zwbl8nICsgbmFtZSk7IH0gY2F0Y2goZSkgeyByZXR1cm4gbnVsbDsgfQogICAgICAgIH0KICAgICAgICAKICAgICAgICBmdW5jdGlvbiBnZXRQZWVySWQobmFtZSkgewogICAgICAgICAgICB2YXIgcm93ID0gZWxzLmNsaWVudHNMaXN0LnF1ZXJ5U2VsZWN0b3IoJy5jbGllbnQtcm93W2RhdGEtbmFtZT0iJyArIG5hbWUgKyAnIl0nKTsKICAgICAgICAgICAgcmV0dXJuIHJvdyA/IHJvdy5kYXRhc2V0LnBlZXJJZCA6IG5hbWU7CiAgICAgICAgfQoKICAgICAgICBmdW5jdGlvbiBkb3dubG9hZENvbmZpZyhpZCwgbmFtZSkgewogICAgICAgICAgICB2YXIgdnBuVXJsID0gZ2V0U3RvcmVkVnBuVXJsKGlkKTsKICAgICAgICAgICAgaWYgKCF2cG5VcmwpIHsKICAgICAgICAgICAgICAgIGlmIChjb25maXJtKCdObyBjb25maWcgc3RvcmVkIGZvciAiJyArIG5hbWUgKyAnIi5cblxuRGVsZXRlIHRoaXMgY2xpZW50IGFuZCBjcmVhdGUgYSBuZXcgb25lIHdpdGggdGhlIHNhbWUgbmFtZT9cblxuVGhpcyB3aWxsIGdlbmVyYXRlIGEgbmV3IGNvbmZpZyB3aXRoIGEgbmV3IGtleS4nKSkgewogICAgICAgICAgICAgICAgICAgIHJlY3JlYXRlQ2xpZW50KGdldFBlZXJJZChuYW1lKSwgbmFtZSk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIHZwblRvQ29uZih2cG5VcmwpLnRoZW4oZnVuY3Rpb24oY29uZikgewogICAgICAgICAgICAgICAgdmFyIHNhZmVOYW1lID0gbmFtZS5yZXBsYWNlKC9bXmEtejAtOV8tXS9naSwgJ18nKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgZG93bmxvYWRUZXh0KGNvbmYsICdhbW5lemlhLScgKyBzYWZlTmFtZSArICcuY29uZicpOwogICAgICAgICAgICAgICAgbXNnKCdEb3dubG9hZGVkOiBhbW5lemlhLScgKyBzYWZlTmFtZSArICcuY29uZicsICdzdWNjZXNzJyk7CiAgICAgICAgICAgIH0pOwogICAgICAgIH0KCiAgICAgICAgZnVuY3Rpb24gc2hvd1FyKGlkLCBuYW1lKSB7CiAgICAgICAgICAgIHZhciB2cG5VcmwgPSBnZXRTdG9yZWRWcG5VcmwoaWQpOwogICAgICAgICAgICBpZiAoIXZwblVybCkgewogICAgICAgICAgICAgICAgaWYgKGNvbmZpcm0oJ05vIHZwbjovLyBVUkwgc3RvcmVkIGZvciAiJyArIG5hbWUgKyAnIi5cblxuRGVsZXRlIHRoaXMgY2xpZW50IGFuZCBjcmVhdGUgYSBuZXcgb25lIHdpdGggdGhlIHNhbWUgbmFtZT8nKSkgewogICAgICAgICAgICAgICAgICAgIHJlY3JlYXRlQ2xpZW50KGdldFBlZXJJZChuYW1lKSwgbmFtZSk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgdmFyIG92ZXJsYXkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgb3ZlcmxheS5zdHlsZS5jc3NUZXh0ID0gJ3Bvc2l0aW9uOmZpeGVkO3RvcDowO2xlZnQ6MDtyaWdodDowO2JvdHRvbTowO2JhY2tncm91bmQ6cmdiYSg1LDYsOSwwLjkpO2JhY2tkcm9wLWZpbHRlcjpibHVyKDZweCk7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO3otaW5kZXg6OTk5OTtvdmVyZmxvdy15OmF1dG87cGFkZGluZzoyMHB4Oyc7CiAgICAgICAgICAgIG92ZXJsYXkuaW5uZXJIVE1MID0gJzxkaXYgc3R5bGU9ImJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE4MGRlZyx2YXIoLS1iZy1lbGV2KSx2YXIoLS1iZy1jYXJkLWJvdHRvbSkpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyLXN0cm9uZyk7Ym9yZGVyLXJhZGl1czoxNnB4O3BhZGRpbmc6MzBweDttYXgtd2lkdGg6OTAlO3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO21heC1oZWlnaHQ6OTV2aDtvdmVyZmxvdy15OmF1dG87Ym94LXNoYWRvdzp2YXIoLS1tb2RhbC1zaGFkb3cpIj4nICsKICAgICAgICAgICAgICAgICc8YnV0dG9uIGlkPSJxci1jbG9zZSIgc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO3RvcDoxMHB4O3JpZ2h0OjE1cHg7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6bm9uZTtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEuNXJlbTtjdXJzb3I6cG9pbnRlciI+JnRpbWVzOzwvYnV0dG9uPicgKwogICAgICAgICAgICAgICAgJzxoMyBzdHlsZT0iY29sb3I6dmFyKC0tdGV4dCk7bWFyZ2luLWJvdHRvbToyMHB4Ij4nICsgZXNjKG5hbWUpICsgJzwvaDM+JyArCiAgICAgICAgICAgICAgICAnPGRpdiBpZD0icXItY2FudmFzIiBzdHlsZT0iYmFja2dyb3VuZDp3aGl0ZTtwYWRkaW5nOjE1cHg7Ym9yZGVyLXJhZGl1czoxMnB4O2Rpc3BsYXk6aW5saW5lLWJsb2NrIj48L2Rpdj4nICsKICAgICAgICAgICAgICAgICc8cCBzdHlsZT0iY29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZTowLjg1cmVtO21hcmdpbi10b3A6MjBweCI+U2NhbiB3aXRoIEFtbmV6aWEgYXBwPC9wPicgKwogICAgICAgICAgICAgICAgJzxkZXRhaWxzIHN0eWxlPSJtYXJnaW4tdG9wOjE2cHg7dGV4dC1hbGlnbjpsZWZ0Ij48c3VtbWFyeSBzdHlsZT0iY29sb3I6I2Y4MDtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MC44NXJlbSI+U2hvdyAuY29uZjwvc3VtbWFyeT48dGV4dGFyZWEgaWQ9InFyLWNvbmYiIHJlYWRvbmx5IHN0eWxlPSJ3aWR0aDoxMDAlO2hlaWdodDoxNjBweDttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtmb250LXNpemU6MC43cmVtO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtiYWNrZ3JvdW5kOnZhcigtLWlucHV0LWJnKTtjb2xvcjp2YXIoLS10ZXh0KTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlci1zdHJvbmcpO2JvcmRlci1yYWRpdXM6OHB4O3dvcmQtYnJlYWs6YnJlYWstYWxsIj48L3RleHRhcmVhPjwvZGV0YWlscz4nICsKICAgICAgICAgICAgICAgICc8L2Rpdj4nOwogICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKG92ZXJsYXkpOwogICAgICAgICAgICB2YXIgYyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdxci1jYW52YXMnKTsKICAgICAgICAgICAgYy5pbm5lckhUTUwgPSAnPHAgc3R5bGU9ImNvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjQwcHgiPkxvYWRpbmcuLi48L3A+JzsKCiAgICAgICAgICAgIHZwblRvQ29uZih2cG5VcmwpLnRoZW4oZnVuY3Rpb24oY29uZikgewogICAgICAgICAgICAgICAgaWYgKGNvbmYgPT09IHZwblVybCkgewogICAgICAgICAgICAgICAgICAgIHZhciBjYyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdxci1jYW52YXMnKTsKICAgICAgICAgICAgICAgICAgICBjYy5pbm5lckhUTUwgPSAnPHAgc3R5bGU9ImNvbG9yOnJlZDtwYWRkaW5nOjIwcHgiPkNhbm5vdCBkZWNvZGUgdnBuOi8vPC9wPic7CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgdmFyIGNmID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3FyLWNvbmYnKTsKICAgICAgICAgICAgICAgIGlmIChjZikgY2YudmFsdWUgPSBjb25mOwogICAgICAgICAgICAgICAgdmFyIGNjID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3FyLWNhbnZhcycpOwogICAgICAgICAgICAgICAgaWYgKHR5cGVvZiBRUkNvZGUgPT09ICd1bmRlZmluZWQnKSB7CiAgICAgICAgICAgICAgICAgICAgY2MuaW5uZXJIVE1MID0gJzxwIHN0eWxlPSJjb2xvcjpyZWQiPlFSIGxpYnJhcnkgZmFpbGVkIHRvIGxvYWQ8L3A+JzsKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBRUkNvZGUudG9DYW52YXMoY29uZiwgeyB3aWR0aDogMzIwLCBtYXJnaW46IDEsIGVycm9yQ29ycmVjdGlvbkxldmVsOiAnTCcsIGNvbG9yOiB7IGRhcms6ICcjMDAwMDAwJywgbGlnaHQ6ICcjZmZmZmZmJyB9IH0sIGZ1bmN0aW9uKGVyciwgY2FudmFzKSB7CiAgICAgICAgICAgICAgICAgICAgaWYgKGVycikgeyBjYy5pbm5lckhUTUwgPSAnPHAgc3R5bGU9ImNvbG9yOnJlZCI+UVIgZXJyb3I8L3A+JzsgcmV0dXJuOyB9CiAgICAgICAgICAgICAgICAgICAgY2MuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgICAgICAgICAgICAgY2MuYXBwZW5kQ2hpbGQoY2FudmFzKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9KTsKCiAgICAgICAgICAgIG92ZXJsYXkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBmdW5jdGlvbihlKSB7CiAgICAgICAgICAgICAgICBpZiAoZS50YXJnZXQgPT09IG92ZXJsYXkgfHwgZS50YXJnZXQuaWQgPT09ICdxci1jbG9zZScpIHsKICAgICAgICAgICAgICAgICAgICBkb2N1bWVudC5ib2R5LnJlbW92ZUNoaWxkKG92ZXJsYXkpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9KTsKICAgICAgICB9CiAgICAgICAgCiAgICAgICAgYXN5bmMgZnVuY3Rpb24gcmVjcmVhdGVDbGllbnQob2xkSWQsIG5hbWUpIHsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIC8vIERlbGV0ZSBvbGQgY2xpZW50CiAgICAgICAgICAgICAgICBhd2FpdCBhcGkoJy9jbGllbnRzJywgewogICAgICAgICAgICAgICAgICAgIG1ldGhvZDogJ0RFTEVURScsCiAgICAgICAgICAgICAgICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoeyBjbGllbnRJZDogb2xkSWQsIHByb3RvY29sOiAnYW1uZXppYXdnMycgfSkKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgLy8gQ3JlYXRlIG5ldyBjbGllbnQgd2l0aCBzYW1lIG5hbWUKICAgICAgICAgICAgICAgIHZhciBkID0gYXdhaXQgYXBpKCcvY2xpZW50cycsIHsKICAgICAgICAgICAgICAgICAgICBtZXRob2Q6ICdQT1NUJywKICAgICAgICAgICAgICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudE5hbWU6IG5hbWUsIHByb3RvY29sOiAnYW1uZXppYXdnMycgfSkKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgdmFyIHZwblVybCA9IGQuY2xpZW50LmNvbmZpZzsKICAgICAgICAgICAgICAgIHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKCd2cG5fJyArIG5hbWUsIHZwblVybCk7IH0gY2F0Y2goZSkge30KICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgdnBuVG9Db25mKHZwblVybCkudGhlbihmdW5jdGlvbihjb25mKSB7CiAgICAgICAgICAgICAgICAgICAgdmFyIHNhZmVOYW1lID0gbmFtZS5yZXBsYWNlKC9bXmEtejAtOV8tXS9naSwgJ18nKS50b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgICAgIGRvd25sb2FkVGV4dChjb25mLCAnYW1uZXppYS0nICsgc2FmZU5hbWUgKyAnLmNvbmYnKTsKICAgICAgICAgICAgICAgICAgICBtc2coJ1JlY3JlYXRlZCEgQ29uZmlnIGRvd25sb2FkZWQuJywgJ3N1Y2Nlc3MnKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICBsb2FkQ2xpZW50cygpOwogICAgICAgICAgICB9IGNhdGNoKGUpIHsgbXNnKGUubWVzc2FnZSwgJ2Vycm9yJyk7IH0KICAgICAgICB9CiAgICAgICAgCiAgICAgICAgZnVuY3Rpb24gdnBuVG9Db25mKHZwbkNvbmZpZykgewogICAgICAgICAgICByZXR1cm4gbmV3IFByb21pc2UoZnVuY3Rpb24ocmVzb2x2ZSkgewogICAgICAgICAgICAgICAgaWYgKHR5cGVvZiB2cG5Db25maWcgIT09ICdzdHJpbmcnIHx8IHZwbkNvbmZpZy5pbmRleE9mKCd2cG46Ly8nKSAhPT0gMCkgewogICAgICAgICAgICAgICAgICAgIHJlc29sdmUodnBuQ29uZmlnIHx8ICcnKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIHZhciBiNjQgPSB2cG5Db25maWcuc3Vic3RyaW5nKDYpLnJlcGxhY2UoLy0vZywgJysnKS5yZXBsYWNlKC9fL2csICcvJyk7CiAgICAgICAgICAgICAgICAgICAgd2hpbGUgKGI2NC5sZW5ndGggJSA0KSBiNjQgKz0gJz0nOwogICAgICAgICAgICAgICAgICAgIHZhciBiaW5hcnlTdHIgPSBhdG9iKGI2NCk7CiAgICAgICAgICAgICAgICAgICAgdmFyIGJ5dGVzID0gbmV3IFVpbnQ4QXJyYXkoYmluYXJ5U3RyLmxlbmd0aCk7CiAgICAgICAgICAgICAgICAgICAgZm9yICh2YXIgaSA9IDA7IGkgPCBiaW5hcnlTdHIubGVuZ3RoOyBpKyspIGJ5dGVzW2ldID0gYmluYXJ5U3RyLmNoYXJDb2RlQXQoaSk7CiAgICAgICAgICAgICAgICAgICAgdmFyIGRlY29tcHJlc3NlZCA9IHBha28uaW5mbGF0ZShieXRlcy5zbGljZSg0KSk7CiAgICAgICAgICAgICAgICAgICAgdmFyIHRleHQgPSBuZXcgVGV4dERlY29kZXIoKS5kZWNvZGUoZGVjb21wcmVzc2VkKTsKICAgICAgICAgICAgICAgICAgICByZXNvbHZlKHBhcnNlQW5kQnVpbGRDb25mKHRleHQpKTsKICAgICAgICAgICAgICAgIH0gY2F0Y2goZSkgewogICAgICAgICAgICAgICAgICAgIGNvbnNvbGUuZXJyb3IoJ3ZwblRvQ29uZiBlcnJvcjonLCBlKTsKICAgICAgICAgICAgICAgICAgICByZXNvbHZlKHZwbkNvbmZpZyk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0pOwogICAgICAgIH0KICAgICAgICAKICAgICAgICBmdW5jdGlvbiBwYXJzZUFuZEJ1aWxkQ29uZih0ZXh0KSB7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICB2YXIganNvbiA9IEpTT04ucGFyc2UodGV4dCk7CiAgICAgICAgICAgICAgICB2YXIgYXdnID0gbnVsbDsKICAgICAgICAgICAgICAgIHZhciBjb250YWluZXJzID0ganNvbi5jb250YWluZXJzIHx8IFtdOwogICAgICAgICAgICAgICAgZm9yICh2YXIgaSA9IDA7IGkgPCBjb250YWluZXJzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgICAgaWYgKGNvbnRhaW5lcnNbaV0uYXdnKSB7IGF3ZyA9IGNvbnRhaW5lcnNbaV0uYXdnOyBicmVhazsgfQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgaWYgKCFhd2cpIHJldHVybiB0ZXh0OwogICAgICAgICAgICAgICAgdmFyIGNmZyA9IGF3Zy5sYXN0X2NvbmZpZzsKICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgY2ZnID09PSAnc3RyaW5nJykgewogICAgICAgICAgICAgICAgICAgIHRyeSB7IGNmZyA9IEpTT04ucGFyc2UoY2ZnKTsgfSBjYXRjaChlKSB7IHJldHVybiB0ZXh0OyB9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBpZiAoIWNmZykgcmV0dXJuIHRleHQ7CiAgICAgICAgICAgICAgICB2YXIgaG9zdCA9IGNmZy5ob3N0TmFtZSB8fCBqc29uLmhvc3ROYW1lIHx8ICcnOwogICAgICAgICAgICAgICAgdmFyIHBvcnQgPSBjZmcucG9ydCB8fCBhd2cucG9ydCB8fCAnJzsKICAgICAgICAgICAgICAgIHZhciByID0gJyc7CiAgICAgICAgICAgICAgICByICs9ICdbSW50ZXJmYWNlXVxuJzsKICAgICAgICAgICAgICAgIHIgKz0gJ0FkZHJlc3MgPSAnICsgKGNmZy5jbGllbnRfaXAgfHwgJycpICsgJy8zMlxuJzsKICAgICAgICAgICAgICAgIHIgKz0gJ0ROUyA9IDEuMS4xLjEsIDEuMC4wLjFcbic7CiAgICAgICAgICAgICAgICByICs9ICdQcml2YXRlS2V5ID0gJyArIChjZmcuY2xpZW50X3ByaXZfa2V5IHx8ICcnKSArICdcbic7CiAgICAgICAgICAgICAgICBpZiAoY2ZnLm10dSkgciArPSAnTVRVID0gJyArIGNmZy5tdHUgKyAnXG4nOwogICAgICAgICAgICAgICAgWydKYycsJ0ptaW4nLCdKbWF4JywnUzEnLCdTMicsJ1MzJywnUzQnLCdIMScsJ0gyJywnSDMnLCdINCcsJ0kxJywnSTInLCdJMycsJ0k0JywnSTUnXS5mb3JFYWNoKGZ1bmN0aW9uKGspIHsKICAgICAgICAgICAgICAgICAgICBpZiAoY2ZnW2tdICE9PSB1bmRlZmluZWQgJiYgY2ZnW2tdICE9PSAnJykgciArPSBrICsgJyA9ICcgKyBjZmdba10gKyAnXG4nOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICBpZiAoY2ZnLkhlYWRlclByb3RlY3Rpb25LZXkpIHIgKz0gJ0hlYWRlclByb3RlY3Rpb25LZXkgPSAnICsgY2ZnLkhlYWRlclByb3RlY3Rpb25LZXkgKyAnXG4nOwogICAgICAgICAgICAgICAgWydDb250ZW50UGFkZGluZ0FkZGl0aW9uJywnUmVrZXlBZnRlclRpbWUnLCdSZWtleVRpbWVvdXQnLCdSZWplY3RBZnRlclRpbWUnLCdLZWVwYWxpdmVUaW1lb3V0JywnTWF4SGFuZHNoYWtlQXR0ZW1wdHMnLCdSYW5kb21UcmFpbGVycycsJ0Rpc2FibGVDb29raWVzJ10uZm9yRWFjaChmdW5jdGlvbihrKSB7CiAgICAgICAgICAgICAgICAgICAgaWYgKGNmZ1trXSAhPT0gdW5kZWZpbmVkICYmIGNmZ1trXSAhPT0gJycpIHIgKz0gayArICcgPSAnICsgY2ZnW2tdICsgJ1xuJzsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgciArPSAnXG5bUGVlcl1cbic7CiAgICAgICAgICAgICAgICByICs9ICdQdWJsaWNLZXkgPSAnICsgKGNmZy5zZXJ2ZXJfcHViX2tleSB8fCAnJykgKyAnXG4nOwogICAgICAgICAgICAgICAgciArPSAnUHJlc2hhcmVkS2V5ID0gJyArIChjZmcucHNrX2tleSB8fCAnJykgKyAnXG4nOwogICAgICAgICAgICAgICAgdmFyIGlwcyA9IEFycmF5LmlzQXJyYXkoY2ZnLmFsbG93ZWRfaXBzKSA/IGNmZy5hbGxvd2VkX2lwcy5qb2luKCcsICcpIDogKGNmZy5hbGxvd2VkX2lwcyB8fCAnJyk7CiAgICAgICAgICAgICAgICByICs9ICdBbGxvd2VkSVBzID0gJyArIChpcHMgfHwgJzAuMC4wLjAvMCwgOjovMCcpICsgJ1xuJzsKICAgICAgICAgICAgICAgIHIgKz0gJ0VuZHBvaW50ID0gJyArIGhvc3QgKyAnOicgKyBwb3J0ICsgJ1xuJzsKICAgICAgICAgICAgICAgIHZhciBrYSA9IGNmZy5wZXJzaXN0ZW50X2tlZXBfYWxpdmU7CiAgICAgICAgICAgICAgICBpZiAoIWthIHx8ICEvXlxkKyQvLnRlc3QoU3RyaW5nKGthKSkpIGthID0gJzI1JzsKICAgICAgICAgICAgICAgIHIgKz0gJ1BlcnNpc3RlbnRLZWVwYWxpdmUgPSAnICsga2EgKyAnXG4nOwogICAgICAgICAgICAgICAgcmV0dXJuIHI7CiAgICAgICAgICAgIH0gY2F0Y2goZSkgewogICAgICAgICAgICAgICAgcmV0dXJuIHRleHQ7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgCiAgICAgICAgLy8gQWRkIGNsaWVudDog0LzQvtC00LDQu9GM0L3QvtC1INC+0LrQvdC+INCyINGB0YLQuNC70LUgd2ctZWFzeQogICAgICAgIHZhciBhZGRNb2RhbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhZGQtbW9kYWwtb3ZlcmxheScpOwogICAgICAgIHZhciBidG5BZGRTdWJtaXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWFkZC1zdWJtaXQnKTsKICAgICAgICBmdW5jdGlvbiBvcGVuQWRkTW9kYWwoKSB7IGFkZE1vZGFsLnN0eWxlLmRpc3BsYXkgPSAnZmxleCc7IGVscy5uYW1lSW5wdXQuZm9jdXMoKTsgfQogICAgICAgIGZ1bmN0aW9uIGNsb3NlQWRkTW9kYWwoKSB7IGFkZE1vZGFsLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7IH0KICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWFkZCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgb3BlbkFkZE1vZGFsKTsKICAgICAgICBidG5BZGRTdWJtaXQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBjcmVhdGVDbGllbnQpOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tYWRkLWNhbmNlbCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgY2xvc2VBZGRNb2RhbCk7CiAgICAgICAgYWRkTW9kYWwuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBmdW5jdGlvbihlKSB7IGlmIChlLnRhcmdldCA9PT0gYWRkTW9kYWwpIGNsb3NlQWRkTW9kYWwoKTsgfSk7CiAgICAgICAgZWxzLm5hbWVJbnB1dC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZnVuY3Rpb24oZSkgeyBpZiAoZS5rZXkgPT09ICdFbnRlcicpIGNyZWF0ZUNsaWVudCgpOyB9KTsKCiAgICAgICAgLy8gLS0tINCQ0LLRgtC+0YDQuNC30LDRhtC40Y8gKNGE0L7RgNC80LAg0LLRhdC+0LTQsCDQsiDQv9Cw0L3QtdC70LgsIHNlc3Npb24tY29va2llKSAtLS0KICAgICAgICB2YXIgbG9naW5PdmVybGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luLW92ZXJsYXknKTsKICAgICAgICB2YXIgbG9naW5Vc2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luLXVzZXInKTsKICAgICAgICB2YXIgbG9naW5QYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luLXBhc3MnKTsKICAgICAgICB2YXIgbG9naW5FcnJvciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2dpbi1lcnJvcicpOwogICAgICAgIHZhciBidG5Mb2dvdXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvZ291dCcpOwoKICAgICAgICBmdW5jdGlvbiBzaG93TG9naW4oKSB7CiAgICAgICAgICAgIGxvZ2dlZEluID0gZmFsc2U7CiAgICAgICAgICAgIGxvZ2luT3ZlcmxheS5zdHlsZS5kaXNwbGF5ID0gJ2ZsZXgnOwogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VydmVyLWNhcmQnKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbWFpbi1zZWN0aW9uJykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgYnRuTG9nb3V0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIGxvZ2luRXJyb3IudGV4dENvbnRlbnQgPSAnJzsKICAgICAgICB9CgogICAgICAgIGZ1bmN0aW9uIGhpZGVMb2dpbigpIHsKICAgICAgICAgICAgbG9nZ2VkSW4gPSB0cnVlOwogICAgICAgICAgICBsb2dpbk92ZXJsYXkuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgYnRuTG9nb3V0LnN0eWxlLmRpc3BsYXkgPSAnaW5saW5lLWJsb2NrJzsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlcnZlci1jYXJkJykuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtYWluLXNlY3Rpb24nKS5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICAgICAgICB9CgogICAgICAgIGFzeW5jIGZ1bmN0aW9uIGRvTG9naW4oKSB7CiAgICAgICAgICAgIHZhciB1c2VyID0gbG9naW5Vc2VyLnZhbHVlOwogICAgICAgICAgICB2YXIgcGFzcyA9IGxvZ2luUGFzcy52YWx1ZTsKICAgICAgICAgICAgaWYgKCF1c2VyKSB7IGxvZ2luRXJyb3IudGV4dENvbnRlbnQgPSAn0JLQstC10LTQuNGC0LUg0LvQvtCz0LjQvSc7IHJldHVybjsgfQogICAgICAgICAgICBpZiAoIXBhc3MpIHsgbG9naW5FcnJvci50ZXh0Q29udGVudCA9ICfQktCy0LXQtNC40YLQtSDQv9Cw0YDQvtC70YwnOyByZXR1cm47IH0KICAgICAgICAgICAgbG9naW5FcnJvci50ZXh0Q29udGVudCA9ICcnOwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgdmFyIHIgPSBhd2FpdCBmZXRjaCgnL2FwaS9hdXRoL2xvZ2luJywgewogICAgICAgICAgICAgICAgICAgIG1ldGhvZDogJ1BPU1QnLAogICAgICAgICAgICAgICAgICAgIGNyZWRlbnRpYWxzOiAnc2FtZS1vcmlnaW4nLAogICAgICAgICAgICAgICAgICAgIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJyB9LAogICAgICAgICAgICAgICAgICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHsgdXNlcjogdXNlciwgcGFzc3dvcmQ6IHBhc3MgfSkKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAgaWYgKCFyLm9rKSB7IGxvZ2luRXJyb3IudGV4dENvbnRlbnQgPSAn0J3QtdCy0LXRgNC90YvQuSDQu9C+0LPQuNC9INC40LvQuCDQv9Cw0YDQvtC70YwnOyBsb2dpblBhc3MudmFsdWUgPSAnJzsgcmV0dXJuOyB9CiAgICAgICAgICAgICAgICBsb2dpblVzZXIudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgIGxvZ2luUGFzcy52YWx1ZSA9ICcnOwogICAgICAgICAgICAgICAgaGlkZUxvZ2luKCk7CiAgICAgICAgICAgICAgICBsb2FkU2VydmVyKCk7CiAgICAgICAgICAgICAgICBsb2FkQ2xpZW50cygpOwogICAgICAgICAgICB9IGNhdGNoKGUpIHsKICAgICAgICAgICAgICAgIGxvZ2luRXJyb3IudGV4dENvbnRlbnQgPSAn0J7RiNC40LHQutCwINGB0L7QtdC00LjQvdC10L3QuNGPJzsKICAgICAgICAgICAgfQogICAgICAgIH0KCiAgICAgICAgYXN5bmMgZnVuY3Rpb24gZG9Mb2dvdXQoKSB7CiAgICAgICAgICAgIHRyeSB7IGF3YWl0IGZldGNoKCcvYXBpL2F1dGgvbG9nb3V0JywgeyBtZXRob2Q6ICdQT1NUJywgY3JlZGVudGlhbHM6ICdzYW1lLW9yaWdpbicgfSk7IH0gY2F0Y2goZSkge30KICAgICAgICAgICAgc2hvd0xvZ2luKCk7CiAgICAgICAgfQoKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvZ2luJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBkb0xvZ2luKTsKICAgICAgICBsb2dpblVzZXIuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGZ1bmN0aW9uKGUpIHsgaWYgKGUua2V5ID09PSAnRW50ZXInKSBsb2dpblBhc3MuZm9jdXMoKTsgfSk7CiAgICAgICAgbG9naW5QYXNzLmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBmdW5jdGlvbihlKSB7IGlmIChlLmtleSA9PT0gJ0VudGVyJykgZG9Mb2dpbigpOyB9KTsKICAgICAgICBidG5Mb2dvdXQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBkb0xvZ291dCk7CgogICAgICAgIC8vIEluaXRpYWwgbG9hZDog0L/RgNC+0LLQtdGA0Y/QtdC8INGB0LXRgdGB0LjRjgogICAgICAgIChhc3luYyBmdW5jdGlvbiBpbml0KCkgewogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgdmFyIHIgPSBhd2FpdCBmZXRjaCgnL2FwaS9hdXRoL3N0YXR1cycsIHsgY3JlZGVudGlhbHM6ICdzYW1lLW9yaWdpbicgfSk7CiAgICAgICAgICAgICAgICBpZiAoci5vaykgewogICAgICAgICAgICAgICAgICAgIGhpZGVMb2dpbigpOwogICAgICAgICAgICAgICAgICAgIGxvYWRTZXJ2ZXIoKTsKICAgICAgICAgICAgICAgICAgICBsb2FkQ2xpZW50cygpOwogICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICBzaG93TG9naW4oKTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfSBjYXRjaChlKSB7CiAgICAgICAgICAgICAgICBzaG93TG9naW4oKTsKICAgICAgICAgICAgfQogICAgICAgIH0pKCk7CgogICAgICAgIC8vIEF1dG8tcmVmcmVzaCAo0YLQvtC70YzQutC+INC/0YDQuCDQsNC60YLQuNCy0L3QvtC5INGB0LXRgdGB0LjQuCkKICAgICAgICBzZXRJbnRlcnZhbChmdW5jdGlvbigpIHsKICAgICAgICAgICAgaWYgKGxvZ2dlZEluKSBsb2FkQ2xpZW50cygpOwogICAgICAgIH0sIDIwMDApOwogICAgfSkoKTsKICAgIDwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K"
if [ -n "$PANEL_B64" ]; then
    echo "$PANEL_B64" | tr -d '\n' | base64 -d > /var/www/html/index.html
    sed -i "s|PLACEHOLDER|${API_KEY}|g" /var/www/html/index.html
    echo "  Панель: $(wc -c < /var/www/html/index.html) байт (из скрипта)"
else
    if [ -f "${SCRIPT_DIR}/index.html" ]; then
        cp "${SCRIPT_DIR}/index.html" /var/www/html/index.html
        sed -i "s|PLACEHOLDER|${API_KEY}|g" /var/www/html/index.html
        echo "  Панель: $(wc -c < /var/www/html/index.html) байт (из файла рядом)"
    else
        echo "  ОШИБКА: панель не вшита в скрипт и index.html не найден рядом"
        exit 1
    fi
fi

if [ -n "$SERVER_COUNTRY" ]; then
    sed -i "s|__SERVER_COUNTRY__|${SERVER_COUNTRY}|g" /var/www/html/index.html
fi

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/sites-available/panel << 'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 10M;

    root /var/www/html;
    index index.html;

    # Форма входа в панели (не браузерный Basic Auth)
    # Auth endpoints: доступны без сессии
    location = /api/auth/login {
        proxy_pass http://127.0.0.1:4002/login;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
    location = /api/auth/logout {
        proxy_pass http://127.0.0.1:4002/logout;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
    location = /api/auth/status {
        proxy_pass http://127.0.0.1:4002/status;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
    # Локация сервера (страна по IP) - за сессией, как остальной API
    location = /api/geo {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:4002/geo;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    # Остальной API - только с валидной сессией
    location /api/ {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:4001/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Внутренняя проверка сессии (для auth_request)
    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:4002/_auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Cookie $http_cookie;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/panel /etc/nginx/sites-enabled/panel

nginx -t
systemctl enable nginx
systemctl restart nginx

# --- 10. Тест ---
echo ""
echo "=========================================="
echo "  Тест..."
echo "=========================================="
sleep 2

echo ""
echo "API direct:"
curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://127.0.0.1:4001/clients
echo ""
echo "API /clients (с ключом):"
curl -s http://127.0.0.1:4001/clients -H "x-api-key: ${API_KEY}" | head -c 300
echo ""
echo ""
echo "Через nginx:"
curl -s -o /dev/null -w "  Панель (страница): HTTP %{http_code}\n" http://127.0.0.1/
curl -s -o /dev/null -w "  /api/server без сессии (ожидается 401): HTTP %{http_code}\n" http://127.0.0.1/api/server
LOGIN_JSON="$(node -e 'const u=process.argv[1],p=process.argv[2];process.stdout.write(JSON.stringify({user:u,password:p}))' "$PANEL_USER" "$PANEL_PASS")"
curl -s -c /tmp/panel.sess -o /dev/null -w "  Вход по паролю (ожидается 200): HTTP %{http_code}\n" -X POST -H 'Content-Type: application/json' --data-binary "$LOGIN_JSON" http://127.0.0.1/api/auth/login
curl -s -b /tmp/panel.sess -o /dev/null -w "  /api/server с сессией: HTTP %{http_code}\n" http://127.0.0.1/api/server
rm -f /tmp/panel.sess

# --- 11. UFW ---
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp 2>/dev/null || true
fi

# --- Финал ---
echo ""
echo "=========================================="
echo "  Установка завершена!"
echo "=========================================="
echo ""
echo "  Панель:           http://${SERVER_IP}/"
echo "  Логин:            ${PANEL_USER}"
echo "  Пароль:           ${PANEL_PASS}   <-- сохраните его!"
echo "  Вход:             форма внутри панели (не браузерный Basic Auth);"
echo "                    пароль запрашивается заново при каждом новом открытии браузера"
echo "  API:              http://${SERVER_IP}/api/server"
echo "  API ключ:         ${API_KEY}      (для /api используется сессия панели)"
echo ""
echo "  Сервисы:"
docker ps --format "  {{.Names}}: {{.Status}}" | grep amnezia
systemctl is-active nginx 2>/dev/null | xargs -I{} echo "  nginx: {}"
systemctl is-active amnezia-api 2>/dev/null | xargs -I{} echo "  amnezia-api: {}"
echo ""
echo "  Лог API:  journalctl -u amnezia-api -f"
echo ""
