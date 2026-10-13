# FleetDM on Kubernetes

A Helm chart that deploys [FleetDM](https://fleetdm.com) with MySQL and Redis, plus a Makefile that runs it on a local
Kind cluster.

- `charts/fleetdm` — the chart
- `local/` — Kind cluster config, local values, agent enrolment script
- `.github/workflows` — chart lint/test on pull requests, chart release on merge
- `docs/architecture.pdf` — architectural design document for Innovate Inc. (theoretical part), diagram source in `docs/hld.svg`

## Prerequisites

Docker, [Kind](https://kind.sigs.k8s.io), kubectl, Helm 3.8+ and `make`. `make agent` also needs `jq`.

## Install

```sh
make cluster   # create the Kind cluster "fleet"
make install   # install the chart into namespace "fleet" and wait until it is ready
```

The first install takes a few minutes: MySQL initialises, then Fleet applies its database migrations before the server
starts. When `make install` returns, the UI is at **https://localhost:8443**. The certificate is signed by a CA the
chart generates, so the browser will warn; `make ca` writes that CA to `fleet-ca.crt` if you want to trust it.

Every command targets the `kind-fleet` kubeconfig context explicitly, so it cannot touch whatever cluster your current
context points at. To use a different local cluster, override it:
`make install KUBE_CONTEXT=docker-desktop FLEET_URL=https://localhost:30443`.

## Verify

```sh
make verify
```

This runs the checks below and fails on the first one that does not pass:

| Component | Check |
|---|---|
| Fleet | Deployment rollout is complete; `helm test` reaches `/healthz` through the Service |
| MySQL | Query through the server counts applied Fleet migrations (proves the schema was prepared) |
| Redis | `redis-cli ping` answers `PONG` |
| Exposure | `/healthz` and `/version` answer on `https://localhost:8443` with the certificate verified against the chart CA |

Fleet's own `/healthz` returns 200 only when it can reach both MySQL and Redis, so a ready Fleet pod already implies
the other two are working.

To check that agents can reach Fleet end to end:

```sh
make agent
```

This completes Fleet's first-run setup with a generated admin account (credentials are saved to `local/.admin.env`,
which is git-ignored), starts an osquery container outside the cluster, enrols it over TLS and waits until it appears
as a host. Skip it if you prefer to do the setup in the UI yourself.

Manual checks, if you want to look around:

```sh
kubectl --context kind-fleet -n fleet get pods,svc,pvc
kubectl --context kind-fleet -n fleet logs deploy/fleet-fleetdm -c prepare-db   # migration output
```

## Teardown

```sh
make uninstall   # remove the release, its volumes and the namespace
make destroy     # delete the Kind cluster
```

## How it works

**Database migrations.** `fleet prepare db --no-prompt` runs as an initContainer of the Fleet pod, after another
initContainer has waited for MySQL and Redis. It is idempotent, so the same mechanism covers the fresh install and
every later upgrade. A Helm hook was the other candidate and does not fit here: MySQL is part of the same release, so
it does not exist yet at `pre-install`, and a `post-install` hook deadlocks with `helm install --wait` because Fleet
never becomes ready before the hook runs. The trade-off is that migrations are not serialised across replicas, so
install with one replica (the default) and scale up afterwards.

**Reaching Fleet.** osquery and fleetd refuse plain HTTP, so Fleet must be served over TLS. For the local cluster Fleet
terminates TLS itself, with a certificate issued by a chart-generated CA, and is published as a NodePort that Kind maps
to port 8443 on the host. Agents trust the CA from `make ca` (`--fleet-certificate` for fleetd, `--tls_server_certs`
for osquery). No ingress controller is needed locally. For a real cluster, set `ingress.enabled=true` and
`fleet.tls.enabled=false` to terminate TLS at the ingress, or pass your own certificate with
`fleet.tls.existingSecret`.

**Secrets.** No passwords are committed or defaulted. The MySQL passwords, Fleet's server private key and the TLS
material are generated on first install and reused on upgrade (the templates look up the existing Secrets). Each can be
supplied instead through an `existingSecret` value. Because of the lookup, tools that render without cluster access
(`helm template`, Argo CD) should use `existingSecret`.

**Hardening.** All containers run as non-root with dropped capabilities; Fleet and Redis use a read-only root
filesystem. NetworkPolicies allow only Fleet pods to reach MySQL and Redis.

**External services.** `mysql.enabled=false` and `redis.enabled=false` point Fleet at external instances
(`mysql.external.address`, `redis.external.address`), which is how it should run in production. The bundled MySQL is a
single instance with a persistent volume, suitable for evaluation, not for production data.

See [`charts/fleetdm/values.yaml`](charts/fleetdm/values.yaml) for all settings.

## CI and releases

- **Pull requests** (`lint-test.yaml`): `ct lint` validates the chart and requires a version bump when it changes, then
  `ct install` installs it into a Kind cluster and runs `helm test`.
- **Every push and pull request** (`e2e.yaml`): runs the Makefile targets above (`cluster`, `install`, `verify`, `agent`,
  `uninstall`) on a Kind cluster, so the local workflow itself is tested.
- **Merge to `main`** (`release.yaml`): [chart-releaser](https://github.com/helm/chart-releaser-action) packages any
  chart version that has no release yet, publishes it as a GitHub Release and updates the Helm repository index on the
  `gh-pages` branch.

To release a new version, bump `version` in `charts/fleetdm/Chart.yaml` and merge. The chart is then installable from
the public repository:

```sh
helm repo add fleetdm https://titan7777.github.io/fleetdm-helm-chart
helm install fleet fleetdm/fleetdm -n fleet --create-namespace
```

One-time repository setup: create an empty `gh-pages` branch and enable GitHub Pages for it.
