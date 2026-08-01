# Automatic Updates

Everything in the homelab that can update itself, does. This file is the map of
what updates what, what is deliberately held back, and how to stop it.

Set up 2026-07-31.

---

## The three pipelines

| Surface | Mechanism | Cadence | Lands via |
| --- | --- | --- | --- |
| OKE apps, Helm charts, Terraform providers, GitHub Actions | **Renovate** (`renovate.json`) | nightly 01:00–06:00 AEST | PR → automerge → `argocd-sync.yml` |
| pico Docker stacks | **Renovate** + git-backed Portainer stacks | nightly, then Portainer polls every 5 min | PR → automerge → Portainer redeploy |
| Portainer control plane | **Renovate**, manual review after a cold data-volume backup | nightly scan | PR → review → pico Compose deployment |
| Home Assistant HACS integrations/cards/themes | HA automation `Auto-update: HA core, Apps and HACS` | nightly 04:00 | `update.install` |
| Home Assistant Core, Matter and MariaDB containers | **Renovate**, manual review after a verified backup | nightly scan | PR → review → pico Compose deployment |
| pico OS packages | `unattended-upgrades` | daily, reboot 05:00 | apt |

Everything routes through this repo except the HACS automation and apt. Stateful
and platform-coordinated upgrades deliberately require a human approval.

---

## 1. Renovate

Config: [`renovate.json`](renovate.json) · Workflow: [`.github/workflows/renovate.yml`](.github/workflows/renovate.yml)

Covers Helm, containers, Terraform providers, Actions, and the pinned ArgoCD
upstream release via built-in and custom managers:

| Manager | Files |
| --- | --- |
| `helmv3` | `apps/*/Chart.yaml`, `cilium/Chart.yaml` — upstream chart versions |
| `helm-values` | `apps/*/values.yaml` — image repository/tag pairs |
| `docker-compose` | `pico/*/compose.yaml` — every pico stack image |
| `dockerfile` | `apps/caddy/Dockerfile` |
| `github-actions` | `.github/workflows/*` |
| `terraform` | `terraform/*.tf` — provider constraints |
| `regex` (custom) | bare template images plus `ARGOCD_VERSION` in `bootstrap/argocd-init.sh` |

Routine updates self-merge only after `.github/workflows/validate.yml` proves
that Renovate config, Helm dependencies/rendering, Compose definitions, and
Terraform configuration are valid. Uptime Kuma is the post-deploy smoke test.

### What does NOT self-merge

| Held back | Why |
| --- | --- |
| Postgres, MySQL, MariaDB, Redis, CloudNativePG | A bad major here is a restore, not a rollback. Opens a PR labelled `database` / `manual-review` and waits. |
| Home Assistant Core and Matter Server | Container-mode migrations need a verified snapshot and compatibility review. |
| Portainer (all updates) | It controls every git-backed pico stack and migrates its database on startup. Back up `portainer_data`, then verify the API, environment and stack inventory. |
| ArgoCD (all updates); Vault, VSO, Cilium, Tailscale Operator and Authentik majors | These coordinate or secure the platform and need release-note/order review. |
| `apps/caddy/Dockerfile` | Caddy is a custom `xcaddy` build. Merging the base-image bump is not enough — the image must be rebuilt and pushed, then `image.tag` bumped in `values.yaml`. The PR body carries the buildx command. |
| `images/garmin-mcp/Dockerfile` | The custom image must be rebuilt and its deployment tag bumped. |

### What is ignored entirely

- **Self-built images** — `syd.ocir.io/**`, `docker.io/stevegore/**`, and the
  bare local images built on pico (`stravakeeper`, `stravabot-rs`, `nuraspace`,
  `gymbooking2`, `goldenboards`). These are tagged with git SHAs or exist in no
  registry at all; the GitHub Actions that build them own their versioning.
- **No floating tags are ignored.** Renovate pins their registry digest, then
  opens digest PRs. That creates the Git change Portainer/ArgoCD need to deploy
  a new immutable image instead of silently drifting behind a mutable tag.

### Auth

