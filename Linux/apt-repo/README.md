# Halltone LAN apt repo

The Ubuntu sender (`halltone-linux`) is installed and upgraded from a self-hosted apt repo on the
LAN, in a Debian 12 container on Proxmox (CT 114, hostname `apt`, DNS `apt.localdomain`).
Everything on that container is built by `server/setup.sh` from this directory.

```
GitHub release linux-v*            desktop (Ubuntu)
  halltone-linux_*.deb, SHA256SUMS   install-halltone.sh  ──fetches──►  http://apt.localdomain/install-halltone.sh
        │ every 15 min                    │ apt                          (+ .asc signature, self-updates)
        ▼                                 ▼
  halltone-repo-sync ──reprepro──►  /srv/apt/halltone  ◄── nginx :80 ──► /halltone/…      apt repo (signed, suite "stable")
  (user repo, verifies SHA256SUMS)                                       /install-halltone.sh, .asc, .desktop
                                                                         /halltone-logs/<kind>  ──► halltone-logrx 127.0.0.1:8082
                                                                              ▲ POST with X-Halltone-Log-Token
                                                                              │ (installer run logs, 5-min service log shipping)
                                                                     /var/log/halltone-clients/<host>/<kind>-YYYY-MM-DD.log
```

| Piece | Where on the server |
|---|---|
| reprepro repo (suite `stable`, arches amd64 arm64 i386 armhf) | `/srv/apt/halltone` (conf in `conf/`, denied by nginx) |
| Signing key, user `repo`, no passphrase | `/var/lib/repo/.gnupg` |
| Public key served to clients | `/srv/apt/halltone/halltone-archive-keyring.{gpg,asc}` |
| Importer + timer | `/usr/local/bin/halltone-repo-sync`, `halltone-repo-sync.timer` |
| Log receiver | `/usr/local/bin/halltone-logrx`, `halltone-logrx.service` (user `halltonelog`) |
| Log token (shared secret) | `/etc/halltone-logrx/token` (root:halltonelog 0640) |
| Installer template, launcher, publisher | `/usr/local/share/halltone/`, `/usr/local/bin/halltone-publish-installer` |
| Published installer | `/srv/apt/install-halltone.sh`, `.asc`, `install-halltone.desktop` |
| nginx site | `/etc/nginx/sites-available/apt` |

Files here: `server/setup.sh` (the one script), `server/halltone-repo-sync`, `server/halltone-logrx`,
`server/halltone-publish-installer`, `server/systemd/*`, `server/nginx/apt.conf`,
`server/install-halltone.desktop`, `test/*` (CI). The installer itself is `../install-halltone.sh`.

## Deploying / updating (existing server)

On CT 114 as root, with a checkout of this repo (clone it, or `git pull` the existing one):

```bash
git clone https://github.com/cmortuus/halltone.git /root/halltone   # first time; later: git -C /root/halltone pull
/root/halltone/Linux/apt-repo/server/setup.sh
```

`setup.sh` is idempotent. It installs packages, keeps the existing signing key and token, rewrites
config only where it differs, restarts a service only when its files changed, republishes the
installer (token substituted from `/etc/halltone-logrx/token`), and prints the key fingerprint.
It warns loudly if that fingerprint differs from the one pinned in `install-halltone.sh`.
Run it again after every change to anything in `Linux/apt-repo/` or `Linux/install-halltone.sh`.

Check: `curl -s http://apt.localdomain/install-halltone.sh | grep ^LOG_TOKEN` (shows the real token, not
the placeholder), `systemctl is-active nginx halltone-logrx halltone-repo-sync.timer`.

## Rebuilding the container from scratch (Proxmox)

1. Create the container (adjust storage, bridge and IP; Debian 12 template via `pveam`):

   ```bash
   pct create 114 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
     --hostname apt --cores 1 --memory 512 --swap 256 \
     --rootfs local-lvm:8 --net0 name=eth0,bridge=vmbr0,ip=dhcp \
     --unprivileged 1 --onboot 1 --features nesting=1
   pct start 114
   ```
   Give it a DHCP reservation / static lease, and make `apt.localdomain` resolve to it on the LAN.
2. **Restore the signing key before the first `setup.sh`** (next section). If you skip this,
   `setup.sh` generates a new key and every client's pinned fingerprint stops matching.
