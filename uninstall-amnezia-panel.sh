#!/bin/bash
###############################################################################
# Amnezia VPN Panel - Удаление
# Останавливает и удаляет панель + API + настройки панели в nginx.
# НЕ ТРОГАЕТ контейнер amnezia-awg (AmneziaVPN) и НЕ удаляет сам nginx:
# на сервере может стоять ispmanager со своими сайтами.
###############################################################################

set -e

echo "=========================================="
echo "  Amnezia VPN Panel Uninstaller"
echo "=========================================="

# --- 1. Остановка и удаление systemd сервисов ---
echo ""
echo "[1/5] Остановка amnezia-api и panel-auth..."
for svc in amnezia-api amnezia-panel-auth; do
    if systemctl list-unit-files | grep -q "$svc"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc.service"
        systemctl daemon-reload
        echo "  $svc остановлен и удалён из автозагрузки"
    else
        echo "  $svc не установлен"
    fi
done

# --- 2. Удаление файлов API и auth-сервиса ---
echo ""
echo "[2/5] Удаление файлов amnezia-api и panel-auth..."
rm -rf /opt/amnezia-api
rm -rf /opt/amnezia/panel-auth
rm -f /etc/amnezia-panel/auth.json
rmdir /etc/amnezia-panel 2>/dev/null || true
rm -f /usr/local/bin/amnezia-api-start.sh
rm -f /var/log/amnezia-api.log
echo "  /opt/amnezia-api и /opt/amnezia/panel-auth удалены"

# --- 3. Удаление панели (index.html) ---
echo ""
echo "[3/5] Удаление веб-панели..."
rm -f /var/www/html/index.html
# каталог /var/www/html оставляем: его может использовать ispmanager/сайты
echo "  /var/www/html/index.html удалён"

# --- 4. Отключение панели из nginx (сам nginx и /etc/nginx НЕ трогаем) ---
echo ""
echo "[4/5] Удаление настроек панели из nginx..."
rm -f /etc/nginx/sites-available/panel
rm -f /etc/nginx/sites-enabled/panel
rm -f /etc/nginx/htpasswd/panel
rm -f /var/www/html/index.html
if command -v nginx &> /dev/null; then
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        echo "  nginx перезагружен (сам nginx не удалялся)"
    else
        echo "  ВНИМАНИЕ: nginx -t не прошёл — конфиг nginx не перезагружен"
    fi
else
    echo "  nginx не установлен"
fi

# --- 5. Конфиг awg (опционально) ---
echo ""
echo "[5/5] Конфигурация AmneziaVPN..."
if [ -d /opt/amnezia/awg ]; then
    read -p "  Удалить скопированный /opt/amnezia/awg? (y/N): " rm_awg
    if [ "$rm_awg" = "y" ] || [ "$rm_awg" = "Y" ]; then
        rm -rf /opt/amnezia
        echo "  /opt/amnezia удалён"
    else
        echo "  /opt/amnezia оставлен"
    fi
else
    echo "  /opt/amnezia не найден"
fi

# --- Проверка ---
echo ""
echo "=========================================="
echo "  Готово!"
echo "=========================================="
echo ""
echo "  Проверка:"
echo "  -----------"
echo -n "  amnezia-api: "
if [ -d /opt/amnezia-api ]; then echo "ОСТАЛСЯ"; else echo "удалён"; fi
echo -n "  panel-auth: "
if systemctl list-unit-files | grep -q amnezia-panel-auth; then echo "ОСТАЛСЯ"; else echo "удалён"; fi
echo -n "  панель (index.html): "
if [ -f /var/www/html/index.html ]; then echo "ОСТАЛСЯ"; else echo "удалён"; fi
echo -n "  настройки панели в nginx: "
if [ -f /etc/nginx/sites-enabled/panel ]; then echo "ОСТАЛСЯ"; else echo "удалены"; fi
echo -n "  nginx: "
if command -v nginx &> /dev/null; then echo "на месте (не тронут)"; else echo "ОТСУТСТВУЕТ"; fi
echo -n "  amnezia-awg2 (AmneziaVPN): "
if docker ps -a --format '{{.Names}}' | grep -q 'amnezia-awg'; then
    echo "работает (не тронут)"
else
    echo "НЕ НАЙДЕН"
fi
echo ""
