#!/bin/sh
# Xray Docker Client — entrypoint.sh
# Автоматически генерирует config.json из подписки, VLESS/VMess/Trojan/SS ссылки
# или использует готовый JSON конфиг.
set -e

CONFIG_PATH="${CONFIG_JSON:-/etc/xray/config.json}"
PROXY_PORT_SOCKS="${PROXY_PORT_SOCKS:-10808}"
PROXY_PORT_HTTP="${PROXY_PORT_HTTP:-10809}"
SELECT_INDEX="${SELECT_INDEX:-0}"

log() { echo "[entrypoint] $*"; }
die() { log "FATAL: $*"; exit 1; }

# ─── Приоритет 1: готовый JSON файл ─────────────────────────────────

if [ -n "$CONFIG_JSON" ] && [ -f "$CONFIG_JSON" ]; then
    log "Использую готовый JSON конфиг: $CONFIG_JSON"
    exec xray run -config "$CONFIG_JSON"
fi

if [ -f /etc/xray/config.json ]; then
    log "Найден /etc/xray/config.json, использую его"
    exec xray run -config /etc/xray/config.json
fi

# ─── Приоритет 2: подписка (URL или файл) ────────────────────────────

SUBSCRIPTION_CONTENT=""

if [ -n "$SUBSCRIPTION_URL" ]; then
    log "Скачиваю подписку: $SUBSCRIPTION_URL"
    SUBSCRIPTION_CONTENT=$(curl -sSL --connect-timeout 15 "$SUBSCRIPTION_URL") || die "Не удалось скачать подписку"
fi

if [ -n "$SUBSCRIPTION_FILE" ] && [ -f "$SUBSCRIPTION_FILE" ]; then
    log "Читаю подписку из файла: $SUBSCRIPTION_FILE"
    SUBSCRIPTION_CONTENT=$(cat "$SUBSCRIPTION_FILE")
fi

if [ -n "$SUBSCRIPTION_CONTENT" ]; then
    # Подписка обычно в base64 — пробуем декодировать
    LINKS=""
    # Проверяем, похоже ли на base64
    if echo "$SUBSCRIPTION_CONTENT" | head -c 100 | grep -qE '^[A-Za-z0-9+/=]+$'; then
        log "Декодирую base64 подписку..."
        DECODED=$(echo "$SUBSCRIPTION_CONTENT" | base64 -d 2>/dev/null || echo "$SUBSCRIPTION_CONTENT")
    else
        DECODED="$SUBSCRIPTION_CONTENT"
    fi

    # Извлекаем ссылки построчно
    LINKS=$(echo "$DECODED" | grep -oE '(vless|vmess|trojan|ss|ssr)://[^ ]+' || true)
    if [ -z "$LINKS" ]; then
        # Может вся строка — одна ссылка
        LINKS=$(echo "$DECODED" | grep -oE '(vless|vmess|trojan|ss|ssr)://[^ ]+' || true)
    fi

    LINK=$(echo "$LINKS" | sed -n "$((SELECT_INDEX + 1))p")
    if [ -z "$LINK" ]; then
        LINK=$(echo "$LINKS" | head -1)
    fi

    if [ -z "$LINK" ]; then
        die "Не найдено ни одной ссылки в подписке"
    fi

    log "Выбран сервер #$((SELECT_INDEX + 1)) из подписки"
    PROTOCOL=$(echo "$LINK" | sed 's|://.*||')
    # Убираем фрагмент (#...) для парсинга
    LINK_BARE=$(echo "$LINK" | sed 's/#.*//')

    case "$PROTOCOL" in
        vless)  generate_vless "$LINK_BARE" "$LINK" ;;
        vmess)  generate_vmess "$LINK_BARE" "$LINK" ;;
        trojan) generate_trojan "$LINK_BARE" "$LINK" ;;
        ss)     generate_ss "$LINK_BARE" "$LINK" ;;
        ssr)    generate_ssr "$LINK_BARE" "$LINK" ;;
        *)      die "Неподдерживаемый протокол: $PROTOCOL" ;;
    esac
    exec xray run -config "$CONFIG_PATH"
