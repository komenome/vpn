# vpn

One-command installer for an **Xray VLESS + TCP + XTLS-Vision + REALITY** server on a fresh Linux VPS, with **TCP BBR** enabled.

## Quick start

SSH into the VPS as root, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/komenome/vpn/main/install.sh | bash
```

When it finishes, it prints a `vless://` link and a QR code. Import either one into your client app.

## What it does

1. Installs dependencies (`curl`, `openssl`, `qrencode`, `unzip`)
2. Installs the latest stable Xray-core with the official [XTLS/Xray-install](https://github.com/XTLS/Xray-install) script
3. Generates a new UUID, x25519 key pair and shortId
4. Writes `/usr/local/etc/xray/config.json` and checks it with `xray run -test`
5. Opens the port in `ufw` / `firewalld` if either one is active
6. Enables and starts the `xray` systemd service
7. Enables TCP BBR + `fq` (saved in `/etc/sysctl.d/99-bbr.conf`)
8. Sets the MTU of the main network interface to `1500` and keeps it after reboot (`set-mtu.service`)
9. Prints the connection details and saves them to `/root/xray-reality-info.txt`

## Defaults

| Setting     | Value                |
|-------------|----------------------|
| Protocol    | VLESS                |
| Transport   | TCP                  |
| Flow        | `xtls-rprx-vision`   |
| Security    | REALITY              |
| Port        | `443`                |
| SNI         | `dl.google.com`      |
| Dest        | `dl.google.com:443`  |
| Fingerprint | `chrome`             |

## Options

Override the defaults with environment variables placed before `bash`:

| Variable | Default            | Description                          |
|----------|--------------------|--------------------------------------|
| `PORT`   | `443`              | Listening port                       |
| `SNI`    | `dl.google.com`    | REALITY server name                  |
| `DEST`   | `$SNI:443`         | REALITY dest / target                |
| `FP`     | `chrome`           | Client uTLS fingerprint in the link  |
| `NAME`   | `<hostname>-reality` | Label at the end of the link       |
| `UUID`   | random             | Use a fixed UUID instead of a new one |
| `MTU`    | `1500`             | MTU for the main network interface   |

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/komenome/vpn/main/install.sh | PORT=8443 SNI=www.microsoft.com bash
```

## Common tasks

**Show the link again**

```bash
cat /root/xray-reality-info.txt
```

**Rotate keys** (if the link leaks). Run the installer again. It creates a new UUID and new keys, and the old link stops working. The previous config is backed up as `config.json.bak.<timestamp>`.

```bash
curl -fsSL https://raw.githubusercontent.com/komenome/vpn/main/install.sh | bash
```

**Update Xray only** (keeps the config, so the link still works)

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

**Check status / logs**

```bash
systemctl status xray
journalctl -u xray -n 50 --no-pager
```

**Uninstall**

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
```

## Clients

Any client that supports VLESS REALITY works, for example v2rayN (Windows), v2rayNG (Android), Hiddify (all platforms) and Streisand / v2Box (iOS).

One link can be shared across several devices at the same time.

## Requirements

- Debian / Ubuntu (apt) or RHEL / Rocky / Alma / CentOS (dnf / yum) with systemd
- Root access
- Port 443/tcp open. Some providers (AWS, GCP, Hetzner, etc.) also need it opened in their own firewall / security group.
- KVM or another full VM for BBR. OpenVZ / LXC containers usually cannot change the congestion control.
