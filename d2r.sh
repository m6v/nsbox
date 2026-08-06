#!/bin/bash
set -e

# Автоматический перезапуск от имени root/sudo, если скрипт запущен от обычного пользователя
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

usage() {
    echo "Использование: $(basename "$0") <IMAGE[:TAG]> <TARGET_DIR>"
    echo "Пример: $(basename "$0") alpine /opt/alpine"
    exit 1
}

if [ "$#" -lt 2 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

RAW_IMAGE="$1"
TARGET_DIR="$2"

# Временное уменьшение MTU для предотвращения зависаний при скачивании
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -n "$IFACE" ]; then
    OLD_MTU=$(ip link show "$IFACE" | grep -oP 'mtu \K\d+' 2>/dev/null || echo 1500)
    
    # Автоматический возврат прежнего MTU при выходе из скрипта или ошибке
    trap 'ip link set dev "$IFACE" mtu "$OLD_MTU" 2>/dev/null || true; rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT
    
    ip link set dev "$IFACE" mtu 1350 2>/dev/null || true
fi

if [[ "$RAW_IMAGE" == *:* ]]; then
    IMAGE_NAME="${RAW_IMAGE%%:*}"
    TAG="${RAW_IMAGE#*:}"
else
    IMAGE_NAME="$RAW_IMAGE"
    TAG="latest"
fi

if [[ "$IMAGE_NAME" != */* ]]; then
    REPO_PATH="library/${IMAGE_NAME}"
else
    REPO_PATH="${IMAGE_NAME}"
fi

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="arm" ;;
    *)       ARCH="$HOST_ARCH" ;;
esac

echo "Скачивание образа: ${REPO_PATH}:${TAG} (${ARCH})"
echo "Целевой каталог:   ${TARGET_DIR}"

parse_json() {
    if command -v python3 &>/dev/null; then
        python3 -c "import sys, json; data=json.load(sys.stdin); $1" 2>/dev/null
    else
        eval "$2"
    fi
}

echo "Получение токена авторизации Docker Hub..."
AUTH_JSON=$(curl -4 -s --connect-timeout 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO_PATH}:pull")
TOKEN=$(echo "$AUTH_JSON" | parse_json "print(data.get('token',''))" "grep -o '\"token\":\"[^\"]*' | cut -d'\"' -f4")

if [ -z "$TOKEN" ]; then
    echo "Ошибка: Не удалось получить токен."
    exit 1
fi

echo "Запрос манифеста..."
MANIFEST=$(curl -4 -s --connect-timeout 10 -H "Authorization: Bearer $TOKEN" \
     -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json" \
     "https://registry-1.docker.io/v2/${REPO_PATH}/manifests/${TAG}")

MEDIA_TYPE=$(echo "$MANIFEST" | parse_json "print(data.get('mediaType',''))" "")

if [[ "$MEDIA_TYPE" == *"manifest.list"* ]] || [[ "$MEDIA_TYPE" == *"image.index"* ]]; then
    echo "Поиск манифеста для архитектуры $ARCH..."
    ARCH_DIGEST=$(echo "$MANIFEST" | parse_json "
for m in data.get('manifests', []):
    if m.get('platform', {}).get('architecture') == '$ARCH':
        print(m.get('digest'))
        break
")
    
    if [ -z "$ARCH_DIGEST" ]; then
        echo "Ошибка: Не найден манифест для архитектуры $ARCH."
        exit 1
    fi

    MANIFEST=$(curl -4 -s --connect-timeout 10 -H "Authorization: Bearer $TOKEN" \
         -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
         "https://registry-1.docker.io/v2/${REPO_PATH}/manifests/${ARCH_DIGEST}")
fi

LAYERS=$(echo "$MANIFEST" | parse_json "print('\n'.join([l['digest'] for l in data.get('layers', [])]))" "grep -o '\"digest\":\"[^\"]*' | cut -d'\"' -f4")

if [ -z "$LAYERS" ]; then
    echo "Ошибка: Не удалось извлечь слои образа."
    exit 1
fi

mkdir -p "$TARGET_DIR"
TMP_DIR=$(mktemp -d)

echo "Скачивание и распаковка слоев..."
for digest in $LAYERS; do
    echo "Скачивание слоя ${digest:0:19}..."
    
    BLOB_HEADERS=$(curl -4 -s -I --connect-timeout 10 -H "Authorization: Bearer $TOKEN" \
         "https://registry-1.docker.io/v2/${REPO_PATH}/blobs/${digest}")
    
    LOCATION=$(echo "$BLOB_HEADERS" | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
    
    if [ -n "$LOCATION" ]; then
        curl -4 --http1.1 -L --connect-timeout 15 --max-time 120 "$LOCATION" -o "$TMP_DIR/layer.tar.gz"
    else
        curl -4 --http1.1 -L --connect-timeout 15 --max-time 120 -H "Authorization: Bearer $TOKEN" \
             "https://registry-1.docker.io/v2/${REPO_PATH}/blobs/${digest}" -o "$TMP_DIR/layer.tar.gz"
    fi
    
    tar -xzf "$TMP_DIR/layer.tar.gz" -C "$TARGET_DIR"
done

echo "Успешно: Файловая система распакована в $TARGET_DIR."