fi

# ─── Приоритет 3: VLESS/VMess/Trojan/SS ссылка ─────────────────────────

LINK=""

for var in VLESS_LINK VMESS_LINK TROJAN_LINK SS_LINK; do
    eval "val=\$$var"
    if [ -n "$val" ]; then
        LINK="$val"
        break
    fi
done

if [ -n "$LINK" ]; then
    log "Использую ссылку из переменной окружения"
    PROTOCOL=$(echo "$LINK" | sed 's|://.*||')
    LINK_BARE=$(echo "$LINK" | sed 's/#.*//')

    case "$PROTOCOL" in
        vless)  generate_vless "$LINK_BARE" "$LINK" ;;
        vmess)  generate_vmess "$LINK_BARE" "$LINK" ;;
        trojan) generate_trojan "$LINK_BARE" "$LINK" ;;
        ss)     generate_ss "$LINK_BARE" "$LINK" ;;
        *)      die "Неподдерживаемый протокол: $PROTOCOL" ;;
    esac
    exec xray run -config "$CONFIG_PATH"
fi

# ─── Ничего не задано ─────────────────────────────────────────────────

die "Не указан ни один источник конфигурации.
Задай одну из переменных:
  SUBSCRIPTION_URL  — URL подписки
  SUBSCRIPTION_FILE — путь к файлу подписки
  VLESS_LINK        — VLESS ссылка
  VMESS_LINK        — VMess ссылка
  TROJAN_LINK       — Trojan ссылка
  SS_LINK           — Shadowsocks ссылка
  CONFIG_JSON       — путь к готовому JSON конфигу
Либо смонтируй config.json в /etc/xray/config.json"

# ═══════════════════════════════════════════════════════════════════════════
# Генераторы конфигов
# ═══════════════════════════════════════════════════════════════════════════

