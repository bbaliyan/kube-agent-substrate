# kube-agent-substrate

Helm charts that run [Agent Substrate](https://github.com/agent-substrate/substrate) actors on self-managed Kubernetes. The repo holds code only.

## Charts

| Chart | What it does |
|---|---|
| `substrate-install` | Installs or upgrades the Substrate control plane with a Job that runs `ate-setup` from a pinned install image |
| `substrate-registration` | Registers the actors of the `substrate-actor` chart in a running control plane with a Job that runs `kubectl-ate` from a pinned registration image |
| `substrate-actor` | Defines any actor from a list in values: image by digest, environment, egress allowlist, credential injection, webhook shim and ingress |

## Install Substrate

The `substrate-install` chart runs one Job. The Job installs the Substrate release that you name in `substrate.version`.

The Job uses the install image in `images/substrate-install/`. CI builds the image. The image holds `ate-setup`, `kustomize` and the checkout of the pinned release. A Substrate release ships no `ate-setup` binary, so the build compiles it from the release tag. The build checks that the tag names the pinned commit. A running Job downloads nothing.

To install:

1. Copy `charts/substrate-install/ci/aws-values.yaml` or `charts/substrate-install/ci/onprem-values.yaml`.
2. Replace the placeholder values with your own.
3. Set `image.digest` to the digest of the published install image.
4. Install the chart with your values file, or sync it with Argo CD.

The `config` value is the body of the upstream `SubstrateInstall` document. The chart adds `images`, `sandboxClasses` and `context`. It also derives `storage.snapshotLocation` and `storage.bucketName` from the storage profile (see Storage profiles). The sizing settings `clusterSize` and `rolloutTimeout` are `config` keys. Set secret settings, such as the database connection string, in `env` with a `secretKeyRef`.

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

### Storage profiles

Set `storage.profile` to `aws` or `s3-compatible`. Any other value fails the render. The chart generates the patch `20-storage-profile` from the `storage` values and the Job applies it with the static patches. You never edit manifests by hand.

The patch sets the backend on the two containers that read the object store settings in release v1.0.0:

- the `objectstore-plugin` sidecar of `ate-api-server`
- the `objectstore-plugin` sidecar of `atelet`

Both must agree. If they differ, the API server deletes or copies snapshots in one bucket while atelet writes to another. Upstream issue #2378 lists a third container, the `atelet` container. In v1.0.0 that container exits if `ATE_STORAGE_BACKEND` is set on it, because the plugin sidecar now does the asset downloads. The chart therefore sets nothing on it. Test operations in the patch stop the install if upstream moves the sidecar.

`ATE_STORAGE_BACKEND` is always explicit (`s3`). The upstream default is GCS.

| Profile | Environment of both sidecars |
|---|---|
| `aws` | `ATE_STORAGE_BACKEND`, `AWS_REGION`. No static keys: the pods use the IAM role of the node. |
| `s3-compatible` | The same, plus `AWS_ENDPOINT_URL`, `AWS_S3_USE_PATH_STYLE`, and `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from a `secretKeyRef`. |

Set `storage.bucket` and `storage.region` for both profiles. The chart sets the snapshot location to `s3://<bucket>/`. You can set `config.storage.snapshotLocation` to `s3://<bucket>` or to a prefix inside the bucket. A location in another bucket fails the render.

For `s3-compatible`, also set `storage.s3Compatible.endpoint` and, if the store needs it, `pathStyle`. Give the keys in one of two ways:

1. Set `credentials.secretName` to an existing Secret in the control plane namespace. The Secret holds the keys named by `accessKeyKey` and `secretKeyKey`.
2. Set `credentials.externalSecret.enabled` to `true`, with `storeName`, `storeKind` and the two remote keys. The chart renders an ExternalSecret that creates the Secret. The default Secret name is `substrate-s3-credentials`.

The chart stores no key. The ExternalSecret lives in `config.namespace`. When you use it, the chart also renders that namespace first, with the annotations `helm.sh/resource-policy: keep` and `Prune=false`, so a delete of the release does not remove it. `ate-setup` applies over the namespace. The ExternalSecret syncs before the Job runs, so the Secret exists when the Job starts.

`ate-setup` treats a cluster that is not kind as GCS and refuses to deploy without `storage.transferGSAName` and `gcp.projectID`. S3 uses neither. The chart sets both to the neutral placeholder `unused-placeholder`, and a value cannot change them. A project value also makes `ate-setup` fetch GKE credentials unless a context is set, so the chart sets `context` to the context of its own kubeconfig.

#### AWS: instance metadata

The pods read the node credentials through the instance metadata service (IMDS). The nodes need IMDSv2 with a hop limit of 2, because a pod is one network hop past the node. A hop limit of 1 blocks the pods. This was not verified in any kube-compute node module. If a module sets a hop limit of 1, raise a kube-compute ticket.

#### Bucket expiry

Add one lifecycle rule to the bucket: abort incomplete multipart uploads after a few days. Do not add a blanket expiry rule for objects. A suspended actor keeps its state in a snapshot object, and that state can rest for months. An expiry rule would delete it.

In v1.0.0 the sidecar of `ate-api-server` deletes snapshots that nothing refers to. Objects that a failed checkpoint upload leaves behind are not removed (upstream issue #610). They need a separate cleanup that this repo does not have.

### Publish the image

CI pushes the multi-arch image to `ghcr.io/bbaliyan/kube-agent-substrate/substrate-install` on every push to `main`. The tag is `main-<short sha>` and the job summary shows the digest. CI does not push release tags. The owner tags.

GitHub creates the package as private. The owner must make it public once, in the package settings.

The chart pins the image by digest. The default `image.digest` is all zeros and never pulls. Set it from the published digest, in a release commit or with a Renovate regex manager. An unset digest fails the pod with an image pull error, not a silent unpinned install.

### microVMs are out

The install uses the gVisor sandbox class only. The chart sets `sandboxClasses: gvisor` and a value cannot change it. A microVM class on a cluster that is not kind needs a cloud CLI to stage its assets, which the image does not hold. Use gVisor until this changes.

## Register actors

An ActorTemplate, an Actor and an EgressPolicy are not Kubernetes resources. They live in the control plane database, and only `kubectl ate` writes them. The `substrate-registration` chart runs one Job that does this for the actors of the `substrate-actor` chart.

To register:

1. Install the `substrate-actor` chart. It renders one ConfigMap for each actor.
2. Add the service account of the Job to the bootstrap owners of the control plane. Set `config.ateapi.authz.bootstrapOwners` in the `substrate-install` values to `system:serviceaccount:<namespace>:<release>-substrate-registration`. The Job creates atespaces, and only a global owner can.
3. Copy `charts/substrate-registration/ci/aws-values.yaml` or `onprem-values.yaml`. Use the same `snapshotStorageLocation` and `actors` as the actor release. One values file can serve both releases.
4. Set `image.digest` to the digest of the published registration image.
5. Install the chart with your values file, or sync it with Argo CD.

### How the Job works

1. It waits for the `ate-api-server` Deployment to be available.
2. For each actor, it waits until the ConfigMap holds the template name that the Job expects. A stale ConfigMap never gets registered.
3. It creates the atespace if it is missing.
4. If the actor does not exist, it creates the template, the actor and the egress policy.
5. If the actor uses the expected template, it changes nothing.
6. If the actor uses an older template and is idle, it swaps: it deletes the actor, creates the new template, the actor and the egress policy, and deletes the old template.
7. If the actor uses an older template and is busy, it leaves the actor alone. The next sync swaps it.

An actor is idle when its state is `ACTOR_STATE_SUSPENDED` or `ACTOR_STATE_CRASHED`. A swap deletes the actor and its state. A busy Job still exits with success and logs the busy actors.

A template is immutable, so its name carries a hash of what it holds: the actor values without the webhook, and the snapshot location. A change to the image, command, environment, resources, worker selector, probe or egress rules gives a new name. A change to the webhook alone does not. The `substrate-actor` chart renders the name into its ConfigMap, and the `substrate-registration` chart computes the same name from the same values. `make test-contract` fails if the two drift.

The Job and its ConfigMap carry a hash of the whole pod spec and the plan in their names, like the install Job. A change creates a new Job. The default values set Argo CD hook annotations, so Argo CD runs the Job again on every sync and deletes the old one first. Helm deletes a finished Job after `ttlSecondsAfterFinished`.

### Access of the Job

`kubectl ate` port-forwards to a pod of `ate-api-server` and sends a bearer token. The Job projects a token of its own service account, with the audience `api.<namespace>.svc`. The principal is `system:serviceaccount:<release namespace>:<service account>`. Port-forward needs no label on the namespace of the Job, because the NetworkPolicy of the control plane does not see the tunnel.

The chart creates this RBAC in the namespace of the control plane:

| Resource | Verbs | Why |
|---|---|---|
| `services/api` | `get` | `kubectl ate` finds the pods behind the Service |
| `pods` | `list` | `kubectl ate` picks a ready pod |
| `pods/portforward` | `get`, `create` | `kubectl ate` opens the tunnel |
| `deployments` | `get`, `list`, `watch` | The Job waits for `ate-api-server` |

It also creates a cluster role with `list` on `clustertrustbundles`. `kubectl ate` reads the CA of `ate-api-server` from them. Default RBAC already allows this, so `rbac.clusterTrustBundles: false` turns the role off.

Port-forward RBAC cannot name a pod, so the Role covers every pod in the namespace of the control plane. Upstream documents the same limit.

### What the kind harness verifies

The kind harness is a later ticket. It must show on a real control plane:

- A sample actor registers: the atespace, the template, the actor and the egress policy exist.
- A second run changes nothing.
- A changed template swaps an idle actor and leaves a resumed actor alone, then swaps it after suspend.
- The Job authenticates with its own token and the RBAC above, with no extra grant.

### Publish the registration image

CI pushes the multi-arch image to `ghcr.io/bbaliyan/kube-agent-substrate/substrate-registration` on every push to `main`, like the install image. The image holds `kubectl-ate`, `kubectl`, `jq` and `bash`. The build compiles `kubectl-ate` from the release tag and checks the commit. It downloads `kubectl` and `jq` for each architecture and verifies a pinned SHA-256 checksum. A running Job downloads nothing. `make test-image-registration` runs the tools of the image.

## Define an actor

1. Copy `charts/substrate-actor/ci/aws-values.yaml` or `charts/substrate-actor/ci/onprem-values.yaml`.
2. Replace the placeholder values with your own.
3. Add one entry to `actors` for each actor.
4. Install the chart with your values file.

The `aws` and `onprem` files differ only in values: the snapshot location, the secret store and the ingress class. The `*-multi-values.yaml` files show several actors in one release.

The values schema rejects an image reference that has no digest.

## Checks

Run `make test-commit` in the kube-devenv image. It lints the charts, runs the chart unit tests and scans for secrets. It also runs the registration script against a stub of `kubectl-ate` (`make test-register`) and checks that the actor and registration charts agree on template names (`make test-contract`). The stub tests the idle gate and the no-change rerun, not the real client.

Run `make test-image` on a host with Docker, `helm` and `awk`. It builds the install image and runs the patch steps on the real release checkout. It also applies the generated storage patch of each `ci` values file and verifies the backend on both plugin sidecars. CI runs it, and builds the arm64 image. CI does not push the image yet.

The render lint is a quick lint. It runs `helm template` and `kubeconform` for each file in `charts/*/ci/`: the `aws` and `onprem` profiles, each with one actor and with several. It does not prove that an install works.

Not covered by any check in this repo:

- An install of the control plane on a cluster. The checks render the Job and run the patches on the checkout. They do not run `ate-setup` against a cluster.
- An install of an actor on a cluster, and a run of the registration Job against a control plane. The kind harness will cover them.
- IAM-based S3 access, SELinux enforcement and microVMs.

## Workaround ledger

Each workaround, the upstream issue behind it and what to delete when the issue is fixed. Upstream is `agent-substrate/substrate`. A row marked "planned" belongs to a chart that this repo does not have yet.

| Workaround | Upstream issue | Delete when it lands |
|---|---|---|
| Registration of actors and template swap. An ActorTemplate is not a CRD, a template is immutable, and an EgressPolicy belongs to an actor, not to a template | none known | The registration chart, once upstream offers a declarative resource for actors |
| Template name carries a hash, because a template has no labels or annotations to hold the applied inputs | none known | The hash in the name, once a template can hold metadata or be updated |
| Swap only an idle actor, because deleting an actor discards its state, and `kubectl ate` has no idle flag beyond the actor state | none known | The gate, once upstream offers a safe in-place template change |
| `kubectl ate` creates a token for the shared `ate-client` account when given no token, so the Job passes its own token with `--token-file` and the account must be a bootstrap owner | none known | The bootstrap owner entry, once a role can be granted to an account without the bootstrap list |
| Port-forward RBAC covers every pod in the control plane namespace, because RBAC cannot name a pod that changes on every rollout | none known | The Role, once `kubectl ate` can reach the API through the Service |
| Install Job around `ate-setup`, with its image and patches | #3158, #3170, #3686, #3240 | The Job and the image, and use the upstream Helm charts |
| Drop the atelet image credential provider flags and host mounts, because RKE2 nodes have no provider | #2669, #3667 | The patch `10-atelet-no-credential-provider` |
| gVisor class only, because microVM asset staging needs a cloud CLI off kind | none known | The `sandboxClasses` setting in the chart, once the install can stage microVM assets |
| Storage profile patch `20-storage-profile`: the chart sets an explicit `s3` backend on both object-store plugin sidecars, because the default is GCS and the settings are repeated per container | #3668 (explicit backend), #2378 (one place for the settings) | The generated patch, and set the backend in values |
| `storage.transferGSAName` and `gcp.projectID` placeholders, and `context`, because `ate-setup` models a cluster that is not kind as GCS | #3651 (open PR: `storage.backend=external` and `--component` for provider storage, not in v1.0.0) | The placeholders, and move the profile to a `--component` |
| Opt-in SELinux admission policy (planned) | #3597 | The policy |
| Idle-suspend CronJob (planned) | #424, #483 | The CronJob, and use the upstream policy |
| One CPU model for each WorkerPool, as a documented rule (planned) | #1657 | The rule |
| Bucket rule: abort incomplete multipart uploads only, no blanket expiry. Objects left by a failed checkpoint upload need a separate cleanup | #610 | The note, once upstream removes them |
| PodMonitors for clusters without the GKE `PodMonitoring` CRD (planned) | #2589 | The PodMonitors |
| On-prem profile values (planned) | #1782 | The profile, once upstream ships one |
| RustFS with large sparse multipart uploads (planned, unverified) | #3921 | The note, once a test shows it works |

## License

Apache-2.0.