Done — `RENOVATE_TOKEN` is set on the repo. It is a fine-grained PAT scoped to
`stevegore/infra` only, with Contents, Pull requests and Workflows read+write.
(`GITHUB_TOKEN` cannot be used: PRs opened with it cannot self-merge.)

**Vault holds the origin copy** at `kv/homelab/renovate`, field `token`. Nothing
reads it automatically — on rotation, push it back to GitHub by hand:

```bash
export VAULT_ADDR=https://vault.stevegore.au
export VAULT_TOKEN=$(cat vault-root.token)
vault kv get -field=token kv/homelab/renovate | gh secret set RENOVATE_TOKEN --repo stevegore/infra
```

`platformAutomerge` also needs **Allow auto-merge** on the repo, which is now
enabled (along with delete-branch-on-merge, since Renovate creates a lot of
branches).

Alternatively install the [Mend Renovate app](https://github.com/apps/renovate)
and delete the workflow; `renovate.json` is read identically either way.

`rebaseWhen: conflicted` lets independent PRs drain in the same run instead of
rebasing the whole queue after every merge. Real conflicts still rebase.

### Watching it

- Dependency dashboard: the repo issue titled **"Renovate: homelab update dashboard"**
- Dry run without opening PRs: `gh workflow run renovate.yml -f dryRun=true -f logLevel=debug`
- Validate a config change before pushing:
  `npx --package renovate@44.4.5 -- renovate-config-validator --strict`

---

## 2. pico stacks are git-backed

All 14 existing Portainer stacks were converted from inline file-editor stacks to
**git-backed stacks** pointing at [`pico/`](pico/) in this repo, polling every
5 minutes with `forcePullImage` on.

That gives three things the file-editor stacks did not have: Renovate can see
and bump the images, every change has a commit, and a pinned digest change
causes Portainer to redeploy an immutable image.

```
pico/
  transmission/compose.yaml
  sonarrradarrjackett/compose.yaml
  immich/compose.yaml
  ... 15 stacks
```

### Secrets

**This repo is public.** No compose file here may contain a credential.

Secrets are `${VAR}` placeholders in the committed compose file; the real values
live in the stack's Portainer Env, which is stored in Portainer's own database
and never leaves pico. Stacks with placeholders:

| Stack | Vars |
| --- | --- |
| `transmission` | `OPENVPN_USERNAME`, `OPENVPN_PASSWORD` |
| `huggin` | `MYSQL_ROOT_PASSWORD`, `APP_SECRET_TOKEN` |
| `immich` | `DB_PASSWORD` |
| `stravakeeper` | `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, `STRAVA_CLIENT_SECRET`, `STRAVA_VERIFY_TOKEN` |
| `plex` | `PLEX_CLAIM` |
| `icloudpd`, `icloudpd-kellesi` | `ICLOUD_USERNAME` |
| `ig-gallery` | `GALLERY_ADMIN_KEY` |

To change one: Portainer → Stacks → *stack* → Environment variables → Update.
Do **not** put the value in the compose file.

### Converting / re-converting a stack

[`scripts/portainer-stacks-to-git.py`](scripts/portainer-stacks-to-git.py).
Portainer has no in-place "convert to git" operation, so the script deletes and
recreates each stack. That removes **containers only** — named volumes, external
volumes and bind mounts (where all pico data lives) are untouched.

```bash
./scripts/portainer-stacks-to-git.py --dump-env > /tmp/stack-env.json   # fill in values
./scripts/portainer-stacks-to-git.py --env-file /tmp/stack-env.json --stack pdf   # dry run
./scripts/portainer-stacks-to-git.py --env-file /tmp/stack-env.json --stack pdf --apply
```

Dry run is the default. Every stack is snapshotted to `/tmp/portainer-rollback/`
before deletion; restore one with `--rollback /tmp/portainer-rollback/pdf.json --apply`.
Those snapshots contain the pre-migration inline secrets and are written `0600` —
keep them out of the repo, and note `/tmp` does not survive the 05:00 reboot.

**Stopped stacks stay stopped.** Creating a stack from a repo deploys it, so the
script records each stack's Portainer `Status` and re-stops anything that was
not running. Two stacks are deliberately stopped and should stay that way:

| Stack | Why it is off | Stays down? |
| --- | --- | --- |
| `stravakeeper` | `strava.stevegore.au` is served by the OKE `strava-keeper` app. | Yes — `restart: unless-stopped` |
| `gymmaster-rest` | Superseded by the OKE `gym-booker` app. | Yes — `restart: unless-stopped` |

Both were verified on 2026-08-01: their composes use `restart: unless-stopped`,
their containers no longer exist on the host, and they stayed down across the
reboot that morning. Ports `8180` and `8112` are closed.

> **Stopping a stack is not permanent if its containers are `restart: always`.**
> Docker restarts those on boot regardless of the Portainer stack's status — a
> reboot brought the ttyd stack back up, listening on `:8788`, after it had been
> stopped. For something that must never run again, **delete the stack and remove
> its `pico/<name>/` directory**, which is what was done to `stevegore-au`
> (ttyd now runs only on OKE, where it has the CiliumNetworkPolicy, the
> egress-lockdown init container and dropped capabilities). Check
> `restart:` in the compose file before relying on a stop.

If a future run brings something unexpected up,
`POST /api/stacks/<id>/stop?endpointId=1`.

### Portainer itself

Portainer is intentionally **not** one of the stacks it manages. Its reviewed
source is [`pico/portainer/compose.yaml`](pico/portainer/compose.yaml), but a
merge cannot self-deploy the control plane. Renovate holds every Portainer PR
for manual review. After merging:

1. Pull `main` on pico and pre-pull the new image.
2. Stop Portainer and take a cold archive of the external `portainer_data`
   volume under `~/.local/state/infra/portainer-backups/`.
3. Run `docker compose -f ~/code/infra/pico/portainer/compose.yaml up -d`.
4. Verify `/api/status`, the `pico-docker` environment, all stack names/statuses,
   and both Uptime Kuma monitors.

The old image is retained until verification, so rollback is: stop Portainer,
restore the archived volume, change the Compose tag/digest back, and redeploy.

The verified 2.33.6 rollback set created before the 2026-08-01 upgrade to
2.39.5 LTS is:

- `~/.local/state/infra/portainer-backups/portainer_data-pre-2.39.5-20260801T165103+1000.tar.gz`
- `~/.local/state/infra/portainer-backups/compose-pre-2.39.5-20260801T165103+1000.yaml`
- archive SHA-256: `153fb008e8fd5991470cc87f0a444d48f7cc3bd44936fdef5e0e39601f3f9731`

The archive is mode `0600`; `gzip -t` passed and `./portainer.db` was confirmed
inside it before the new container was started. The upgrade preserved the
instance ID, endpoint, and all 14 stack names/statuses; the public and direct
Uptime Kuma monitors both returned to green.

---

## 3. Home Assistant

> **HA moved from Supervised to Container on 2026-08-01.** That splits its
> updates across two mechanisms — the automation below no longer covers core.

Automation: **`automation.auto_update_ha_core_apps_and_hacs`**, nightly at 04:00.
It installs every pending `update.*` entity, which in Container mode means
**HACS only** — integrations, Lovelace cards and themes.

### What Container mode removed

Without a Supervisor these entities no longer exist, so nothing installs them:

| Gone | Now handled by |
| --- | --- |
| `update.home_assistant_core_update` | the image tag in the compose file (see below) |
| `update.home_assistant_supervisor_update` | n/a — no Supervisor |
| add-on entities (mariadb, phpmyadmin, matter_server, studio_code_server) | plain compose services; add-ons do not exist in Container mode |

Core, Matter Server and MariaDB are now defined in
`pico/homeassistant/compose.yaml`, with the deployed copy at
`/opt/ha-container/compose.yaml`. Renovate sees all three. Core and Matter wait
for `home-assistant` / `manual-review`; MariaDB inherits the database holdback.

Before approval, run `scripts/backup-ha-container.sh`. It takes a logical,
single-transaction MariaDB dump plus config/Matter state, verifies both inner
archives and checksums, then stages the result under the existing Duplicati Home
Assistant source. pico runs it at 00:30, before Duplicati at 01:00. The first
snapshot was also restored into an isolated temporary MariaDB container.

### The backup bit

`update.install` takes `backup: true` only where the entity advertises
`UpdateEntityFeature.BACKUP`, which is **bit 8** — not bit 1 (that is `INSTALL`,
set on every update entity). Passing `backup: true` to an entity that lacks it
errors. Every current entity is `sf=23`, so backup is always false in practice.

### Held back

**`device_class: firmware`** — currently the three eero mesh nodes. Flashing
every router in the house unattended has no remote recovery path if it goes
wrong, and firmware cannot be rolled back. The exclusion is by device class, so
any future firmware entity is caught automatically.

To pause: turn the automation off.

---

## 4. pico OS packages

`unattended-upgrades`, configured by
[`scripts/setup-host-auto-updates.sh`](scripts/setup-host-auto-updates.sh) via a
drop-in at `/etc/apt/apt.conf.d/52homelab-auto-upgrades`.

The stock config only allowed the release and `-security` pockets, which meant
ordinary package updates in `noble-updates` were never applied. The drop-in adds
`-updates` plus the signed Tailscale stable origin, enables unused-kernel and
unused-dependency removal, and turns on
automatic reboot at 05:00 (verified safe — pico has no LUKS, so an unattended
boot cannot hang on a passphrase prompt).

Major Ubuntu release upgrades remain reviewed operations. The current
24.04→26.04 preparation, private baseline capture, rollback, and verification
steps are in [`pico/UPGRADE-26.04.md`](pico/UPGRADE-26.04.md).

`sudo` on pico requires a password, so this cannot be applied remotely:

```bash
scp scripts/setup-host-auto-updates.sh pico.local:/tmp/
ssh -t pico.local 'sudo bash /tmp/setup-host-auto-updates.sh'
```

### Disk

The same script installs a **weekly Docker prune** (`docker-prune.timer`,
Sundays 04:30). This exists because of the rest of the pipeline: Renovate bumps
tags and Portainer force-pulls, so every update leaves the old image behind. At
setup time pico held 20.6 GB of reclaimable images and 2.8 GB of build cache
with 55 GB free on a root filesystem at 88%.

It prunes **images and build cache only**, keeping the last 7 days so a
rollback does not need a re-pull. It never touches volumes —
`docker system prune --volumes` on pico would destroy live application data.

---

## Not covered

- **`raspberrypi.local`** — SSH key auth is not working from this machine
  (`Permission denied (publickey,password)`), so nothing was configured there.
- **OKE Kubernetes version and node replacement** — owned by the `homelab-tf`
  ORM stack and deliberately manual. The control plane is pinned at current
  `v1.36.1`; the node-pool definition is pinned to the 2026-07-20 OKE image.
  Applying the Terraform change updates future-node configuration; cycle the two
  workers one at a time only after reviewing the ORM plan and workload health.
- **ArgoCD rollout** — Renovate opens a held PR for the pinned release. After
  merge, re-run `bootstrap/argocd-init.sh`; it upgrades the upstream manifests,
  waits for the server, and reapplies the Cilium/Flannel probe patches.
- **The ArgoCD ApplicationSet** — not self-managed. Editing
  `argocd/applicationset.yaml` still needs a manual
  `kubectl apply --server-side --force-conflicts`.

---

## Turning it off

| Stop | How |
| --- | --- |
| All Renovate PRs | Set `"enabled": false` at the top of `renovate.json` |
| One package | Add a `packageRules` entry with `"enabled": false` |
| Automerge only (still get PRs) | Set `"automerge": false` at the top of `renovate.json` |
| pico stack redeploys | Portainer → Stacks → *stack* → turn off GitOps updates |
| HA updates | Turn off `automation.auto_update_ha_core_apps_and_hacs` |
| apt updates | `sudo rm /etc/apt/apt.conf.d/52homelab-auto-upgrades` |
| Just the auto-reboot | Set `Unattended-Upgrade::Automatic-Reboot "false";` in that drop-in |
