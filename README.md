# kube-agent-substrate

Helm charts that run [Agent Substrate](https://github.com/agent-substrate/substrate) actors on self-managed Kubernetes. The repo holds code only.

## Charts

| Chart | What it does |
|---|---|
| `substrate-install` | Installs or upgrades the Substrate control plane with a Job that runs `ate-setup` from a pinned install image |
| `substrate-actor` | Defines any actor from a list in values: image by digest, environment, egress allowlist, credential injection, webhook shim and ingress |

## Install Substrate

The `substrate-install` chart runs one Job. The Job installs the Substrate release that you name in `substrate.version`.

The Job uses the install image in `images/substrate-install/`. CI builds the image. The image holds `ate-setup`, `kustomize` and the checkout of the pinned release. A Substrate release ships no `ate-setup` binary, so the build compiles it from the release tag. The build checks that the tag names the pinned commit. A running Job downloads nothing.

To install:

1. Copy `charts/substrate-install/ci/aws-values.yaml` or `charts/substrate-install/ci/onprem-values.yaml`.
2. Replace the placeholder values with your own.
3. Set `image.digest` to the digest of the published install image.
4. Install the chart with your values file, or sync it with Argo CD.

The `config` value is the body of the upstream `SubstrateInstall` document. The chart adds `images` and `sandboxClasses`. Set `config.storage.snapshotLocation`. It is required, because `ate-setup` stops without it, and the schema rejects an empty value. The sizing settings `clusterSize` and `rolloutTimeout` are `config` keys. Set secret settings, such as the database connection string, in `env` with a `secretKeyRef`.

### How the Job works

1. The `seed` init container copies the checkout from the image to a writable directory.
2. The `patch` init container adds each patch to the kustomization in that copy.
3. The `deploy` container runs `ate-setup deploy ate-system` in the copy.

Kubernetes finishes both init containers before the `deploy` container starts. The patches therefore always apply before the deploy, and a sync never brings back the upstream defaults. A chart unit test and `make test-image` check this.

The Job reads its kubeconfig from a file that names the service account of the pod. The chart creates the service account. It binds the `cluster-admin` role, because the install creates cluster roles and an account can only grant what it holds. Set `rbac.clusterRole` to use another role.

The Job and its config map carry a hash of the whole pod spec in their names: the image, patches, config, environment, resources, node selector, tolerations and service account. A change to any of them creates a new Job and never edits the immutable template of an old one. If the inputs are the same, the Job already exists and nothing runs again. `ate-setup` keeps existing secrets and applies the same manifests, so a repeat on an installed cluster changes nothing.

### Patches

A patch is a directory in `charts/substrate-install/patches/`. It holds one kustomize `Component` in `kustomization.yaml`. The chart applies the directories in the order of their names, so start each name with a number.

To add a patch, add a directory. The chart packs it into the config map and the Job applies it. The Job needs no other change.

### Publish the image

CI pushes the multi-arch image to `ghcr.io/bbaliyan/kube-agent-substrate/substrate-install` on every push to `main`. The tag is `main-<short sha>` and the job summary shows the digest. CI does not push release tags. The owner tags.

GitHub creates the package as private. The owner must make it public once, in the package settings.

The chart pins the image by digest. The default `image.digest` is all zeros and never pulls. Set it from the published digest, in a release commit or with a Renovate regex manager. An unset digest fails the pod with an image pull error, not a silent unpinned install.

### microVMs are out

The install uses the gVisor sandbox class only. The chart sets `sandboxClasses: gvisor` and a value cannot change it. A microVM class on a cluster that is not kind needs a cloud CLI to stage its assets, which the image does not hold. Use gVisor until this changes.

## Define an actor

1. Copy `charts/substrate-actor/ci/aws-values.yaml` or `charts/substrate-actor/ci/onprem-values.yaml`.
2. Replace the placeholder values with your own.
3. Add one entry to `actors` for each actor.
4. Install the chart with your values file.

The `aws` and `onprem` files differ only in values: the snapshot location, the secret store and the ingress class. The `*-multi-values.yaml` files show several actors in one release.

The values schema rejects an image reference that has no digest.

## Checks

Run `make test-commit` in the kube-devenv image. It lints the charts, runs the chart unit tests and scans for secrets.

Run `make test-image` on a host with Docker. It builds the install image and runs the patch steps on the real release checkout. CI runs it, and builds the arm64 image. CI does not push the image yet.

The render lint is a quick lint. It runs `helm template` and `kubeconform` for each file in `charts/*/ci/`: the `aws` and `onprem` profiles, each with one actor and with several. It does not prove that an install works.

Not covered by any check in this repo:

- An install of the control plane on a cluster. The checks render the Job and run the patches on the checkout. They do not run `ate-setup` against a cluster.
- An install of an actor on a cluster. The ActorTemplate and the EgressPolicy are not Kubernetes resources. The chart renders them into a ConfigMap as data. A registration step, which this repo does not have yet, must apply them.
- IAM-based S3 access, SELinux enforcement and microVMs.

## Workaround ledger

Each workaround, the upstream issue behind it and what to delete when the issue is fixed. Upstream is `agent-substrate/substrate`. A row marked "planned" belongs to a chart that this repo does not have yet.

| Workaround | Upstream issue | Delete when it lands |
|---|---|---|
| Registration of actors and template swap (planned). An ActorTemplate is not a CRD, and an EgressPolicy belongs to a running actor, not to a template | none known | The registration step, once upstream offers a declarative resource for actors |
| Install Job around `ate-setup`, with its image and patches | #3158, #3170, #3686, #3240 | The Job and the image, and use the upstream Helm charts |
| Drop the atelet image credential provider flags and host mounts, because RKE2 nodes have no provider | #2669, #3667 | The patch `10-atelet-no-credential-provider` |
| gVisor class only, because microVM asset staging needs a cloud CLI off kind | none known | The `sandboxClasses` setting in the chart, once the install can stage microVM assets |
| Storage profile patches for S3 (planned) | #3668, #2378 | The patches, and set the backend in values |
| Opt-in SELinux admission policy (planned) | #3597 | The policy |
| Idle-suspend CronJob (planned) | #424, #483 | The CronJob, and use the upstream policy |
| One CPU model for each WorkerPool, as a documented rule (planned) | #1657 | The rule |
| Bucket expiry rule for orphaned snapshots (planned) | #610 | The rule |
| PodMonitors for clusters without the GKE `PodMonitoring` CRD (planned) | #2589 | The PodMonitors |
| On-prem profile values (planned) | #1782 | The profile, once upstream ships one |
| RustFS with large sparse multipart uploads (planned, unverified) | #3921 | The note, once a test shows it works |

## License

Apache-2.0.