generate_vless() {
    LINK_BARE="$1"
    LINK_FULL="$2"

    # Парсим VLESS: vless://uuid@host:port?params#name
    # Удаляем протокол
    WITHOUT_PROTO=$(echo "$LINK_BARE" | sed 's|^vless://||')
    # Разделяем на user@host:port и query
    USERPART=$(echo "$WITHOUT_PROTO" | cut -d'?' -f1)
    QUERY=$(echo "$WITHOUT_PROTO" | cut -d'?' -f2-)
    UUID=$(echo "$USERPART" | cut -d'@' -f1)
    HOSTPORT=$(echo "$USERPART" | cut -d'@' -f2-)
    ADDRESS=$(echo "$HOSTPORT" | rev | cut -d':' -f2- | rev)
    PORT=$(echo "$HOSTPORT" | rev | cut -d':' -f1 | rev)

    # Парсим query параметры
    ENCRYPTION=$(parse_query "$QUERY" "encryption" "none")
    FLOW=$(parse_query "$QUERY" "flow" "")
    SECURITY=$(parse_query "$QUERY" "security" "none")
    TYPE=$(parse_query "$QUERY" "type" "tcp")
    HEADER_TYPE=$(parse_query "$QUERY" "headerType" "none")
    SNI=$(parse_query "$QUERY" "sni" "")
    PBK=$(parse_query "$QUERY" "pbk" "")
    SID=$(parse_query "$QUERY" "sid" "")
    SPX=$(parse_query "$QUERY" "spx" "")
    FP=$(parse_query "$QUERY" "fp" "chrome")
    PATH_VAL=$(parse_query "$QUERY" "path" "")
    HOST=$(parse_query "$QUERY" "host" "")
    SERVICE_NAME=$(parse_query "$QUERY" "serviceName" "")
    MODE=$(parse_query "$QUERY" "mode" "multi")

    # Имя из фрагмента
    NAME=$(echo "$LINK_FULL" | grep -o '#.*' | sed 's/^#//' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "")

    # Собираем JSON
    jq -n \
      --arg address "$ADDRESS" \
      --arg port "$PORT" \
      --arg uuid "$UUID" \
      --arg encryption "$ENCRYPTION" \
      --arg flow "$FLOW" \
      --arg security "$SECURITY" \
      --arg type "$TYPE" \
      --arg headerType "$HEADER_TYPE" \
      --arg sni "$SNI" \
      --arg pbk "$PBK" \
      --arg sid "$SID" \
      --arg spx "$SPX" \
      --arg fp "$FP" \
      --arg path "$PATH_VAL" \
      --arg host "$HOST" \
      --arg serviceName "$SERVICE_NAME" \
      --arg mode "$MODE" \
      --arg socks_port "$PROXY_PORT_SOCKS" \
      --arg http_port "$PROXY_PORT_HTTP" \
      --arg name "$NAME" \
      '{
        log: { loglevel: "warning" },
        inbounds: [
          {
            listen: "0.0.0.0",
            port: ($socks_port | tonumber),
            protocol: "socks",
            settings: { auth: "noauth", udp: true },
            tag: "socks"
          },
          {
            listen: "0.0.0.0",
            port: ($http_port | tonumber),
            protocol: "http",
            tag: "http"
          }
        ],
        outbounds: [
          {
            protocol: "vless",
            settings: {
              vnext: [
                {
                  address: $address,
                  port: ($port | tonumber),
                  users: [
                    {
                      id: $uuid,
                      encryption: $encryption,
                      flow: $flow
                    }
                  ]
                }
              ]
            },
            streamSettings: ({
              network: $type,
              security: $security
            } + 
            (if $type == "tcp" then {
              tcpSettings: { header: { type: $headerType } }
            } else {} end) +
            (if $type == "ws" then {
              wsSettings: {
                path: $path,
                headers: (if $host != "" then { Host: $host } else {} end)
              }
            } else {} end) +
            (if $type == "grpc" then {
              grpcSettings: {
                serviceName: $serviceName,
                multiMode: ($mode == "multi")
              }
            } else {} end) +
            (if $security == "reality" then {
              realitySettings: {
                serverName: $sni,
                fingerprint: $fp,
                publicKey: $pbk,
                shortId: $sid,
                spiderX: $spx
              }
            } else {} end) +
            (if $security == "tls" then {
              tlsSettings: {
                serverName: ($sni // $host // $address),
                fingerprint: $fp,
                alpn: ["h2", "http/1.1"]
              }
            } else {} end)
            )
          } // {tag: "proxy"}
        ]
      }' > "$CONFIG_PATH" 2>/dev/null || die "Ошибка генерации VLESS конфига"

    log "Сгенерирован VLESS конфиг: $ADDRESS:$PORT ($NAME)"
}

