#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "======================================================="
    echo "ОШИБКА: Этот скрипт необходимо запускать от админа!"
    echo "Пожалуйста, используйте: sudo ./install.sh"
    echo "======================================================="
    exit 1
fi

if [ ! -f .env ]; then
    echo "Ошибка: Создайте файл .env перед запуском."
    exit 1
fi

# Безопасный импорт переменных из .env
set -a
source .env
set +a

chmod +x entrypoint.sh

echo "=== 1. Установка зависимостей на хосте ==="
apt update && apt install -y firejail unzip curl sed
sed -i 's/restricted-network yes/restricted-network no/g' /etc/firejail/firejail.config

echo "=== 2. Подготовка бинарника tun2socks ==="
if [ ! -f tun2socks ]; then
    echo "Запрашиваем актуальный релиз через GitHub API..."
    LATEST_TAG=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$LATEST_TAG" ] && LATEST_TAG="v2.6.0"
    
    DOWNLOAD_URL="https://github.com/xjasonlyu/tun2socks/releases/download/${LATEST_TAG}/tun2socks-linux-amd64.zip"
    curl -f -L -o tun2socks.zip "$DOWNLOAD_URL"
    unzip -o tun2socks.zip "tun2socks-linux-amd64" -d ./
    mv tun2socks-linux-amd64 tun2socks
    rm -f tun2socks.zip
fi

echo "=== 3. Создание базовой сети Docker ==="
docker network create --subnet=172.25.0.0/24 --gateway=172.25.0.1 proxynet || true

echo "=== 4. Запуск шлюза через Docker Compose ==="
docker compose down 2>/dev/null || true
docker compose up -d --build

echo "=== 5. Очистка временных файлов на хосте ==="
rm -f tun2socks tun2socks.zip tun2socks.tar.gz

echo "=== 6. Создание команды proxify ==="
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

add_proxify() {
    local file="$1"
    if [ -f "$file" ]; then
        # Удаляем старую функцию, если она была записана ранее
        sed -i '/proxify()/,/^}/d' "$file" 2>/dev/null || true
        
        # Записываем функцию с правильным экранированием.
        # EOF без кавычек, чтобы $BRIDGE_INTERFACE и другие переменные установки
        # не хардкодились, а вычислялись динамически во время работы proxify.
        cat << EOF >> "$file"
proxify() {
    local GW_IP=\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' local-proxy-gw 2>/dev/null)
    if [ -z "\$GW_IP" ]; then
        echo "Ошибка: Контейнер шлюза не запущен!"
        return 1
    fi
    
    local NET_ID=\$(docker network inspect proxynet -f '{{.Id}}' 2>/dev/null | cut -c1-12)
    if [ -z "\$NET_ID" ]; then
        echo "Ошибка: Сеть proxynet не найдена!"
        return 1
    fi
    local RUNTIME_BRIDGE="br-\${NET_ID}"
    
    # Запуск в изолированной сети ядра, но с полным доступом к файловой системе и Docker сокету
    firejail --noprofile --allow-debuggers --noblacklist=/var/lib/docker --noblacklist=/var/run/docker.sock --net="\${RUNTIME_BRIDGE}" --defaultgw="\$GW_IP" --dns=8.8.8.8 "\$@"
}
EOF
        chown "$REAL_USER":"$REAL_USER" "$file"
    fi
}

add_proxify "$REAL_HOME/.bashrc"
add_proxify "$REAL_HOME/.zshrc"

echo "======================================================="
echo "Установка успешно завершена! Архитектура исправлена."
echo "Примените изменения: source ~/.bashrc"
echo "======================================================="