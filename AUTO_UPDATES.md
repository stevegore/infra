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

### Throughput: ~2 PRs per run

Renovate merges **at most 2 PRs per run**, by design. After an automerge the base
branch has moved, so it logs `Restarting repository job after automerge result`
and re-runs — but only once, then finishes. A backlog of 20 PRs therefore takes
about 10 runs, i.e. ~10 nights on the normal schedule.

That is fine for steady state (a handful of updates a night drains immediately),
but to clear a backlog now, either dispatch repeatedly with `ignoreSchedule`, or
merge the already-approved ones directly — identical outcome, since these are PRs
the config has already classified as automerge:

```bash
gh pr list --repo stevegore/infra --limit 60 --json number,labels \
  -q '.[] | select((([.labels[].name]|index("database")) or ([.labels[].name]|index("needs-rebuild"))) | not) | .number' \
  | xargs -I{} gh pr merge {} --repo stevegore/infra --squash --delete-branch
```

The label filter is what keeps the database and caddy hold-backs out of it.

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

**HA cannot update its own core in Container mode.** Core is
`ghcr.io/home-assistant/home-assistant:<tag>` in `/opt/ha-container/compose.yaml`
on pico. That file is a bare `docker compose` project — not a Portainer stack and
not in this repo — so **Renovate does not see it and HA core will not auto-update
today**. To close that gap, move it to `pico/homeassistant/compose.yaml` and
convert it with `scripts/portainer-stacks-to-git.py`, exactly like the other 15.
Its `mariadb:11` service would then fall under the database hold-back
automatically, which is the behaviour you want.

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