3. `pct exec 114 -- bash -c 'apt-get update && apt-get install -y git ca-certificates'`, then clone
   the repo inside and run `Linux/apt-repo/server/setup.sh` as above.
4. A **new log token** is generated on a fresh server and substituted into the published installer.
   Clients pick it up on their next installer run (self-update). Old copies keep logging with the old token
   (rejected, harmless) until then.
5. The release importer re-downloads every `linux-v*` release (state files are gone), so the repo repopulates itself
   within ~15 minutes, or run `runuser -u repo -- /usr/local/bin/halltone-repo-sync`.

## Backing up the signing key

The key lives only on the server. Clients pin its fingerprint (`FINGERPRINT` in `install-halltone.sh`),
so losing it means every client must be re-bootstrapped. Back up the keyring directory off the container
(it has no passphrase: treat the backup like a secret and keep it out of git):

```bash
pct exec 114 -- tar -C /var/lib/repo -czf - .gnupg > halltone-apt-gnupg-backup.tar.gz   # on the Proxmox host
chmod 600 halltone-apt-gnupg-backup.tar.gz   # then move it somewhere safe (password manager / encrypted disk)
```

Restore on a fresh container, before running `setup.sh`:

```bash
id repo >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/repo --shell /usr/sbin/nologin repo
tar -C /var/lib/repo -xzf halltone-apt-gnupg-backup.tar.gz && chown -R repo:repo /var/lib/repo/.gnupg && chmod 700 /var/lib/repo/.gnupg
```

If the key must change (compromise, expiry; it is valid 10 years from creation): generate a new one,
change `FINGERPRINT` in `Linux/install-halltone.sh`, rerun `setup.sh` (it republishes), and have each
client run the installer *once with the new fingerprint*. The old installer will refuse the new key
and self-update is signature-checked against the pinned key too, so clients need a fresh copy of
the installer by hand (e.g. the `.desktop` launcher, which fetches the latest every time, then `HALLTONE_FINGERPRINT=<new>`
once if the old pinned value blocks it).

## Client installer and self-update

Desktop users run `install-halltone.sh` (never with sudo). It:

* refuses root, checks the served key against the pinned fingerprint, writes a deb822 source pinned to the dpkg
  architecture, `apt-get install`s `halltone-linux`, sets up the user service, tray, and a 5-minute log shipper;
* uploads its own run log (`kind=install`) on exit, success or failure;
* **self-updates**: first it fetches `/install-halltone.sh` and `.asc` from the server, verifies the detached
  signature against the pinned-fingerprint key, and, if the published copy differs, replaces its own file with it
  and re-runs it (`HALLTONE_SELF_UPDATED=1` guards against loops). A git checkout (placeholder token) is never overwritten.
  On any failure it continues with the copy it has.

Fresh machines: download `http://apt.localdomain/install-halltone.desktop` (double-click launcher), or
`curl -fsSL http://apt.localdomain/install-halltone.sh | bash`.

The signature means a LAN attacker who can answer for `apt.localdomain` cannot feed clients code through
self-update without the repo key. (A first-time `curl | bash` bootstrap is plain HTTP and trusts the LAN.)
Note the token is visible to anyone on the LAN who fetches the installer: it only gates log uploads
(5 MB each, 200 MB per host).

Test-only overrides: `HALLTONE_SERVER` (default `http://apt.localdomain`), `HALLTONE_FINGERPRINT`.

## Reading client logs

On the server, `/var/log/halltone-clients/<hostname>/<kind>-YYYY-MM-DD.log`, kinds `install` (installer runs)
and `service` (halltone service journal, every 5 min):

```bash
ls /var/log/halltone-clients/
tail -n 100 /var/log/halltone-clients/<host>/install-$(date +%F).log
tail -f /var/log/halltone-clients/<host>/service-$(date +%F).log
journalctl -u halltone-logrx -n 50      # receiver itself (rejects show up here)
```

## CI

`.github/workflows/apt-repo.yml`: shellcheck of every script; `setup.sh` run twice in a Debian 12 container
(snapshot diff proves idempotency) with nginx, the log receiver, the signed installer and the release importer
(fake GitHub releases, including a bad checksum) exercised; and the installer run in a clean Ubuntu 24.04
container against a throwaway reprepro repo (stub `halltone-linux` .debs): install, self-update, upgrade, not-root guard,
wrong fingerprint, bad signature, loop guard. `systemctl --user` parts are skipped there with a message.