generate_vmess() {
    LINK_BARE="$1"
    LINK_FULL="$2"
    # VMess ссылки бывают двух видов:
    # 1. vmess://base64-encoded-json
    # 2. vmess://uuid@host:port?params  (редко)

    BASE64PART=$(echo "$LINK_BARE" | sed 's|^vmess://||')

    # Пробуем декодировать как base64 (JSON)
    JSON=$(echo "$BASE64PART" | base64 -d 2>/dev/null || echo "")

    if [ -n "$JSON" ] && echo "$JSON" | jq . >/dev/null 2>&1; then
        # Формат 1: base64 JSON
        ADDRESS=$(echo "$JSON" | jq -r '.add // .host // ""')
        PORT=$(echo "$JSON" | jq -r '.port // ""')
        UUID=$(echo "$JSON" | jq -r '.id // ""')
        AID=$(echo "$JSON" | jq -r '.aid // .alterId // "0"')
        SECURITY=$(echo "$JSON" | jq -r '.scy // .security // "auto"')
        TYPE=$(echo "$JSON" | jq -r '.net // .network // "tcp"')
        HEADER_TYPE=$(echo "$JSON" | jq -r '.type // "none"')
        PATH_VAL=$(echo "$JSON" | jq -r '.path // ""')
        HOST=$(echo "$JSON" | jq -r '.host // ""')
        SNI=$(echo "$JSON" | jq -r '.sni // .host // ""')
        TLS=$(echo "$JSON" | jq -r '.tls // ""')
        FP=$(echo "$JSON" | jq -r '.fp // "chrome"')
        SERVICE_NAME=$(echo "$JSON" | jq -r '.serviceName // .grpc // ""')
        MODE=$(echo "$JSON" | jq -r '.mode // "multi"')
        NAME=$(echo "$JSON" | jq -r '.ps // .remark // .name // ""')
        SECURITY_VAL="none"
        [ "$TLS" = "tls" ] && SECURITY_VAL="tls"

        jq -n \
          --arg address "$ADDRESS" \
          --arg port "$PORT" \
          --arg uuid "$UUID" \
          --arg aid "$AID" \
          --arg security "$SECURITY_VAL" \
          --arg type "$TYPE" \
          --arg headerType "$HEADER_TYPE" \
          --arg path "$PATH_VAL" \
          --arg host "$HOST" \
          --arg sni "$SNI" \
          --arg fp "$FP" \
          --arg serviceName "$SERVICE_NAME" \
          --arg mode "$MODE" \
          --arg socks_port "$PROXY_PORT_SOCKS" \
          --arg http_port "$PROXY_PORT_HTTP" \
          --arg name "$NAME" \
          '{
            log: { loglevel: "warning" },
            inbounds: [
              {
                listen: "0.0.0.0",
                port: ($socks_port | tonumber),
                protocol: "socks",
                settings: { auth: "noauth", udp: true },
                tag: "socks"
              },
              {
                listen: "0.0.0.0",
                port: ($http_port | tonumber),
                protocol: "http",
                tag: "http"
              }
            ],
            outbounds: [
              {
                protocol: "vmess",
                settings: {
                  vnext: [
                    {
                      address: $address,
                      port: ($port | tonumber),
                      users: [
                        {
                          id: $uuid,
                          alterId: ($aid | tonumber),
                          security: "auto"
                        }
                      ]
                    }
                  ]
                },
                streamSettings: ({
                  network: $type,
                  security: $security
                } + 
                (if $type == "ws" then {
                  wsSettings: {
                    path: $path,
                    headers: (if $host != "" then { Host: $host } else {} end)
                  }
                } else {} end) +
                (if $type == "grpc" then {
                  grpcSettings: {
                    serviceName: $serviceName,
                    multiMode: ($mode == "multi")
                  }
                } else {} end) +
                (if $type == "tcp" and $headerType != "none" then {
                  tcpSettings: { header: { type: $headerType } }
                } else {} end) +
                (if $security == "tls" then {
                  tlsSettings: {
                    serverName: ($sni // $host // $address),
                    fingerprint: $fp,
                    alpn: ["h2", "http/1.1"]
                  }
                } else {} end)
                )
              } // {tag: "proxy"}
            ]
          }' > "$CONFIG_PATH" 2>/dev/null || die "Ошибка генерации VMess конфига"

        log "Сгенерирован VMess конфиг: $ADDRESS:$PORT ($NAME)"
    else
        # Формат 2: vmess://uuid@host:port?params (редкий)
        WITHOUT_PROTO=$(echo "$LINK_BARE" | sed 's|^vmess://||')
        USERPART=$(echo "$WITHOUT_PROTO" | cut -d'?' -f1)
        QUERY=$(echo "$WITHOUT_PROTO" | cut -d'?' -f2-)
        UUID=$(echo "$USERPART" | cut -d'@' -f1)
        HOSTPORT=$(echo "$USERPART" | cut -d'@' -f2-)
        ADDRESS=$(echo "$HOSTPORT" | rev | cut -d':' -f2- | rev)
        PORT=$(echo "$HOSTPORT" | rev | cut -d':' -f1 | rev)

        jq -n \
          --arg address "$ADDRESS" \
          --arg port "$PORT" \
          --arg uuid "$UUID" \
          --arg socks_port "$PROXY_PORT_SOCKS" \
          --arg http_port "$PROXY_PORT_HTTP" \
          '{
            log: { loglevel: "warning" },
            inbounds: [
              {
                listen: "0.0.0.0",
                port: ($socks_port | tonumber),
                protocol: "socks",
                settings: { auth: "noauth", udp: true },
                tag: "socks"
              },
              {
                listen: "0.0.0.0",
                port: ($http_port | tonumber),
                protocol: "http",
                tag: "http"
              }
            ],
            outbounds: [
              {
                protocol: "vmess",
                settings: {
                  vnext: [
                    {
                      address: $address,
                      port: ($port | tonumber),
                      users: [{ id: $uuid, security: "auto" }]
                    }
                  ]
                },
                streamSettings: { network: "tcp" }
              } // {tag: "proxy"}
            ]
          }' > "$CONFIG_PATH" 2>/dev/null || die "Ошибка генерации VMess конфига"

        log "Сгенерирован VMess конфиг: $ADDRESS:$PORT"
    fi
}

