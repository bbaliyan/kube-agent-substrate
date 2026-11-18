# kube-agent-substrate

Helm charts that run [Agent Substrate](https://github.com/agent-substrate/substrate) actors on self-managed Kubernetes. The repo holds code only.

## Charts

| Chart | What it does |
|---|---|
| `substrate-actor` | Defines any actor from a list in values: image by digest, environment, egress allowlist, credential injection, webhook shim and ingress |

## Define an actor

1. Copy `charts/substrate-actor/ci/aws-values.yaml` or `charts/substrate-actor/ci/onprem-values.yaml`.
2. Replace the placeholder values with your own.
3. Add one entry to `actors` for each actor.
4. Install the chart with your values file.

The `aws` and `onprem` files differ only in values: the snapshot location, the secret store and the ingress class. The `*-multi-values.yaml` files show several actors in one release.

The values schema rejects an image reference that has no digest.

## Checks

Run `make test-commit` in the kube-devenv image. It lints the charts, runs the chart unit tests and scans for secrets.

The render lint is a quick lint. It runs `helm template` and `kubeconform` for each file in `charts/*/ci/`: the `aws` and `onprem` profiles, each with one actor and with several. It does not prove that an install works.

Not covered by any check in this repo:

- An install on a cluster. The ActorTemplate and the EgressPolicy are not Kubernetes resources. The chart renders them into a ConfigMap as data. A registration step, which this repo does not have yet, must apply them.
- IAM-based S3 access, SELinux enforcement and microVMs.

## Workaround ledger

Each workaround, the upstream issue behind it and what to delete when the issue is fixed. Upstream is `agent-substrate/substrate`. A row marked "planned" belongs to a chart that this repo does not have yet.

| Workaround | Upstream issue | Delete when it lands |
|---|---|---|
| Registration of actors and template swap (planned). An ActorTemplate is not a CRD, and an EgressPolicy belongs to a running actor, not to a template | none known | The registration step, once upstream offers a declarative resource for actors |
| Install Job around `ate-setup` (planned) | #3158, #3170, #3686, #3240 | The Job, and use the upstream Helm charts |
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
