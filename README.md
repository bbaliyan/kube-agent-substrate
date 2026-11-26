# kube-agent-substrate

Helm charts that install the [Agent Substrate](https://github.com/agent-substrate/substrate) v1.0.1 control plane on a Kubernetes cluster and run actors on it. An actor is a sandboxed process that Substrate can suspend to a snapshot and resume later.

## Charts

| Chart | What it does |
|---|---|
| `substrate-install` | Installs or upgrades the control plane. A Job runs `ate-setup` from a pinned install image. |
| `substrate-workers` | Runs one WorkerPool: the gVisor worker pods that run actors. |
| `substrate-actor` | Defines actors from a list in values: image by digest, environment, resources and egress rules. |
| `substrate-registration` | Registers the actors of `substrate-actor` in the control plane. A Job runs `kubectl-ate` from a pinned registration image. |

## Where it runs

The charts use plain Kubernetes objects. They do not depend on one cloud or distribution. These facts limit where they run:

- Storage has two profiles: `aws` (Amazon S3 with the IAM role of the node) and `s3-compatible` (any S3 API store with static keys). There is no Google Cloud Storage or Azure Blob profile.
- The cluster must serve the Pod Certificate and ClusterTrustBundle APIs. If you cannot set API server feature gates, as on most managed clusters, your Kubernetes version must serve them by default.
- The install always removes the settings of `atelet` for an image credential provider (patch `10-atelet-no-credential-provider`). An actor image that needs a credential provider on the node, such as a private Amazon ECR repository, is therefore not expected to pull. This is not verified.
- Only the gVisor sandbox class is installed. microVMs are not supported.

What was verified, and where:

| Platform | What ran | How often |
|---|---|---|
| kind, Kubernetes 1.37, one node | The full lifecycle with the `s3-compatible` profile and RustFS (see [Integration test](#integration-test)) | CI, on every pull request |
| Self-managed RKE2, Kubernetes 1.37, SELinux enforcing, RustFS | Install, workers, one actor with suspend, resume and a restore from RustFS | One manual run |
| `aws` profile | Render tests, and the storage patch applied to the real release manifests (`make test-image`) | CI |

Not verified: an install on Amazon EKS or any AWS cluster, Google GKE, Azure AKS, several nodes, `arm64` nodes, Kubernetes 1.36, observability on a real cluster, and the private CA of the egress gateway on a live cluster.

## Requirements

- Kubernetes 1.36 or later. Only 1.37 was verified.
- The Pod Certificate and ClusterTrustBundle APIs.
- A default StorageClass for the bundled Postgres, or a class in `config.ateapi.postgres.storageClass` of `substrate-install`.
- The `privileged` Pod Security level on the control plane namespace `ate-system` and on each worker pool namespace. The install chart creates `ate-system` with this level by default. You must create each worker pool namespace.
- The stub of the GKE `PodMonitoring` CRD, on any cluster without the GKE operator. Set `podMonitoringCrdStub: true` in the values of `substrate-install`.
- An S3 bucket, or a bucket in an S3-compatible store.
- One CPU model for each worker pool (see [One CPU model for each pool](#one-cpu-model-for-each-pool)).
- trust-manager, only if you set `egress.trustedCaPem`.

[docs/cluster-requirements.md](docs/cluster-requirements.md) lists each requirement with a command that verifies it.

## Quick start

Use the files in `examples/onprem/` as a start. They hold values for a small cluster with SELinux nodes and an S3-compatible store. Replace every placeholder value.

The charts deploy no object store. Bring your own S3 bucket or S3-compatible store, and set `storage.s3Compatible.endpoint` to it. The example expects RustFS at `http://rustfs.rustfs.svc:9000`. For a reference, `tests/integration/rustfs.yaml` deploys RustFS for the test, in the namespace `ate-system`.

If you start from `charts/substrate-install/ci/aws-values.yaml`, add these keys to it. The values come from `tests/integration/install-values.yaml`:

```yaml
config:
  preview: PerTemplateSnapshotLocation
  atenet:
    egress:
      credentialProvider: '{"enabled":false}'
  ateapi:
    authz:
      bootstrapOwners: system:serviceaccount:ate-system:ate-client,system:serviceaccount:substrate-system:substrate-registration
```

`ate-setup` needs `credentialProvider`, and the registration Job needs the other two (see [Register actors](#register-actors)).

The install chart creates the control plane namespace `ate-system` with the `privileged` Pod Security level (`createNamespace: true`). The S3 keys of an existing Secret must be in `ate-system` before the install. In that case, you create the namespace yourself and set `createNamespace: false`, as `examples/onprem/install-values.yaml` does. Helm cannot adopt a namespace that already exists, so an install with `createNamespace: true` into an existing `ate-system` fails. Argo CD can adopt it.

1. Verify the requirements with [docs/cluster-requirements.md](docs/cluster-requirements.md).
2. Create the snapshot bucket.
3. If the S3 keys come from an existing Secret, create the namespace `ate-system` with the label `pod-security.kubernetes.io/enforce=privileged`.
4. If the S3 keys come from an existing Secret, create the Secret in `ate-system`.
5. If you did step 3, set `createNamespace: false` in the install values.
6. Set `image.digest` in the install values (see [Images](#images)).
7. Run `helm upgrade --install substrate-install charts/substrate-install -n substrate-system --create-namespace -f install-values.yaml --wait --wait-for-jobs --timeout 20m`.
8. Label the worker nodes so that they match `pool.nodeSelector`. For the example, run `kubectl label node <node> worker-cpu-model=fixed`.
9. Create the worker pool namespace with the label `pod-security.kubernetes.io/enforce=privileged`.
10. Run `helm upgrade --install substrate-workers charts/substrate-workers -n <pool namespace> -f workers-values.yaml --set workers.replicas=0`.
11. Wait a few seconds, so that the SELinux admission policy is active.
12. Run `helm upgrade --install substrate-workers charts/substrate-workers -n <pool namespace> -f workers-values.yaml`.
13. Run `helm upgrade --install substrate-actor charts/substrate-actor -n substrate-system -f actors-values.yaml`.
14. Run `helm upgrade --install substrate-registration charts/substrate-registration -n substrate-system -f actors-values.yaml --set image.digest=<digest> --wait --wait-for-jobs --timeout 15m`.

If SELinux is off in the workers values, you can skip steps 10 and 11. With the `aws` profile or an ExternalSecret, skip steps 3 to 5 and keep `createNamespace: true`. The chart then creates `ate-system`.

The `substrate-actor` and `substrate-registration` releases must be in the same namespace, because the Job reads the ConfigMaps of the actors. You can also sync each chart with Argo CD. The charts carry sync waves and hooks for it.

## Install the control plane

The `substrate-install` chart runs one Job that installs the release in `substrate.version` (default `v1.0.1`).

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
| `createNamespace` | `true` | Renders the namespace `ate-system` with the `privileged` Pod Security level. Set it to `false` if you create the namespace yourself. |
| `rbac.clusterRole` | `cluster-admin` | The role of the Job. The install creates cluster roles, and an account can only grant what it holds. |
| `backoffLimit` | `2` | Retries of the Job |
| `activeDeadlineSeconds` | `1800` | The Job stops after this time. |
| `resources`, `nodeSelector`, `tolerations` | see `values.yaml` | The pod of the Job |

The control plane namespace must be `ate-system`, because `ate-setup` refuses another one. The schemas allow only `ate-system` in `config.namespace` of `substrate-install`, `substrate.namespace` of `substrate-registration`, and `observability.controlPlaneNamespace` of `substrate-workers`.

The chart sets some parts of the document, and a value cannot change them. These parts are `apiVersion`, `kind`, `images`, `sandboxClasses`, `context`, `gcp.projectID`, `storage.transferGSAName` and `storage.bucketName`. The chart also sets `storage.snapshotLocation`, but you can change it within the bucket (see [Storage profiles](#storage-profiles)). `ate-setup` treats a cluster that is not kind as GCS and needs a project and a transfer account. S3 uses neither, so the chart sets both to `unused-placeholder`.

`ate-setup` needs a credential provider setting for egress. Set `config.atenet.egress.credentialProvider` to `{"name":"k8s.io"}` for the bundled Secrets provider. Set it to `{"enabled":false}` to turn off credential injection. The `ci/` values files do not set it.

### How the Job works

1. The `seed` init container copies the release checkout from the image to a writable volume.
2. The `patch` init container adds each patch to the kustomization of that copy.
3. The `patch-postgres` init container writes the Postgres sizing over the Postgres manifest.
4. If `egress.trustedCaPem` is set, the `patch-egress` init container writes the CA mount over the egress gateway manifest.
5. The `deploy` container runs `ate-setup deploy` on the patched copy.

The Job and its ConfigMap carry a hash of the Job inputs in their names. A change to one of these inputs creates a new Job: the image, the patches, the config, the environment and the resources. The node selector, the tolerations, the service account, `backoffLimit` and `activeDeadlineSeconds` count too. The same inputs find the old Job, and nothing runs again. A repeat run on an installed cluster changes nothing.

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
- Set `credentials.externalSecret.enabled` to `true`, with `storeName`, `storeKind` and the two remote keys. The chart renders an ExternalSecret in `ate-system` that creates the Secret `substrate-s3-credentials`. With `createNamespace: true`, Argo CD applies the namespace before the ExternalSecret (sync wave `-3`). The namespace carries `helm.sh/resource-policy: keep`, so a delete of the release does not remove it.

For `aws`, the pods read the node credentials through the instance metadata service. A pod is one network hop past the node, so the nodes must allow IMDSv2 with a hop limit of 2. This is not verified.

Do not add an expiry rule for objects to the bucket. A suspended actor keeps its state in a snapshot object, and that object can rest for months. You should add a rule that aborts incomplete multipart uploads after a few days. Objects that a failed checkpoint upload leaves behind are not removed.

### Postgres sizing

Upstream sets fixed resources on the bundled Postgres. A small node cannot schedule them next to the other control plane pods. The defaults of the `postgres` values are the upstream numbers:

| Value | Default |
|---|---|
| `postgres.resources.requests.cpu` | `"2"` |
| `postgres.resources.requests.memory` | `1Gi` |
| `postgres.resources.limits.cpu` | `"16"` |
| `postgres.resources.limits.memory` | `2Gi` |
| `postgres.storage` | `500Gi` |

Write the CPU and memory values as strings. The schema rejects other forms, zero and unknown keys. `examples/onprem/install-values.yaml` uses a CPU request of 250 millicores and a volume of 10 GiB.

The volume uses the default StorageClass. To use another class, set `config.ateapi.postgres.storageClass`. `charts/substrate-install/ci/aws-values.yaml` sets `gp3`. The chart passes this key to `ate-setup` unchanged, and no check verifies it on a cluster.

Limits:

- A StatefulSet cannot change its volume claim. Set `postgres.storage` before the first install. A later change fails the install.
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

Known limit of `container_engine_t`: the policy denies `atelet` the connection to the kubelet socket. The node then offers no `ate.dev/kvm` resource. The gVisor class does not need it. This limit was seen in the manual run, and no check verifies it.

### Trust a private CA on the egress gateway

The egress gateway ends the TLS of an actor and opens a new TLS connection to the real server. It verifies that server against the public roots only. A server behind a private CA fails with a 503 and `upstream_failure TLS_error` in the gateway log.

Set `egress.trustedCaPem` to the PEM of the CA. It can hold more than one certificate. The chart then:

1. Renders a trust-manager `Bundle` named `egress-ca-bundle` with the default public roots and your CA. trust-manager writes it as a ConfigMap in `ate-system`.
2. Generates the patch `26-egress-trusted-ca`. The patch mounts that ConfigMap over `/etc/ssl/certs/ca-certificates.crt` in the `envoy` container of `atenet-egress`.
3. Puts a hash of the PEM on the gateway pod, so a new CA restarts the gateway.

A value with only spaces counts as empty, and the chart then renders no Bundle and no patch. A value without `BEGIN CERTIFICATE` fails the schema.

`ate-setup` applies `atenet-egress.yaml` on its own, outside the base kustomization. The `patch-egress` step therefore builds that manifest with the patch and writes it back. The step fails if the manifest no longer reads `/etc/ssl/certs/ca-certificates.crt`. It also fails if the marker line `#ATE_EGRESS_INJECT_FLAGS` is not there exactly once. `make test-image` runs this step on the real release manifest. No check runs it on a cluster.

## Run workers

The `substrate-workers` chart renders one WorkerPool in the release namespace. The worker image is the gVisor `ateworker` image of the Substrate release, pinned by tag and digest. The tag must match the control plane release.

1. Copy `examples/onprem/workers-values.yaml` or `charts/substrate-workers/ci/aws-values.yaml`.
2. Set `pool.name`, `pool.labels` and `pool.nodeSelector`. The `workerSelector` of an actor must match `pool.labels`.
3. Set `workers.replicas`, `workers.cpu` and `workers.memory`.
4. Install the chart in the namespace of the pool.

| Value | Default | Meaning |
|---|---|---|
| `pool.name` | the release name | Name of the WorkerPool. The worker pods carry the label `ate.dev/worker-pool=<name>`. |
| `pool.labels` | `{}` | Labels of the WorkerPool. The `workerSelector` of an actor matches them. |
| `pool.nodeSelector`, `pool.tolerations` | `{}`, `[]` | Where the worker pods run |
| `image.tag`, `image.digest` | `v1.0.1` and its digest | The `ateworker-gvisor` image of the release |
| `workers.replicas` | `2` | Number of worker pods |
| `workers.cpu`, `workers.memory` | `"1"`, `2Gi` | Request and limit of each worker pod |
| `sandboxClass` | `gvisor` | The only value that the schema accepts |
| `selinux.enabled`, `selinux.type` | `false`, `spc_t` | See [SELinux on workers](#selinux-on-workers) |
| `observability.enabled` | `false` | See [Observability](#observability) |

The chart sets the limits equal to the requests, so each worker pod is Guaranteed. A worker must offer at least the CPU and memory of the actor it runs. You should run at least 2 workers: the golden snapshot holds one worker while an actor runs on another.

`atelet` tolerates the taint `ate.dev/sandboxClass:NoSchedule`. To reserve nodes for workers, taint them with `ate.dev/sandboxClass=gvisor:NoSchedule`.

### One CPU model for each pool

A gVisor snapshot depends on the CPU features of the worker that made it. A worker with other CPU features cannot restore it. Use one CPU model in each pool, and a second pool for other hardware.

- On AWS, use one instance type for the pool. One instance type can span processor generations, so prefer a family with one generation, such as `m6i`.
- On VMs, set a fixed named CPU model. Do not pass the host CPU through on mixed hardware.

### SELinux on workers

The `MutatingAdmissionPolicy` matches only pods with the label `ate.dev/worker-pool=<pool name>` in the release namespace. It has `failurePolicy: Fail`. Workers need no level. The policy needs `admissionregistration.k8s.io/v1`, and the chart renders no beta version. The chart assumes that Kubernetes 1.36 serves `v1`. This is not verified.

A new policy takes a few seconds to become active, and it does not change a pod that already exists. Argo CD applies the policy first (sync wave `-1`). With Helm, do these steps:

1. Install the chart with `--set workers.replicas=0`.
2. Wait a few seconds.
3. Upgrade the chart with the real `workers.replicas`.
4. If a worker pod started without the SELinux type, delete the pod.

### Observability

Set `observability.enabled` to `true` to render a Prometheus Operator `PodMonitor` for each entry in `observability.components`, and a ConfigMap for each dashboard in `observability.dashboards`. It is off by default, so a cluster without the Prometheus Operator can install the chart.

- Set `observability.podMonitorLabels` to the labels that your Prometheus selects.
- Each series carries the label `app` of its pod, for example `app="atenet-router"`.
- The PodMonitors select the control plane, not the pool. Turn observability on in one release only.
- Upstream v1.0.1 ships no dashboard. The dashboard ConfigMaps carry the label `grafana_dashboard: "1"`. Change the label name with `observability.dashboardLabel`.

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
| `warm` | no | If `true`, the registration Job resumes the actor when it is suspended. Default `false`. See below. |

`snapshotStorageLocation` is the snapshot location of every template. The default is `objectstore://substrate-snapshots`. The examples and the integration test use `s3://<bucket>/<prefix>`, and only that form is verified. `actors` defaults to an empty list.

An `https` egress rule ends TLS at the egress gateway, so the application must trust the gateway CA. Set `egressTrustBundle: true`. The chart then mounts the gateway CA and the public roots in one file, `/run/ate/egress-trust-bundle/trust-bundle.pem`. Point the application at the file, for example with `SSL_CERT_FILE`. Python `requests` reads `REQUESTS_CA_BUNDLE`.

## Register actors

An ActorTemplate, an Actor and an EgressPolicy are not Kubernetes resources. They live in the control plane database, and only `kubectl ate` writes them. The `substrate-registration` chart runs one Job that registers the actors of the `substrate-actor` chart.

Before the first registration, set these values in `substrate-install`:

1. Append the service account of the Job to `config.ateapi.authz.bootstrapOwners`: `system:serviceaccount:<namespace>:<service account>`. The Job creates atespaces, and only a bootstrap owner can.
2. If you use the `ate-client` account, keep `system:serviceaccount:ate-system:ate-client` in that list.
3. Set `config.preview` to `PerTemplateSnapshotLocation`. Each template names its snapshot location, and the server accepts that only with this preview gate.

The value of `bootstrapOwners` is one comma-separated string, and a set list replaces the default.

The service account name is `<release>-substrate-registration`, cut to 40 characters. If the release name already contains `substrate-registration`, the name is the release name. `serviceAccount.name` replaces it.

Then install the chart with the same values file as the actor release, and set `image.digest`.

| Value | Default | Meaning |
|---|---|---|
| `snapshotStorageLocation`, `actors` | as in `substrate-actor` | Must be the same as in the actor release |
| `substrate.namespace` | `ate-system` | The namespace of `ate-api-server` |
| `image.digest` | all zeros | Digest of the registration image. The all-zero digest never pulls. |
| `accessBindings` | `[]` | Roles to grant. Each entry has `atespace`, `role` (`viewer` or `editor`) and `members`. The Job adds the members to the access policy of the atespace. It removes nobody, so a revoke is a manual `kubectl ate update access-policy`. A member has the prefix `user:`. |
| `unregister.enabled` | `false` | Runs an Argo CD PreDelete hook Job when the Application is deleted. It deletes each actor, then its templates, then each atespace if it is empty. NotFound counts as done, and an atespace that another agent still uses stays. The atespace delete needs the `owner` role, so the chart binds the Job as owner of the atespaces of its actors. `accessBindings` still rejects `owner`. A delete that skips the finalizer does not run the hook. Then run `kubectl ate delete` by hand. |
| `waitSeconds` | `900` | How long the Job waits for `ate-api-server` and for the actor ConfigMaps |
| `backoffLimit`, `activeDeadlineSeconds` | `2`, `1800` | Retries and time limit of the Job |
| `ttlSecondsAfterFinished` | `86400` | Time before a finished Job is deleted |
| `job.annotations` | Argo CD `Sync` hook, `BeforeHookCreation`, sync wave `1` | Annotations of the Job. With Helm only, you can set it to `null`, as the integration test does. |
| `serviceAccount.name` | `""` | Replaces the generated service account name |

### What the Job does

1. It waits until `ate-api-server` answers.
2. It waits until each actor ConfigMap holds the expected template name and egress hash.
3. It creates the atespace, the template and the actor if they are missing.
4. If an actor uses an older template and is suspended, it moves the actor to the new template. The actor keeps its identity, and its state restarts from the new template.
5. If the server refuses that move, it deletes the actor and creates it again. The state is lost, and the log says so.
6. If an actor has crashed, it reverts the actor to its last snapshot, whatever the template. If the server refuses the revert, it deletes the actor and creates it again. The state is lost, and the log says so.
7. If an actor uses an older template and is in any other state, the actor is busy. The Job leaves it.
8. It updates the egress policy in place.
9. It deletes the older templates of the actor.
10. If an actor has `warm: true` and is suspended, it resumes the actor.
11. If an actor was busy, the Job fails and names the actor.

A webhook sender gives up after about 10 seconds, and the first start of an actor can take longer. A warm actor has started before the first request, so the router answers inside its park window. The actor stays running until something suspends it. If another chart suspends idle actors (the chart `substrate-idle-suspend` in kube-ai-agents does), the Job resumes a warm actor on each sync, so the actor is running after a deploy and is suspended again after its idle time.

A template is immutable, so its name carries a hash of the actor fields that make the template and the snapshot location. `warm` and `egress` are not part of it. A change to the image, command, environment, resources, worker selector or probe gives a new template. A change to the egress rules does not: the policy changes in place. `make test-contract` fails if the two charts compute different names.

If an actor was busy, suspend it and sync again. The default values set Argo CD hook annotations, so Argo CD runs the Job on every sync. The Kubernetes TTL controller deletes a finished Job after `ttlSecondsAfterFinished` (default 86400 seconds).

### Access of the Job

The Job sends a projected token of its own service account, with the audience `api.ate-system.svc`. It reaches `ate-api-server` by port-forward. The chart creates a Role in `ate-system`:

| Resource | Verbs |
|---|---|
| `services`, name `api` | `get` |
| `pods` | `list` |
| `pods/portforward` | `get`, `create` |

RBAC cannot name a pod that changes on every rollout, so the Role covers every pod in `ate-system`. `kubectl ate` also lists ClusterTrustBundles. Default Kubernetes RBAC allows that for every account.

## Call an actor through the router

A client in the cluster reaches an actor through the ingress router `atenet-router`. The router resumes a suspended actor and routes the request. The charts include no client.

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
| `ghcr.io/bbaliyan/kube-agent-substrate/substrate-registration` | `kubectl-ate`, `jq`, `curl` and `bash` | `substrate-registration` |

The images build `ate-setup` and `kubectl-ate` from the release tag and verify the pinned commit. A running Job downloads nothing. The charts pull each image by digest. To read a digest, run `docker buildx imagetools inspect <image>:main-<short commit>`. The CI job summary also shows it.

## Upgrade

### Take a new Substrate release

When upstream publishes a release, Renovate opens one pull request named `substrate release`, with the label `upstream-release`. Renovate never merges it. The pull request changes these together:

- `SUBSTRATE_TAG` and `SUBSTRATE_COMMIT` in the install and the registration Dockerfile.
- `substrate.version` of `substrate-install`.
- `appVersion` of the three charts that have one.

Renovate does not change the worker image of `substrate-workers`. That image is a value that you set.

1. Read the release notes of the new release.
2. Wait for the CI jobs `image` and `integration`. The `image` job applies every patch to the manifests of the new release. A patch fails the build if upstream moved what it patches.
3. Merge the pull request.
4. After the `publish` job pushes the new images, read their digests (see [Images](#images)).
5. Follow the steps below to move a cluster to the new release.

### Move a cluster to a release

0. If an actor is running and its work matters, suspend it (see below).
1. Set `substrate.version` in `substrate-install` to the new release.
2. Set `image.tag` and `image.digest` in `substrate-workers` to the worker image of the new release.
3. Set `image.digest` of the install and registration images to an image built for that release.
4. Run `helm upgrade` for each chart, in the order of the quick start.

The inputs of the install Job change, so a new Job runs. The new release rolls the worker pods. Upstream gives actors 30 minutes after SIGTERM, and then an actor that is still running crashes.

To lose no work, run step 0 first. If an actor is running, suspend it with a synchronous snapshot: `kubectl ate suspend actor <name> -a <atespace> --mode=sync`. A suspended actor does not crash on the roll.

If an actor crashes, the registration Job reverts it to its last snapshot. The actor keeps its identity and its volumes. Work since that snapshot is lost. Do not change `postgres.storage` on an installed cluster.

## Checks

| Command | Where | What it verifies |
|---|---|---|
| `make test-commit` | the kube-devenv image | YAML lint, chart lint and render with `kubeconform`, unit tests, the registration script against stubs, the template name contract, the `examples/onprem/` values and a secret scan |
| `make test-image` | a host with Docker, `helm` and `awk` | Builds the install image and applies the patches to the real release manifests: the credential provider patch, the storage profile of each `ci` values file, the atelet SELinux patch, the Postgres sizing and the `patch-egress` step |
| `make test-image-registration` | a host with Docker | Builds the registration image and runs its tools |
| `make test-integration` | a host with Docker, `kubectl`, `helm`, `jq` and `curl` | The full lifecycle on kind |

CI runs all four. The render checks do not prove that an install works.

`tests/egress-ca/test-image.sh` is the `patch-egress` part of `make test-image`. It renders the step with a test CA and runs it in the install image on the real `atenet-egress.yaml`. It verifies three things:

- The bundle is mounted, and the marker `#ATE_EGRESS_INJECT_FLAGS` stays once, at the indent of the flags.
- The markers and placeholders that `ate-setup` replaces later are still there.
- The step fails, and leaves the manifest unchanged, if the manifest no longer reads the CA file or the marker is missing.

### Integration test

`make test-integration` builds the images, starts a local registry and a one-node kind cluster, and runs the charts. Set `KEEP_CLUSTER=1` to keep the cluster after the run. The files are in `tests/integration/`.

It verifies:

- The install with the `s3-compatible` profile and RustFS, and a repeat install that changes nothing. The test creates `ate-system` first and sets `createNamespace: false`. Only the unit tests cover `createNamespace: true`.
- A worker pool, and the SELinux admission policy on the worker pods. kind does not enforce SELinux, so the test verifies only the patch.
- The registration of one actor, and a repeat run that changes nothing.
- Resume, suspend and a restore from RustFS after the node-local snapshot is dropped. The snapshot uploads as a multipart object.
- A template change that moves a suspended actor, and a Job that fails on a running actor.
- An egress change that updates the policy in place.
- The pods request no more than 4 CPUs, the size of a GitHub runner.

It does not verify: IAM access to S3, SELinux enforcement, observability, credential injection, the private CA of the egress gateway, a client that calls the router, several actors, several nodes, a CPU model mismatch, TLS to the registry or the object store.

## Workaround ledger

Each workaround, the upstream issue behind it, and what to remove when the issue is fixed. Upstream is `agent-substrate/substrate`. An issue marked "not verified" has no reference in the code or tests of this repo.

| Workaround | Why | Upstream issue | Remove when fixed |
|---|---|---|---|
| The install Job, its image and its patches | Upstream installs with `ate-setup` and ships no Helm chart | #79 | The Job and the install image |
| Patch `10-atelet-no-credential-provider` | `atelet` expects a credential provider for images on the node | #2669, #3667 | The patch |
| Patch `20-storage-profile` | The default backend is GCS, and the settings repeat in each container | #3668, #2378 | The patch |
| Placeholders for `gcp.projectID` and `storage.transferGSAName`, and `context` | `ate-setup` treats a cluster that is not kind as GCS | #3651 (not verified) | The placeholders |
| Patch `25-atelet-selinux` and the worker admission policy | The pods run as `container_t` and cannot write `/var/lib/ate` | #3597 | Both `selinux` switches |
| Patch `30-postgres-sizing` and the `patch-postgres` step | Upstream hardcodes the Postgres sizing | #3167, #3168 | The patch, the step and the `postgres` values |
| Patch `26-egress-trusted-ca` and the trust-manager Bundle | The egress gateway reads one fixed CA file, so it trusts the public roots only | #2684, #3648 | The patch, the Bundle and `egress.trustedCaPem` |
| The stub `PodMonitoring` CRD | The manifests hold a `PodMonitoring` object, and `ate-setup` stops without the CRD | #2589 | The stub |
| PodMonitors in `substrate-workers` | Upstream ships only the GKE `PodMonitoring` kind | #2589 | The PodMonitors |
| gVisor class only | microVM assets need a cloud CLI outside kind | none known | `sandboxClasses: gvisor` in the chart |
| One CPU model for each pool | A gVisor snapshot depends on the CPU features | #1657 (not verified) | The rule |
| No expiry rule on the bucket | A failed checkpoint upload leaves objects behind | #610 (not verified) | The rule |
| The registration Job | Actors, templates and egress policies are not Kubernetes resources | none known | The registration chart |
| A hash in the template name, and a compare of the live egress policy | A template has no metadata and cannot change | none known | The hash |
| Move an actor only while it is suspended | The server refuses to move a running actor | none known | The busy-actor gate |
| The Job is a bootstrap owner and passes its own token. It also grants `viewer` and `editor` roles | `kubectl ate` falls back to the shared `ate-client` account, and the access policy has no declarative form | none known | The bootstrap owner entry, and the role list of the schema |
| The Role covers every pod in `ate-system` | Port-forward RBAC cannot name a pod | none known | The Role |
| `--preview` in the registration Job | Each template names a snapshot location, which is a preview feature | none known | The flag |
| The access bindings of the registration Job | Substrate v1.0.1 has no declarative access policy | none known | The `accessBindings` value |
| The `examples/onprem/` values and the cluster requirements page | Upstream ships no profile for self-managed clusters | #1782 (not verified) | The examples |
| RustFS with large multipart uploads, verified with one multipart snapshot only | Large sparse uploads can fail | #3921 (not verified) | The note, once a check covers 64 to 128 MiB and parallel uploads |

## License

Apache-2.0.