generate_trojan() {
    LINK_BARE="$1"
    LINK_FULL="$2"
    # trojan://password@host:port?security=tls&sni=...&fp=...#Name
    WITHOUT_PROTO=$(echo "$LINK_BARE" | sed 's|^trojan://||')
    USERPART=$(echo "$WITHOUT_PROTO" | cut -d'?' -f1)
    QUERY=$(echo "$WITHOUT_PROTO" | cut -d'?' -f2-)
    PASSWORD=$(echo "$USERPART" | cut -d'@' -f1)
    HOSTPORT=$(echo "$USERPART" | cut -d'@' -f2-)
    ADDRESS=$(echo "$HOSTPORT" | rev | cut -d':' -f2- | rev)
    PORT=$(echo "$HOSTPORT" | rev | cut -d':' -f1 | rev)

    SNI=$(parse_query "$QUERY" "sni" "$ADDRESS")
    FP=$(parse_query "$QUERY" "fp" "chrome")
    SECURITY="tls"
    NAME=$(echo "$LINK_FULL" | grep -o '#.*' | sed 's/^#//' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "")

    jq -n \
      --arg address "$ADDRESS" \
      --arg port "$PORT" \
      --arg password "$PASSWORD" \
      --arg sni "$SNI" \
      --arg fp "$FP" \
      --arg socks_port "$PROXY_PORT_SOCKS" \
      --arg http_port "$PROXY_PORT_HTTP" \
      --arg name "$NAME" \
      '{
        log: { loglevel: "warning" },
        inbounds: [
          {
            listen: "0.0.0.0",
            port: ($socks_port | tonumber),
            protocol: "socks",
            settings: { auth: "noauth", udp: true },
            tag: "socks"
          },
          {
            listen: "0.0.0.0",
            port: ($http_port | tonumber),
            protocol: "http",
            tag: "http"
          }
        ],
        outbounds: [
          {
            protocol: "trojan",
            settings: {
              servers: [
                {
                  address: $address,
                  port: ($port | tonumber),
                  password: $password
                }
              ]
            },
            streamSettings: {
              network: "tcp",
              security: "tls",
              tlsSettings: {
                serverName: $sni,
                fingerprint: $fp,
                alpn: ["h2", "http/1.1"]
              }
            }
          } // {tag: "proxy"}
        ]
      }' > "$CONFIG_PATH" 2>/dev/null || die "Ошибка генерации Trojan конфига"

    log "Сгенерирован Trojan конфиг: $ADDRESS:$PORT ($NAME)"
}

