#!/usr/bin/env python3
import argparse
import base64
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request
import warnings

# Отключение предупреждений об устаревании
warnings.filterwarnings("ignore", category=DeprecationWarning)

def get_auth_params(registry_url, repo, username=None, password=None):
    """
    Предзапрос к реестру, чтобы узнать точный URL сервера авторизации (Auth Discovery)
    и тип поддерживаемой авторизации (Bearer или Basic).
    """
    url = f"https://{registry_url}/v2/{repo}/manifests/latest"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", "Docker-Client/24.0.7 (linux)")
    
    # Если переданы учетные данные, пробуем подставить их сразу на случай Basic Auth
    if username and password:
        creds = base64.b64encode(f"{username}:{password}".encode()).decode()
        req.add_header("Authorization", f"Basic {creds}")
        
    try:
        with urllib.request.urlopen(req) as r:
            # Если запрос прошел успешно с Basic Auth, токен не нужен
            if username and password:
                return "basic", None, None, None
            return "anonymous", None, None, None
    except urllib.error.HTTPError as e:
        auth_header = e.headers.get("Www-Authenticate")
        if not auth_header:
            return "anonymous", None, None, None
        
        # Если реестр отвечает Bearer, парсим параметры токен-сервера
        if auth_header.startswith("Bearer "):
            params = {}
            parts = auth_header[7:].split(",")
            for part in parts:
                if "=" in part:
                    k, v = part.split("=", 1)
                    params[k.strip()] = v.strip('"')
            
            scope = params.get("scope", f"repository:{repo}:pull")
            return "bearer", params.get("realm"), params.get("service"), scope
            
        # Если реестр явно требует Basic Auth
        elif auth_header.startswith("Basic "):
            return "basic", None, None, None
            
    except Exception:
        pass
    return "anonymous", None, None, None

