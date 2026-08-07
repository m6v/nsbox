#!/usr/bin/env python3
import os, sys, json, shutil, platform, subprocess, warnings, argparse, tarfile

# Подавление DeprecationWarning для совместимости (3.7 - 3.14)
warnings.filterwarnings("ignore", category=DeprecationWarning)

def main():
    parser = argparse.ArgumentParser(
        description="Fetch Docker images, cache layers, and extract rootfs with full xattrs support."
    )
    parser.add_argument("image", help="Имя образа (например, alpine:latest)")
    parser.add_argument("target_dir", help="Целевой каталог для rootfs")
    args = parser.parse_args()
    
    if os.geteuid() != 0:
        print("Ошибка: Скрипт должен быть запущен от имени root (через sudo) для сохранения xattrs.")
        sys.exit(1)

    image_arg = args.image
    target_dir = os.path.abspath(args.target_dir)

    if ":" in image_arg:
        name, tag = image_arg.split(":", 1)
    else:
        name, tag = image_arg, "latest"

    repo = "library/" + name if "/" not in name else name
    arch = "amd64" if platform.machine() == "x86_64" else "arm64" if platform.machine() == "aarch64" else platform.machine()

    print("Получение токена и манифеста...")
    auth_host = bytes.fromhex("68747470733a2f2f617574682e646f636b65722e696f2f746f6b656e").decode()
    manifest_host = bytes.fromhex("68747470733a2f2f72656769737472792d312e646f636b65722e696f2f76322f").decode()

    auth_query = "service=registry.docker.io&scope=repository:" + repo + ":pull"
    auth_url = auth_host + "?" + auth_query

    cmd_auth = ["curl", "-s", "-L", "-H", "User-Agent: Docker-Client/24.0.7 (linux)", auth_url]
    auth_res = subprocess.check_output(cmd_auth, text=True)
    token = json.loads(auth_res)["token"]

    manifest_url = manifest_host + repo + "/manifests/" + tag
    cmd_manifest = [
        "curl", "-s", "-L", "-H", "User-Agent: Docker-Client/24.0.7 (linux)",
        "-H", "Authorization: Bearer " + token,
        "-H", "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json",
        manifest_url
    ]
    manifest_res = subprocess.check_output(cmd_manifest, text=True)
    res = json.loads(manifest_res)

    if "manifests" in res:
        digest = next(m["digest"] for m in res["manifests"] if m.get("platform", {}).get("architecture") == arch)
        arch_url = manifest_host + repo + "/manifests/" + digest
        cmd_manifest[-1] = arch_url
        manifest_res = subprocess.check_output(cmd_manifest, text=True)
        res = json.loads(manifest_res)

    layers = [l["digest"] for l in res["layers"]]

    # --- СТАРТ ПРОМЫШЛЕННОГО КЭШИРОВАНИЯ ---
    os.makedirs(target_dir, exist_ok=True)
    cache_dir = os.path.join(target_dir, ".cache_layers")
    os.makedirs(cache_dir, exist_ok=True)

    cached_files = []
    
    # Этап 1: Сначала только скачиваем все слои в кэш
    print(f"Скачивание {len(layers)} слоев в кэш...")
    for idx, digest in enumerate(layers, 1):
        print(f"Загрузка [{idx}/{len(layers)}] -> {digest[7:19]}.tar.gz")
        blob_url = manifest_host + repo + "/blobs/" + digest
        layer_file = os.path.join(cache_dir, f"{idx}_{digest[7:19]}.tar.gz")
        
        # Убран флаг "-s", добавлен "-S" для вывода таблицы прогресса и ошибок
        cmd_blob = [
            "curl", "-L", "-S",
            "-H", "User-Agent: Docker-Client/24.0.7 (linux)",
            "-H", "Authorization: Bearer " + token,
            "-o", layer_file, blob_url
        ]
        subprocess.run(cmd_blob, check=True)
        cached_files.append(layer_file)

    # Этап 2: Послойная высокоэффективная распаковка
    print("Распаковка и OCI-процессинг слоев...")
    for layer_file in cached_files:
        
        # Высокоэффективный поиск whiteout-файлов ДО распаковки слоя (анализ оглавления архива)
        with tarfile.open(layer_file, mode="r|gz") as tar:
            for member in tar:
                basename = os.path.basename(member.name)
                dirname = os.path.dirname(member.name)
                
                # 1. Точечный Explicit Whiteout (.wh.filename)
                if basename.startswith(".wh.") and basename != ".wh..wh..opq":
                    real_name = basename[4:]
                    to_delete = os.path.join(target_dir, dirname, real_name)
                    if os.path.exists(to_delete) or os.path.islink(to_delete):
                        shutil.rmtree(to_delete) if os.path.isdir(to_delete) and not os.path.islink(to_delete) else os.remove(to_delete)
                        
                # 2. Точечный Opaque Whiteout (.wh..wh..opq)
                elif basename == ".wh..wh..opq":
                    opaque_dir = os.path.join(target_dir, dirname)
                    if os.path.exists(opaque_dir):
                        for item in os.listdir(opaque_dir):
                            item_path = os.path.join(opaque_dir, item)
                            shutil.rmtree(item_path) if os.path.isdir(item_path) and not os.path.islink(item_path) else os.remove(item_path)

        # Накатываем слой через системный tar (сохраняя xattrs и разрешая жесткие ссылки)
        # Так как файлы кэшированы локально, tar отработает мгновенно и без сетевых сбоев
        cmd_tar = ["tar", "--xattrs", "--xattrs-include=*", "-xzf", layer_file, "-C", target_dir]
        subprocess.run(cmd_tar, check=True)

    # Этап 3: Финальная зачистка самих маркеров удаления с диска (теперь это секундная операция)
    for root, dirs, files in os.walk(target_dir):
        for f in files:
            if f.startswith(".wh."):
                os.remove(os.path.join(root, f))

    # Удаляем папку кэша
    shutil.rmtree(cache_dir)

    # Создание необходимых точек монтирования для systemd-nspawn
    print("Подготовка точек монтирования для systemd-nspawn...")
    for mp in ["proc", "sys", "dev", "run", "tmp"]:
        os.makedirs(os.path.join(target_dir, mp), exist_ok=True)

    print("Файловая система успешно развернута в: " + target_dir)

if __name__ == "__main__":
    main()
