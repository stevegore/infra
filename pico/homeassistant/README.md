# Home Assistant Container stack

This is the Git source of truth for the Compose definition running from
`/opt/ha-container` on pico. Persistent data remains in that host directory;
only the Compose definition belongs in Git. Secrets stay in
`/opt/ha-container/.env` or, after Portainer conversion, in the stack's
Portainer environment. Never commit `.env`.

Home Assistant Core and Matter Server updates require manual review. MariaDB is
covered by the repository-wide database holdback. Before approving any of them:

1. Confirm HACS integrations, cards and themes have no pending updates.
2. Run `scripts/backup-ha-container.sh` and verify its two output locations.
3. Review release notes for breaking changes and database migrations.
4. After deployment, check Core logs, failed integrations, recorder/history,
   Matter state, and both `hass.stevegore.au` endpoints.

> **Git leads the host here — check both before deploying.** This file is the
> source of truth, but nothing deploys it automatically; `/opt/ha-container`
> only changes when someone copies the definition over and runs
> `docker compose up -d`. So a merged Renovate PR is *not* deployed, and the
> two can differ for weeks. Diff them first:
>
> ```bash
> diff -u /opt/ha-container/compose.yaml ~/code/infra/pico/homeassistant/compose.yaml
> ```
>
> **As of 2026-09-05** the host runs Home Assistant **2026.7.4** and MariaDB
> **11.8.8**, while this file carries HA **2026.9.0** (PR #56, merged
> 2026-09-05 without the review above — do steps 1-4 before deploying it).
> MariaDB was also bumped to 12.3.3 by PR #46 the same day and has been
> reverted to 11.8.8; see the comment in `compose.yaml`.
>
> This is a different failure from `/opt/portainer`, which held a *stale
> abandoned* copy that silently downgraded the control plane. Here the split is
> intentional — the risk is only that git runs ahead of the host unnoticed.

The nightly backup is installed in Steve's crontab on pico at 00:30, before the
existing 01:00 Duplicati Home Assistant job and the 04:00 HACS automation:

```bash
install -m 700 scripts/backup-ha-container.sh /home/steve/.local/bin/backup-ha-container
crontab -e
# 30 0 * * * /home/steve/.local/bin/backup-ha-container >> /home/steve/.local/state/ha-container-backup.log 2>&1
```