def main():
    parser = argparse.ArgumentParser(
        description="Fetch Docker/OCI images from any public or private registry, cache layers, and extract rootfs."
    )
    parser.add_argument("image", help="Имя образа (например, alpine:latest, quay.io/username/private-image:1.0)")
    parser.add_argument("target_dir", help="Целевой каталог для rootfs")
    parser.add_argument("-u", "--user", help="Имя пользователя для авторизации в реестре", default=None)
    parser.add_argument("-p", "--password", help="Пароль или токен доступа (Token/PAT) для авторизации", default=None)
    args = parser.parse_args()
    
    if os.geteuid() != 0:
        print("Ошибка: Скрипт должен быть запущен от имени root (через sudo) для сохранения xattrs.")
        sys.exit(1)

    image_arg = args.image
    target_dir = os.path.abspath(args.target_dir)
    username = args.user
    password = args.password

    # Выделяем тег
    if ":" in image_arg:
        image_part, tag = image_arg.split(":", 1)
    else:
        image_part, tag = image_arg, "latest"

    # Определение хоста реестра
    parts = image_part.split("/", 1)
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        registry_host = parts[0]
        repo = parts[1]
    else:
        registry_host = "registry-1.docker.io"
        repo = "library/" + image_part if "/" not in image_part else image_part

    arch = "amd64" if platform.machine() == "x86_64" else "arm64" if platform.machine() == "aarch64" else platform.machine()

    print(f"Анализ реестра {registry_host}...")
    
    # Динамическое обнаружение типа авторизации
    auth_type, realm, service, scope = get_auth_params(registry_host, repo, username, password)
    
    # Подготовка базовых аргументов авторизации для curl
    curl_auth_args = []
    
    if auth_type == "bearer" and realm:
        print(f"Получение временного токена с сервера {realm}...")
        query = urllib.parse.urlencode({"service": service, "scope": scope}, safe="/:")
        auth_url = f"{realm}?{query}"
        
        cmd_auth = ["curl", "-s", "-L", "-H", "User-Agent: Docker-Client/24.0.7 (linux)"]
        # Если переданы логин/пароль, передача их серверу токенов через Basic Auth
        if username and password:
            cmd_auth.extend(["-u", f"{username}:{password}"])
        cmd_auth.append(auth_url)
        
        try:
            auth_res = subprocess.check_output(cmd_auth, text=True)
            token = json.loads(auth_res).get("token") or json.loads(auth_res).get("access_token")
            if token:
                curl_auth_args = ["-H", f"Authorization: Bearer {token}"]
        except Exception as e:
            print(f"Ошибка получения токена: {e}. Попытка продолжить анонимно...")
            
    elif auth_type == "basic" and username and password:
        print("Использование прямой Basic-авторизации для каждого запроса...")
        curl_auth_args = ["-u", f"{username}:{password}"]

    # Запрос манифеста
    print("Запрос манифеста образа...")
    manifest_url = f"https://{registry_host}/v2/{repo}/manifests/{tag}"
    
    cmd_manifest = [
        "curl", "-s", "-L",
        "-H", "User-Agent: Docker-Client/24.0.7 (linux)",
        "-H", "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json"
    ]
    cmd_manifest.extend(curl_auth_args)
    cmd_manifest.append(manifest_url)

    manifest_res = subprocess.check_output(cmd_manifest, text=True)
    res = json.loads(manifest_res)

    if "manifests" in res:
        digest = next(m["digest"] for m in res["manifests"] if m.get("platform", {}).get("architecture") == arch)
        arch_url = f"https://{registry_host}/v2/{repo}/manifests/{digest}"
        cmd_manifest[-1] = arch_url
        manifest_res = subprocess.check_output(cmd_manifest, text=True)
        res = json.loads(manifest_res)

    layer_keys = ["layers", "fsLayers"]
    active_key = next((k for k in layer_keys if k in res), None)
    if not active_key:
        print(f"Ошибка: Не удалось найти слои в манифесте. Ответ сервера: {res}")
        sys.exit(1)
        
    layers = [l.get("digest") or l.get("blobSum") for l in res[active_key]]

    # Скачивание слоев в кэш
    os.makedirs(target_dir, exist_ok=True)
    cache_dir = os.path.join(target_dir, ".cache_layers")
    os.makedirs(cache_dir, exist_ok=True)

    cached_files = []
    print(f"Скачивание {len(layers)} слоев в кэш...")
    for idx, digest in enumerate(layers, 1):
        clean_digest = digest.split(":")[-1]
        print(f"Загрузка [{idx}/{len(layers)}] -> {clean_digest[:12]}.tar.gz")
        blob_url = f"https://{registry_host}/v2/{repo}/blobs/{digest}"
        layer_file = os.path.join(cache_dir, f"{idx}_{clean_digest[:12]}.tar.gz")
        
        cmd_blob = [
            "curl", "-L", "-S",
            "-H", "User-Agent: Docker-Client/24.0.7 (linux)",
            "-o", layer_file
        ]
        cmd_blob.extend(curl_auth_args)
        cmd_blob.append(blob_url)
        
        subprocess.run(cmd_blob, check=True)
        cached_files.append(layer_file)

    # Послойная обработка и извлечение слоев
    print("Распаковка и OCI-процессинг слоев...")
    for layer_file in cached_files:
        with tarfile.open(layer_file, mode="r|gz") as tar:
            for member in tar:
                basename = os.path.basename(member.name)
                dirname = os.path.dirname(member.name)
                
                if basename.startswith(".wh.") and basename != ".wh..wh..opq":
                    real_name = basename[4:]
                    to_delete = os.path.join(target_dir, dirname, real_name)
                    if os.path.exists(to_delete) or os.path.islink(to_delete):
                        shutil.rmtree(to_delete) if os.path.isdir(to_delete) and not os.path.islink(to_delete) else os.remove(to_delete)
                        
                elif basename == ".wh..wh..opq":
                    opaque_dir = os.path.join(target_dir, dirname)
                    if os.path.exists(opaque_dir):
                        for item in os.listdir(opaque_dir):
                            item_path = os.path.join(opaque_dir, item)
                            shutil.rmtree(item_path) if os.path.isdir(item_path) and not os.path.islink(item_path) else os.remove(item_path)

        cmd_tar = ["tar", "--xattrs", "--xattrs-include=*", "-xzf", layer_file, "-C", target_dir]
        subprocess.run(cmd_tar, check=True)

    # Удаление маркеров .wh.
    for root, dirs, files in os.walk(target_dir):
        for f in files:
            if f.startswith(".wh."):
                os.remove(os.path.join(root, f))

    shutil.rmtree(cache_dir)

    # Подготовка точек монтирования для systemd-nspawn
    print("Подготовка точек монтирования для systemd-nspawn...")
    for mp in ["proc", "sys", "dev", "run", "tmp"]:
        os.makedirs(os.path.join(target_dir, mp), exist_ok=True)

    print("Файловая система успешно развернута в: " + target_dir)

if __name__ == "__main__":
    main()
