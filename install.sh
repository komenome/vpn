#!/usr/bin/env bash
# Xray VLESS + TCP + XTLS-Vision + REALITY one-shot installer
#
#   curl -fsSL https://raw.githubusercontent.com/komenome/vpn/main/install.sh | bash
#
# Override defaults with env vars, e.g.:
#   curl -fsSL https://raw.githubusercontent.com/komenome/vpn/main/install.sh | PORT=8443 SNI=www.microsoft.com bash
set -euo pipefail

PORT="${PORT:-443}"
SNI="${SNI:-dl.google.com}"
DEST="${DEST:-${SNI}:443}"
FP="${FP:-chrome}"
NAME="${NAME:-$(hostname)-reality}"
UUID="${UUID:-}"
MTU="${MTU:-1500}"

CONFIG=/usr/local/etc/xray/config.json
INFO=/root/xray-reality-info.txt

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo -i first)."
command -v systemctl >/dev/null || die "systemd is required."

# ---------- packages ----------
info "Installing dependencies"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl openssl ca-certificates qrencode unzip >/dev/null
elif command -v dnf >/dev/null; then
  dnf install -y curl openssl ca-certificates qrencode unzip >/dev/null || dnf install -y curl openssl ca-certificates unzip >/dev/null
elif command -v yum >/dev/null; then
  yum install -y curl openssl ca-certificates unzip >/dev/null
  yum install -y qrencode >/dev/null 2>&1 || true
else
  die "Unsupported distro (need apt, dnf or yum)."
fi

# ---------- port check ----------
if ss -ltnH "sport = :${PORT}" 2>/dev/null | grep -q . ; then
  if ! ss -ltnpH "sport = :${PORT}" | grep -q xray; then
    die "Port ${PORT} is already in use by another program:
$(ss -ltnpH "sport = :${PORT}")"
  fi
fi

# ---------- install xray ----------
info "Installing Xray-core (XTLS/Xray-install)"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
XRAY=/usr/local/bin/xray
[[ -x $XRAY ]] || die "xray binary not found after install."
green "Installed: $($XRAY version | head -n1)"

# ---------- keys ----------
info "Generating UUID, x25519 key pair and shortId"
[[ -n $UUID ]] || UUID="$($XRAY uuid)"
KEYS="$($XRAY x25519)"
# Older xray prints "Private key:/Public key:", newer prints "PrivateKey:/Password (PublicKey):"
PRIVATE_KEY="$(awk -F': *' 'tolower($1) ~ /^private ?key/ {print $2}' <<<"$KEYS")"
PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $2}' <<<"$KEYS")"
[[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || die "Could not parse 'xray x25519' output:
$KEYS"
SHORT_ID="$(openssl rand -hex 8)"

# ---------- config ----------
info "Writing ${CONFIG}"
mkdir -p "$(dirname "$CONFIG")"
[[ -f $CONFIG ]] && cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"
cat >"$CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision", "email": "${NAME}" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF

$XRAY run -test -config "$CONFIG" >/dev/null || die "xray config test failed."

# ---------- firewall ----------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  info "Opening ${PORT}/tcp in ufw"
  ufw allow "${PORT}/tcp" >/dev/null
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  info "Opening ${PORT}/tcp in firewalld"
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

# ---------- start ----------
info "Starting xray"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; die "xray failed to start."; }

# ---------- BBR ----------
info "Enabling TCP BBR"
modprobe tcp_bbr 2>/dev/null || true
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  green "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)  qdisc: $(sysctl -n net.core.default_qdisc)"
else
  red "Kernel does not support BBR (OpenVZ/LXC or kernel < 4.9) - skipped."
fi

# ---------- MTU ----------
IFACE="$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
if [[ -n $IFACE ]]; then
  info "Setting MTU ${MTU} on ${IFACE}"
  # A oneshot unit works on every distro, whatever manages the network (ifupdown, netplan, networkd)
  cat >/etc/systemd/system/set-mtu.service <<EOF
[Unit]
Description=Set MTU ${MTU} on ${IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(command -v ip) link set dev ${IFACE} mtu ${MTU}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if systemctl enable --now set-mtu.service >/dev/null 2>&1; then
    green "MTU on ${IFACE}: $(cat "/sys/class/net/${IFACE}/mtu")"
  else
    red "Could not set MTU ${MTU} on ${IFACE} - skipped."
  fi
else
  red "No default route interface found - MTU skipped."
fi

# ---------- output ----------
SERVER_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org || curl -4 -fsS --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')"
LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NAME}"

cat >"$INFO" <<EOF
Address     : ${SERVER_IP}
Port        : ${PORT}
UUID        : ${UUID}
Flow        : xtls-rprx-vision
Network     : tcp
Security    : reality
SNI         : ${SNI}
Fingerprint : ${FP}
Public key  : ${PUBLIC_KEY}
Short ID    : ${SHORT_ID}
Private key : ${PRIVATE_KEY}   (server only - do not share)

${LINK}
EOF
chmod 600 "$INFO"

echo
green "================ Xray REALITY is ready ================"
grep -v '^Private key' "$INFO"
echo
if command -v qrencode >/dev/null; then
  qrencode -t ansiutf8 "$LINK"
fi
green "Saved to ${INFO}"
