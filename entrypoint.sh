#!/bin/sh
set -e

# Динамически получаем реальный шлюз Docker-сети
REAL_GW=$(ip route show default | awk '/default via/ {print $3}')

# Обрабатываем local-хост прокси
if [ "$PROXY_IP" = "127.0.0.1" ] || [ "$PROXY_IP" = "localhost" ]; then
    echo "Обнаружен локальный прокси на хосте. Перенаправляем на шлюз Docker: $REAL_GW"
    PROXY_IP="$REAL_GW"
fi

# Резолвим IP-адрес, если PROXY_IP является доменным именем
RESOLVED_IP=""
if echo "$PROXY_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    RESOLVED_IP="$PROXY_IP"
else
    echo "Резолвим доменное имя прокси: $PROXY_IP..."
    RESOLVED_IP=$(getent hosts "$PROXY_IP" | awk '{print $1; exit}')
    if [ -z "$RESOLVED_IP" ]; then
        echo "Ошибка: Не удалось разрешить доменное имя $PROXY_IP"
        exit 1
    fi
    echo "Домен резолвится в: $RESOLVED_IP"
fi

if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    PROXY_URL="${PROXY_TYPE}://${PROXY_USER}:${PROXY_PASS}@${RESOLVED_IP}:${PROXY_PORT}"
else
    PROXY_URL="${PROXY_TYPE}://${RESOLVED_IP}:${PROXY_PORT}"
fi

echo "=== Докер-шлюз успешно запущен ==="
echo "Трафик проксируется через: $RESOLVED_IP:$PROXY_PORT"

# Создаем TUN интерфейс
ip tuntap add dev tun0 mode tun
ip link set dev tun0 up

# А трафик до самого прокси-сервера пускаем в обход, чтобы не было бесконечной петли
# Но только если прокси-сервер не находится на самом шлюзе (для локальных прокси)
if [ "$RESOLVED_IP" != "$REAL_GW" ]; then
    ip route add "$RESOLVED_IP" via "$REAL_GW" dev eth0
fi

# Удаляем дефолтный маршрут Docker через eth0 и перенаправляем всё в tun0
ip route del default
ip route add default dev tun0

# Настраиваем NAT
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# Явно разрешаем прохождение чужих пакетов (от Firejail) через шлюз
iptables -P FORWARD ACCEPT
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Запускаем tun2socks
exec tun2socks -device tun0 -proxy "$PROXY_URL" -loglevel info