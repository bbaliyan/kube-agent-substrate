# kube-agent-substrate

Helm charts that install the [Agent Substrate](https://github.com/agent-substrate/substrate) v1.0.0 control plane on a Kubernetes cluster and run actors on it. An actor is a sandboxed process that Substrate can suspend to a snapshot and resume later.

## Charts

| Chart | What it does |
|---|---|
| `substrate-install` | Installs or upgrades the control plane. A Job runs `ate-setup` from a pinned install image. |
| `substrate-workers` | Runs one WorkerPool: the gVisor worker pods that run actors. |
| `substrate-actor` | Defines actors from a list in values: image by digest, environment, resources and egress rules. |
| `substrate-registration` | Registers the actors of `substrate-actor` in the control plane. A Job runs `kubectl-ate` from a pinned registration image. |
| `substrate-idle-suspend` | Optional. A CronJob suspends running actors that are idle, based on Prometheus metrics. |

## Where it runs

The charts use plain Kubernetes objects. They do not depend on one cloud or distribution. These facts limit where they run:

- Storage has two profiles: `aws` (Amazon S3 with the IAM role of the node) and `s3-compatible` (any S3 API store with static keys). There is no Google Cloud Storage or Azure Blob profile.
- The cluster must serve the Pod Certificate and ClusterTrustBundle APIs. If you cannot set API server feature gates, as on most managed clusters, your Kubernetes version must serve them by default.
- The install always removes the image credential provider settings of `atelet` (patch `10-atelet-no-credential-provider`). An actor image that needs a kubelet credential provider, such as a private Amazon ECR repository, is therefore not expected to pull. This is not verified.
- Only the gVisor sandbox class is installed. microVMs are not supported.

What was verified, and where:

| Platform | What ran | How often |
|---|---|---|
| kind, Kubernetes 1.37, one node | The full lifecycle with the `s3-compatible` profile and RustFS (see [Integration test](#integration-test)) | CI, on every pull request |
| Self-managed RKE2, Kubernetes 1.37, SELinux enforcing, RustFS | Install, workers, one actor with suspend, resume and a restore from RustFS | One manual run |
| `aws` profile | Render tests, and the storage patch applied to the real release manifests (`make test-image`) | CI |

Not verified: an install on Amazon EKS or any AWS cluster, Google GKE, Azure AKS, several nodes, `arm64` nodes, Kubernetes 1.36, `idle-suspend` and observability on a real cluster, and the private CA of the egress gateway on a live cluster.

## Requirements

- Kubernetes 1.36 or later. Only 1.37 was verified.
- The Pod Certificate and ClusterTrustBundle APIs.
- A default StorageClass for the bundled Postgres.
- The `privileged` Pod Security level on the control plane namespace `ate-system` and on each worker pool namespace.
- The stub of the GKE `PodMonitoring` CRD, on any cluster without the GKE operator. Use `examples/onprem/podmonitoring-crd.yaml`.
- An S3 bucket, or a bucket in an S3-compatible store.
- One CPU model for each worker pool (see [One CPU model for each pool](#one-cpu-model-for-each-pool)).
- trust-manager, only if you set `egress.trustedCaPem`.
- Prometheus that scrapes the control plane, only for `substrate-idle-suspend`.

[docs/cluster-requirements.md](docs/cluster-requirements.md) lists each requirement with a command that verifies it.

## Quick start

Use the files in `examples/onprem/` as a start. They hold values for a small cluster with RustFS in the same cluster. For AWS, start from the `ci/aws-values.yaml` file of each chart. Replace every placeholder value.

1. Verify the requirements with [docs/cluster-requirements.md](docs/cluster-requirements.md).
2. Run `kubectl apply -f examples/onprem/podmonitoring-crd.yaml`.
3. Create the namespace `ate-system` with the label `pod-security.kubernetes.io/enforce=privileged`. Skip this step if you use `credentials.externalSecret`, because the chart then renders the namespace.
4. Create the snapshot bucket.
5. If you use the `s3-compatible` profile with an existing Secret, create the Secret in `ate-system`.
6. Set `image.digest` in the install values (see [Images](#images)).
7. Run `helm upgrade --install substrate-install charts/substrate-install -n substrate-system --create-namespace -f install-values.yaml --wait --wait-for-jobs --timeout 20m`.
8. Create the worker pool namespace with the `privileged` label.
9. Run `helm upgrade --install substrate-workers charts/substrate-workers -n <pool namespace> -f workers-values.yaml`.
10. Run `helm upgrade --install substrate-actor charts/substrate-actor -n substrate-system -f actors-values.yaml`.
11. Run `helm upgrade --install substrate-registration charts/substrate-registration -n substrate-system -f actors-values.yaml --set image.digest=<digest> --wait --wait-for-jobs`.

The `substrate-actor` and `substrate-registration` releases must be in the same namespace, because the Job reads the ConfigMaps of the actors. You can also sync each chart with Argo CD. The charts carry sync waves and hooks for it.

## Install the control plane

The `substrate-install` chart runs one Job that installs the release in `substrate.version` (default `v1.0.0`).

### Values that matter

| Value | Default | Meaning |
|---|---|---|
| `image.digest` | all zeros | Digest of the install image. The all-zero digest never pulls, so the pod fails with an image pull error. |
| `storage.profile` | `aws` | `aws` or `s3-compatible`. Any other value fails the render. |
| `storage.bucket`, `storage.region` | `example-snapshots`, `us-east-1` | The snapshot bucket and its region. |
| `config` | see `values.yaml` | The body of the upstream `SubstrateInstall` document. |
| `env` | `[]` | Environment of `ate-setup`. Use a `secretKeyRef` for secrets, such as `ATE_API_POSTGRES_READ_WRITE_CONNECTION_STRING`. |
| `postgres.*` | upstream numbers | Size of the bundled Postgres (see [Postgres sizing](#postgres-sizing)). |
| `selinux.*` | off | SELinux type of the `atelet` pods (see [SELinux](#selinux)). |
| `egress.trustedCaPem` | `""` | A private CA for the egress gateway (see [Trust a private CA on the egress gateway](#trust-a-private-ca-on-the-egress-gateway)). |
| `rbac.clusterRole` | `cluster-admin` | The role of the Job. The install creates cluster roles, and an account can only grant what it holds. |

Keep `config.namespace` at `ate-system`. The generated patches and other charts name `ate-system` directly.

The chart sets these parts of the document, and a value cannot change them: `apiVersion`, `kind`, `images`, `sandboxClasses: gvisor`, `context`, `gcp.projectID`, `storage.transferGSAName`, `storage.bucketName` and `storage.snapshotLocation`. `ate-setup` treats a cluster that is not kind as GCS and needs a project and a transfer account. S3 uses neither, so the chart sets both to `unused-placeholder`.

`ate-setup` needs a credential provider setting for egress. Set `config.atenet.egress.credentialProvider` to `{"name":"k8s.io"}` for the bundled Secrets provider. Set it to `{"enabled":false}` to turn off credential injection. The `ci/` values files do not set it.

### How the Job works

1. The `seed` init container copies the release checkout from the image to a writable volume.
2. The `patch` init container adds each patch to the kustomization of that copy.
3. The `patch-postgres` init container writes the Postgres sizing over the Postgres manifest.
4. If `egress.trustedCaPem` is set, the `patch-egress` init container writes the CA mount over the egress gateway manifest.
5. The `deploy` container runs `ate-setup deploy` on the patched copy.

The Job and its ConfigMap carry a hash of the pod inputs in their names. A change to the image, the patches, the config, the environment, the resources, the node selector, the tolerations or the service account creates a new Job. The same inputs find the old Job, and nothing runs again. A repeat run on an installed cluster changes nothing.

### Patches

A patch is a kustomize `Component`. The chart applies the patches in the order of their names.

| Patch | Source | When |
|---|---|---|
| `10-atelet-no-credential-provider` | `charts/substrate-install/patches/` | Always. It removes the image credential provider flags and mounts of `atelet`. |
| `20-storage-profile` | Generated from `storage` | Always. |
| `25-atelet-selinux` | Generated from `selinux` | If `selinux.enabled` is `true`. |
| `26-egress-trusted-ca` | Generated from `egress` | If `egress.trustedCaPem` is set. |
| `30-postgres-sizing` | Generated from `postgres` | Always. |

To add a static patch, add a directory with a `kustomization.yaml` to `charts/substrate-install/patches/`. Start the name with a number. Each patch holds `test` operations, so the install stops if a new upstream release moves the field that the patch changes.

### Storage profiles

The patch `20-storage-profile` sets the object store settings on the `objectstore-plugin` sidecar of `ate-api-server` and of `atelet`. Both must agree, or the API server and `atelet` use different buckets. `ATE_STORAGE_BACKEND` is always `s3`, because the upstream default is GCS.

| Profile | Settings on both sidecars |
|---|---|
| `aws` | `ATE_STORAGE_BACKEND` and `AWS_REGION`. There are no static keys: the pods use the IAM role of the node. |
| `s3-compatible` | The same, plus `AWS_ENDPOINT_URL`, `AWS_S3_USE_PATH_STYLE`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` |

The snapshot location is `s3://<bucket>/`. You can set `config.storage.snapshotLocation` to `s3://<bucket>` or to a prefix in that bucket. A location in another bucket fails the render.

For `s3-compatible`, set `storage.s3Compatible.endpoint` and `pathStyle` (default `true`). Give the keys in one of two ways:

- Set `credentials.secretName` to an existing Secret in `ate-system`. The keys are named by `accessKeyKey` (default `access-key-id`) and `secretKeyKey` (default `secret-access-key`).
- Set `credentials.externalSecret.enabled` to `true`, with `storeName`, `storeKind` and the two remote keys. The chart renders an ExternalSecret that creates the Secret `substrate-s3-credentials`. It also renders the namespace `ate-system` first, with `helm.sh/resource-policy: keep`, so a delete of the release does not remove the namespace. That namespace has no Pod Security label. This option is not verified on a cluster that enforces Pod Security.

For `aws`, the pods read the node credentials through the instance metadata service. A pod is one network hop past the node, so the nodes must allow IMDSv2 with a hop limit of 2. This is not verified.

Do not add an expiry rule for objects to the bucket. A suspended actor keeps its state in a snapshot object, and that object can rest for months. You should add a rule that aborts incomplete multipart uploads after a few days. Objects that a failed checkpoint upload leaves behind are not removed (upstream issue #610).

### Postgres sizing

Upstream sets fixed resources on the bundled Postgres. A small node cannot schedule them next to the other control plane pods. The defaults of the `postgres` values are the upstream numbers:

| Value | Default |
|---|---|
| `postgres.resources.requests.cpu` | `"2"` |
| `postgres.resources.requests.memory` | `1Gi` |
| `postgres.resources.limits.cpu` | `"16"` |
| `postgres.resources.limits.memory` | `2Gi` |
| `postgres.storage` | `500Gi` |

Write the CPU and memory values as strings. The schema rejects other forms, zero and unknown keys. `examples/onprem/install-values.yaml` uses a 250m CPU request and a 10 GiB volume.

Limits:

- A StatefulSet cannot change its volume claim (upstream issue #3691). Set `postgres.storage` before the first install. A later change fails the install.
- With `config.clusterSize: size10`, `ate-setup` sets the CPU and memory itself. Only `postgres.storage` applies.

### SELinux

On nodes that enforce SELinux, such as the RHEL family, the `atelet` and worker pods run as `container_t`. They cannot write `/var/lib/ate` and exit with `permission denied` (upstream issue #3597). Two switches fix it, and you must turn on both:

- `selinux.enabled` in `substrate-install` sets the type on the `atelet` pods (patch `25-atelet-selinux`).
- `selinux.enabled` in `substrate-workers` sets the type on the worker pods with a `MutatingAdmissionPolicy`.

| `selinux.type` | Node setup | `selinux.level` in `substrate-install` |
|---|---|---|
| `spc_t` (default) | None | Not needed |
| `container_engine_t` | `/var/lib/ate` labelled `container_file_t` at level `s0` | Required, for example `s0:c100,c200` |

With a type other than `spc_t`, a missing level fails the render. Without a fixed level, each container of the `atelet` pod gets its own MCS categories, and the object-store plugin cannot read the pod files.

Known limit of `container_engine_t`: the policy denies `atelet` the connection to the kubelet socket. The node then offers no `ate.dev/kvm` resource. The gVisor class does not need it.

### Trust a private CA on the egress gateway

The egress gateway ends the TLS of an actor and opens a new TLS connection to the real server. It verifies that server against the public roots only. A server behind a private CA fails with a 503 and `upstream_failure TLS_error` in the gateway log.

Set `egress.trustedCaPem` to the PEM of the CA. It can hold more than one certificate. The chart then:

1. Renders a trust-manager `Bundle` named `egress-ca-bundle` with the default public roots and your CA. trust-manager writes it as a ConfigMap in `ate-system`.
2. Generates the patch `26-egress-trusted-ca`. The patch mounts that ConfigMap over `/etc/ssl/certs/ca-certificates.crt` in the `envoy` container of `atenet-egress`.
3. Puts a hash of the PEM on the gateway pod, so a new CA restarts the gateway.

A value with only spaces counts as empty, and the chart then renders no Bundle and no patch. A value with no certificate in it fails the schema. The `patch-egress` step fails if the egress manifest no longer reads `/etc/ssl/certs/ca-certificates.crt`. The unit tests cover the render. No check applies this patch to the release manifests or runs it on a cluster.

## Run workers

The `substrate-workers` chart renders one WorkerPool in the release namespace. The worker image is the gVisor `ateworker` image of the Substrate release, pinned by tag and digest. The tag must match the control plane release.

1. Copy `examples/onprem/workers-values.yaml` or `charts/substrate-workers/ci/aws-values.yaml`.
2. Set `pool.name`, `pool.labels` and `pool.nodeSelector`. The `workerSelector` of an actor must match `pool.labels`.
3. Set `workers.replicas`, `workers.cpu` and `workers.memory`.
4. Install the chart in the namespace of the pool.

The chart sets the limits equal to the requests, so each worker pod is Guaranteed. A worker must offer at least the CPU and memory of the actor it runs. You should run at least 2 workers: the golden snapshot holds one worker while an actor runs on another.

`atelet` tolerates the taint `ate.dev/sandboxClass:NoSchedule`. To reserve nodes for workers, taint them with `ate.dev/sandboxClass=gvisor:NoSchedule`.

### One CPU model for each pool

A gVisor snapshot depends on the CPU features of the worker that made it (upstream issue #1657). A worker with other CPU features cannot restore it. Use one CPU model in each pool, and a second pool for other hardware.

- On AWS, use one instance type for the pool. One instance type can span processor generations, so prefer a family with one generation, such as `m6i`.
- On VMs, set a fixed named CPU model. Do not pass the host CPU through on mixed hardware.

### SELinux on workers

The `MutatingAdmissionPolicy` matches only pods with the label `ate.dev/worker-pool=<pool name>` in the release namespace. It has `failurePolicy: Fail`. Workers need no level. The policy needs `admissionregistration.k8s.io/v1`, which Kubernetes serves from 1.36. The chart renders no beta version.

A new policy takes a few seconds to become active, and it does not change a pod that already exists. Argo CD applies the policy first (sync wave `-1`). With Helm, do these steps:

1. Install the chart with `--set workers.replicas=0`.
2. Wait a few seconds.
3. Upgrade the chart with the real `workers.replicas`.
4. If a worker pod started without the SELinux type, delete the pod.

### Observability

Set `observability.enabled` to `true` to render a Prometheus Operator `PodMonitor` for each entry in `observability.components`, and a ConfigMap for each dashboard in `observability.dashboards`. It is off by default, so a cluster without the Prometheus Operator can install the chart.

- Set `observability.podMonitorLabels` to the labels that your Prometheus selects.
- The PodMonitors select the control plane, not the pool. Turn observability on in one release only.
- Upstream v1.0.0 ships no dashboard. The dashboard ConfigMaps carry the label `grafana_dashboard: "1"`. Change the label name with `observability.dashboardLabel`.

## Define actors

1. Copy `examples/onprem/actors-values.yaml` or `charts/substrate-actor/ci/aws-values.yaml`.
2. Add one entry to `actors` for each actor.
3. Install the chart.

The chart renders one ConfigMap for each actor, with the ActorTemplate and the egress policy. It creates no actor. The `substrate-registration` chart does that.

| Field | Required | Meaning |
|---|---|---|
| `name`, `atespace` | yes | DNS labels |
| `image` | yes | The image, pinned by digest. A tag alone fails the schema. |
| `resources.cpuMillicores`, `resources.memoryBytes` | yes | The limits of the actor |
| `command`, `args`, `env` | no | The process of the actor |
| `workerSelector` | no | Labels of the worker pool |
| `wakeupProbe` | no | `path`, `port` and `timeoutSeconds` (default 30) |
| `egress` | no | Rules with `protocol` (`http`, `https` or `tlsPassthrough`), `hostnames`, `ports` and an optional `credential` |
| `egressTrustBundle` | no | Mounts the egress gateway CA (see below) |

`snapshotStorageLocation` is the snapshot location of every template. The examples and the integration test use `s3://<bucket>/<prefix>`.

An `https` egress rule ends TLS at the egress gateway, so the application must trust the gateway CA. Set `egressTrustBundle: true`. The chart then mounts the gateway CA and the public roots in one file, `/run/ate/egress-trust-bundle/trust-bundle.pem`. Point the application at the file, for example with `SSL_CERT_FILE`. Python `requests` reads `REQUESTS_CA_BUNDLE`.

## Register actors

An ActorTemplate, an Actor and an EgressPolicy are not Kubernetes resources. They live in the control plane database, and only `kubectl ate` writes them. The `substrate-registration` chart runs one Job that registers the actors of the `substrate-actor` chart.

Before the first registration, set these values in `substrate-install`:

1. Append the service account of the Job to `config.ateapi.authz.bootstrapOwners`: `system:serviceaccount:<namespace>:<service account>`. The Job creates atespaces, and only a bootstrap owner can.
2. Keep `system:serviceaccount:ate-system:ate-client` in that list if you use it. The value is one comma-separated string, and a set list replaces the default.
3. Set `config.preview` to `PerTemplateSnapshotLocation`. Each template names its snapshot location, and the server accepts that only with this preview gate.

The service account name is `<release>-substrate-registration`, cut to 40 characters. If the release name already contains `substrate-registration`, the name is the release name. `serviceAccount.name` replaces it.

Then install the chart with the same values file as the actor release, and set `image.digest`.

### What the Job does

1. It waits until `ate-api-server` answers.
2. It waits until each actor ConfigMap holds the expected template name and egress hash.
3. It creates the atespace, the template and the actor if they are missing.
4. If an actor uses an older template and is suspended, it moves the actor to the new template. The actor keeps its identity, and its state restarts from the new template.
5. If the server refuses that move, it deletes the actor and creates it again. The state is lost, and the log says so.
6. If an actor uses an older template and has crashed, it deletes the actor and creates it again.
7. If an actor uses an older template and is in any other state, the actor is busy. The Job leaves it.
8. It updates the egress policy in place.
9. It deletes the older templates of the actor.
10. If an actor was busy, the Job fails and names the actor.

A template is immutable, so its name carries a hash of the actor values and the snapshot location. A change to the image, command, environment, resources, worker selector or probe gives a new template. A change to the egress rules does not: the policy changes in place. `make test-contract` fails if the two charts compute different names.

If an actor was busy, suspend it and sync again. The default values set Argo CD hook annotations, so Argo CD runs the Job on every sync. Helm deletes a finished Job after `ttlSecondsAfterFinished` (default 86400 seconds).

### Access of the Job

The Job sends a projected token of its own service account, with the audience `api.ate-system.svc`. It reaches `ate-api-server` by port-forward. The chart creates a Role in `ate-system`:

| Resource | Verbs |
|---|---|
| `services`, name `api` | `get` |
| `pods` | `list` |
| `pods/portforward` | `get`, `create` |

RBAC cannot name a pod that changes on every rollout, so the Role covers every pod in `ate-system`. `kubectl ate` also lists ClusterTrustBundles. Default Kubernetes RBAC allows that for every account.

## Suspend idle actors

Substrate v1.0.0 never suspends an idle actor (upstream issues #424 and #483). The `substrate-idle-suspend` chart runs a CronJob that does it for the actors you list. The CronJob uses the registration image. You can delete the chart when upstream ships its own idle policy.

1. Make Prometheus scrape `atenet-router`, `atenet-egress`, `ate-api-server` and `atelet`.
2. Copy `examples/onprem/idle-suspend-values.yaml`.
3. Set `actors`, `prometheus.url` and `image.digest`.
4. Set `schedule` (default every 5 minutes) and `idleMinutes` (default 30).
5. Install the chart.
6. Run `kubectl ate update access-policy -a <atespace>`, and grant the CronJob principal the `editor` role.

The principal is `user:system:serviceaccount:<release namespace>:<service account>`. The service account name follows the same rule as the registration chart, with `substrate-idle-suspend`. Do not make this account a bootstrap owner.

If Prometheus needs a bearer token, set `prometheus.bearerTokenSecret.name`. If it uses a private CA, set `prometheus.caSecret.name`.

### When an actor is suspended

A run suspends an actor only when all of these are true:

- `kubectl ate` reads the actor, and the state is `ACTOR_STATE_RUNNING`.
- Every `health` query returns a number above 0. This proves that each metric source is scraped.
- Every signal query returns exactly one number, and each says idle.

| Signal | Busy when |
|---|---|
| `routed` | The router counted a request for the template of the actor in the idle time. |
| `resumed` | The API server resumed the actor in the idle time. |
| `inflight` | Any request or tunnel through the router was open in the idle time. This signal covers every actor. |
| `cpu` | The CPU rate over the idle time is above `idleCpuCores` (default 0.05). |

Any other result suspends nothing and fails the run. One failing actor does not stop the check of the others. The queries are values in `queries.*`. Change them if your Prometheus names the metrics or labels in another way.

Each actor of `substrate-actor` has its own template, so a template signal is an actor signal. If actors share a template, a busy actor keeps the others awake.

Warnings:

- An actor that answers at once and keeps working in the background can look idle. Set `idleMinutes` longer than its longest background task.
- A request that is younger than one scrape interval is not in the data yet. Keep `idleMinutes` well above the scrape interval.
- Upstream v1.0.0 documents no drain of a running request on suspend. A suspend at that moment can cut the request.

## Call an actor through the router

A client in the cluster reaches an actor through the ingress router `atenet-router`. The router resumes a suspended actor and routes the request. The first start of a new actor can take about 15 seconds, and the router can answer 502 or 504 meanwhile. The charts include no client.

1. Add the client identity to `config.ingressAllowedSPIFFEIDs` in `substrate-install`: `spiffe://<trust domain>/ns/<namespace>/sa/<service account>`.
2. Give the client pod a pod certificate of the signer `podidentity.podcert.ate.dev/identity`.
3. Make the client trust the ClusterTrustBundle of the signer `servicedns.podcert.ate.dev/identity`.
4. Send the request to `https://atenet-router.ate-system.svc` on port 443.
5. Set the header `ate-target-actor` to `<atespace>/<actor>`.
6. Make the actor listen on port 80. The router reaches the actor on port 80.

`config.ingressAllowedSPIFFEIDs` is one comma-separated string. A set value replaces the list. This path is not verified by any check.

## Images

CI builds two multi-arch (`amd64` and `arm64`) images on every push to `main` and pushes them to GitHub Container Registry. The tag is `main-<short commit>`.

| Image | Holds | Used by |
|---|---|---|
| `ghcr.io/bbaliyan/kube-agent-substrate/substrate-install` | `ate-setup`, `kustomize` and the release checkout | `substrate-install` |
| `ghcr.io/bbaliyan/kube-agent-substrate/substrate-registration` | `kubectl-ate`, `jq`, `curl` and `bash` | `substrate-registration`, `substrate-idle-suspend` |

The images build `ate-setup` and `kubectl-ate` from the release tag and verify the pinned commit. A running Job downloads nothing. The charts pull each image by digest. To read a digest, run `docker buildx imagetools inspect <image>:main-<short commit>`. The CI job summary also shows it.

## Upgrade

1. Set `substrate.version` in each chart and `image.tag` and `image.digest` in `substrate-workers` to the new release.
2. Set `image.digest` of the install and registration images to an image built for that release.
3. Run `helm upgrade` for each chart, in the order of the quick start.

The inputs of the install Job change, so a new Job runs. Do not change `postgres.storage` on an installed cluster. This procedure is not verified: v1.0.0 is the only release that the charts support today.

## Checks

| Command | Where | What it verifies |
|---|---|---|
| `make test-commit` | the kube-devenv image | YAML lint, chart lint and render with `kubeconform`, unit tests, the registration and idle-suspend scripts against stubs, the template name contract, the `examples/onprem/` values and a secret scan |
| `make test-image` | a host with Docker, `helm` and `awk` | Builds the install image and applies the patches to the real release manifests: the credential provider patch, the storage profile of each `ci` values file, the atelet SELinux patch and the Postgres sizing |
| `make test-image-registration` | a host with Docker | Builds the registration image and runs its tools |
| `make test-integration` | a host with Docker, `kubectl`, `helm`, `jq` and `curl` | The full lifecycle on kind |

CI runs all four. The render checks do not prove that an install works.

### Integration test

`make test-integration` builds the images, starts a local registry and a one-node kind cluster, and runs the charts. Set `KEEP_CLUSTER=1` to keep the cluster after the run. The files are in `tests/integration/`.

It verifies:

- The install with the `s3-compatible` profile and RustFS, and a repeat install that changes nothing.
- A worker pool, and the SELinux admission policy on the worker pods. kind does not enforce SELinux, so the test verifies only the patch.
- The registration of one actor, and a repeat run that changes nothing.
- Resume, suspend and a restore from RustFS after the node-local snapshot is dropped. The snapshot uploads as a multipart object.
- A template change that moves a suspended actor, and a Job that fails on a running actor.
- An egress change that updates the policy in place.
- The idle-suspend chart: a busy actor stays running, a refused query suspends nothing, and an idle actor is suspended.
- The pods request no more than 4 CPUs, the size of a GitHub runner.

It does not verify: IAM access to S3, SELinux enforcement, observability, credential injection, the private CA of the egress gateway, a client that calls the router, several actors, several nodes, a CPU model mismatch, TLS to the registry or the object store, and an idle time of 30 minutes.

## Workaround ledger

Each workaround, the upstream issue behind it, and what to remove when the issue is fixed. Upstream is `agent-substrate/substrate`.

| Workaround | Why | Upstream issue | Remove when fixed |
|---|---|---|---|
| The install Job, its image and its patches | Upstream installs with `ate-setup` and ships no Helm chart | #3158, #3170, #3686, #3240 | The Job and the install image |
| Patch `10-atelet-no-credential-provider` | `atelet` expects a kubelet image credential provider on the node | #2669, #3667 | The patch |
| Patch `20-storage-profile` | The default backend is GCS, and the settings repeat in each container | #3668, #2378 | The patch |
| Placeholders for `gcp.projectID` and `storage.transferGSAName`, and `context` | `ate-setup` treats a cluster that is not kind as GKE | #3651 | The placeholders |
| Patch `25-atelet-selinux` and the worker admission policy | The pods run as `container_t` and cannot write `/var/lib/ate` | #3597 | Both `selinux` switches |
| Patch `30-postgres-sizing` and the `patch-postgres` step | Upstream hardcodes the Postgres sizing | #3167, #3168 | The patch, the step and the `postgres` values |
| Patch `26-egress-trusted-ca` and the trust-manager Bundle | The egress gateway trusts the public roots only | none known | The patch, the Bundle and `egress.trustedCaPem` |
| The stub `PodMonitoring` CRD | The manifests hold a `PodMonitoring` object, and `ate-setup` stops without the CRD | #2589 | The stub |
| PodMonitors in `substrate-workers` | Upstream ships only the GKE `PodMonitoring` kind | #2589 | The PodMonitors |
| gVisor class only | microVM assets need a cloud CLI outside kind | none known | `sandboxClasses: gvisor` in the chart |
| One CPU model for each pool | A gVisor snapshot depends on the CPU features | #1657 | The rule |
| No expiry rule on the bucket | A failed checkpoint upload leaves objects behind | #610 | The rule |
| The registration Job | Actors, templates and egress policies are not Kubernetes resources | none known | The registration chart |
| A hash in the template name, and a compare of the live egress policy | A template has no metadata and cannot change | none known | The hash |
| Move an actor only while it is suspended | The server refuses to move a running actor | none known | The busy-actor gate |
| The Job is a bootstrap owner and passes its own token | `kubectl ate` falls back to the shared `ate-client` account | none known | The bootstrap owner entry |
| The Role covers every pod in `ate-system` | Port-forward RBAC cannot name a pod | none known | The Role |
| `--preview` in the registration Job | Each template names a snapshot location, which is a preview feature | none known | The flag |
| The `substrate-idle-suspend` chart | Substrate v1.0.0 suspends no idle actor | #424, #483 | The chart, and `curl` in the registration image |
| The `examples/onprem/` values and the cluster requirements page | Upstream ships no profile for self-managed clusters | #1782 | The examples |
| RustFS with large multipart uploads, verified at 257 MiB only | Large sparse uploads can fail | #3921 | The note, once a check covers 64 to 128 MiB and parallel uploads |

## License

Apache-2.0.
