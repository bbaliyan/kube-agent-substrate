# kube-agent-substrate

Helm charts that run [Agent Substrate](https://github.com/agent-substrate/substrate) actors on self-managed Kubernetes. The repo holds code only.

## Charts

| Chart | What it does |
|---|---|
| `substrate-install` | Installs or upgrades the Substrate control plane with a Job that runs `ate-setup` from a pinned install image |
| `substrate-registration` | Registers the actors of the `substrate-actor` chart in a running control plane with a Job that runs `kubectl-ate` from a pinned registration image |
| `substrate-idle-suspend` | Suspends an idle running actor after a set idle time with a CronJob that runs `kubectl-ate` from the registration image. Delete it when upstream ships its own idle policy |
| `substrate-actor` | Defines any actor from a list in values: image by digest, environment, egress allowlist, credential injection, an Envoy webhook shim that checks the sender's token, and ingress |
| `substrate-workers` | Runs a WorkerPool with its sizing, an opt-in SELinux admission policy and optional PodMonitors and dashboards |

## Install Substrate

The `substrate-install` chart runs one Job. The Job installs the Substrate release that you name in `substrate.version`.

The Job uses the install image in `images/substrate-install/`. CI builds the image. The image holds `ate-setup`, `kustomize` and the checkout of the pinned release. A Substrate release ships no `ate-setup` binary, so the build compiles it from the release tag. The build checks that the tag names the pinned commit. A running Job downloads nothing.

To install:

1. Copy `charts/substrate-install/ci/aws-values.yaml` or `charts/substrate-install/ci/onprem-values.yaml`.
2. Replace the placeholder values with your own. For a small self-managed cluster, start from `examples/onprem/install-values.yaml` instead.
3. Set `image.digest` to the digest of the published install image.
4. Install the chart with your values file, or sync it with Argo CD.

The `config` value is the body of the upstream `SubstrateInstall` document. The chart adds `images`, `sandboxClasses` and `context`. It also derives `storage.snapshotLocation` and `storage.bucketName` from the storage profile (see Storage profiles). The sizing settings `clusterSize` and `rolloutTimeout` are `config` keys. Set secret settings, such as the database connection string, in `env` with a `secretKeyRef`. `ate-setup` also refuses to deploy without a credential provider setting. Set `config.atenet.egress.credentialProvider` to `{"name":"k8s.io"}` for the bundled Secrets provider, or to `{"enabled":false}` to turn off egress credential injection. The `ci` values files do not set it.

### How the Job works

1. The `seed` init container copies the checkout from the image to a writable directory.
2. The `patch` init container adds each patch to the kustomization in that copy.
3. The `patch-postgres` init container renders the Postgres sizing patch over the Postgres manifest in that copy (see Postgres sizing).
4. The `deploy` container runs `ate-setup deploy ate-system` in the copy.

Kubernetes finishes the init containers before the `deploy` container starts. The patches therefore always apply before the deploy, and a sync never brings back the upstream defaults. A chart unit test and `make test-image` check this.

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

### Postgres sizing

Upstream hardcodes the bundled control plane Postgres: a 2 CPU and 1 GiB request, a 16 CPU and 2 GiB limit and a 500 GiB volume. A small node cannot schedule that next to the other control plane pods. The `postgres` values set the numbers, and the defaults are the upstream numbers:

| Value | Default | Meaning |
|---|---|---|
| `postgres.resources.requests.cpu` | `"2"` | CPU request, such as `"2"` or `250m` |
| `postgres.resources.requests.memory` | `1Gi` | Memory request |
| `postgres.resources.limits.cpu` | `"16"` | CPU limit |
| `postgres.resources.limits.memory` | `2Gi` | Memory limit |
| `postgres.storage` | `500Gi` | Size of the data volume. The size also holds the WAL, so a full `pg_wal` cannot drop every connection |

Write the CPU and memory values as strings. The schema rejects other forms, unknown keys and zero. The chart generates the patch `30-postgres-sizing`. `ate-setup` applies the Postgres manifest on its own, outside the kustomization that the `patch` container edits. The `patch-postgres` container therefore builds that manifest with the patch and writes the result back over the manifest in the copy, before the deploy. The merge patch has no target. If no StatefulSet named `postgres` exists, the build fails and so does the install. The patch changes only the `postgres` container and its `data` volume claim. A `test` operation stops the install if upstream moves either one.

Three limits:

- The volume claim of a StatefulSet cannot change on a running cluster (see upstream #3691), so a new `postgres.storage` fails on a cluster that is installed. Set the size before the first install. To resize later, delete the StatefulSet with `--cascade=orphan`, grow the claim by hand if the storage class allows it, and run the install again.
- With `config.clusterSize: size10`, `ate-setup` sets the CPU and memory of the container itself, after this patch. Only `postgres.storage` still applies.
- The kind install profile of `ate-setup` (`kind: true`) reads `kind/postgres` and not this manifest, and that overlay sets the CPU and the storage again. The patch does not apply there. The chart sets no kind profile, so this matters only if you set it through `env`.

`make test-image` runs the command that the chart gives the Job on the real v1.0.0 manifest, with the default values and with changed values, and verifies the requests, the limits and the claim. It also verifies that the command fails when no StatefulSet is named `postgres`.

### Publish the image

CI pushes the multi-arch image to `ghcr.io/bbaliyan/kube-agent-substrate/substrate-install` on every push to `main`. The tag is `main-<short sha>` and the job summary shows the digest. CI does not push release tags. The owner tags.

GitHub creates the package as private. The owner must make it public once, in the package settings.

The chart pins the image by digest. The default `image.digest` is all zeros and never pulls. Set it from the published digest, in a release commit or with a Renovate regex manager. An unset digest fails the pod with an image pull error, not a silent unpinned install.

### SELinux on atelet

On nodes that enforce SELinux, `atelet` runs as `container_t` and cannot write `/var/lib/ate`. It exits at start with `permission denied`. Set `selinux.enabled` to `true`. The chart then generates the patch `25-atelet-selinux`. The patch adds the SELinux type from `selinux.type` (default `spc_t`) and, if set, the level from `selinux.level` to the pod spec of the `atelet` DaemonSet. The patch has no target, so the build fails if the manifests hold no DaemonSet named `atelet` in `ate-system`. The switch is off by default. Turn it on together with `selinux.enabled` of the `substrate-workers` chart. Upstream issue #3597. `make test-image` applies the patch to the real release manifest.

We recommend the stock confined type: set `selinux.type` to `container_engine_t` and `selinux.level` to a fixed level, for example `s0:c100,c200`. The level is required with any type other than `spc_t`. Without it, containerd gives each container of the pod its own MCS categories, and the object-store plugin cannot read the pod files. The chart fails the render if the level is missing. The node must label `/var/lib/ate` as `container_file_t` at level `s0` (see `docs/onprem-nodes.md`). Known limit: under `container_engine_t` the SELinux policy denies the `connectto` of `atelet` to the kubelet socket. The device plugin cannot register `ate.dev/kvm`, so the node offers none. The gVisor class needs no such resource. Keep `spc_t` as the fallback: it needs no node setup and no level.

### microVMs are out

The install uses the gVisor sandbox class only. The chart sets `sandboxClasses: gvisor` and a value cannot change it. A microVM class on a cluster that is not kind needs a cloud CLI to stage its assets, which the image does not hold. Use gVisor until this changes.

## Run workers

The `substrate-workers` chart renders one WorkerPool in the release namespace. One release is one pool. The worker image is the gVisor `ateworker` image of the Substrate release, pinned by tag and digest. The tag must match the control plane release.

To run a pool:

1. Copy `charts/substrate-workers/ci/aws-values.yaml` or `charts/substrate-workers/ci/onprem-values.yaml`.
2. Set `pool.name`, `pool.labels` and the node selector. The `workerSelector` of an actor matches the pool labels.
3. Set `workers.replicas`, `workers.cpu` and `workers.memory`.
4. Install the chart in the namespace of the pool.

### Sizing

Sizing comes only from values. The chart sets the limits equal to the requests, so each worker pod is Guaranteed. A worker needs room beside the control-plane pods on the same nodes: after the control plane has its share, a node must have `cpu` and `memory` free for each worker that runs on it.

The `workers` values size the pool only. The install pod is sized in the `substrate-install` values. The control-plane database is not configurable yet: upstream sets its resources in the manifests, at 2 CPUs and 1 GiB of memory. On a small node, count these in the room that the control plane takes.

### One CPU model for each pool

Use one CPU model in a WorkerPool. A gVisor golden snapshot is pinned to the CPU feature set of the worker that made the checkpoint (upstream issue #1657). A worker with another feature set cannot restore it.

- AWS: do not mix instance types in a pool. One instance type can still span processor generations (an `m5` runs on Skylake or Cascade Lake). Use an instance family with a single processor generation, such as `m6i`, or pin the hardware in another way. Select it with `pool.nodeSelector`, or use one node group for the pool.
- Proxmox: set a fixed VM CPU type, such as a named model. Do not use `host` on mixed hardware, because `host` passes the real features of each physical CPU.

Use a second pool, with its own CPU model, for other hardware.

### Node requirements

The cluster needs the Pod Certificate and ClusterTrustBundle APIs, a default StorageClass, the `privileged` Pod Security level on the control plane and worker namespaces, and one CPU type for each pool. Nested virtualization is needed only for microVMs, which are out for now. `docs/onprem-nodes.md` lists each requirement with a command that verifies it. `examples/onprem/` holds ready-to-use values for a small cluster with an S3-compatible store (RustFS) in the same cluster.

### SELinux nodes

This policy covers worker pods only. The `atelet` pods need the `selinux.enabled` switch of the `substrate-install` chart (see "SELinux on atelet"). Turn on both switches.

On nodes that enforce SELinux (the RHEL family), worker pods run as `container_t`. They cannot write the `/var/lib/ate` host path, and the `ateworker` exits at start (upstream issue #3597, open). The WorkerPool has no `securityContext` field and the control plane creates the pods, so only admission can fix it.

Set `selinux.enabled` to `true`. The chart then renders a `MutatingAdmissionPolicy` and its binding. They set the SELinux type from `selinux.type` (default `spc_t`; we recommend `container_engine_t`) on the pods that carry the label `ate.dev/worker-pool=<pool name>`, in the release namespace. No other pod is matched. The policy uses an `objectSelector` and no match conditions. It has `reinvocationPolicy: IfNeeded` and `failurePolicy: Fail`. The mutation is an `ApplyConfiguration` merge, so it works when the pod has no `securityContext` yet.

Worker pods need no level: they have one container. The node needs the `/var/lib/ate` label described in "SELinux on atelet". The switch is off by default. Verify that your nodes need it before you turn it on.

A policy takes a few seconds to become active, and a pod that exists before then stays unpatched. The policy objects carry the Argo CD sync wave `-1`, so Argo CD applies them before the pool. With Helm, install the chart with `workers.replicas` set to `0`, wait a few seconds, then set the real value. If a worker pod started without the patch, delete the pod.

Minimum version: Kubernetes 1.36. The API is `admissionregistration.k8s.io/v1` `MutatingAdmissionPolicy`, which is GA and on by default from 1.36. On 1.34 and 1.35 it is `v1beta1` behind the feature gate `MutatingAdmissionPolicy` and the runtime-config of that API, and the chart does not render that version.

### Observability

Set `observability.enabled` to `true` to render PodMonitors and dashboard ConfigMaps. It is off by default. With it off, the chart renders no `monitoring.coreos.com` object or other provider CRD, so a cluster without the Prometheus Operator installs with it off. A unit test verifies this.

Upstream sends its metrics over OTLP to a collector, not to a Prometheus scrape. Only some components also serve a Prometheus endpoint. The chart creates one PodMonitor for each of these, from `observability.components`: `ate-api-server`, `atelet`, `ate-controller` (a pull listener on port 8080, on only when the controller does not push metrics) and the Envoy metrics port of `atenet-router` and `atenet-egress`. Set `observability.podMonitorLabels` to the labels your Prometheus selects. The router and egress components have two entries each: the Envoy port and the `metrics` port. Edit `components` if a port differs on your release.

The PodMonitors select the control plane, not the pool. Each release with `observability.enabled` renders the same ones. Turn observability on in one release only.

Upstream v1.0.0 ships no Grafana dashboard. Add your own in `observability.dashboards`: each key is a file name and each value is the dashboard JSON. The chart makes one ConfigMap for each, with the label `grafana_dashboard: "1"`. Change the label with `observability.dashboardLabel` to match your Grafana sidecar.

## Register actors

An ActorTemplate, an Actor and an EgressPolicy are not Kubernetes resources. They live in the control plane database, and only `kubectl ate` writes them. The `substrate-registration` chart runs one Job that does this for the actors of the `substrate-actor` chart.

To register:

1. Install the `substrate-actor` chart. It renders one ConfigMap for each actor.
2. Add the service account of the Job to the bootstrap owners of the control plane. The Job creates atespaces, and only a global owner can. Append `system:serviceaccount:<namespace>:<release>-substrate-registration` to `config.ateapi.authz.bootstrapOwners` in the `substrate-install` values. The value is one comma-separated string. Do not replace the list. A set list drops the default `ate-client` principal, which the upstream demos and `ate-setup` use. Add `system:serviceaccount:ate-system:ate-client` to the list if you still need it.
3. Enable the preview gate `PerTemplateSnapshotLocation` on the control plane. The template of each actor names its snapshot location, and the server accepts that only with the gate. Set `config.preview` to `PerTemplateSnapshotLocation` in the `substrate-install` values. The Job passes `--preview` to `kubectl ate` for the same reason.
4. Copy `charts/substrate-registration/ci/aws-values.yaml` or `onprem-values.yaml`. Use the same `snapshotStorageLocation` and `actors` as the actor release. One values file can serve both releases.
5. Set `image.digest` to the digest of the published registration image.
6. Install the chart with your values file, or sync it with Argo CD.

### How the Job works

1. It waits until `kubectl ate` can read the atespaces. This shows that a pod of `ate-api-server` is ready.
2. For each actor, it waits until the ConfigMap holds the template name and the egress hash that the Job expects. A stale ConfigMap never gets registered.
3. It creates the atespace if it is missing.
4. If the actor does not exist, it creates the template and the actor.
5. If the actor is `ACTOR_STATE_DELETING`, an earlier delete did not finish. It runs the delete again and creates the actor.
6. If the actor uses an older template and is `ACTOR_STATE_SUSPENDED`, it moves the actor with `kubectl ate update actor --template`. The actor keeps its identity. Its memory and root filesystem restart from the new template, because the new template defines a new process. If the server refuses the update, for example because the snapshot location changed, the Job deletes the actor and creates it again. The state is lost, and the log says so.
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
- A changed template moves a suspended actor in place with the same identity, and the Job fails on a resumed actor, then moves it after suspend.
- An egress-only change updates the live policy in place, and a run after it changes nothing. The real protojson output of `get egress-policy` matches the rules that the chart renders.
- The Job authenticates with its own token and the RBAC above, with no extra grant.

### Publish the registration image

CI pushes the multi-arch image to `ghcr.io/bbaliyan/kube-agent-substrate/substrate-registration` on every push to `main`, like the install image. The image holds `kubectl-ate`, `jq`, `curl` and `bash`. The `substrate-idle-suspend` chart uses the same image. The build compiles `kubectl-ate` from the release tag and checks the commit. It downloads `jq` for each architecture and verifies a pinned SHA-256 checksum. A running Job downloads nothing. `make test-image-registration` runs the tools of the image.

## Suspend idle actors

Agent Substrate v1.0.0 never suspends an idle actor. Suspend is an API call, and the caller must make it (upstream issues #424 and #483). The `substrate-idle-suspend` chart makes this call for the actors that you list. It is a separate chart, so you can delete it when upstream ships its own policy.

The chart runs one CronJob. The CronJob uses the registration image, which holds `kubectl-ate`, `jq` and `curl`. It has a service account of its own. `concurrencyPolicy` is `Forbid`, and a failed run is not retried: the next schedule is the retry.

To use it:

1. Run Prometheus, and make it scrape the router, the egress proxy, ate-api-server and atelet (see "The signals").
2. Copy `charts/substrate-idle-suspend/ci/aws-values.yaml` or `onprem-values.yaml`.
3. Set `actors` to the atespace and name of each actor, `prometheus.url`, and `image.digest` to the digest of the registration image.
4. Set `schedule` and `idleMinutes`. The defaults are every 5 minutes and 30 minutes of idle time. `idleCpuCores` is the CPU use that still counts as idle. The default is 0.05 cores.
5. Grant the service account of the CronJob the `editor` role in the atespace of each actor. The principal is `user:system:serviceaccount:<release namespace>:<service account name>`. The service account name is `<release>-substrate-idle-suspend`, or only `<release>` if the release name already contains `substrate-idle-suspend`, cut to 40 characters. The value `serviceAccount.name` replaces it. To read the real name, run `kubectl -n <release namespace> get cronjob -o jsonpath='{.items[*].spec.jobTemplate.spec.template.spec.serviceAccountName}'`. Add the principal to the access policy of the atespace with `kubectl ate update access-policy -a <atespace>`. The chart cannot do this for you, because the control plane keeps access policies in its database, and it has no value for it. The account can then read and suspend the actors of that atespace and nothing else. Do not make it a bootstrap owner.
6. Install the chart, or sync it with Argo CD.

If Prometheus needs a bearer token, put the token in a Secret and set `prometheus.bearerTokenSecret.name`. If it uses a private CA, set `prometheus.caSecret.name`.

### How a run works

For each actor in `actors`, the script does these steps:

1. It reads the state of the actor with `kubectl ate get actor`. It does not read the state from metrics, because a series can outlive the actor.
2. If the actor does not exist, the run fails with a clear message.
3. If the actor is not `ACTOR_STATE_RUNNING`, it does nothing.
4. It reads the signals from Prometheus (see below).
5. If every signal says idle, it runs `kubectl ate suspend actor`. If any signal says busy, it does nothing.

The chart has no declarative option for step 5: the control plane has no resource for a suspend. The header of the script says so.

### The signals

Substrate puts no actor name on a metric, because that would give every actor its own series. The metrics carry the template of the actor. The substrate-actor chart gives each actor its own template, so a signal that carries the template is a signal of that actor. If you share one template between actors, a busy actor keeps its neighbours awake. This fails safe.

All names are the OpenTelemetry names of the Substrate metric registry (`docs/metrics/registry/metrics.yaml` of the release) after the Prometheus conversion.

| Signal | Query reads | Busy when |
|---|---|---|
| `health` (four queries) | `envoy_server_live` for `inflight`, and `go_memstats_alloc_bytes` with the pod label `app` of the router (`routed`), of ate-api-server (`resumed`) and of atelet (`cpu`) | A result that is not above 0 fails the run. This proves that each source of a signal is scraped. Without it, a renamed or unscraped series would read as silence |
| `routed` | `atenet_router_route_duration_seconds_count` for the template | The count changed in the idle time. The router and the egress proxy record every routed request here |
| `resumed` | `ate_actor_lifecycle_operation_duration_seconds_count` with `ate_actor_operation_name="resume"` for the template | ateapi resumed the actor in the idle time. The actor did not rest for the full time |
| `inflight` | `envoy_cluster_upstream_rq_active` for the `actor_*` clusters of the router | A request or an open tunnel was active at any time in the idle time. Envoy has no series for one actor, so this signal is the same for every actor: one open tunnel of any client keeps every watched actor busy. A tunnel that nobody uses closes after 60 seconds |
| `cpu` | `ate_actor_stats_cpu_time_seconds_total` for the template | The rate over the idle time is above `idleCpuCores` |

Upstream v1.0.0 has no metric or field for the last activity of an actor. The `routed` and `resumed` queries compare the count now with the count one idle time ago. They do not use `increase()`, because a counter that starts at 1 has no earlier sample, and `increase()` would read 0 for the first request.

The queries are values (`queries.*`). Change them if your backend names the metrics another way, for example with Google Managed Prometheus. The script replaces `@ATESPACE@`, `@TEMPLATE@` and `@WINDOW@`.

The check of an actor ends at the first busy signal, so the later queries do not run. An actor that was just resumed has no CPU series yet, and this keeps it from failing the run.

### The fail-safe rule

The script suspends an actor only when all of these are true:

- `kubectl ate` read the actor and the state is `ACTOR_STATE_RUNNING`.
- Every query returned exactly one number.
- Each `health` query shows that its source is scraped.
- Every signal says idle.

Any other result ends the run with a non-zero exit code and suspends nothing for that actor. This includes a refused query, an HTTP error, no sample, many samples, a value that is not a number, a template name that is not a plain name, and a failed `kubectl ate` call. One failing actor does not stop the check of the next actor, and the run still fails at the end.

The `inflight` signal is fleet-wide and counts tunnels. This is the safe side: it can delay a suspend, never cause one. The cost is that a long-lived tunnel of one client holds back the suspend of every actor. If that is too coarse for you, narrow the `inflight` query to the clusters that you use. Do not remove it.

A request can still arrive between the last query and the suspend. A request that is younger than one scrape interval is not in the data yet. The idle time makes this rare, not impossible, so keep `idleMinutes` well above the scrape interval. The router parks a request for a suspended actor until the actor has resumed, so a request that arrives after the suspend is not lost. Upstream v1.0.0 documents no drain of a request that is already running on the actor, so a suspend at that moment can cut it.

### What the kind harness verifies

`make test-integration` deploys a minimal Prometheus that scrapes the router, the egress proxy and atelet. The harness installs the chart with an idle time of 1 minute and starts each run of the CronJob by hand. It verifies:

- The service account of the CronJob, with only the editor role of the atespace, can read and suspend the actor.
- A request resumes the suspended actor. A run right after it reports the actor as busy and leaves it running.
- The harness closes the tunnel of its proxy and waits for the idle time. Then the queries for the five signals return numbers, and all of them say idle.
- After the idle time, a run with a query that Prometheus refuses fails and leaves the idle actor running.
- With the default queries, the next run suspends the idle actor.
- A run on a suspended actor does nothing.
- The next request resumes the actor, and its counters continue (they do not restart).
- The default queries return real series: the metric names above exist in the kind cluster.

The harness does not verify:

- The Kubernetes schedule. The harness turns it off and starts each run by hand.
- A busy actor because of CPU alone, and a request in flight. No step creates them. The stub test of the script covers these branches, not the real signals.
- Prometheus with authentication, TLS or Google Managed Prometheus. The harness Prometheus has none of them, and it scrapes every 5 seconds.
- An idle time of 30 minutes. The harness uses 1 minute.

`make test-idle-suspend` runs the script against stubs of `kubectl-ate` and `curl`. It covers an idle actor, each busy signal, each kind of query error, an actor that is not running and an actor that does not exist.

## Define an actor

1. Copy `charts/substrate-actor/ci/aws-values.yaml` or `charts/substrate-actor/ci/onprem-values.yaml`.
2. Replace the placeholder values with your own.
3. Add one entry to `actors` for each actor.
4. Install the chart with your values file.

The `aws` and `onprem` files differ only in values: the snapshot location, the secret store and the ingress class. The `*-multi-values.yaml` files show several actors in one release.

The values schema rejects an image reference that has no digest.

### Trust the egress gateway

An `https` egress rule ends TLS at the egress gateway, so the application must trust the gateway CA. Set `egressTrustBundle: true` on the actor. The chart then adds a system information volume to the ActorTemplate. The volume holds the gateway CA and the public roots in one file, `/run/ate/egress-trust-bundle/trust-bundle.pem`.

The chart does not set environment variables. Point the application at the file. For many programs, set `SSL_CERT_FILE`. Python `requests` reads `REQUESTS_CA_BUNDLE`. See the upstream guide `egress-trust-bundle`. The key changes the template name, so a running actor moves to a new template at the next registration.

## Webhook shim

An actor can have a `webhook` block. The chart then runs a shim in front of the actor. The shim is a stock Envoy pod from a pinned image (`webhookShimImage`). You build no image and write no code.

**Warning: this is a breaking change.** The settings `webhook.image`, `webhook.args` and `webhook.env` no longer exist, and the schema rejects them. The setting `webhook.secret` is now required. Move any custom shim logic to the sender or to the actor.

### How a request flows

1. The sender, for example GitLab, sends the webhook to the shim. With an ingress, the request comes through the ingress.
2. The shim compares the header `X-Gitlab-Token` with the secret file. If the header is missing or wrong, the shim answers 401. The shim removes trailing white space and new lines from the file before it compares. If the file is empty, the shim answers 401 to every request.
3. If the header matches, the shim replaces the token with the hop token. It sets the header `ate-target-actor` to `<atespace>/<actor>`.
4. The shim sends the request to the ingress router of the control plane over mTLS. The router resumes a suspended actor and routes the request.

The real secret stays in the Secret that `webhook.secret` names. The pod mounts it as a file, and the shim reads the file on every request. A new value in the Secret takes effect after the kubelet refreshes the mount. The actor, the ConfigMap and the values never hold the real secret.

The hop token is a public value. It is not a secret. Set the token that the actor checks to the hop token. The router allowlist guards this last hop, not the hop token.

### Values

| Value | Meaning |
|---|---|
| `webhook.secret.name` | The name of the Secret that holds the webhook secret. Required. |
| `webhook.secret.key` | The key in the Secret. The default is `WEBHOOK_SECRET`. |
| `webhook.secret.externalSecret` | Makes an ExternalSecret for the Secret. Optional. |
| `webhook.hopToken` | The token that the actor sees. The default is `substrate-webhook-hop`. |
| `webhook.port` | The port of the shim and its Service. The default is 8080. |
| `webhook.timeoutSeconds` | The time that the shim waits for the router, all tries together. The default is 75. |
| `webhook.retries` | How many more tries the shim makes. The default is 2. |
| `webhook.perTryTimeoutSeconds` | The time that one try waits. The default is 25. |
| `webhook.keepWarmSeconds` | The seconds between keep-warm requests to the actor. The default is 30. Set 0 to turn them off. |
| `webhook.keepWarmPath` | The path of the keep-warm request. The actor must answer 200. The default is `/`. |
| `webhook.keepWarmTimeoutSeconds` | The time that a keep-warm request waits for a cold actor. The default is 30. |
| `webhook.allowFrom` | The `from` entries of a NetworkPolicy for the shim pod. With none, the chart renders no policy. |
| `webhook.ingress` | An optional Ingress for the shim. |
| `router.host`, `router.port` | The router Service. The defaults are `atenet-router.ate-system.svc` and 443. |

### Cold start

A suspended or new actor needs about 15 seconds to start. The router resumes the actor before it routes the request. While it resumes, the router can answer 502 or 504.

The shim tries again after a refused connection, a reset before the request, a 502, a 503, a 504 and a try that runs out of time. The defaults are 2 more tries, 25 seconds for each try and 75 seconds in total. In a rare case, one webhook reaches the actor twice. The actor must tolerate a duplicate. A second review is a smaller loss than a lost review.

The shim stops its request when the sender leaves. If the actor needs longer to resume than the sender waits, the delivery is lost, because the router never finishes the request. `make test-shim` shows this. Envoy cannot answer the sender at once and keep the delivery going with retries. The chart therefore cannot make a slow start safe on its own. Use these measures:

1. Keep the actor running. Do not install `substrate-idle-suspend` for an actor with a webhook.
2. Keep the actor warm. Every `webhook.keepWarmSeconds`, the shim asks the actor for a 200 through the router. The router resumes a suspended actor for that request. After a restart of the node or the worker, the actor resumes within one interval. This relies on the router resuming an actor for any request. It is not verified on a real router.
3. Resume the actor once after you register it, so the first webhook does not find a new actor.
4. If the sender can wait longer, raise its webhook timeout. For a self-managed GitLab, set `gitlab_rails['webhook_timeout']` in `gitlab.rb`, then reconfigure and restart. The GitLab documentation gives no default and no maximum.

GitLab can record a failure for a delivery that times out. After four failures in a row, GitLab disables the webhook for 1 minute, and up to 24 hours after more failures. After 40 failures in a row, GitLab disables it for good. A request from the GitLab page of recent events can resend a delivery, and a test request that gets a 2xx answer enables the webhook again.

The shim runs one pod, and the chart makes no PodDisruptionBudget. A node drain stops the shim for a short time, and GitLab records a failure for any delivery in that time.

### Set up the router

1. Install the `substrate-install` chart before you install an actor with a webhook. The shim needs the pod certificate signers of the install.
2. Add the identity of the shim to `config.ingressAllowedSPIFFEIDs` in the `substrate-install` values. The identity is `spiffe://<trust domain>/ns/<namespace>/sa/<actor>-webhook`. The value is one comma-separated string. Do not replace the list.
3. Use the HTTPS ingress port of the router (443). The CONNECT listener of the router answers 404 to a plain request.
4. If the actor listens on a port other than 80, set the port in the actor template. The router reaches the actor on port 80 by default.
5. To limit who can call the shim, set `webhook.allowFrom`. For an ingress, allow the namespace of the ingress controller. For a sender in the same cluster, allow the namespace of the sender.

### What `make test-shim` verifies

The test renders the chart and starts the rendered shim in Docker. The shim runs as a non-root user on a read-only file system. It sends requests to a stand-in router that needs a client certificate. The test verifies:

- A missing token, a wrong token, and the right token with extra bytes all get 401.
- A missing secret file, an empty secret file and a secret file of white space only get 401 for every request. An empty token gets 401 too.
- A secret file that ends in a new line still matches the right token.
- The right token reaches the router with the target header and the hop token.
- After a change of the secret file, the old token gets 401 and the new token gets 200.
- A router that always answers 502 or 504 gets the POST 3 times, and the sender gets that answer.
- A router that answers 504 once, as it does while it resumes an actor, and then answers 200: the retry reaches the router, and the sender gets the 200. The router receives the POST twice.
- A try that runs out of time is tried again and gets the 200.
- A slow start that succeeds reaches a sender that waits.
- A sender that leaves early takes the request with it: the router received the POST and never finished it.
- The keep-warm request reaches the router at the set interval, with the target header.
- A router with a certificate for another host name is refused. The shim answers 503.
- A shim with a client certificate from an unknown CA is refused by the router. The shim answers 503. Another shim with a valid certificate gets 200 from the same router, so the client certificate is what the router checks.
- The health route answers without a token.

The test does not cover the real router, a real pod certificate signer, or the kubelet that rotates certificates. It does not cover the file read under gVisor, a pod with the real Kubernetes security context, or a retry after a refused connection. It does not cover whether a real router resumes a suspended actor for a keep-warm request.

## Checks

Run `make test-commit` in the kube-devenv image. It lints the charts, runs the chart unit tests and scans for secrets. It also runs the registration script against a stub of `kubectl-ate` (`make test-register`) and checks that the actor and registration charts agree on template names (`make test-contract`). The stub tests the idle gate and the no-change rerun, not the real client. `make test-idle-suspend` runs the script of the `substrate-idle-suspend` chart against stubs of `kubectl-ate` and `curl`.

Run `make test-image` on a host with Docker, `helm` and `awk`. It builds the install image and runs the patch steps on the real release checkout. It also applies the generated storage patch of each `ci` values file and verifies the backend on both plugin sidecars. CI runs it, and builds the arm64 image. CI does not push the image yet.

Run `make test-shim` on a host with Docker, `helm`, `openssl` and `curl`. It runs the webhook shim in Docker against a stand-in router (see "Webhook shim"). CI runs it.

`make test-examples` lints and renders the values of `examples/onprem/` for every chart, validates them against the schemas, and verifies that the install values point at the RustFS Service and turn the SELinux patch on.

The render lint is a quick lint. It runs `helm template` and `kubeconform` for each file in `charts/*/ci/`: the `aws` and `onprem` profiles, each with one actor and with several. It does not prove that an install works.

### Integration test

`make test-integration` is the main test of this repo. It needs Docker, `kubectl`, `helm`, `jq` and `curl`. It took 385 seconds on a Linux host with 16 cores and warm image layers. It is not part of `make test-commit`. The kind cluster, the registry and the files of a run are deleted when it ends. Set `KEEP_CLUSTER=1` to keep them.

The test does these steps, in order:

1. It builds the install image, the registration image and the counter demo actor image from this repo and the pinned Substrate release. It pushes them to a registry that it starts next to the cluster. The charts pin the images by their pushed digest.
2. It creates one kind node with the cluster settings that Substrate needs: the pod certificate and cluster trust bundle APIs.
3. It deploys RustFS and creates the snapshot bucket. RustFS 1.0.x cannot create a bucket itself, so a Job with the pinned AWS CLI image does it. The keys are fixed test values in a Secret that the test creates.
4. It installs the `substrate-install` chart with the `s3-compatible` storage profile and waits for the install Job to finish.
5. It installs the `substrate-workers` chart for the worker pool, installs the `substrate-actor` chart and the `substrate-registration` chart for one actor, and checks that the actor registers.
6. It resumes the actor and sends it requests through `kubectl ate proxy`. It suspends the actor, drops its node-local snapshot with a revert and resumes it again. The test verifies that the memory and root filesystem counters continue and that atelet downloaded the snapshot from RustFS. Then it suspends the actor. The test fails if the actor is not `ACTOR_STATE_RUNNING` after a resume or not `ACTOR_STATE_SUSPENDED` after a suspend.
7. It runs the install Job and the registration Job again, and verifies that nothing changes.
8. It verifies that the live egress policy equals the rules that the chart renders.
9. It changes the template and verifies that the suspended actor moves in place with the same identity and that its counters restart from the new template. The chart has no durable volumes, so the test does not verify that a volume survives the move.
10. It changes the template again while the actor runs and verifies that the Job fails. It suspends the actor and verifies that the Job then moves it.
11. It changes only the egress rules and verifies that the policy updates in place.
12. It deploys a minimal Prometheus and the `substrate-idle-suspend` chart, and verifies that a busy actor stays, a failing signal query suspends nothing, an idle actor is suspended and the next request resumes it. See "Suspend idle actors".

The files are in `tests/integration/`: `run.sh` runs the steps, and the manifests and values hold every setting. The pods of the finished test request 3510m CPU and 3650Mi of memory, with the small Postgres numbers of `install-values.yaml`. The test fails if they request more than 4 CPUs, the size of a GitHub runner. It passed on a kind node capped at 4 CPUs and 8 GiB (485 seconds, no OOM kill) and on the runner (508 seconds).

The test does not cover:

- IAM-based S3 access. It uses static keys against RustFS. The `aws` profile is checked only by the render tests and by `make test-image`.
- SELinux enforcement. The kind node does not enforce it, so the test cannot show that `spc_t` lets a worker write `/var/lib/ate`. It turns the policy on and verifies only that the admission policy sets `spc_t` (the default) on both worker pods.
- Observability. The cluster has no Prometheus Operator. The unit tests cover the render only.
- The CPU model of a Proxmox worker pool and the restore of a golden snapshot on another CPU. The cluster has one node.
- microVMs. The install uses the gVisor class only.
- Credential injection. The test sets the credential provider to off. The sample actor has egress rules without credentials.
- The webhook shim against the real router, the ingress and the External Secrets resources of the `substrate-actor` chart. `make test-shim` covers the shim against a stand-in router.
- Several actors, several nodes and the `arm64` architecture. The test runs the architecture of the host.
- Registry and object store TLS. The test uses plain HTTP inside the cluster.

Not covered by any check in this repo:

- An install on a real cluster in CI. The integration test runs the same charts and images on kind. A manual run on a self-managed RKE2 cluster with SELinux enforcing passed once (see `docs/onprem-nodes.md`), and CI does not repeat it.

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
| Opt-in SELinux fix, atelet and workers both: the `selinux.enabled` switch of the `substrate-workers` chart (admission policy, because a WorkerPool has no `securityContext`) and the `selinux.enabled` switch of the `substrate-install` chart (patch `25-atelet-selinux` on the atelet pod spec). Both pod kinds run as `container_t` on SELinux nodes and cannot write `/var/lib/ate`. `selinux.type` defaults to `spc_t`; `container_engine_t` with `selinux.level` on atelet is the recommended setting. Verified in a manual run on a self-managed RKE2 cluster with SELinux enforcing: atelet and a worker exit with `permission denied` without the switch and run with it. A second run with `container_engine_t` passed the full lifecycle, with the `ate.dev/kvm` limit above | #3597 | The policy, the patch, both switches, the `selinux.type` and `selinux.level` values and the node label note, once the pods get the right SELinux type without them |
| The `substrate-idle-suspend` chart: a CronJob suspends an idle running actor, because Substrate v1.0.0 suspends no idle actor and leaves it to the caller. The planned actor-side `/suspend` endpoint of v1.1 needs the actor to call it, which a third-party image cannot do | #424 (no automatic suspend of idle actors), #483 (idle policy and the actor-side suspend endpoint) | The whole chart, and `curl` in `images/substrate-registration`, once upstream suspends idle actors by its own policy |
| One CPU model for each WorkerPool, as a documented rule | #1657 | The rule |
| The control-plane database resources are fixed in the upstream manifests (2 CPUs, 1 GiB) and no chart value sets them | none known | The note in the sizing section, once the install chart can set them |
| Bucket rule: abort incomplete multipart uploads only, no blanket expiry. Objects left by a failed checkpoint upload need a separate cleanup | #610 | The note, once upstream removes them |
| PodMonitors for clusters without the GKE `PodMonitoring` CRD, behind `observability.enabled` in the `substrate-workers` chart | #2589 | The PodMonitors |
| On-prem profile values in `examples/onprem/` and the node requirements in `docs/onprem-nodes.md`. Manual run on a self-managed RKE2 cluster with SELinux enforcing, with RustFS: install, workers, a sample actor with suspend, resume and a restore from RustFS. Not run there: idle-suspend, observability, several nodes | #1782 | The profile, once upstream ships one |
| RustFS with large sparse multipart uploads. Verified on kind with RustFS 1.0.3: a 257 MiB snapshot (256 MiB of random data in the actor) uploaded as one object of 9 parts, and the actor resumed from it after a revert dropped the node-local copy. Not verified: the 64 to 128 MiB range of the issue, many uploads at once and a real disk | #3921 | The note, once a test covers the 64 to 128 MiB range and parallel uploads |
| Stub of the GKE `PodMonitoring` CRD in the integration test, because the base manifests hold a `PodMonitoring` object and `ate-setup` stops without the CRD. A cluster without the GKE operator needs a stub or a patch that drops the object. The install chart has neither yet | #2589 | The stub, once the install no longer applies the object |
| `--preview` in the registration Job, because the actor chart sets a snapshot location in every template and the server forbids it without the client flag | none known | The flag, once the actor chart leaves the location out |
| Postgres sizing patch `30-postgres-sizing`: the chart sets the requests, limits and volume size of the bundled Postgres, because upstream hardcodes 2 CPU / 1 GiB requests, 16 CPU / 2 GiB limits and 500 Gi | #3167 (`--component`) plus #3168 (sizing contract) | The generated patch, the `patch-postgres` init container and the `postgres` values, once upstream offers both |

## License

Apache-2.0.
