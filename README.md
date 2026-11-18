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
2. Add the service account of the Job to the bootstrap owners of the control plane. The Job creates atespaces, and only a global owner can. Append `system:serviceaccount:<namespace>:<release>-substrate-registration` to `config.ateapi.authz.bootstrapOwners` in the `substrate-install` values. Do not replace the list. A set list drops the default `ate-client` principal, which the upstream demos and `ate-setup` use. Add `system:serviceaccount:ate-system:ate-client` to the list if you still need it.
3. Copy `charts/substrate-registration/ci/aws-values.yaml` or `onprem-values.yaml`. Use the same `snapshotStorageLocation` and `actors` as the actor release. One values file can serve both releases.
4. Set `image.digest` to the digest of the published registration image.
5. Install the chart with your values file, or sync it with Argo CD.

### How the Job works

1. It waits until `kubectl ate` can read the atespaces. This shows that a pod of `ate-api-server` is ready.
2. For each actor, it waits until the ConfigMap holds the template name and the egress hash that the Job expects. A stale ConfigMap never gets registered.
3. It creates the atespace if it is missing.
4. If the actor does not exist, it creates the template and the actor.
5. If the actor is `ACTOR_STATE_DELETING`, an earlier delete did not finish. It runs the delete again and creates the actor.
6. If the actor uses an older template and is `ACTOR_STATE_SUSPENDED`, it moves the actor with `kubectl ate update actor --template`. The actor keeps its state. If the server refuses the update, for example because the snapshot location changed, the Job deletes the actor and creates it again. The state is lost, and the log says so.
7. If the actor uses an older template and is `ACTOR_STATE_CRASHED`, it deletes the actor and creates it again.
8. If the actor uses an older template and is in any other state, it is busy. The Job leaves it alone.
9. It brings the egress policy to the rules in the ConfigMap. It creates, updates in place, or deletes the policy, so an egress change never recreates the actor.
10. It deletes the older templates of the actor.
11. If any actor was busy, the Job fails with a message that names the actors.

A busy actor fails the Job so the drift shows in Argo CD. The Job retries up to `backoffLimit` times. The actor then moves if it has suspended. Otherwise, suspend the actor and sync again.

A template is immutable, so its name carries a hash of what it holds: the actor values without the webhook and the egress rules, and the snapshot location. A change to the image, command, environment, resources, worker selector or probe gives a new name. A change to the webhook or the egress rules does not. The egress policy has its own hash in the ConfigMap, and the Job compares the policy with the live one. The `substrate-actor` chart renders both values, and the `substrate-registration` chart computes the same values from the same values file. `make test-contract` fails if the two drift.

The Job and its ConfigMap carry a hash of the whole pod spec and the plan in their names, like the install Job. A change creates a new Job. The default values set Argo CD hook annotations, so Argo CD runs the Job again on every sync and deletes the old one first. Helm deletes a finished Job after `ttlSecondsAfterFinished`.

### Access of the Job

`kubectl ate` port-forwards to a pod of `ate-api-server` and sends a bearer token. The Job projects a token of its own service account, with the audience `api.<namespace>.svc`. The principal is `system:serviceaccount:<release namespace>:<service account>`. Port-forward needs no label on the namespace of the Job, because the NetworkPolicy of the control plane does not see the tunnel.

The chart creates this RBAC in the namespace of the control plane:

| Resource | Verbs | Why |
|---|---|---|
| `services/api` | `get` | `kubectl ate` finds the pods behind the Service |
| `pods` | `list` | `kubectl ate` picks a ready pod |
| `pods/portforward` | `get`, `create` | `kubectl ate` opens the tunnel |

`kubectl ate` also lists ClusterTrustBundles to read the CA of `ate-api-server`. Default RBAC lets every service account do this, so the chart adds no role for it. If your cluster removed that default, grant `list` on `clustertrustbundles` to the service account of the Job.

Port-forward RBAC cannot name a pod, so the Role covers every pod in the namespace of the control plane. Upstream documents the same limit.

### What the kind harness verifies

`make test-integration` runs the registration Job on a real control plane. See "Integration test" below. It verifies:

- A sample actor registers: the atespace, the template, the actor and the egress policy exist.
- A second run changes nothing.
- A changed template moves a suspended actor in place and keeps its state, and the Job fails on a resumed actor, then moves it after suspend.
- An egress-only change updates the live policy in place, and a run after it changes nothing. The real protojson output of `get egress-policy` matches the rules that the chart renders.
- The Job authenticates with its own token and the RBAC above, with no extra grant.

