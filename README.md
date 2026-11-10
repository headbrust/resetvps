# resetvps

Analyze a Debian/Ubuntu VPS, then strip it back to near-factory state.

## What it does

1. **Analyze** — disk usage, packages, services, users, docker, large dirs → written to `/var/log/resetvps-*.log`
2. **Stop** heavy services (nginx, mysql, docker, etc.)
3. **Wipe** user homes, `/var/www`, `/opt/*`, docker data, custom folders
4. **Purge** packages: desktop, panels, web/db stacks, docker, snap, node, php…
5. **Clean** logs, apt cache, journal, tmp, bash history
6. **Clear** cron and extra systemd units
7. **Keep SSH** running so you stay connected

Result: base OS packages only, no extra users, no sites, no containers. Closest you can get to “brand new” without a full provider reinstall / DD.

## Requirements

- Root
- Debian or Ubuntu
- Backup anything you care about first

## Important — repo is private

`raw.githubusercontent.com` returns **404** while the repo is private.

**Fix:** GitHub → `headbrust/resetvps` → **Settings** → **General** → **Danger Zone** → **Change repository visibility** → **Public**.

Or clone with auth:
```bash
git clone https://github.com/headbrust/resetvps.git
cd resetvps && sudo ./resetvps.sh
```

## Usage

```bash
# after making the repo public:
curl -fsSL https://raw.githubusercontent.com/headbrust/resetvps/main/resetvps.sh -o resetvps.sh
chmod +x resetvps.sh

# dry-run first (recommended)
sudo ./resetvps.sh --dry-run

# real run — type RESET when asked
sudo ./resetvps.sh
```

After it finishes:

```bash
reboot
apt update && apt upgrade -y
```

## Safety

- Requires typing `RESET` before any destructive action
- Does **not** disable SSH
- Does **not** wipe the entire disk (no `dd`)
- For a true zero image use your hoster’s **Reinstall OS** button or a network reinstall script

## Scope

| Kept | Removed |
|------|---------|
| Base system packages | Desktop / GUI |
| SSH | nginx / apache / mysql / postgres / redis / mongo |
| Kernel | Docker + all images/volumes |
| Network config | All uid ≥ 1000 users + homes |
| | `/var/www`, `/opt/*`, most of `/usr/local` |
| | Logs, caches, cron, custom systemd units |

## License

MIT — use at your own risk.
