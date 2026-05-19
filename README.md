# Xray Docker Client 🛡️

**Xray-клиент в Docker** — запускай VLESS/VMess/Trojan/Shadowsocks как SOCKS5 прокси одной командой.

```
┌──────────────┐     SOCKS5 :10808     ┌──────────────┐     VLESS/VMess/etc     ┌─────────────┐
│   Контейнер  │ ──────────────────→   │   Xray       │ ──────────────────────→  │  Сервер VPN │
│ (браузер/бот)│                      │ (этот образ)  │                         │  (удалённый) │
└──────────────┘                       └──────────────┘                         └─────────────┘
```

**Что это даёт:**
- 🔒 Шифрованный туннель до твоего сервера
- 🐳 Работает в Docker — чистое окружение
- 🔌 SOCKS5 на `:10808` — любой контейнер может подключиться
- 📦 Не требует tun/TUN-устройства и root-прав

---

## 📋 Содержание

- [Быстрый старт](#-быстрый-старт)
- [Варианты конфигурации](#-варианты-конфигурации)
  - [1. Подписка (Subscription URL)](#1-подписка-subscription-url)
  - [2. VLESS / VMess / Trojan / Shadowsocks ссылка](#2-vless--vmess--trojan--shadowsocks-ссылка)
  - [3. JSON конфиг](#3-json-конфиг)
  - [4. Base64 подписка из файла](#4-base64-подписка-из-файла)
- [Подключение контейнеров через прокси](#-подключение-контейнеров-через-прокси)
- [Переменные окружения](#-переменные-окружения)
- [Продвинутое: routing и несколько outbound](#-продвинутое-routing-и-несколько-outbound)
- [FAQ](#-faq)

---

## 🚀 Быстрый старт

```yaml
# docker-compose.yml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped
    ports:
      - "127.0.0.1:10808:10808"   # SOCKS5 (только localhost)
      - "127.0.0.1:10809:10809"   # HTTP прокси
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro
```

Положи конфиг в `./xray/config.json` (смотри раздел [Варианты конфигурации](#-варианты-конфигурации)) и запусти:

```bash
docker compose up -d
```

**Проверка:**

```bash
# Через SOCKS5
curl -x socks5://127.0.0.1:10808 ifconfig.me

# Через HTTP прокси
curl -x http://127.0.0.1:10809 ifconfig.me
```

Если вернулся IP твоего VPN-сервера — всё работает ✅

---

## ⚙️ Варианты конфигурации

### 1. Подписка (Subscription URL)

Подписка — это URL, который возвращает список серверов в формате base64 (каждая строка — VLESS/VMess/Trojan/Shadowsocks ссылка).

**Способ A — через `entrypoint.sh` (автоматическая конвертация):**

Используй наш entrypoint-скрипт, который сам скачает и распарсит подписку:

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped
    ports:
      - "127.0.0.1:10808:10808"
    environment:
      SUBSCRIPTION_URL: "https://example.com/link/your-sub?token=xxx"
      # или на выбор один из вариантов:
      # VLESS_LINK: "vless://..."
      # CONFIG_JSON: "/etc/xray/config.json"
    volumes:
      - ./xray/entrypoint.sh:/entrypoint.sh
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
```

👉 Скрипт `entrypoint.sh` (лежит в этом репозитории) делает следующее:
1. Скачивает подписку по `SUBSCRIPTION_URL`
2. Декодирует base64
3. Парсит первую VLESS/VMess/Trojan/Shadowsocks ссылку
4. Генерирует `config.json`
5. Запускает Xray с этим конфигом

### 2. VLESS / VMess / Trojan / Shadowsocks ссылка

Если у тебя есть готовая ссылка:

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped
    ports:
      - "127.0.0.1:10808:10808"
    environment:
      VLESS_LINK: "vless://your-id@example.com:443?security=reality&flow=xtls-rprx-vision&pbk=...&fp=chrome&type=tcp&headerType=none&sni=example.com#MyServer"
    volumes:
      - ./xray/entrypoint.sh:/entrypoint.sh
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
```

**Поддерживаемые протоколы в ссылках:**
- `vless://` — VLESS (включая REALITY, xtls-rprx-vision)
- `vmess://` — VMess (включая WebSocket, gRPC, TCP)
- `trojan://` — Trojan
- `ss://` — Shadowsocks
- `ssr://` — ShadowsocksR

### 3. JSON конфиг

Самый гибкий способ — подготовить `config.json` вручную или сгенерировать через конвертеры (например, [sub-web](https://github.com/CareyWang/sub-web)):

```json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 10808,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true },
      "tag": "socks"
    },
    {
      "listen": "0.0.0.0",
      "port": 10809,
      "protocol": "http",
      "tag": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "example.com",
          "port": 443,
          "users": [{
            "id": "your-uuid",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "example.com",
          "fingerprint": "chrome",
          "publicKey": "...",
          "shortId": "..."
        }
      },
      "tag": "proxy"
    }
  ]
}
```

Просто положи файл в `./xray/config.json` и используй базовый `docker-compose.yml` из [Быстрого старта](#-быстрый-старт).

**Где взять готовый JSON:**
- Конвертировать подписку: [v2rayse.com](https://v2rayse.com/) или [sub2json](https://github.com/tsaohucn/sub2json)
- Сгенерировать: [Xray Tools](https://xtls.github.io/config/) или любой конфигуратор для v2ray/xray
- Твой провайдер VPN может выдавать JSON напрямую

### 4. Base64 подписка из файла

Если подписка уже сохранена локально:

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped
    ports:
      - "127.0.0.1:10808:10808"
    volumes:
      - ./xray/subscription.txt:/subscription.txt:ro
      - ./xray/entrypoint.sh:/entrypoint.sh
    environment:
      SUBSCRIPTION_FILE: "/subscription.txt"
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
```

Файл `subscription.txt` — обычный base64-текст подписки (строка или файл).

---

## 🔗 Подключение контейнеров через прокси

### Способ 1: `network_mode: service` (рекомендуемый)

Контейнеры разделяют сетевой стек Xray:

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped
    ports:
      - "127.0.0.1:10808:10808"
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro

  my-app:
    image: alpine:latest
    network_mode: "service:xray"
    command: ash -c "apk add curl && curl -s ifconfig.me"
    depends_on:
      - xray
```

Весь трафик `my-app` идёт через Xray. Просто и надёжно.

### Способ 2: `ALL_PROXY` / `HTTP_PROXY` (для контейнеров, которые уважают прокси)

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped

  my-app:
    image: your-image
    environment:
      ALL_PROXY: "socks5://xray:10808"
      HTTP_PROXY: "http://xray:10809"
      HTTPS_PROXY: "http://xray:10809"
      NO_PROXY: "localhost,127.0.0.1,.local"
    depends_on:
      - xray
```

Подходит для:
- `curl`, `wget`, `git`
- `python` requests/httpx
- `node.js` fetch/axios
- `go` с `HTTP_PROXY`
- `gradle`, `npm`, `pip`

### Способ 3: docker-прокси в стиле `redsocks` (весь трафик контейнера)

Самый агрессивный способ — перенаправлять **весь** TCP трафик через прокси, включая приложения, которые не читают `HTTP_PROXY`. Понадобится `redsocks` или `iptables` в контейнере:

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped
    ports:
      - "127.0.0.1:10808:10808"
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro

  my-app:
    image: alpine:latest
    cap_add:
      - NET_ADMIN
    command: >
      sh -c "
        apk add redsocks iptables &&
        # redsocks.conf — перенаправляет весь TCP на SOCKS5
        cat > /etc/redsocks.conf << 'EOF'
        base {
          log_debug = off;
          log_info = on;
          daemon = off;
          redirector = iptables;
        }
        redsocks {
          local_ip = 127.0.0.1;
          local_port = 12345;
          ip = xray;
          port = 10808;
          type = socks5;
        }
        EOF
        # Iptables правила
        iptables -t nat -N REDSOCKS
        iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
        iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
        iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
        iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
        iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
        iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
        iptables -t nat -A REDSOCKS -d 224.0.0.0/4 -j RETURN
        iptables -t nat -A REDSOCKS -d 240.0.0.0/4 -j RETURN
        iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
        iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
        redsocks -c /etc/redsocks.conf
      "
```

**Важно:** требует `cap_add: NET_ADMIN` и работает только с TCP.

---

## 🔧 Переменные окружения

| Переменная | Описание | Пример |
|---|---|---|
| `SUBSCRIPTION_URL` | URL подписки (base64) | `https://example.com/sub?token=xxx` |
| `SUBSCRIPTION_FILE` | Путь к файлу подписки внутри контейнера | `/subscription.txt` |
| `VLESS_LINK` | VLESS ссылка | `vless://...` |
| `VMESS_LINK` | VMess ссылка | `vmess://...` |
| `TROJAN_LINK` | Trojan ссылка | `trojan://...` |
| `SS_LINK` | Shadowsocks ссылка | `ss://...` |
| `CONFIG_JSON` | Путь к JSON конфигу (по умолч. `/etc/xray/config.json`) | `/etc/xray/config.json` |
| `PROXY_PORT_SOCKS` | Порт SOCKS5 (по умолч. `10808`) | `10808` |
| `PROXY_PORT_HTTP` | Порт HTTP прокси (по умолч. `10809`) | `10809` |
| `SELECT_INDEX` | Выбор сервера из подписки (0 — первый, omit — все) | `0` или `1` |

**Приоритет (что используется, если указано несколько):**
1. `CONFIG_JSON` (явный путь к файлу)
2. `SUBSCRIPTION_URL` или `SUBSCRIPTION_FILE`
3. `VLESS_LINK` / `VMESS_LINK` / `TROJAN_LINK` / `SS_LINK`

---

## 🧩 Продвинутое: routing и несколько outbound

Xray может маршрутизировать разные домены через разные серверы. Пример конфига с двумя outbound:

```json
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 10808,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true },
      "tag": "socks-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": { "vnext": [{ "address": "us.example.com", "port": 443, "users": [{"id": "xxx", "encryption": "none"}] }] },
      "tag": "us-proxy"
    },
    {
      "protocol": "vless",
      "settings": { "vnext": [{ "address": "de.example.com", "port": 443, "users": [{"id": "xxx", "encryption": "none"}] }] },
      "tag": "de-proxy"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "direct", "domain": ["geosite:google-scholar", "geosite:category-scholar-!cn"] },
      { "type": "field", "outboundTag": "us-proxy", "domain": ["geosite:netflix", "geosite:hbo"] },
      { "type": "field", "outboundTag": "de-proxy", "domain": ["geosite:youtube", "geosite:twitter"] },
      { "type": "field", "outboundTag": "us-proxy", "network": "tcp,udp" }
    ]
  }
}
```

**Полезные geosite теги:** `netflix`, `youtube`, `twitter`, `facebook`, `google`, `telegram`, `github`, `microsoft`, `apple`, `speedtest`, `category-ads`.

---

## ❓ FAQ

**Q: Нужны ли root-права для запуска?**
A: Нет. Xray в режиме SOCKS5 не требует привилегий. TUN-режим — да, но он опционален.

**Q: Как обновить подписку без пересборки?**
A: Перезапусти контейнер: `docker compose restart`. Если используешь entrypoint.sh, он скачает свежую подписку.

**Q: Xray не запускается, пишет "failed to listen"**
A: Порт 10808 занят. Поменяй `PROXY_PORT_SOCKS` или останови другой процесс.

**Q: Работает ли UDP (например, для DNS)?**
A: Да, SOCKS5 inbound включён с `"udp": true`. Для UDP через прокси нужна поддержка на стороне клиента.

**Q: Можно ли использовать с браузером?**
A: Да. Настрой SOCKS5 прокси `127.0.0.1:10808` в браузере (FoxyProxy, SwitchyOmega или системные настройки).

**Q: Что делать, если подписка в формате JSON, а не base64?**
A: Положи JSON прямо в `config.json` — entrypoint пропустит конвертацию, если видит валидный JSON.

**Q: Антивирус/файрвол блокирует?**
A: Если порты закрыты — смени порт в `docker-compose.yml` (например, `10808` → `443` или `30000`).

---

## 📄 Лицензия

MIT. Делай что хочешь.