### Publish the registration image

CI pushes the multi-arch image to `ghcr.io/bbaliyan/kube-agent-substrate/substrate-registration` on every push to `main`, like the install image. The image holds `kubectl-ate`, `jq` and `bash`. The build compiles `kubectl-ate` from the release tag and checks the commit. It downloads `jq` for each architecture and verifies a pinned SHA-256 checksum. A running Job downloads nothing. `make test-image-registration` runs the tools of the image.

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

### Integration test

`make test-integration` is the main test of this repo. It needs Docker, `kubectl`, `helm`, `jq` and `curl`. It takes about 5 minutes on a warm Dev box. It is not part of `make test-commit`. The kind cluster, the registry and the files of a run are deleted when it ends. Set `KEEP_CLUSTER=1` to keep them.

The test does these steps, in order:

1. It builds the install image, the registration image and the counter demo actor image from this repo and the pinned Substrate release. It pushes them to a registry that it starts next to the cluster. The charts pin the images by their pushed digest.
2. It creates one kind node with the cluster settings that Substrate needs: the pod certificate and cluster trust bundle APIs.
3. It deploys RustFS and creates the snapshot bucket. RustFS 1.0.x cannot create a bucket itself, so a Job with the pinned AWS CLI image does it. The keys are fixed test values in a Secret that the test creates.
4. It installs the `substrate-install` chart with the `s3-compatible` storage profile and waits for the install Job to finish.
5. It starts a worker pool, installs the `substrate-actor` chart and the `substrate-registration` chart for one actor, and checks that the actor registers.
6. It resumes the actor, suspends it, drops its node-local snapshot with a revert, resumes it again from RustFS, and suspends it. The test fails if the actor is not `ACTOR_STATE_RUNNING` after a resume or not `ACTOR_STATE_SUSPENDED` after a suspend.
7. It runs the install Job and the registration Job again, and verifies that nothing changes.
8. It verifies that the live egress policy equals the rules that the chart renders.
9. It changes the template and verifies that the suspended actor moves with its state kept and the same identity.
10. It changes the template again while the actor runs and verifies that the Job fails. It suspends the actor and verifies that the Job then moves it.
11. It changes only the egress rules and verifies that the policy updates in place.

The files are in `tests/integration/`: `run.sh` runs the steps, and the manifests and values hold every setting. The test runs on the Dev box with `scripts/devbox-check <repo> test-integration`. On a kind node with less than 4 GiB of memory the install does not finish, so give the node 8 GiB.

The test does not cover:

- IAM-based S3 access. It uses static keys against RustFS. The `aws` profile is checked only by the render tests and by `make test-image`.
- SELinux enforcement. The kind node does not enforce it, and the repo has no SELinux policy yet.
- The CPU model of a Proxmox worker pool and the restore of a golden snapshot on another CPU. The cluster has one node.
- microVMs. The install uses the gVisor class only.
- Credential injection. The test sets the credential provider to off. The sample actor has egress rules without credentials.
- The webhook shim, the ingress and the External Secrets resources of the `substrate-actor` chart.
- Several actors, several nodes and the `arm64` architecture. The test runs the architecture of the host.
- Registry and object store TLS. The test uses plain HTTP inside the cluster.

Not covered by any check in this repo:

- An install on a real cluster. The integration test runs the same charts and images on kind, which differs from RKE2 and from a Proxmox VM in its node image, its storage class and its network.

## Workaround ledger

Each workaround, the upstream issue behind it and what to delete when the issue is fixed. Upstream is `agent-substrate/substrate`. A row marked "planned" belongs to a chart that this repo does not have yet.

| Workaround | Upstream issue | Delete when it lands |
|---|---|---|
| Registration of actors and template swap. An ActorTemplate is not a CRD, a template is immutable, and an EgressPolicy belongs to an actor, not to a template | none known | The registration chart, once upstream offers a declarative resource for actors |
| Template name carries a hash, because a template has no labels or annotations to hold the applied inputs. The egress policy has no name, so the Job compares it with the live policy | none known | The hash in the name, once a template can hold metadata or be updated |
| Move an actor to a new template only while it is suspended, because the server refuses the change otherwise, and recreate it when the server refuses an in-place update | none known | The gate and the recreate, once upstream moves a running actor to a new template |
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
