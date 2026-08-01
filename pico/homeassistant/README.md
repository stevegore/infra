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

The nightly backup is installed in Steve's crontab on pico at 00:30, before the
existing 01:00 Duplicati Home Assistant job and the 04:00 HACS automation:

```bash
install -m 700 scripts/backup-ha-container.sh /home/steve/.local/bin/backup-ha-container
crontab -e
# 30 0 * * * /home/steve/.local/bin/backup-ha-container >> /home/steve/.local/state/ha-container-backup.log 2>&1
```
