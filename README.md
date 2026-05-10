# vless-setup

One-shot bash script: fresh Linux server → working VLESS+Reality VPN with web panel.

## Usage

SSH into a fresh **Debian 12+** or **Ubuntu 22+/24+** box as root, then:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/shushakov-usa/vless-setup/main/setup.sh)
```

You'll be prompted for:

- Admin username / password / panel base path / panel port (sensible random defaults)
- Number of clients to create + their names
- Your SSH public key(s) — paste, Ctrl-D when done
- Pick from the top-5 auto-detected Reality SNIs (or type your own)
- Y/N for the optional dotfiles + AI-CLIs bundle

The script writes a full summary to `/root/vless-setup-output.txt` (panel URL, admin creds, all client UUIDs, vless:// links, subscription URLs).

## What it does

1. **Pre-flight**: checks distro, root, public IP, country
2. **Idempotency**: if Marzban is already installed → menu (skip / add-clients-only / wipe)
3. **Prompts**: panel security + initial client list + SSH keys
4. **Port check**: aborts if `:443` or panel port is taken
5. **SNI selection** (hybrid):
   - Downloads `RealiTLScanner` and scans the server's `/24` neighbor range
   - Filters by: TLS 1.3, h2 ALPN, GEO matches server's country, cert issuer is a major CDN (Cloudflare/MS/Apple/Amazon/Akamai/Google/Fastly)
   - Probes each candidate for handshake latency
   - Shows top 5, you pick (or type a custom one)
   - Falls back to a curated CDN-edge SNI list if scan finds nothing
6. **Self-signed cert** for the panel (CN = server IP, valid 10y)
7. **Marzban install** via the official installer (`marzban.sh @ install`)
8. **Config**: writes `/opt/marzban/.env` + `xray_config.json` with the Reality inbound
9. **Reality keys**: generates fresh x25519 keypair + 8 short IDs per server (never reused)
10. **Clients**: creates each via Marzban's HTTP API; collects subscription URLs
11. **Firewall**: detects ufw/firewalld; if neither active, installs+enables UFW with rules for SSH/443/panel-port
12. **SSH hardening**: disables password auth + installs fail2ban (only if `authorized_keys` is non-empty)
13. **Optional extras (Y/N)**: zsh+oh-my-zsh, vim, tmux, htop, ripgrep/fd/bat/fzf, nvm+Node LTS, Codex CLI, Claude Code, Copilot CLI

## What it doesn't do (intentional)

- **No real domain / Let's Encrypt cert** — self-signed is the simplest path with no domain. Browser warns once. (Future: optional `--domain` flag.)
- **No mldsa65 / post-quantum** — would constrain SNI choice to RSA-cert sites only. Old clients ignore it; current threat model doesn't justify it. Skip in v1.
- **No SSH port change** — preserves `:22` for muscle memory. fail2ban handles brute-force noise.
- **No QR codes** — keeps the script free of `qrencode` dependency. Use the vless:// link in your client.
- **No multi-distro support beyond Debian/Ubuntu** — adds complexity for marginal value.

## Re-run behavior

If `/opt/marzban/.env` exists, the script offers:

1. Skip & exit
2. Add more clients only (preserves keys)
3. Wipe & reinstall (typed `WIPE` confirmation; regenerates ALL keys, breaks old clients)

## Output file

`/root/vless-setup-output.txt` (mode 600) — keep it; it has the admin password.

## Troubleshooting

- **API didn't come up within 60s**: `marzban logs` to inspect; usually a port conflict or bad cert path.
- **vless:// link doesn't work**: check the SNI is reachable from the client's network; some SNIs that pass the install-time probe can be DPI-blocked from specific client regions later.
- **Locked out of SSH after hardening**: boot into rescue mode and revert `/etc/ssh/sshd_config.vless-setup.bak`.
