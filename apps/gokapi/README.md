# gokapi — file sharing at `send.stevegore.au`

Upload a file, hand out the link, the link stops working after N downloads or a
deadline — whichever comes first — and the blob is deleted. Upstream:
[Forceu/Gokapi](https://github.com/Forceu/Gokapi), a ~15 MB Go binary.

Admin UI: <https://send.stevegore.au/admin>

## Shape

| | |
| --- | --- |
| Image | `docker.io/f0rc3/gokapi` (multi-arch, has `linux/arm64`) |
| Storage | one `oci-fss` PVC at `/app/persist` (`config/` + `data/`) |
| Auth | Authentik forward-auth in Caddy + Gokapi header auth (`Method: 2`) |
| Replicas | 1, `Recreate` — SQLite on a shared mount |

Downloads are public by design; only Gokapi's `requireLogin()` routes are gated.
The split lives in the `send.stevegore.au` vhost in
`apps/caddy/templates/configmap.yaml`.

## Why oci-fss and not oci-bv

The boot+block Always-Free budget is saturated at exactly 200 GB (2×50 GB node
boot volumes + `pg-shared` + `uptime-kuma`), and OCI block volumes have a 50 GB
hard minimum — any `oci-bv` PVC here would move the account off $0. FSS is a
separate, near-empty 100 GB allotment billed on actual usage. See
`oracle-cloud.md`.

The usual FSS blocker (the CSI driver ignores `fsGroup`, so non-root workloads
cannot write) does not bite because the Gokapi image runs as **root** unless
`DOCKER_NONROOT=true`. **Do not** add a `runAsUser`/`runAsNonRoot`
securityContext or set `DOCKER_NONROOT` without also adding a chown init
container — see `apps/gym-booker` for that pattern.

## Bootstrap — two things must exist, not one

Seeding `config.json` is **not** sufficient. Gokapi 2.2.4 refuses to start with

```
No user found in database. Please run setup first or create user with --deployment-password
```

if the `Users` table is empty, no matter what the config says. The `bootstrap`
init container in `deployment.yaml` therefore does two independent, idempotent
steps on a fresh volume:

1. copies the seed `config.json` off the ConfigMap (skipped if one exists), and
2. runs `/app/gokapi --deployment-password <random>`, which creates the
   super-admin row named in `Authentication.Username` and exits 0.

That password is random and discarded on purpose: under header auth it is never
used to log in. Verified on a clean volume — the bootstrapped user comes out as
`Userlevel: 0` with `Permissions: 511` (full super-admin). To set a real
password (only needed if you ever switch to internal auth):

```bash
kubectl -n gokapi exec deploy/gokapi -- /app/gokapi --deployment-password '<pw>'
```

**`config.json` is owned by Gokapi at runtime** — it rewrites the file to store
generated salts and E2E state — so it cannot be a read-only ConfigMap mount,
hence the copy-on-first-boot. The consequence: **once the PVC has a
`config.json`, edits to the ConfigMap do nothing.** Change settings in the UI,
or delete the file and let the pod reseed it (which regenerates the salts).

`ConfigVersion: 22` matches appVersion 2.2.4, and is also that release's
*minimum* — Gokapi exits rather than migrate anything older. Bump it in lockstep
with any image upgrade that changes the config schema.

## Security — the header is the whole perimeter

Gokapi's `isGrantedHeader()` **does not check which peer sent the request**. It
reads `X-authentik-username` verbatim and, by default, auto-creates whatever
username it finds. Verified locally against v2.2.4: a request carrying a made-up
username landed on a fully functional upload page as a brand-new account.

Three independent controls keep that shut. Removing any one of them is a real
downgrade, not a cleanup:

1. **Caddy strips** any client-supplied `X-Authentik-Username` before
   `forward_auth` re-adds the authenticated value. The vhost uses an explicit
   `route` block to force that order — in Caddy's default directive order
   `request_header` sorts *after* `forward_auth`, so flattening the `route`
   would delete the real header and break admin access rather than protect it.
2. **`CiliumNetworkPolicy`** limits ingress on :53842 to the Caddy pods, so
   nothing else in the cluster can reach the port to forge a header at all.
   Because this policy selects the pod, kubelet HTTP probes would be classified
   as CIDR traffic and dropped — **the probes are `exec` for that reason.** Do
   not convert them back to `httpGet`.
3. **`OnlyRegisteredUsers: true`** rejects usernames Gokapi has not seen before,
   which is the only one of the three that does not depend on Caddy or Cilium
   being right. Cost: a genuinely new person must be added at `/users` first.

`config.adminUsername` must match the username Authentik sends, or you get
auto-created as an ordinary user with no admin menu:

```bash
kubectl -n authentik exec deploy/authentik-server -- \
  ak shell -c "from authentik.core.models import User; print([u.username for u in User.objects.all()])"
```

## Deploy

GitOps as usual — edit, commit, push to `main`; the ApplicationSet picks up a
brand-new `apps/gokapi/` on its next poll. See `ARGOCD_WORKFLOW.md`.

## Gotcha: the Service name collides with the app's env namespace

The Service is called `gokapi`, so Kubernetes' legacy Docker-link injection
produces `GOKAPI_PORT=tcp://<clusterIP>:53842` — and Gokapi reads `GOKAPI_PORT`
as its own webserver port. The pod crash-loops at startup with:

```
Error parsing env variables: env: parse error on field "WebserverPort"
of type "int": strconv.ParseInt: parsing "tcp://10.96.x.x:53842": invalid syntax
```

`enableServiceLinks: false` in the pod spec is the fix and must stay. Renaming
the Service would also work, but the injection covers `GOKAPI_SERVICE_PORT` and
friends too, so turning it off is the durable answer.
