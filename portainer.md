# Portainer Configuration on pico

**Endpoint:** pico-docker (Local Docker Engine)  
**Docker Version:** 29.0.1  
**Portainer Version:** portainer-ee 2.33.6  
**Portainer Compose:** `/opt/portainer/docker-compose.yml` (host network mode)  
**Total Containers:** 36 running  
**Total Volumes:** 44  
**Total Images:** 149  
**Total Stacks:** 16 (14 active, 2 stopped)  
**System CPU:** 12 cores  
**System Memory:** ~31 GB

---

## Table of Contents

### Stacks

1. [transmission](#transmission) - OpenVPN-based torrent downloader  
2. [sonarrradarrjackett](#sonarrradarrjackett) - Media automation (TV/Movies/Indexers)  
3. [plex](#plex) - Media server  
4. [vault](#vault) - Secrets management  
5. [owncloud](#owncloud) - Cloud storage (stopped)  
6. [stevegore-au](#stevegore-au) - Web terminal and utilities  
7. [photoprism](#photoprism) - Photo management with AI  
8. [gitea](#gitea) - Git server (stopped)  
9. [huggin](#huggin) - Task automation  
10. [nuraspace2](#nuraspace2) - NuraSpace application  
11. [pdf](#pdf) - Stirling PDF document processor  
12. [gymmaster-rest](#gymmaster-rest) - Gym booking system  
13. [goldenboards](#goldenboards) - Golden Boards application  
14. [stravakeeper](#stravakeeper) - Strava data keeper  
15. [transmission-wg](#transmission-wg) - WireGuard-based torrent (stopped)  
16. [stravabot-rs](#stravabot-rs) - Strava bot in Rust

### Standalone Containers

1. [Portainer](#portainer) - Container management UI  
2. [Home Assistant](#home-assistant) - Smart home automation  
3. [Heimdall](#heimdall) - Application dashboard  
4. [Bitwarden (Vaultwarden)](#bitwarden-vaultwarden) - Password manager  
5. [Duplicati](#duplicati) - Backup and disaster recovery

### Reference

1. [Networks](#networks) - Docker network topology  
2. [Named Volumes](#named-volumes) - Persistent storage inventory  
3. [Ports in Use](#ports-in-use) - Port allocation map  
4. [Container Health Status](#container-health-status) - Healthcheck summary  
5. [Bind Mount Paths](#bind-mount-paths) - Host filesystem mappings  
6. [Custom-Built Images](#custom-built-images) - Locally built containers

---

## Active Stacks

### transmission

**Status:** Running (healthy)  
**Stack ID:** 2  
**Project Path:** `/data/compose/2`  
**Compose Version:** v6  
**Last Updated:** 2025-05-05  
**Created:** 2021-06-14

**Containers:**

| Container                         | Image                                  | Status               |
| --------------------------------- | -------------------------------------- | -------------------- |
| transmission-transmission-1       | haugene/transmission-openvpn:5.3       | Up 10 days (healthy) |
| transmission-transmission-proxy-1 | haugene/transmission-openvpn-proxy:5.3 | Up 2 weeks           |

**Docker Compose:**

```yaml
version: "3.3"
services:
  transmission:
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    volumes:
      - "/var/lib/transmission/:/data"
    environment:
      - OPENVPN_PROVIDER=WINDSCRIBE
      - OPENVPN_CONFIG=Sydney-OperaHouse-udp
      - OPENVPN_USERNAME=kl6tsrpe-4dte9yj
      - OPENVPN_PASSWORD=hs593zeayg
      - LOCAL_NETWORK=10.20.30.0/24
      - TRANSMISSION_DOWNLOAD_QUEUE_SIZE=50
    logging:
      driver: json-file
      options:
        max-size: 10m
    networks:
      - transmission
    ports:
      - "9093:9091"
    image: haugene/transmission-openvpn:5.3
    sysctls:
      - "net.ipv6.conf.all.disable_ipv6=0"
    security_opt:
      - seccomp:unconfined
  transmission-proxy:
    image: haugene/transmission-openvpn-proxy:5.3
    restart: unless-stopped
    networks:
      - transmission
    ports:
      - "9092:8080"

networks:
  transmission:
    external: true
    name: transmission_net
```

**Purpose:** BitTorrent client with Windscribe VPN integration (Sydney node). The proxy container provides an nginx reverse proxy to the Transmission web UI.  
**Ports:** 9093 -> 9091 (Transmission web UI), 9092 -> 8080 (nginx proxy)  
**Network:** Uses external `transmission_net` bridge network, shared with sonarrradarrjackett stack  
**VPN:** Windscribe OpenVPN via Sydney-OperaHouse endpoint  
**Health:** Transmission container has autoheal label enabled  
**Command:** `dumb-init /etc/openvpn/start.sh`

---

### sonarrradarrjackett

**Status:** Running  
**Stack ID:** 7  
**Project Path:** `/data/compose/7`  
**Compose Version:** v4  
**Last Updated:** 2025-11-21  
**Created:** 2021-10-04

**Containers:**

| Container | Image                        | Status     |
| --------- | ---------------------------- | ---------- |
| radarr    | linuxserver/radarr:5.22.4    | Up 2 weeks |
| sonarr    | linuxserver/sonarr:4.0.16    | Up 2 weeks |
| jackett   | linuxserver/jackett:0.24.338 | Up 2 weeks |

**Docker Compose:**

```yaml
version: '3'
services:
  radarr:
    container_name: radarr
    restart: unless-stopped
    networks:
      - transmission_net
    ports:
      - 7878:7878
    volumes:
      - radarr-config:/config
      - /var/lib/transmission:/data
      - /srv/movies:/movies
    environment:
      - TZ=Australia/Sydney
    image: linuxserver/radarr:5.22.4

  sonarr:
    container_name: sonarr
    restart: unless-stopped
    networks:
      - transmission_net
    ports:
      - 8989:8989
    volumes:
      - sonarr-config:/config
      - /var/lib/transmission:/data
      - /srv/tv:/tv
    environment:
      - TZ=Australia/Sydney
    image: linuxserver/sonarr:4.0.16

  jackett:
    container_name: jackett
    restart: unless-stopped
    networks:
      - transmission_net
    ports:
      - 9117:9117
    volumes:
      - jackett-config:/config
    environment:
      - TZ=Australia/Sydney
    image: linuxserver/jackett:0.24.338

volumes:
  radarr-config:
  sonarr-config:
  jackett-config:

networks:
  transmission_net:
    external: true
```

**Purpose:** Media automation - Sonarr for TV shows, Radarr for movies, Jackett for torrent indexing  
**Ports:** 7878 (Radarr), 8989 (Sonarr), 9117 (Jackett)  
**Network:** Uses external `transmission_net` to communicate with Transmission VPN container  
**Storage:** Radarr accesses `/srv/movies`, Sonarr accesses `/srv/tv`, both share `/var/lib/transmission` for download access  
**Volumes:** `sonarrradarrjackett_radarr-config`, `sonarrradarrjackett_sonarr-config`, `sonarrradarrjackett_jackett-config`

---

### plex

**Status:** Running (healthy)  
**Stack ID:** 10  
**Project Path:** `/data/compose/10`  
**Compose Version:** v3  
**Last Updated:** 2025-05-07  
**Created:** 2021-11-27

**Containers:**

| Container | Image                                    | Status               |
| --------- | ---------------------------------------- | -------------------- |
| plex      | plexinc/pms-docker:1.41.6.9685-d301f511a | Up 2 weeks (healthy) |

**Docker Compose:**

```yaml
version: '2'
services:
  plex:
    container_name: plex
    image: plexinc/pms-docker:1.41.6.9685-d301f511a
    restart: unless-stopped
    ports:
      - 32400:32400/tcp
      - 3005:3005/tcp
      - 8324:8324/tcp
      - 32469:32469/tcp
      - 32410:32410/udp
      - 32412:32412/udp
      - 32413:32413/udp
      - 32414:32414/udp
    environment:
      - TZ=Australia/Sydney
      - PLEX_CLAIM=claim-MuDFFkYK25yaVxvRUtCz
      - ADVERTISE_IP=<http://152.67.110.42:32400>
      - ALLOWED_NETWORKS=192.168.0.0/16,10.0.0.0/8
      # - NVIDIA_VISIBLE_DEVICES=all
    hostname: PlexOnPico
    volumes:
      - plex-config:/config
      - plex-temp:/transcode
      - /srv/tv:/data/tv
      - /srv/movies:/data/movies
      - /dev/bus/usb:/dev/bus/usb

volumes:
  plex-config:
  plex-temp:
```

**Purpose:** Plex Media Server - streaming movies and TV shows  
**Ports:** 32400 (primary web UI), 3005 (Plex Companion), 8324 (Roku), 32469 (DLNA), 32410-32414/udp (GDM network discovery)  
**External IP:** 152.67.110.42  
**Hostname:** PlexOnPico  
**Storage:** Media from `/srv/tv` and `/srv/movies`, USB passthrough via `/dev/bus/usb`  
**Volumes:** `plex_plex-config`, `plex_plex-temp`  
**Note:** NVIDIA GPU passthrough is commented out but available

---

### vault

**Status:** Running  
**Stack ID:** 23  
**Project Path:** `/data/compose/23`  
**Compose Version:** v7  
**Last Updated:** 2025-10-31  
**Created:** 2022-07-14

**Containers:**

| Container | Image                | Status     |
| --------- | -------------------- | ---------- |
| vault     | hashicorp/vault:1.21 | Up 2 weeks |

**Docker Compose:**

```yaml
version: '3.8'
services:
  vault:
    image: hashicorp/vault:1.21
    container_name: vault
    restart: unless-stopped
    ports:
      - "8202:8200"
    cap_add:
      - IPC_LOCK
    environment:
      VAULT_ADDR: <http://127.0.0.1:8200>
      VAULT_LOCAL_CONFIG: |
        {
          "storage": {"file": {"path": "/vault/file"}},
          "listener": [{"tcp": {"address": "0.0.0.0:8200", "tls_disable": true}}],
          "ui": true,
          "default_lease_ttl": "168h",
          "max_lease_ttl": "720h"
        }
    volumes:
      - vault-data:/vault/file
    command: server

volumes:
  vault-data:
```

**Purpose:** HashiCorp Vault - secrets and credentials management  
**Ports:** 8202 -> 8200 (web UI, no TLS)  
**Storage:** Single-node file-based storage backend  
**Config:** UI enabled, default lease 168h (7 days), max lease 720h (30 days)  
**Volumes:** `vault_vault-data`  
**Command:** `docker-entrypoint.sh server`

---

### owncloud

**Status:** Stopped  
**Stack ID:** 24  
**Project Path:** `/data/compose/24`  
**Compose Version:** v1  
**Last Updated:** 2023-06-07  
**Created:** 2023-01-04

**Services:**  

- `owncloud` - owncloud/server:10.12  
- `mariadb` - mariadb:10.5  
- `redis` - redis:6

**Docker Compose:**

```yaml
version: "3"
volumes:
  files:
    driver: local
  mysql:
    driver: local
  redis:
    driver: local

services:
  owncloud:
    image: owncloud/server:10.12
    container_name: owncloud_server
    restart: always
    ports:
      - 8844:8080
    depends_on:
      - mariadb
      - redis
    environment:
      - OWNCLOUD_DOMAIN=oc.stevegore.au
      - OWNCLOUD_DB_TYPE=mysql
      - OWNCLOUD_DB_NAME=owncloud
      - OWNCLOUD_DB_USERNAME=owncloud
      - OWNCLOUD_DB_PASSWORD=cb3JCJQpj56N4b
      - OWNCLOUD_DB_HOST=mariadb
      - OWNCLOUD_ADMIN_USERNAME=steve
      - OWNCLOUD_ADMIN_PASSWORD=XBFm9gegW4rV.om
      - OWNCLOUD_MYSQL_UTF8MB4=true
      - OWNCLOUD_REDIS_ENABLED=true
      - OWNCLOUD_REDIS_HOST=redis
    healthcheck:
      test: ["CMD", "/usr/bin/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
    volumes:
      - files:/mnt/data

  mariadb:
    image: mariadb:10.5
    container_name: owncloud_mariadb
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=TTWUCxuj8CfBNt
      - MYSQL_USER=owncloud
      - MYSQL_PASSWORD=cb3JCJQpj56N4b
      - MYSQL_DATABASE=owncloud
    command: ["--max-allowed-packet=128M", "--innodb-log-file-size=64M"]
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-u", "root", "--password=owncloud"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - mysql:/var/lib/mysql

  redis:
    image: redis:6
    container_name: owncloud_redis
    restart: always
    command: ["--databases", "1"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - redis:/data
```

**Purpose:** OwnCloud - self-hosted cloud storage solution (decommissioned)  
**Ports:** 8844 -> 8080 (web)  
**Domain:** oc.stevegore.au  
**Database:** MariaDB 10.5 with utf8mb4, max-allowed-packet=128M  
**Cache:** Redis 6 (single database)  
**Volumes:** `owncloud_files`, `owncloud_mysql`, `owncloud_redis` (still present on disk)  
**Note:** Stack is stopped but volumes remain. Could be cleaned up if no longer needed.

---

### stevegore-au

**Status:** Running  
**Stack ID:** 29  
**Project Path:** `/data/compose/29`  
**Compose Version:** v2  
**Public:** Yes (Portainer resource control set to public)  
**Last Updated:** 2025-12-09  
**Created:** 2023-07-06

**Containers:**

| Container                | Image                   | Status                     |
| ------------------------ | ----------------------- | -------------------------- |
| stevegore-au-ttyd-1      | stevegore/ttyd (custom) | Up ~30 min (auto-restarts) |
| stevegore-au-restarter-1 | docker:cli              | Up 2 weeks                 |

**Docker Compose:**

```yaml
services:
  ttyd:
    image: stevegore/ttyd
    labels:
      - ttyd
    volumes:
      - homedir:/home/visitor
      - tmpdir:/tmp
      - tmpdir:/var/tmp
    ports:
      - 8788:8788
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 250M
    ulimits:
      nproc: 250
      nofile:
        soft: 500
        hard: 500

  restarter:
    image: docker:cli
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: ["/bin/sh", "-c", "while true; do sleep 1800; for container in $$(docker ps -f label=ttyd -q); do docker restart $$container; done; done"]
    restart: unless-stopped

volumes:
  homedir:
    driver: local
    driver_opts:
      o: "size=500m,uid=222,gid=222"
      device: tmpfs
      type: tmpfs
  tmpdir:
    driver: local
    driver_opts:
      o: "size=500m"
      device: tmpfs
      type: tmpfs
```

**Purpose:** Web-based terminal (ttyd) with automatic restart management for public access  
**Ports:** 8788 (terminal web UI)  
**Command:** `ttyd --writable -t fontSize=14 -t 'fontFamily=Consolas, Monaco, Courier New, monospace' -p 8788 zsh`  
**Resource Limits:** 0.5 CPU cores, 250M memory, 250 max processes, 500 file descriptors  
**Storage:** All tmpfs-backed (ephemeral) - homedir 500M (uid/gid 222), tmpdir 500M  
**Restarter:** Sidecar container restarts ttyd every 30 minutes via Docker socket  
**Volumes:** `stevegore-au_homedir` (tmpfs), `stevegore-au_tmpdir` (tmpfs)

---

### photoprism

**Status:** Running  
**Stack ID:** 30  
**Project Path:** `/data/compose/30`  
**Compose Version:** v4  
**Last Updated:** 2024-09-22  
**Created:** 2023-08-06

**Containers:**

| Container               | Image                        | Status     |
| ----------------------- | ---------------------------- | ---------- |
| photoprism-photoprism-1 | photoprism/photoprism:240915 | Up 2 weeks |
| photoprism-mariadb-1    | mariadb:10.11                | Up 2 weeks |
| photoprism-chadburn-1   | premoweb/chadburn:latest     | Up 2 weeks |

**Docker Compose:**

```yaml
version: '3.5'
services:
  chadburn:
    image: premoweb/chadburn:latest
    depends_on:
      - photoprism
    command: daemon
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  photoprism:
    image: photoprism/photoprism:240915
    restart: unless-stopped
    stop_grace_period: 10s
    depends_on:
      - mariadb
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    ports:
      - "2342:2342"
    env_file:
      - stack.env
    working_dir: "/photoprism"
    volumes:
      - "/media/m2/photos:/photoprism/originals"
      - "/media/m2/photoprism/storage:/photoprism/storage"
    labels:
      chadburn.enabled: "true"
      chadburn.job-exec.indexjob.schedule: "0 2 * * *"
      chadburn.job-exec.indexjob.command: "photoprism index --cleanup"

  mariadb:
    image: mariadb:10.11
    restart: unless-stopped
    stop_grace_period: 5s
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    command: >-
      mariadbd
      --innodb-buffer-pool-size=512M
      --transaction-isolation=READ-COMMITTED
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --max-connections=512
      --innodb-rollback-on-timeout=OFF
      --innodb-lock-wait-timeout=120
    volumes:
      - "/media/m2/photoprism/database:/var/lib/mysql"
    env_file:
      - stack.env
```

**stack.env:**

```text
MARIADB_AUTO_UPGRADE=1
MARIADB_INITDB_SKIP_TZINFO=1
MARIADB_DATABASE=photoprism
MARIADB_USER=photoprism
MARIADB_PASSWORD=k3jh45k3hj
MARIADB_ROOT_PASSWORD=k3jh45k3hj
PHOTOPRISM_DATABASE_DRIVER=mysql
PHOTOPRISM_DATABASE_SERVER=mariadb:3306
PHOTOPRISM_DATABASE_NAME=photoprism
PHOTOPRISM_DATABASE_USER=photoprism
PHOTOPRISM_DATABASE_PASSWORD=k3jh45k3hj
PHOTOPRISM_ADMIN_USER=steve
PHOTOPRISM_ADMIN_PASSWORD=X4dknm.pp!
PHOTOPRISM_AUTH_MODE=password
PHOTOPRISM_SITE_URL=<http://localhost:2342/>
PHOTOPRISM_DISABLE_TLS=false
PHOTOPRISM_DEFAULT_TLS=true
PHOTOPRISM_ORIGINALS_LIMIT=5000
PHOTOPRISM_HTTP_COMPRESSION=gzip
PHOTOPRISM_LOG_LEVEL=info
PHOTOPRISM_READONLY=false
PHOTOPRISM_EXPERIMENTAL=false
PHOTOPRISM_DISABLE_CHOWN=false
PHOTOPRISM_DISABLE_WEBDAV=false
PHOTOPRISM_DISABLE_SETTINGS=false
PHOTOPRISM_DISABLE_TENSORFLOW=false
PHOTOPRISM_DISABLE_FACES=false
PHOTOPRISM_DISABLE_CLASSIFICATION=false
PHOTOPRISM_DISABLE_VECTORS=false
PHOTOPRISM_DISABLE_RAW=false
PHOTOPRISM_RAW_PRESETS=false
PHOTOPRISM_JPEG_QUALITY=85
PHOTOPRISM_DETECT_NSFW=false
PHOTOPRISM_UPLOAD_NSFW=true
PHOTOPRISM_SITE_CAPTION=The Gore's Photos
PHOTOPRISM_SITE_DESCRIPTION=
PHOTOPRISM_SITE_AUTHOR=Steve Gore
PHOTOPRISM_INIT=ffmpeg
```

**Purpose:** AI-powered photo management with facial recognition and classification  
**Ports:** 2342 (web UI, also exposes 2442/2443 internally for TLS)  
**Storage:** Originals on `/media/m2/photos`, cache/sidecar on `/media/m2/photoprism/storage`, database on `/media/m2/photoprism/database` (all on M.2 SSD)  
**Database:** MariaDB 10.11 with 512M InnoDB buffer pool, utf8mb4  
**Scheduler:** Chadburn runs `photoprism index --cleanup` daily at 2:00 AM  
**Features:** Face detection, ML classification, WebDAV, FFmpeg, gzip compression, JPEG quality 85  
**Admin:** User `steve`, password auth mode

---

### gitea

**Status:** Stopped  
**Stack ID:** 34  
**Project Path:** `/data/compose/34`  
**Compose Version:** v1  
**Created:** 2023-08-21

**Services:**  

- `server` - gitea/gitea:1.20.2

**Docker Compose:**

```yaml
version: "3"
networks:
  gitea:
    external: false

services:
  server:
    image: gitea/gitea:1.20.2
    container_name: gitea
    environment:
      - USER_UID=1000
      - USER_GID=1000
    restart: always
    networks:
      - gitea
    volumes:
      - gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "3030:3000"
      - "222:22"

volumes:
  gitea:
```

**Purpose:** Gitea - lightweight Git service with web UI (decommissioned)  
**Ports:** 3030 -> 3000 (web), 222 -> 22 (SSH)

---

### huggin

**Status:** Running  
**Stack ID:** 37  
**Project Path:** `/data/compose/37`  
**Compose Version:** v2  
**Last Updated:** 2024-05-20  
**Created:** 2023-12-26

**Containers:**

| Container           | Image                                | Status     |
| ------------------- | ------------------------------------ | ---------- |
| huggin-web-1        | ghcr.io/huginn/huginn-single-process | Up 2 weeks |
| huggin-threaded-1   | ghcr.io/huginn/huginn-single-process | Up 2 weeks |
| huggin-mysql-1      | mysql:5.7                            | Up 2 weeks |
| huggin-mysqladmin-1 | phpmyadmin                           | Up 2 weeks |

**Docker Compose:**

```yaml
version: '3'
services:
  mysql:
    image: mysql:5.7
    restart: always
    environment:
      - MYSQL_PORT_3306_TCP_ADDR=mysql
      - MYSQL_ROOT_PASSWORD=l3k4lk4j!!!!
    volumes:
      - mysqldata:/var/lib/mysql

  web:
    image: ghcr.io/huginn/huginn-single-process
    restart: always
    ports:
      - "3000:3000"
    environment:
      - MYSQL_PORT_3306_TCP_ADDR=mysql
      - MYSQL_ROOT_PASSWORD=l3k4lk4j!!!!
      - HUGINN_DATABASE_PASSWORD=l3k4lk4j!!!!
      - HUGINN_DATABASE_USERNAME=root
      - HUGINN_DATABASE_NAME=huginn
      - APP_SECRET_TOKEN=3bd139f9186b31a85336bb89cd1a1337078921134b2f48e022fd09c234d764d3e19b018b2ab789c6e0e04a1ac9e3365116368049660234c2038dc9990513d49c
    depends_on:
      - mysql
    volumes:
      - /etc/timezone:/etc/timezone
      - /etc/localtime:/etc/localtime

  threaded:
    image: ghcr.io/huginn/huginn-single-process
    command: /scripts/init bin/threaded.rb
    restart: always
    environment:
      - MYSQL_PORT_3306_TCP_ADDR=mysql
      - MYSQL_ROOT_PASSWORD=l3k4lk4j!!!!
      - HUGINN_DATABASE_PASSWORD=l3k4lk4j!!!!
      - HUGINN_DATABASE_USERNAME=root
      - HUGINN_DATABASE_NAME=huginn
      - APP_SECRET_TOKEN=3bd139f9186b31a85336bb89cd1a1337078921134b2f48e022fd09c234d764d3e19b018b2ab789c6e0e04a1ac9e3365116368049660234c2038dc9990513d49c
    depends_on:
      - mysql
      - web
    volumes:
      - /etc/timezone:/etc/timezone
      - /etc/localtime:/etc/localtime

  mysqladmin:
    image: phpmyadmin
    restart: always
    ports:
      - "3011:80"
    depends_on:
      - mysql
    environment:
      - PMA_HOST=mysql
      - MYSQL_ROOT_PASSWORD=l3k4lk4j!!!!

volumes:
  mysqldata:
```

**Purpose:** Huginn - workflow automation and task scheduling platform  
**Ports:** 3000 (Huginn web UI), 3011 (phpMyAdmin for database management)  
**Services:**  

- `web` - Main Huginn web process (handles UI and web requests)  
- `threaded` - Background worker process (`bin/threaded.rb`) for running scheduled agents  
- `mysql` - MySQL 5.7 database backend  
- `mysqladmin` - phpMyAdmin for database administration  
**Database:** MySQL 5.7, database name `huginn`  
**Volumes:** `huggin_mysqldata`

---

### nuraspace2

**Status:** Running  
**Stack ID:** 38  
**Project Path:** `/data/compose/38`  
**Compose Version:** v2  
**Last Updated:** 2025-01-05  
**Created:** 2024-01-04

**Containers:**

| Container              | Image              | Status     |
| ---------------------- | ------------------ | ---------- |
| nuraspace2-nuraspace-1 | nuraspace (custom) | Up 2 weeks |

**Docker Compose:**

```yaml
version: '3.5'
services:
  nuraspace:
    image: nuraspace  # Built manually and kept local currently due to credentials
    ports:
      - 8111:5000
    restart: unless-stopped
    volumes:
      - /var/nura:/var/nura
      - /etc/timezone:/etc/timezone
      - /etc/localtime:/etc/localtime
```

**Purpose:** NuraSpace application (custom Python deployment)  
**Ports:** 8111 -> 5000  
**Command:** `poetry run python app.py`  
**Storage:** `/var/nura` (bind mount)  
**Note:** Locally built image, not pushed to a registry

---

### pdf

**Status:** Running  
**Stack ID:** 41  
**Project Path:** `/data/compose/41`  
**Compose Version:** v2  
**Last Updated:** 2026-01-26  
**Created:** 2024-05-06

**Containers:**

| Container          | Image                 | Status      |
| ------------------ | --------------------- | ----------- |
| pdf-stirling-pdf-1 | frooodle/s-pdf:latest | Up 45 hours |

**Docker Compose:**

```yaml
version: '3.3'
services:
  stirling-pdf:
    image: frooodle/s-pdf:latest
    ports:
      - '8083:8080'
    volumes:
      - stirling-pdf-config:/configs
    environment:
      - DOCKER_ENABLE_SECURITY=false
      - INSTALL_BOOK_AND_ADVANCED_HTML_OPS=false
      - LANGS=en_GB

volumes:
  stirling-pdf-config:
```

**Purpose:** Stirling PDF - PDF manipulation and conversion tool  
**Ports:** 8083 -> 8080  
**Command:** `tini -- /scripts/init.sh`  
**Volumes:** `pdf_stirling-pdf-config`

---

### gymmaster-rest

**Status:** Running (healthy)  
**Stack ID:** 49  
**Project Path:** `/data/compose/49`  
**Compose Version:** v1  
**Created:** 2024-11-02

**Containers:**

| Container                   | Image                | Status               |
| --------------------------- | -------------------- | -------------------- |
| gymmaster-rest-gymbooking-1 | gymbooking2 (custom) | Up 2 weeks (healthy) |

**Docker Compose:**

```yaml
version: '3.5'
services:
  gymbooking:
    image: gymbooking2
    ports:
      - 8112:5000
    restart: unless-stopped
    volumes:
      - /var/elixr:/var/elixr
      - /etc/timezone:/etc/timezone
      - /etc/localtime:/etc/localtime
```

**Purpose:** Gym booking system (Elixr gym)  
**Ports:** 8112 -> 5000  
**Command:** `poetry run python main.py`  
**Storage:** `/var/elixr` (bind mount)  
**Note:** Locally built Python image, has healthcheck configured

---

### goldenboards

**Status:** Running  
**Stack ID:** 51  
**Project Path:** `/data/compose/51`  
**Compose Version:** v1  
**Created:** 2025-01-06

**Containers:**

| Container                   | Image                 | Status     |
| --------------------------- | --------------------- | ---------- |
| goldenboards-goldenboards-1 | goldenboards (custom) | Up 2 weeks |

**Docker Compose:**

```yaml
version: '3.5'
services:
  goldenboards:
    image: goldenboards
    restart: unless-stopped
    volumes:
      - /var/goldenboards:/var/goldenboards
      - /etc/timezone:/etc/timezone
      - /etc/localtime:/etc/localtime
```

**Purpose:** Golden Boards application (custom Go binary)  
**Ports:** None exposed  
**Command:** `/app/goldenboards`  
**Storage:** `/var/goldenboards` (bind mount)  
**Note:** Locally built image, no external port mapping

---

### stravakeeper

**Status:** Running  
**Stack ID:** 52  
**Project Path:** `/data/compose/52`  
**Compose Version:** v1  
**Created:** 2025-02-23

**Containers:**

| Container                   | Image                 | Status     |
| --------------------------- | --------------------- | ---------- |
| stravakeeper-stravakeeper-1 | stravakeeper (custom) | Up 2 weeks |

**Docker Compose:**

```yaml
services:
  stravakeeper:
    image: stravakeeper
    ports:
      - 8180:8180
    restart: unless-stopped
    volumes:
      - /var/stravakeeper:/var/stravakeeper
      - /etc/timezone:/etc/timezone
      - /etc/localtime:/etc/localtime
```

**Purpose:** Strava data keeper and archiver (custom Go binary)  
**Ports:** 8180  
**Command:** `./main`  
**Storage:** `/var/stravakeeper` (bind mount)  
**Note:** Locally built image

---

### transmission-wg

**Status:** Stopped  
**Stack ID:** 53  
**Project Path:** `/data/compose/53`  
**Compose Version:** v2  
**Last Updated:** 2025-05-05  
**Created:** 2025-05-05

**Services:**  

- `gluetun` - qmcgaw/gluetun (WireGuard VPN)  
- `transmission` - linuxserver/transmission

**Docker Compose:**

```yaml
version: "3.7"
services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=windscribe
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=mI0F/Vmtl2dg1d9buRgxtPj/WyXptamVu8OEIOJNM3s=
      - WIREGUARD_ADDRESSES=100.103.223.63/32
      - WIREGUARD_PUBLIC_KEY=eSxX+L8qX+1MdmwjtlZGIDbDivFdURBh5Rm1KfUpYzc=
      - WIREGUARD_ENDPOINT=syd-243-wg.whiskergalaxy.com:65142
      - FIREWALL=on
      - TZ=Australia/Sydney
    ports:
      - "9092:9091"
    restart: unless-stopped

  transmission:
    image: linuxserver/transmission
    container_name: transmission
    network_mode: "service:gluetun"
    depends_on:
      - gluetun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Australia/Sydney
      - TRANSMISSION_WEB_UI=combustion
    volumes:
      - "/var/lib/transmission/:/data"
      - transmission_config:/config
    restart: unless-stopped

volumes:
  transmission_config:
```

**Purpose:** Alternative Transmission setup using WireGuard VPN via Gluetun (currently stopped in favour of OpenVPN stack)  
**Ports:** 9092 -> 9091 (web UI via gluetun)  
**VPN:** Windscribe WireGuard via Sydney endpoint (syd-243-wg.whiskergalaxy.com:65142)  
**Web UI:** Combustion theme  
**Volumes:** `transmission-wg_transmission_config`  
**Note:** Port 9092 conflicts with the OpenVPN transmission proxy when both are running

---

### stravabot-rs

**Status:** Running  
**Stack ID:** 56  
**Project Path:** `/data/compose/56`  
**Compose Version:** v3  
**Last Updated:** 2026-01-26  
**Created:** 2026-01-26

**Containers:**

| Container    | Image                        | Status    |
| ------------ | ---------------------------- | --------- |
| stravabot-rs | stravabot-rs:latest (custom) | Up 2 days |

**Docker Compose:**

```yaml
services:
  stravabot-rs:
    image: stravabot-rs:latest
    container_name: stravabot-rs
    restart: unless-stopped
    ports:
      - "8082:8082"
    environment:
      - AUTH_TOKEN_PATH=/var/stravabot-rs/.strava-auth-token
      - PROGRESS_MARKER_PATH=/app/data/.stravabot_progress.json
      - DEBUG=false
      - RUN_ON_STARTUP=false
    volumes:
      - stravabot-rs-data:/app/data
      - /var/stravabot-rs/.strava-auth-token:/var/stravabot-rs/.strava-auth-token:ro

volumes:
  stravabot-rs-data:
```

**Purpose:** Strava bot written in Rust for Strava activity automation  
**Ports:** 8082  
**Command:** `/app/stravabot`  
**Storage:** Auth token mounted read-only from `/var/stravabot-rs/.strava-auth-token`, progress data in `stravabot-rs_stravabot-rs-data` volume  
**Note:** Locally built Rust binary, does not run on startup (triggered via API)

---

## Standalone Containers (Not in Stacks)

### Portainer

**Container:** portainer-portainer-1  
**Image:** portainer/portainer-ee:2.33.6  
**Status:** Running (Up 45 hours)  
**Network:** host (all ports exposed directly)  
**Compose Config:** `/opt/portainer/docker-compose.yml`  
**Command:** `/portainer`  
**Mounts:**  

- `portainer_data` volume -> `/data`  
- `/etc/localtime` bind -> `/etc/localtime`  
- `/etc/timezone` bind -> `/etc/timezone`  
- `/run/docker.sock` bind -> `/var/run/docker.sock`

**Purpose:** Container management UI (Enterprise Edition)

---

### Home Assistant

**Container:** homeassistant  
**Image:** ghcr.io/home-assistant/qemux86-64-homeassistant:2025.12.2  
**Status:** Running (Up 2 weeks)  
**Network:** host (all ports exposed directly)  
**Command:** `/init`  
**Mounts:**  

- `/usr/share/hassio/homeassistant` -> `/config`  
- `/usr/share/hassio/media` -> `/media`  
- `/usr/share/hassio/share` -> `/share`  
- `/usr/share/hassio/ssl` -> `/ssl` (read-only)  
- `/dev` -> `/dev` (device passthrough)  
- `/run/dbus` -> `/run/dbus` (D-Bus access)

**Purpose:** Smart home automation and control (Home Assistant Supervised)

**Supervisor:**

| Container         | Image                                             | Status     | Network        |
| ----------------- | ------------------------------------------------- | ---------- | -------------- |
| hassio_supervisor | homeassistant/amd64-hassio-supervisor (2026.01.1) | Up 12 days | bridge, hassio |

**Core Components:**

| Container        | Image                                                   | Status     | Network |
| ---------------- | ------------------------------------------------------- | ---------- | ------- |
| hassio_multicast | ghcr.io/home-assistant/amd64-hassio-multicast:2025.08.0 | Up 2 weeks | host    |
| hassio_audio     | ghcr.io/home-assistant/amd64-hassio-audio:2025.08.0     | Up 2 weeks | hassio  |
| hassio_dns       | ghcr.io/home-assistant/amd64-hassio-dns:2025.08.0       | Up 2 weeks | hassio  |
| hassio_cli       | ghcr.io/home-assistant/amd64-hassio-cli:2026.01.0       | Up 2 weeks | hassio  |
| hassio_observer  | ghcr.io/home-assistant/amd64-hassio-observer:2025.02.0  | Up 2 weeks | hassio  |

**Addons:**

| Container                 | Image                                         | Purpose                | Status               | Network |
| ------------------------- | --------------------------------------------- | ---------------------- | -------------------- | ------- |
| addon_a0d7b954_vscode     | ghcr.io/hassio-addons/vscode/amd64:6.0.1      | VS Code editor         | Up 2 weeks (healthy) | hassio  |
| addon_a0d7b954_phpmyadmin | ghcr.io/hassio-addons/phpmyadmin/amd64:0.13.0 | Database management    | Up 2 weeks           | hassio  |
| addon_core_matter_server  | homeassistant/amd64-addon-matter-server:8.1.1 | Matter protocol bridge | Up 2 weeks           | host    |
| addon_core_mariadb        | homeassistant/amd64-addon-mariadb:2.7.2       | Database backend       | Up 2 weeks           | hassio  |

**HA Storage:** All HA data under `/usr/share/hassio/` with subdirectories for homeassistant, media, share, ssl, addons, backup, dns, audio  
**HA Network:** Uses dedicated `hassio` bridge network (172.30.32.0/23) plus host network for core and Matter  
**Observer Port:** 4357 (HA system observer/health)

---

### Heimdall

**Container:** heimdall  
**Image:** linuxserver/heimdall:latest (v2.2.2-ls130)  
**Status:** Running (Up 2 weeks)  
**Network:** bridge  
**Ports:** 8080 -> 80 (HTTP), 8443 -> 443 (HTTPS)  
**Mounts:** `heimdall` volume -> `/config`  
**Purpose:** Application dashboard - unified interface for all services

---

### Bitwarden (Vaultwarden)

**Container:** bitwarden  
**Image:** vaultwarden/server:1.34.3-alpine  
**Status:** Running (Up 2 weeks, healthy)  
**Network:** bridge  
**Ports:** 8081 -> 80 (web UI), 3012 -> 3012 (WebSocket notifications)  
**Command:** `/start.sh`  
**Restart Policy:** always  
**Healthcheck:** `/healthcheck.sh` (interval 60s, timeout 10s)  
**Mounts:** `/usr/share/bitwarden` bind -> `/data`  
**Domain:** <https://bw.stevegore.io>  
**Environment:**

```text
ADMIN_TOKEN=x3lS42JV7pymWtPk14z+plBbbsIH74PL8GVYDT7s7Uxg1hOJU8aFAgki1R9SpzFJ
DOMAIN=<https://bw.stevegore.io>
ROCKET_ADDRESS=0.0.0.0
ROCKET_ENV=staging
ROCKET_PORT=80
ROCKET_PROFILE=release
ROCKET_WORKERS=10
SIGNUPS_ALLOWED=false
WEBSOCKET_ENABLED=true
```

**Purpose:** Password manager (Vaultwarden - lightweight Bitwarden-compatible server). Signups are disabled; WebSocket notifications enabled for live sync.

---

### Duplicati

**Container:** duplicati  
**Image:** duplicati/duplicati:2.0.8.1_beta_2024-05-07  
**Status:** Running (Up 2 weeks)  
**Network:** bridge  
**Port:** 8200  
**Command:** `duplicati-server --webservice-port=8200 --webservice-interface=any`  
**Mounts:**  

- `/usr/share/duplicati` bind -> `/data` (Duplicati config/database)  
- `/var/lib/docker/volumes` bind -> `/docker_vols` (read-only, backs up Docker volumes)  
- `/media` bind -> `/media` (access to M.2 SSD media)  
- `/usr/share` bind -> `/usr_share` (read-only, backs up system share data)

**Purpose:** Backup and disaster recovery utility. Has read access to all Docker volumes and media storage for comprehensive backup coverage.

---

## Networks

| Network                     | Driver | Subnet          | Project             | Purpose                                      |
| --------------------------- | ------ | --------------- | ------------------- | -------------------------------------------- |
| bridge                      | bridge | 172.17.0.0/16   | (system)            | Default Docker bridge                        |
| host                        | host   | -               | (system)            | Host network (Portainer, HA, Matter)         |
| none                        | null   | -               | (system)            | No networking                                |
| hassio                      | bridge | 172.30.32.0/23  | Home Assistant      | HA supervisor and addon communication        |
| transmission_net            | bridge | 172.29.0.0/16   | (standalone)        | Shared by transmission + sonarrradarrjackett |
| transmission_transmission   | bridge | 172.23.0.0/16   | transmission        | Internal transmission stack network          |
| sonarrradarrjackett_default | bridge | 172.18.0.0/16   | sonarrradarrjackett | Default network for arr stack                |
| photoprism_default          | bridge | 172.19.0.0/16   | photoprism          | PhotoPrism + MariaDB                         |
| huggin_default              | bridge | 172.21.0.0/16   | huggin              | Huginn services                              |
| nuraspace2_default          | bridge | 172.22.0.0/16   | nuraspace2          | NuraSpace                                    |
| plex_default                | bridge | 172.24.0.0/16   | plex                | Plex                                         |
| stevegore-au_default        | bridge | 172.25.0.0/16   | stevegore-au        | ttyd terminal                                |
| gymmaster-rest_default      | bridge | 172.26.0.0/16   | gymmaster-rest      | Gym booking                                  |
| goldenboards_default        | bridge | 172.27.0.0/16   | goldenboards        | Golden Boards                                |
| stravakeeper_default        | bridge | 172.28.0.0/16   | stravakeeper        | StravaKeeper                                 |
| stravabot-rs_default        | bridge | 192.168.16.0/20 | stravabot-rs        | Strava bot                                   |
| vault_default               | bridge | 172.31.0.0/16   | vault               | Vault                                        |
| pdf_default                 | bridge | 192.168.32.0/20 | pdf                 | Stirling PDF                                 |

**Key:** The `transmission_net` network is shared across the `transmission` and `sonarrradarrjackett` stacks, allowing Sonarr/Radarr/Jackett to route traffic through the VPN-protected Transmission container.

---

## Named Volumes

### Stack Volumes

| Volume                              | Stack               | Created    | Notes                             |
| ----------------------------------- | ------------------- | ---------- | --------------------------------- |
| plex_plex-config                    | plex                | 2021-11-27 | Plex server configuration         |
| plex_plex-temp                      | plex                | 2021-11-27 | Plex transcoding temp             |
| sonarrradarrjackett_radarr-config   | sonarrradarrjackett | 2021-10-04 | Radarr configuration              |
| sonarrradarrjackett_sonarr-config   | sonarrradarrjackett | 2021-10-04 | Sonarr configuration              |
| sonarrradarrjackett_jackett-config  | sonarrradarrjackett | 2021-10-04 | Jackett configuration             |
| owncloud_files                      | owncloud            | 2021-05-22 | OwnCloud file storage (orphaned)  |
| owncloud_mysql                      | owncloud            | 2021-05-22 | OwnCloud MariaDB data (orphaned)  |
| owncloud_redis                      | owncloud            | 2021-05-22 | OwnCloud Redis data (orphaned)    |
| vault_vault-data                    | vault               | 2023-01-04 | Vault secrets storage             |
| vault_vault-config                  | vault               | 2023-01-05 | Vault configuration               |
| huggin_mysqldata                    | huggin              | 2023-12-16 | Huginn MySQL data                 |
| stevegore-au_homedir                | stevegore-au        | 2023-07-06 | tmpfs, 500M, uid/gid 222          |
| stevegore-au_tmpdir                 | stevegore-au        | 2023-07-06 | tmpfs, 500M                       |
| pdf_stirling-pdf-config             | pdf                 | 2024-05-06 | Stirling PDF configuration        |
| transmission-wg_transmission_config | transmission-wg     | 2025-05-05 | WG Transmission config (orphaned) |
| stravabot-rs_stravabot-rs-data      | stravabot-rs        | 2026-01-26 | Strava bot progress data          |

### Standalone Volumes

| Volume         | Created    | Notes                     |
| -------------- | ---------- | ------------------------- |
| portainer_data | 2021-05-29 | Portainer data/config     |
| heimdall       | 2021-06-30 | Heimdall dashboard config |

### Legacy Volumes

| Volume                        | Created    | Notes                           |
| ----------------------------- | ---------- | ------------------------------- |
| stirling-pdf_pdf-logs         | 2024-05-06 | From older PDF deployment       |
| stirling-pdf_pdf-config       | 2024-05-06 | From older PDF deployment       |
| stravabot-rs_stravakudos-data | 2026-01-26 | From previous stravabot version |

**Note:** There are also 24 anonymous volumes (SHA256 hash names) that are likely orphaned from container recreations and could be cleaned up with `docker volume prune`.

---

## Ports in Use

| Port  | Service               | Container                         | Protocol |
| ----- | --------------------- | --------------------------------- | -------- |
| 2342  | PhotoPrism            | photoprism-photoprism-1           | TCP      |
| 3000  | Huginn                | huggin-web-1                      | TCP      |
| 3005  | Plex Companion        | plex                              | TCP      |
| 3011  | phpMyAdmin (Huginn)   | huggin-mysqladmin-1               | TCP      |
| 3012  | Vaultwarden WebSocket | bitwarden                         | TCP      |
| 3030  | Gitea (stopped)       | gitea                             | TCP      |
| 4357  | HA Observer           | hassio_observer                   | TCP      |
| 7878  | Radarr                | radarr                            | TCP      |
| 8080  | Heimdall HTTP         | heimdall                          | TCP      |
| 8081  | Vaultwarden HTTP      | bitwarden                         | TCP      |
| 8082  | Strava Bot            | stravabot-rs                      | TCP      |
| 8083  | Stirling PDF          | pdf-stirling-pdf-1                | TCP      |
| 8111  | NuraSpace             | nuraspace2-nuraspace-1            | TCP      |
| 8112  | GymBooking            | gymmaster-rest-gymbooking-1       | TCP      |
| 8180  | StravaKeeper          | stravakeeper-stravakeeper-1       | TCP      |
| 8200  | Duplicati             | duplicati                         | TCP      |
| 8202  | Vault                 | vault                             | TCP      |
| 8324  | Plex Roku             | plex                              | TCP      |
| 8443  | Heimdall HTTPS        | heimdall                          | TCP      |
| 8788  | ttyd Terminal         | stevegore-au-ttyd-1               | TCP      |
| 8844  | OwnCloud (stopped)    | owncloud_server                   | TCP      |
| 8989  | Sonarr                | sonarr                            | TCP      |
| 9092  | Transmission Proxy    | transmission-transmission-proxy-1 | TCP      |
| 9093  | Transmission WebUI    | transmission-transmission-1       | TCP      |
| 9117  | Jackett               | jackett                           | TCP      |
| 32400 | Plex Primary          | plex                              | TCP      |
| 32410 | Plex GDM              | plex                              | UDP      |
| 32412 | Plex GDM              | plex                              | UDP      |
| 32413 | Plex GDM              | plex                              | UDP      |
| 32414 | Plex GDM              | plex                              | UDP      |
| 32469 | Plex DLNA             | plex                              | TCP      |

**Host network mode** (all ports on host): Portainer, Home Assistant, hassio_multicast, addon_core_matter_server

---

## Container Health Status

| Container                   | Health  | Method                          |
| --------------------------- | ------- | ------------------------------- |
| bitwarden                   | healthy | Built-in healthcheck            |
| plex                        | healthy | Built-in healthcheck            |
| gymmaster-rest-gymbooking-1 | healthy | Built-in healthcheck            |
| transmission-transmission-1 | healthy | Built-in healthcheck (autoheal) |
| addon_a0d7b954_vscode       | healthy | Built-in healthcheck            |
| All others                  | none    | No healthcheck configured       |

---

## Bind Mount Paths

Summary of all host filesystem paths used by containers:

| Host Path                              | Container(s)                 | Purpose                                 |
| -------------------------------------- | ---------------------------- | --------------------------------------- |
| `/srv/movies`                          | radarr, plex                 | Movie library                           |
| `/srv/tv`                              | sonarr, plex                 | TV show library                         |
| `/var/lib/transmission`                | transmission, radarr, sonarr | Torrent download directory              |
| `/media/m2/photos`                     | photoprism                   | Photo originals (M.2 SSD)               |
| `/media/m2/photoprism/storage`         | photoprism                   | PhotoPrism cache/sidecar (M.2 SSD)      |
| `/media/m2/photoprism/database`        | photoprism-mariadb           | PhotoPrism MariaDB data (M.2 SSD)       |
| `/var/nura`                            | nuraspace                    | NuraSpace app data                      |
| `/var/elixr`                           | gymbooking                   | Gym booking data                        |
| `/var/goldenboards`                    | goldenboards                 | Golden Boards data                      |
| `/var/stravakeeper`                    | stravakeeper                 | StravaKeeper data                       |
| `/var/stravabot-rs/.strava-auth-token` | stravabot-rs                 | Strava OAuth token (read-only)          |
| `/usr/share/bitwarden`                 | bitwarden                    | Vaultwarden data                        |
| `/usr/share/duplicati`                 | duplicati                    | Duplicati config/database               |
| `/usr/share/hassio`                    | Home Assistant (all)         | HA Supervised root                      |
| `/var/lib/docker/volumes`              | duplicati                    | Docker volume backup source (read-only) |
| `/dev/bus/usb`                         | plex                         | USB device passthrough                  |
| `/dev/net/tun`                         | gluetun                      | TUN device for VPN                      |

---

## Custom-Built Images

These images are built locally on pico and are not available from any registry:

| Image               | Stack          | Language/Runtime    | Command                     |
| ------------------- | -------------- | ------------------- | --------------------------- |
| stravabot-rs:latest | stravabot-rs   | Rust                | `/app/stravabot`            |
| gymbooking2         | gymmaster-rest | Python (Poetry)     | `poetry run python main.py` |
| stravakeeper        | stravakeeper   | Go                  | `./main`                    |
| nuraspace           | nuraspace2     | Python (Poetry)     | `poetry run python app.py`  |
| goldenboards        | goldenboards   | Go                  | `/app/goldenboards`         |
| stevegore/ttyd      | stevegore-au   | Custom (ttyd + zsh) | `ttyd ... zsh`              |

---

## Summary

This Portainer instance manages a comprehensive home infrastructure on pico:

### Media & Entertainment

- **Plex** - Media streaming server (healthy, M.2 storage)  
- **Transmission** (OpenVPN) - Torrent downloading with Windscribe VPN (healthy)  
- **Sonarr/Radarr** - TV and movie automation via transmission_net  
- **Jackett** - Torrent indexer aggregation

### Smart Home

- **Home Assistant** - Supervised installation with Matter, MariaDB, VS Code, phpMyAdmin addons

### Cloud & Storage

- **OwnCloud** - Cloud storage (stopped, volumes retained)  
- **PhotoPrism** - Photo library with AI features, nightly auto-indexing via Chadburn  
- **Duplicati** - Backup utility with access to all Docker volumes and media

### Security & Access

- **Vaultwarden** - Password manager (healthy)  
- **Vault** - HashiCorp secrets management  
- **Heimdall** - Application dashboard

### Automation & Utilities

- **Huginn** - Workflow automation with threaded worker and phpMyAdmin  
- **Stirling PDF** - PDF manipulation and conversion

### Custom Applications

- **GymBooking** - Gym reservation system (Python, healthy)  
- **StravaKeeper** - Strava data archiver (Go)  
- **StravaBot-rs** - Strava automation (Rust)  
- **NuraSpace** - Custom application (Python)  
- **GoldenBoards** - Custom application (Go, no ports)  
- **ttyd** - Web terminal access (auto-restarts every 30 min, tmpfs storage)

**Last Updated:** 2026-01-28
