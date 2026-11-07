#!/usr/bin/env bash
# vipin — установщик VPN: VLESS + TCP + REALITY (Vision), схема self-steal.
# На сервер ставятся Xray, nginx с сайтом-заглушкой и сертификат Let's Encrypt
# для вашего домена. REALITY маскируется под этот сайт, клиенты получают
# Happ-подписку, ссылку vless:// и QR-код.
#
# Использование (от root, Ubuntu 20.04+/Debian 11+):
#   bash <(curl -fsSL https://raw.githubusercontent.com/WasiliyMalyshev/vipin/main/install.sh)
#   bash install.sh                  установка (спросит домен и пользователей)
#   bash install.sh add <имя>        добавить пользователя
#   bash install.sh del <имя>        удалить пользователя
#   bash install.sh show [имя]       показать ссылки и QR (всех или одного)
#   bash install.sh list             список пользователей
#
# Перед установкой: A-запись домена должна указывать на IP сервера
# (в Cloudflare — режим "DNS only", без оранжевого облака).

set -euo pipefail
trap 'echo -e "\e[31m[x]\e[0m Ошибка в строке $LINENO: $BASH_COMMAND (код $?)" >&2' ERR

STATE_DIR=/etc/vipin
STATE_ENV=$STATE_DIR/server.env
USERS_DB=$STATE_DIR/users.db          # строки: имя uuid shortId token
OUT_DIR=/root/vipin-clients
SITE_ROOT=/var/www/vipin-site
SUB_DIR=/var/www/vipin-sub
XRAY_CFG=/usr/local/etc/xray/config.json
BACKEND_PORT=8443
SELF_URL=${VIPIN_URL:-https://raw.githubusercontent.com/WasiliyMalyshev/vipin/main/install.sh}

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
info() { echo "${c_g}==>${c_0} $*"; }
warn() { echo "${c_y}[!]${c_0} $*"; }
die()  { echo "${c_r}[x]${c_0} $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"; }

valid_name() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }

load_state() {
  [[ -f $STATE_ENV ]] || die "Сервер ещё не установлен. Запустите: bash $0"
  # shellcheck disable=SC1090
  source "$STATE_ENV"
}

# ---------------------------------------------------------------- генерация

gen_shortid() { openssl rand -hex 8; }
gen_token()   { openssl rand -hex 12; }

gen_keys() {
  local out
  out=$(xray x25519)
  PRIV=$(awk -F': ' '/^Private ?[Kk]ey/ {print $2}' <<<"$out")
  PUB=$(awk -F': ' '/^Public ?[Kk]ey|^Password/ && !f {print $2; f=1}' <<<"$out")
  [[ -n $PRIV && -n $PUB ]] || die "Не удалось разобрать вывод 'xray x25519':\n$out"
}

write_server_config() {
  local clients="" sids="" name uuid sid tok
  while read -r name uuid sid tok; do
    [[ -z ${name:-} ]] && continue
    clients+="${clients:+,}
          { \"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\", \"email\": \"$name\" }"
    sids+="${sids:+, }\"$sid\""
  done < "$USERS_DB"
  [[ -z $sids ]] && sids='""'

  cat > "$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [$clients
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:$BACKEND_PORT",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIV",
          "shortIds": [$sids]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
  xray run -test -c "$XRAY_CFG" >/dev/null || die "Xray отклонил конфиг $XRAY_CFG"
  systemctl restart xray
}

client_json() { # name uuid sid
  cat <<EOF
{
  "remarks": "$PROFILE_TITLE $1",
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["1.1.1.1", "1.0.0.1"], "queryStrategy": "UseIP" },
  "inbounds": [
    { "tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
      "settings": { "udp": true, "auth": "noauth" },
      "sniffing": { "enabled": true, "routeOnly": false, "destOverride": ["http", "tls", "quic"] } },
    { "tag": "http", "port": 10809, "listen": "127.0.0.1", "protocol": "http",
      "settings": { "allowTransparent": false },
      "sniffing": { "enabled": true, "routeOnly": false, "destOverride": ["http", "tls", "quic"] } }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$DOMAIN",
          "port": 443,
          "users": [{ "id": "$2", "encryption": "none", "flow": "xtls-rprx-vision" }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$DOMAIN",
          "fingerprint": "firefox",
          "publicKey": "$PUB",
          "shortId": "$3"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "domainMatcher": "hybrid",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:category-ru", "domain:yandex.com", "domain:yandex.net",
          "regexp:.*\\\\.ru\$", "regexp:.*\\\\.su\$", "regexp:.*\\\\.xn--p1ai\$"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:ru"], "outboundTag": "direct" }
    ]
  }
}
EOF
}

