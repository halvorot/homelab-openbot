# OpenBot homelab

[OpenBot](https://openbot.halvorteigen.no) runs on `openbot-vm` with Docker Compose. The existing Cloudflare Access, tunnel, and Caddy handle ingress. 9Router serves model requests, and CopilotKit Intelligence stores conversations and memory.

## Deploy and update

- Review and merge PRs after **Compose, shell and secret scan** passes. A merge to `main` deploys over Tailscale. Use [Deploy OpenBot](https://github.com/halvorot/homelab-openbot/actions/workflows/deploy.yml) to redeploy `main`.
- Image tags live in [`compose.yaml`](compose.yaml). Keep the four OpenBot images on the same release when reviewing Renovate PRs.
- Change runtime settings in `/etc/openbot/runtime.env` on the VM, then redeploy. Keep credentials outside Git. Changes to [`ops/`](ops/) need a separate install or reload on the VM.

## Check the VM

Paste into Ghostty while SSH’d into `openbot-vm`:

```sh
sudo bash -c 'source /opt/openbot/repo/scripts/common.sh && compose ps -a && compose logs --tail 10 worker'
```

Check for healthy services and a recent `routine-sweep` log. After an update or reboot, test an existing conversation, a scheduled routine, and an isolated bot’s browser profile.

Each deploy saves a PostgreSQL dump under `/var/backups/openbot` before migrations. See the [setup and recovery runbook](docs/setup-and-recovery.md) for rebuilding the VM, off-VM backups, restores, and rollback.
