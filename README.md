# OpenBot homelab

OpenBot v1.0.2 on a dedicated Ubuntu VM. Compose runs the web UI/API, pgvector PostgreSQL, migrations, a routine worker, the Docker supervisor and a managed LangGraph agent. The supervisor starts browser computers on demand. Image pins come from the [OpenBot release manifest](https://github.com/CopilotKit/OpenBot/releases/tag/v1.0.2).

GitHub-hosted Actions validates PRs and deploys protected `main` over Tailscale. The public repository has no self-hosted runner. The deployment SSH key can only request the current `main` commit. A root-owned command fetches it from GitHub and deploys under a host lock. Merging to main grants code execution on this VM.

## Create openbot-vm

1. Download [Ubuntu Server 26.04.1 amd64](https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.iso). Verify it against Ubuntu's signed checksums. In Proxmox, select the ISO storage → **ISO Images → Upload**.
2. Select **Create VM**. Set the name to `openbot-vm` and choose the ISO. Set machine **q35**, BIOS **OVMF (UEFI)**, add an EFI disk, and keep Secure Boot enabled with pre-enrolled keys. Use **VirtIO SCSI single**, a 60 GB SCSI disk, four cores with CPU type **host**, 8192 MiB RAM and a **VirtIO** NIC on the existing LAN bridge. Enable **QEMU Guest Agent**. Enable **Start at boot** under VM Options and put it after `homelab-docker` if both are on the same node.
3. Install Ubuntu with hostname `openbot-vm`, the 60 GB guest disk, an admin account, and **Install OpenSSH server**. Import your SSH public key and test it from a second terminal. Reserve the VM address in DHCP. Keep the Proxmox console open when changing SSH or firewall rules.
4. Run on the new VM:

   ```sh
   sudo apt update
   sudo apt upgrade
   sudo apt install ca-certificates curl git jq openssl qemu-guest-agent unattended-upgrades nftables restic
   sudo systemctl enable --now qemu-guest-agent
   sudo dpkg-reconfigure -plow unattended-upgrades
   hostnamectl
   ip -br addr
   free -h
   df -h /
   ```

   Check the guest IP appears in Proxmox **VM → Summary**. Install Docker Engine and the Compose plugin from the [official Ubuntu apt instructions](https://docs.docker.com/engine/install/ubuntu/#install-using-the-apt-repository). Verify `sudo docker run --rm hello-world` and `docker compose version`. This stack uses Compose 2.33.1+ for gateway priority.

## Bootstrap the VM

After the repository has an initial `main`, run these from an admin session. Apply firewall changes only after reviewing your LAN and keeping console access.

```sh
sudo install -d -m 0700 /opt/openbot /etc/openbot /var/backups/openbot
sudo git clone https://github.com/halvorot/homelab-openbot.git /opt/openbot/repo
sudo install -m 0700 /opt/openbot/repo/ops/deploy-from-github /usr/local/sbin/openbot-deploy-from-github
sudo install -m 0755 /opt/openbot/repo/ops/ssh-deploy /usr/local/bin/openbot-ssh-deploy
sudo install -m 0440 /opt/openbot/repo/ops/openbot-deploy.sudoers /etc/sudoers.d/openbot-deploy
sudo visudo -cf /etc/sudoers
sudo adduser --disabled-password --gecos '' openbot-deploy
sudo install -d -o openbot-deploy -g openbot-deploy -m 0700 /home/openbot-deploy/.ssh
sudo install -o openbot-deploy -g openbot-deploy -m 0600 /dev/null /home/openbot-deploy/.ssh/authorized_keys
sudoedit /home/openbot-deploy/.ssh/authorized_keys
```

Generate a dedicated Ed25519 deploy key on your workstation. Place only its public key in that account's `authorized_keys`, prefixed with `restrict `. Keep the private key for the GitHub environment. Install the SSH drop-ins after verifying that your admin key works. Verify the effective settings with `sshd -T` and `sshd -T -C user=openbot-deploy,host=openbot-vm,addr=100.64.0.1`.

```sh
sudo install -m 0644 /opt/openbot/repo/ops/{10-openbot-ssh,90-openbot-deploy}.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl reload ssh
sudo install -m 0600 /opt/openbot/repo/ops/openbot-firewall.nft /etc/openbot/firewall.nft
sudo nft -c -f /etc/openbot/firewall.nft
sudo install -m 0644 /opt/openbot/repo/ops/openbot-firewall.service /etc/systemd/system/
sudo install -D -m 0644 /opt/openbot/repo/ops/docker.service.d/openbot-firewall.conf \
  /etc/systemd/system/docker.service.d/openbot-firewall.conf
sudo systemctl daemon-reload
sudo systemctl enable --now openbot-firewall
sudo nft list table inet openbot_filter
```

The guest firewall filters the published TCP port 3010 before Docker translates it. The LAN allow rule matches Caddy at `192.168.1.200` and OpenBot at `192.168.1.250` on `ens18`. Reserve both addresses and check the interface name before installing the rules. This port-specific rule can be used with the Proxmox datacenter firewall disabled. If Proxmox filtering is active, allow the same Caddy source there and preserve SSH and DHCP access. Leave VM-wide outbound available for system updates, Tailscale, model APIs and Intelligence. The guest firewall blocks computer traffic to the host and private ranges. Add any locally routed public subnets to the blocked set. Explicitly test denied destinations including Proxmox, Hermes, n8n, both Docker engines, host gateway, tailnet peers and metadata IP. Verify the computer can still open a public HTTPS site.

## Runtime secrets

```sh
sudo install -m 0600 /opt/openbot/repo/.env.example /etc/openbot/runtime.env
sudoedit /etc/openbot/runtime.env
```

Set `OPENBOT_BIND_IP` to the reserved LAN IP after ingress filtering is in place. Before then, leave it at loopback. Generate a fresh `openssl rand -hex 32` per password or token field. Use `openssl rand -base64 32` for `KEY_ENCRYPTION_KEY`. Use hex for PostgreSQL because its password goes into a connection URI. Keep generated values out of shell arguments, chat and Git. Compose env files accept single-quoted values for keys containing dollar signs.

- Create a separate Google **Web application** OAuth client for OpenBot. Register `https://openbot.halvorteigen.no/api/auth/callback/google`. Fill the Google client ID and secret and set `INITIAL_ADMIN_EMAILS` to the approved Google identity. Set an allowed domain only for a domain you intend to admit. Cloudflare Access must enforce the exact email allowlist for consumer Gmail.
- Enter the CopilotKit Intelligence API URL, gateway WebSocket URL and project key from the intended Intelligence project. The OpenBot server proxies the browser's gateway WebSocket on the application origin.
- Set `BOT_PROVIDER` and its matching model API key. Choose a model available to your account or leave `BOT_MODEL` empty for the upstream default. For an OpenAI-compatible gateway such as 9Router, set `BOT_PROVIDER=openai`, `OPENAI_BASE_URL` to the gateway API base ending in `/v1`, `OPENAI_API_KEY` to a gateway key, and `BOT_MODEL` to the exact gateway model ID. Use HTTPS for a remote gateway.
- Preserve the key encryption key with every backup. Rotate OAuth and provider credentials at their providers and redeploy. Rotate shared runtime tokens on both sides together via the runtime file and redeploy. For PostgreSQL change the existing role password in PostgreSQL during a maintenance window, then update the runtime file. Changing the Compose variable alone affects only initial database creation. Treat encryption-key changes as recovery-sensitive and follow upstream migration tooling before replacing it.

## GitHub and Tailscale

1. In GitHub **Settings → Rules → Rulesets**, protect `main` against deletion and force pushes. Require pull requests and the **Compose, shell and secret scan** check after its first completed run. Require an independent approval if a second reviewer is available. GitHub cannot count the author's own approval.
2. Create **Settings → Environments → production**. Set deployment branches to **Selected branches**, add the **branch** `main` only. Keep secrets scoped here. If independent approval is unavailable, use an explicit manual merge after CI and consider an environment reviewer as a separate deployment gate if one is available.
3. Install Tailscale on the VM using the [Ubuntu instructions](https://tailscale.com/download/linux). Enroll the VM tagged `tag:openbot-vm`. Keep Tailscale SSH off for this host so OpenSSH enforces the forced command. Advertise no routes. In the tailnet policy grant `tag:openbot-ci` access to `tag:openbot-vm` on TCP 22 only. Check that no existing wildcard grant widens this permission.
4. Create a [Tailscale OAuth client](https://tailscale.com/docs/integrations/github/github-action?tab=oauth+client) scoped to `tag:openbot-ci` for ephemeral CI devices. In the GitHub environment set `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `OPENBOT_DEPLOY_KEY` and `OPENBOT_KNOWN_HOSTS`. Set environment variable `OPENBOT_DEPLOY_HOST` to the VM's tailnet DNS name. Build the known-hosts line from that exact hostname and the public host key from `/etc/ssh/ssh_host_ed25519_key.pub` read through the Proxmox console or an already trusted admin SSH session.
5. Run **Deploy OpenBot** manually on main for the first deploy. Verify the Actions result, then on the VM run `sudo bash -c 'source /opt/openbot/repo/scripts/common.sh; compose ps -a; compose logs --tail 10 worker'`. Look for successful migration, healthy services, and a fresh `routine-sweep` log.
6. Install the [Mend Renovate GitHub App](https://github.com/apps/renovate) for this repo. Merge the onboarding PR after CI. Renovate groups the four OpenBot images. Validation checks every digest against the same official manifest, so a partial update fails. If registry tags and the manifest disagree, run `scripts/sync-images.sh vX.Y.Z` on the update PR and retry validation. Update PostgreSQL only within 17. Schedule any major database upgrade separately.

## Existing homelab integrations

- **Ingress.** Create a Cloudflare Access self-hosted app for the entire hostname, using Google and an exact-email allow policy. Add the public hostname to the existing tunnel, origin `http://caddy:80`. Enable **Protect with Access** and select the app audience. After approval, apply [the Caddy example](ops/Caddyfile.example) in `homelab-docker`, replacing the LAN IP. Caddy handles WebSockets and SSE. Verify an incognito request redirects to Access, Google sign-in works inside OpenBot, and the browser can stream a bot response and open its live session. Confirm the LAN listener refuses a non-Caddy source.
- **Dockhand.** Use [Hawser Standard](https://github.com/Finsys/hawser) on the OpenBot VM, pinned by digest. Bind TLS to its LAN IP and restrict TCP 2376 to the Dockhand host at Proxmox. Configure a unique token through `TOKEN_FILE`, verify the certificate with the issuing CA in Dockhand, and add the environment under **Settings → Environments**. Confirm container visibility, logs, health and a manual restart. Hawser's Docker access is root-equivalent. Keep Git deployment and auto-updates disabled in Dockhand.
- **Beszel.** Add a system to the existing hub. Install the matching [Beszel agent](https://beszel.dev/guide/agent-installation) on this VM. Restrict TCP 45876 to the hub or use the agent-initiated HTTPS transport. Verify CPU, RAM, disk and containers report.
- **Uptime Kuma.** From the existing monitor, use an Access service token scoped to a dedicated hostname/path policy and probe `https://openbot.halvorteigen.no/health`. Match a healthy JSON response so a login page fails the check. Use a harmless scheduled OpenBot routine with a private Kuma Push monitor and existing notifications to exercise worker, supervisor and agent together. Treat the Push URL as a secret and constrain the routine's permissions.

## Isolation and operations

Mark each bot **Isolated** in OpenBot. Other bots from one person can share a supervisor-managed computer. Compare containers and profile volume names after running two isolated bots. The supervisor pins the computer image, sets a 1.5 GiB cap and replaces old images on next use while preserving volumes. Start with one active browser computer on the 8 GB VM and measure RAM before increasing concurrency. v1.0.2 does not forward the shared computer's browser concurrency or idle settings to dynamic containers.

The supervisor needs the Docker socket. A read-only mount still allows Docker API writes. Computers get derived per-computer tokens and no socket. Native action policies and approval prompts cover supported tool operations. Restrict tools, credentials and networks before granting shell or browser access. Use test accounts with limited permissions. Never give bots admin credentials for Proxmox, AWS or the main homelab.

Evaluate gVisor by installing and registering `runsc` per the [official guide](https://gvisor.dev/docs/user_guide/install/), then set `COMPUTER_RUNTIME=runsc` and redeploy. Run a disposable bot through Chromium streaming, routine execution and profile persistence before relying on it. SPIRE is omitted because v1.0.2 reports SVIDs without enforcing access, and the upstream Compose attestor adds Docker socket and host PID access.

After upgrades, check server UI, managed model response, a routine run and isolated browser persistence. Test a VM reboot, Docker restart and temporary PostgreSQL outage from the Proxmox console during a maintenance window. Check fresh worker logs and repeat the routine. Docker restarts long-running services, the worker retries failed sweeps, and the firewall unit is a Docker prerequisite. Keep an eye on available disk in Beszel. Review and remove specific unused image IDs only after checking which releases and running computers need them.

## Backup and recovery

- Schedule Proxmox VM backups to another host or backup storage. Verify guest-agent freeze/thaw and regularly boot a restore on an isolated network.
- Deployments stop the server and worker, create a custom-format PostgreSQL dump, then migrate. Sync `/var/backups/openbot` to encrypted off-VM Restic storage. Protect bucket credentials on the VM. Set a retention policy and verify a separate restore.
- For a portable application backup, hold `/run/lock/openbot-deploy.lock` with `flock`. Stop server and worker, then stop the running computers selected by both labels `openbot.supervisor=true` and `openbot.namespace=openbot` so Chromium flushes profiles. Save each matching volume's complete `docker volume inspect` metadata and tar its mounted contents read-only. Preserve owners and permissions. Run `scripts/backup.sh /absolute/path/to/new.dump` from the root-owned checkout. Include the release SHA, `/etc/openbot`, and the portable computer archives in the encrypted backup. Restart only the containers that previously ran. Use a tested backup window.
- Restore on a clean VM with the saved runtime settings and same release. Run `sudo scripts/restore.sh /absolute/path/to/postgres.dump`. Recreate each named computer volume from its saved metadata with the original labels and archive contents before starting the server. Bare volumes without ownership labels are refused by the supervisor. Test migration, OAuth, provider calls, a scheduled routine and a saved browser profile in the isolated restore before making it live.
- A failed migration leaves the server and worker stopped. Diagnose via `compose logs migrate` in the root checkout. Retry only after correcting the underlying issue. For a failed release with a schema change, restore the pre-deploy dump and old release on a fresh VM or volume after capturing the failed state. App-image rollback alone can be unsafe after migration.
- Managed CopilotKit Intelligence stores threads and memories separately. Confirm recovery and data retention with that project's operators.

Existing Caddy, tunnel, Dockhand and Beszel patterns were checked against the [homelab-docker configuration](https://github.com/halvorot/homelab-docker/tree/da0b8e20651c51a71c25604c1888e18fe5e9fc28). Production integration and reboot checks require the new VM and are listed above.