vless_link() { # name uuid sid
  echo "vless://$2@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=firefox&pbk=$PUB&sid=$3&type=tcp#$PROFILE_TITLE-$1"
}

write_client_files() {
  mkdir -p "$OUT_DIR" "$SUB_DIR"
  rm -f "$SUB_DIR"/*.json
  local name uuid sid tok
  while read -r name uuid sid tok; do
    [[ -z ${name:-} ]] && continue
    client_json "$name" "$uuid" "$sid" > "$OUT_DIR/$name.json"
    { echo "["; cat "$OUT_DIR/$name.json"; echo "]"; } > "$SUB_DIR/$tok.json"
    vless_link "$name" "$uuid" "$sid" > "$OUT_DIR/$name.txt"
    echo "https://$DOMAIN/s/$tok" > "$OUT_DIR/$name-subscription.txt"
    qrencode -s 10 -o "$OUT_DIR/$name-subscription.png" "https://$DOMAIN/s/$tok"
    qrencode -s 8  -o "$OUT_DIR/$name-link.png" "$(cat "$OUT_DIR/$name.txt")"
  done < "$USERS_DB"
  chmod 644 "$SUB_DIR"/*.json 2>/dev/null || true
  chmod 700 "$OUT_DIR"
}

apply() { write_server_config; write_client_files; }

show_user() { # name
  local line name uuid sid tok
  line=$(awk -v n="$1" '$1==n' "$USERS_DB")
  [[ -n $line ]] || die "Нет пользователя '$1'"
  read -r name uuid sid tok <<<"$line"
  echo
  echo "${c_b}━━━━━━━━━━━━━━━━━━━━━━━━  $name  ━━━━━━━━━━━━━━━━━━━━━━━━${c_0}"
  echo "${c_b}Подписка для Happ${c_0} (рекомендуется: обновляется сама, включает фрагментацию):"
  echo "  https://$DOMAIN/s/$tok"
  qrencode -t ansiutf8 -m 2 "https://$DOMAIN/s/$tok"
  echo "${c_b}Ссылка vless://${c_0} (если подписка не загружается):"
  echo "  $(vless_link "$name" "$uuid" "$sid")"
  echo "Файлы: $OUT_DIR/$name.{json,txt} и QR-картинки $OUT_DIR/$name-*.png"
}

show_all() { local n; for n in $(awk '{print $1}' "$USERS_DB"); do show_user "$n"; done; }

add_user() { # name
  valid_name "$1" || die "Имя '$1' недопустимо: только латиница, цифры, - и _"
  if awk -v n="$1" '$1==n {f=1} END {exit !f}' "$USERS_DB"; then die "Пользователь '$1' уже есть"; fi
  echo "$1 $(xray uuid) $(gen_shortid) $(gen_token)" >> "$USERS_DB"
}

# ---------------------------------------------------------------- установка

public_ip() {
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
    || ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

write_site() {
  mkdir -p "$SITE_ROOT"
  cat > "$SITE_ROOT/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MicroCalc — simple online calculator</title>
<meta name="description" content="A tiny, fast online calculator. No ads, no tracking.">
<style>
  :root{--bg:#f4f5f7;--card:#fff;--fg:#1d2330;--key:#eceef2;--op:#3b6cf6;--muted:#7a8193}
  @media (prefers-color-scheme:dark){:root{--bg:#12141a;--card:#1b1e26;--fg:#e8eaf0;--key:#262a35;--op:#5b84ff;--muted:#8a90a2}}
  *{box-sizing:border-box}body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;background:var(--bg);color:var(--fg);font:16px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
  h1{font-size:20px;font-weight:600;margin:0 0 16px}.calc{background:var(--card);padding:18px;border-radius:18px;box-shadow:0 8px 30px rgba(0,0,0,.08);width:min(320px,92vw)}
  #d{width:100%;font-size:32px;text-align:right;border:0;background:transparent;color:var(--fg);padding:8px 4px 16px;outline:0}
  .g{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}button{font:inherit;font-size:20px;padding:14px 0;border:0;border-radius:12px;background:var(--key);color:var(--fg);cursor:pointer}
  button.o{background:var(--op);color:#fff}button.w{grid-column:span 2}footer{margin-top:18px;color:var(--muted);font-size:13px}
</style>
</head>
<body>
<h1>MicroCalc</h1>
<div class="calc"><input id="d" value="0" readonly aria-label="display"><div class="g" id="k"></div></div>
<footer>&copy; MicroCalc &middot; No ads, no tracking.</footer>
<script>
const keys=["C","(",")","/","7","8","9","*","4","5","6","-","1","2","3","+","0",".","="];
const d=document.getElementById("d"),k=document.getElementById("k");let s="";
keys.forEach(x=>{const b=document.createElement("button");b.textContent=x;if("/*-+=".includes(x))b.className="o";if(x==="0")b.className="w";
b.onclick=()=>{if(x==="C")s="";else if(x==="="){try{s=String(Function("return ("+(s||"0")+")")())}catch(e){s="Error"}}else{if(s==="Error")s="";s+=x}d.value=s||"0"};k.appendChild(b)});
</script>
</body>
</html>
EOF
  printf 'User-agent: *\nAllow: /\n' > "$SITE_ROOT/robots.txt"
}

write_nginx_http() {
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/vipin-http <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $SITE_ROOT; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  ln -sf /etc/nginx/sites-available/vipin-http /etc/nginx/sites-enabled/vipin-http
  nginx -t >/dev/null 2>&1 || { nginx -t; die "Ошибка в конфиге nginx"; }
  systemctl restart nginx
}

write_nginx_tls() {
  local title_b64
  title_b64=$(printf '%s' "$PROFILE_TITLE" | base64 -w0)
  cat > /etc/nginx/sites-available/vipin-tls <<EOF
server {
    listen 127.0.0.1:$BACKEND_PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=31536000" always;

    root $SITE_ROOT;
    index index.html;

    # Happ-подписки
    location ~ "^/s/([a-f0-9]{24})\$" {
        alias $SUB_DIR/\$1.json;
        default_type application/json;
        add_header profile-title "base64:$title_b64" always;
        add_header profile-update-interval "12" always;
        add_header fragmentation-enable "1" always;
        add_header fragmentation-packets "1-3" always;
        add_header fragmentation-length "50-100" always;
        add_header fragmentation-interval "10-20" always;
        add_header Cache-Control "no-store" always;
    }

    location / { try_files \$uri \$uri/ =404; }
}
EOF
  ln -sf /etc/nginx/sites-available/vipin-tls /etc/nginx/sites-enabled/vipin-tls
  nginx -t >/dev/null 2>&1 || { nginx -t; die "Ошибка в конфиге nginx"; }
  systemctl reload nginx
}

do_install() {
  need_root
  [[ -f /etc/os-release ]] && . /etc/os-release
  [[ ${ID:-} =~ ^(ubuntu|debian)$ || ${ID_LIKE:-} =~ debian ]] || die "Поддерживаются только Ubuntu и Debian"

  if [[ -f $STATE_ENV ]]; then
    warn "vipin уже установлен на этом сервере ($STATE_ENV)."
    warn "Повторная установка создаст НОВЫЕ ключи, и старые подписки перестанут работать."
    warn "Чтобы добавить пользователя: bash $0 add <имя>; показать ссылки: bash $0 show"
    read -rp "Переустановить с нуля? [y/N] " a; [[ $a =~ ^[Yy]$ ]] || exit 0
  fi

  echo "${c_b}vipin — установка VPN (VLESS + REALITY, self-steal)${c_0}"
  echo
  read -rp "Домен (A-запись уже указывает на этот сервер), например vpn.example.com: " DOMAIN
  DOMAIN=$(tr 'A-Z' 'a-z' <<<"${DOMAIN// /}")
  [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "Это не похоже на домен: '$DOMAIN'"

  read -rp "Пользователи через пробел [laptop phone]: " USERS_IN
  USERS_IN=${USERS_IN:-laptop phone}
  for u in $USERS_IN; do valid_name "$u" || die "Имя '$u' недопустимо: только латиница, цифры, - и _"; done

  read -rp "Название профиля в Happ [VPN]: " PROFILE_TITLE
  PROFILE_TITLE=${PROFILE_TITLE:-VPN}
  PROFILE_TITLE=${PROFILE_TITLE//[^a-zA-Z0-9_-]/}
  [[ -n $PROFILE_TITLE ]] || PROFILE_TITLE=VPN

  read -rp "E-mail для Let's Encrypt (можно пусто): " LE_EMAIL

  info "Устанавливаю пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl unzip ufw nginx certbot qrencode openssl dnsutils ca-certificates >/dev/null

  info "Проверяю DNS"
  local myip dnsip
  myip=$(public_ip)
  dnsip=$(dig +short A "$DOMAIN" @1.1.1.1 | grep -E '^[0-9.]+$' | tail -1 || true)
  echo "    IP сервера: $myip, $DOMAIN -> ${dnsip:-<нет записи>}"
  if [[ $dnsip != "$myip" ]]; then
    warn "Домен не указывает на этот сервер. Сертификат не выпустится."
    warn "Создайте A-запись $DOMAIN -> $myip (в Cloudflare: DNS only) и подождите пару минут."
    read -rp "Всё равно продолжить? [y/N] " a; [[ $a =~ ^[Yy]$ ]] || exit 1
  fi

  info "Устанавливаю Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
  # без "| head": head закрывает канал раньше, xray получает SIGPIPE (141), и set -e обрывает скрипт
  xray version | sed -n 1p

  info "Файрвол: открываю 22, 80, 443"
  local sshport
  sshport=$(sshd -T 2>/dev/null | awk '/^port / && !p {p=$2} END {print p}' || true); sshport=${sshport:-22}
  ufw allow "$sshport"/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null

  info "BBR"
  grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || \
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.ipv4.tcp_mtu_probing=1\n' >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true

  info "Сайт-заглушка и nginx"
  write_site
  write_nginx_http

  info "Получаю сертификат Let's Encrypt для $DOMAIN"
  local le_mail=(--register-unsafely-without-email)
  [[ -n $LE_EMAIL ]] && le_mail=(-m "$LE_EMAIL")
  certbot certonly --webroot -w "$SITE_ROOT" -d "$DOMAIN" --non-interactive --agree-tos "${le_mail[@]}" --keep-until-expiring >/dev/null \
    || die "Не удалось получить сертификат. Проверьте A-запись и что порт 80 открыт у хостера."
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/vipin-reload-nginx.sh
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/vipin-reload-nginx.sh

  write_nginx_tls

  info "Генерирую ключи и пользователей"
  gen_keys
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  cat > "$STATE_ENV" <<EOF
DOMAIN='$DOMAIN'
PRIV='$PRIV'
PUB='$PUB'
PROFILE_TITLE='$PROFILE_TITLE'
EOF
  chmod 600 "$STATE_ENV"
  : > "$USERS_DB"; chmod 600 "$USERS_DB"
  for u in $USERS_IN; do add_user "$u"; done

  apply
  # При запуске через bash <(curl ...) файла скрипта на диске нет: скачиваем себя
  if [[ -f $0 ]]; then
    install -m 755 "$(readlink -f "$0")" /usr/local/bin/vipin
  else
    curl -fsSL "$SELF_URL" -o /usr/local/bin/vipin && chmod 755 /usr/local/bin/vipin \
      || warn "Не удалось установить команду vipin"
  fi

  info "Проверяю работу"
  sleep 1
  systemctl is-active --quiet xray  || die "Xray не запустился: journalctl -u xray -n 50"
  systemctl is-active --quiet nginx || die "nginx не запустился: journalctl -u nginx -n 50"
  curl -fsS --max-time 10 -o /dev/null --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" \
    && echo "    https://$DOMAIN отвечает сайтом-заглушкой через REALITY: OK" \
    || warn "Сайт через порт 443 не ответил, проверьте: journalctl -u xray -n 50"

  show_all
  echo
  info "Готово. Дальше на этом сервере можно использовать команду vipin:"
  echo "    vipin add <имя> | vipin del <имя> | vipin show [имя] | vipin list"
}

# ---------------------------------------------------------------- команды

cmd=${1:-install}
case $cmd in
  install) do_install ;;
  add)
    need_root; load_state; [[ -n ${2:-} ]] || die "Укажите имя: $0 add <имя>"
    add_user "$2"; apply; show_user "$2" ;;
  del|delete|rm)
    need_root; load_state; [[ -n ${2:-} ]] || die "Укажите имя: $0 del <имя>"
    awk -v n="$2" '$1==n {f=1} END {exit !f}' "$USERS_DB" || die "Нет пользователя '$2'"
    awk -v n="$2" '$1!=n' "$USERS_DB" > "$USERS_DB.tmp" && mv "$USERS_DB.tmp" "$USERS_DB"
    rm -f "$OUT_DIR/$2".* "$OUT_DIR/$2"-*
    apply; info "Пользователь '$2' удалён, его ключ больше не работает" ;;
  show)
    need_root; load_state
    if [[ -n ${2:-} ]]; then show_user "$2"; else show_all; fi ;;
  list)
    need_root; load_state; awk '{print $1}' "$USERS_DB" ;;
  -h|--help|help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" ;;
  *) die "Неизвестная команда '$cmd'. Справка: $0 help" ;;
esac
