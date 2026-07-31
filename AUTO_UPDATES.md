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
| Home Assistant core, Apps, HACS | HA automation `Auto-update: HA core, Apps and HACS` | nightly 04:00 | `update.install` |
| pico OS packages | `unattended-upgrades` | daily, reboot 05:00 | apt |

Everything routes through this repo except the HA automation and apt.
Nothing is applied by hand.

---

## 1. Renovate

Config: [`renovate.json`](renovate.json) · Workflow: [`.github/workflows/renovate.yml`](.github/workflows/renovate.yml)

Covers 67 dependencies across 43 files, via seven managers:

| Manager | Files |
| --- | --- |
| `helmv3` | `apps/*/Chart.yaml`, `cilium/Chart.yaml` — upstream chart versions |
| `helm-values` | `apps/*/values.yaml` — image repository/tag pairs |
| `docker-compose` | `pico/*/compose.yaml` — every pico stack image |
| `dockerfile` | `apps/caddy/Dockerfile` |
| `github-actions` | `.github/workflows/*` |
| `terraform` | `terraform/*.tf` — provider constraints |
| `regex` (custom) | bare `image: repo:tag` lines that `helm-values` does not model — `apps/ttyd/values.yaml`, `apps/gym-booker/templates/deployment.yaml` |

**Policy: everything self-merges.** `automerge: true` including majors, with
`platformAutomerge` so GitHub does the merge. Uptime Kuma is the smoke test.

### What does NOT self-merge

| Held back | Why |
| --- | --- |
| Postgres, MySQL, MariaDB, Redis, CloudNativePG | A bad major here is a restore, not a rollback. Opens a PR labelled `database` / `manual-review` and waits. |
| `apps/caddy/Dockerfile` | Caddy is a custom `xcaddy` build. Merging the base-image bump is not enough — the image must be rebuilt and pushed, then `image.tag` bumped in `values.yaml`. The PR body carries the buildx command. |

### What is ignored entirely

- **Self-built images** — `syd.ocir.io/**`, `docker.io/stevegore/**`, and the
  bare local images built on pico (`stravakeeper`, `stravabot-rs`, `nuraspace`,
  `gymbooking2`, `goldenboards`). These are tagged with git SHAs or exist in no
  registry at all; the GitHub Actions that build them own their versioning.
- **Floating tags** — `:latest`, `:release`, `:stable`. There is nothing for
  Renovate to bump. These refresh when Portainer force-pulls on redeploy
  (see below), so they are muted rather than left on the dashboard forever.

### Setup required

Renovate needs one repo secret, `RENOVATE_TOKEN` — a fine-grained PAT scoped to
`stevegore/infra` with Contents, Pull requests and Workflows all read+write.
`GITHUB_TOKEN` will not work: PRs opened with it cannot self-merge.

Alternatively install the [Mend Renovate app](https://github.com/apps/renovate)
and delete the workflow; `renovate.json` is read identically either way.

### Watching it

- Dependency dashboard: the repo issue titled **"Renovate: homelab update dashboard"**
- Dry run without opening PRs: `gh workflow run renovate.yml -f dryRun=true -f logLevel=debug`
- Validate a config change before pushing:
  `npx --package renovate@44.4.5 -- renovate-config-validator --strict`

---

## 2. pico stacks are git-backed

All 15 Portainer stacks were converted from inline file-editor stacks to
**git-backed stacks** pointing at [`pico/`](pico/) in this repo, polling every
5 minutes with `forcePullImage` on.

That gives three things the file-editor stacks did not have: Renovate can see
and bump the images, every change has a commit, and floating tags
(`:latest`, `:release`) actually get re-pulled on redeploy.

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

---

## 3. Home Assistant

Automation: **`automation.auto_update_ha_core_apps_and_hacs`**, nightly at 04:00.

Installs every pending `update.*` entity — HA Core, Supervisor, Apps
(add-ons), HACS integrations and cards — taking a backup wherever the entity
advertises the BACKUP supported-feature bit.

HA Core is installed **last and alone**, because installing it restarts Home
Assistant and kills the automation run; anything sequenced after it would
silently never execute.

### Held back

- **`device_class: firmware`** — currently the three eero mesh nodes. Flashing
  every router in the house unattended has no remote recovery path if it goes
  wrong, and firmware cannot be rolled back. This exclusion is by device class,
  so any future firmware entity is caught automatically.
- **`update.mariadb_update`** — HA's recorder database, matching the data-layer
  carve-out Renovate uses. Drop it from the automation's `held` variable to
  un-hold it.

To pause everything: turn the automation off.

---

## 4. pico OS packages

`unattended-upgrades`, configured by
[`scripts/setup-host-auto-updates.sh`](scripts/setup-host-auto-updates.sh) via a
drop-in at `/etc/apt/apt.conf.d/52homelab-auto-upgrades`.

The stock config only allowed the release and `-security` pockets, which meant
ordinary package updates in `noble-updates` were never applied. The drop-in adds
`-updates`, enables unused-kernel and unused-dependency removal, and turns on
automatic reboot at 05:00 (verified safe — pico has no LUKS, so an unattended
boot cannot hang on a passphrase prompt).

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
- **OKE Kubernetes version and node pools** — owned by the `homelab-tf` ORM
  stack. Deliberately manual; see [`terraform/README.md`](terraform/README.md).
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