generate_ss() {
    LINK_BARE="$1"
    LINK_FULL="$2"
    # ss://method:password@host:port#Name  или ss://base64(method:password)@host:port?plugin=...&...  или ss://base64(method:password@host:port)#Name
    WITHOUT_PROTO=$(echo "$LINK_BARE" | sed 's|^ss://||')
    
    # Пробуем разные форматы
    if echo "$WITHOUT_PROTO" | grep -q '@'; then
        # Формат method:password@host:port
        USERPASS=$(echo "$WITHOUT_PROTO" | cut -d'@' -f1)
        HOSTPORT=$(echo "$WITHOUT_PROTO" | cut -d'@' -f2-)
        ADDRESS=$(echo "$HOSTPORT" | rev | cut -d':' -f2- | rev)
        PORT=$(echo "$HOSTPORT" | rev | cut -d':' -f1 | rev)
        METHOD=$(echo "$USERPASS" | cut -d':' -f1)
        PASSWORD=$(echo "$USERPASS" | cut -d':' -f2-)
    else
        # Формат base64(method:password@host:port) — вся строка base64
        DECODED=$(echo "$WITHOUT_PROTO" | base64 -d 2>/dev/null || echo "")
        if [ -n "$DECODED" ]; then
            USERPASS=$(echo "$DECODED" | cut -d'@' -f1)
            HOSTPORT=$(echo "$DECODED" | cut -d'@' -f2-)
            ADDRESS=$(echo "$HOSTPORT" | rev | cut -d':' -f2- | rev)
            PORT=$(echo "$HOSTPORT" | rev | cut -d':' -f1 | rev)
            METHOD=$(echo "$USERPASS" | cut -d':' -f1)
            PASSWORD=$(echo "$USERPASS" | cut -d':' -f2-)
        else
            die "Не удалось распарсить Shadowsocks ссылку"
        fi
    fi

    NAME=$(echo "$LINK_FULL" | grep -o '#.*' | sed 's/^#//' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "")

    jq -n \
      --arg address "$ADDRESS" \
      --arg port "$PORT" \
      --arg method "$METHOD" \
      --arg password "$PASSWORD" \
      --arg socks_port "$PROXY_PORT_SOCKS" \
      --arg http_port "$PROXY_PORT_HTTP" \
      --arg name "$NAME" \
      '{
        log: { loglevel: "warning" },
        inbounds: [
          {
            listen: "0.0.0.0",
            port: ($socks_port | tonumber),
            protocol: "socks",
            settings: { auth: "noauth", udp: true },
            tag: "socks"
          },
          {
            listen: "0.0.0.0",
            port: ($http_port | tonumber),
            protocol: "http",
            tag: "http"
          }
        ],
        outbounds: [
          {
            protocol: "shadowsocks",
            settings: {
              servers: [
                {
                  address: $address,
                  port: ($port | tonumber),
                  method: $method,
                  password: $password
                }
              ]
            }
          } // {tag: "proxy"}
        ]
      }' > "$CONFIG_PATH" 2>/dev/null || die "Ошибка генерации Shadowsocks конфига"

    log "Сгенерирован Shadowsocks конфиг: $ADDRESS:$PORT ($NAME)"
}

generate_ssr() {
    # SSR — сложный формат, базовая поддержка
    LINK_BARE="$1"
    LINK_FULL="$2"
    log "ПРЕДУПРЕЖДЕНИЕ: ShadowsocksR имеет ограниченную поддержку"
    
    WITHOUT_PROTO=$(echo "$LINK_BARE" | sed 's|^ssr://||')
    DECODED=$(echo "$WITHOUT_PROTO" | base64 -d 2>/dev/null || echo "$WITHOUT_PROTO")
    
    # ssr://base64(host:port:protocol:method:obfs:base64pass/?params)
    # Базовая обработка
    PARTS=$(echo "$DECODED" | sed 's|/?.*||')
    ADDRESS=$(echo "$PARTS" | cut -d':' -f1)
    PORT=$(echo "$PARTS" | cut -d':' -f2)
    # Для SSR лучше использовать готовый JSON конфиг
    die "SSR ссылки требуют готового JSON конфига. Используй CONFIG_JSON."
}

parse_query() {
    QUERY="$1"
    KEY="$2"
    DEFAULT="$3"
    # Извлекаем значение параметра из query string
    echo "$QUERY" | tr '&' '\n' | grep "^$KEY=" | sed "s/^$KEY=//" | head -1 | python3 -c "
import sys, urllib.parse
val = sys.stdin.read().strip()
if val:
    print(urllib.parse.unquote(val))
else:
    print('$DEFAULT')
" 2>/dev/null || echo "$DEFAULT"
}
