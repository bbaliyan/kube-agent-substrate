# Node requirements for self-managed clusters

This page lists what a self-managed cluster must provide before the charts work. The target is a cluster on Proxmox VMs, with RKE2 on AlmaLinux. Each requirement has a command that verifies it.

The values in `examples/onprem/` assume these requirements. Run every command on a machine with `kubectl` and a kubeconfig for the cluster, unless the text says "on the node".

A real run on a Proxmox-hosted RKE2 cluster on AlmaLinux (Kubernetes v1.37, one general node, three control-plane nodes) met every requirement below. See "What the real run showed".

## 1. Kubernetes version

The cluster must run Kubernetes 1.36 or later. The `MutatingAdmissionPolicy` API of the SELinux policy is generally available from 1.36. The chart does not render the beta version.

1. Run `kubectl version`. Verify that the server version is v1.36 or later.
2. Run `kubectl api-resources --api-group=admissionregistration.k8s.io`. Verify that the list holds `mutatingadmissionpolicies` with the version `admissionregistration.k8s.io/v1`.

## 2. Pod Certificate and ClusterTrustBundle APIs

The control plane gives each pod an identity from the `PodCertificateRequest` API. It shares trust roots through `ClusterTrustBundle` objects and projected volumes.

- On Kubernetes 1.37, the stable `certificates.k8s.io/v1` API serves both resources. You set no feature gate.
- On Kubernetes 1.36, the upstream project turns them on with three feature gates and one runtime setting: `ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest`, and `--runtime-config=certificates.k8s.io/v1beta1=true`. Set them on the API server. On RKE2, set them in the `kube-apiserver-arg` list of `/etc/rancher/rke2/config.yaml`.
- Substrate v1.0.0 uses `v1` when the cluster serves it. Otherwise it uses `v1beta1`.

To verify:

1. Run `kubectl api-resources --api-group=certificates.k8s.io`. Verify that `clustertrustbundles` and `podcertificaterequests` are in the list.
2. Verify the two projected volume types. Send a pod that uses both to the API server with `kubectl apply --dry-run=server -o yaml -f pod.yaml`. The pod needs a `clusterTrustBundle` source and a `podCertificate` source in one `projected` volume. Verify that both sources are in the output. A server with a gate off removes the source.

## 3. Default StorageClass

The bundled Postgres of the control plane and the RustFS store each ask for a volume. The cluster must have a default StorageClass that provisions a `ReadWriteOnce` volume. Set the size of the Postgres volume in `postgres.storage`, because the upstream size of 500 GiB is too large for a small cluster.

1. Run `kubectl get storageclass`.
2. Verify that exactly one class shows `(default)`.

RustFS takes its class from `storageClassName` in its own values. Name a class there.

## 4. Pod Security level

`atelet` mounts the host directories `/dev`, `/var/lib/ate` and the kubelet plugin directories, so it needs the `privileged` level. The worker pods need the host path volume and the `spc_t` SELinux type, which the Baseline level blocks.

1. Create the namespace `ate-system` with the label `pod-security.kubernetes.io/enforce=privileged`.
2. Create the namespace of each worker pool with the same label.
3. Verify with `kubectl get ns ate-system -o jsonpath='{.metadata.labels}'`.
4. If the cluster has a default admission configuration that enforces the restricted level, verify that it exempts both namespaces.

## 5. SELinux

On RHEL-family nodes, SELinux runs in enforcing mode. Pods run as `container_t` and cannot write the host directory `/var/lib/ate`. Upstream issue #3597 tracks this. Two switches fix it:

- `selinux.enabled` in the `substrate-install` chart sets `spc_t` on the `atelet` pods.
- `selinux.enabled` in the `substrate-workers` chart sets `spc_t` on the worker pods, with an admission policy.

Turn both on when the nodes enforce SELinux.

1. On the node, run `getenforce`. If the output is `Enforcing`, turn both switches on.
2. After the install, verify `atelet`: run `kubectl -n ate-system get pods -l app=atelet`. Each pod must be `Running`.
3. Verify the policy: run `kubectl -n <worker namespace> run probe --image=probe --dry-run=server -o jsonpath='{.spec.securityContext.seLinuxOptions.type}' -l ate.dev/worker-pool=<pool>`. The output must be `spc_t`.

## 6. Where `atelet` runs

`atelet` is a DaemonSet. A worker pod must run on a node that runs `atelet`. The DaemonSet tolerates no custom taint. A node that has a custom taint gets no `atelet`, so it can run no worker.

1. Run `kubectl -n ate-system get pods -l app=atelet -o wide`.
2. Verify that every node of a worker pool is in the list.

## 7. One CPU type for each worker pool

A gVisor snapshot depends on the CPU features of the worker that made it (upstream issue #1657). Every node of one pool must show the same CPU model and flags.

1. On the Proxmox host, run `qm config <vmid> | grep '^cpu:'` for each VM of the pool. Verify that the value is the same on every VM. It must be a named model, not `host`, unless all hosts have the same CPU.
2. On each node, run `grep -m1 'model name' /proc/cpuinfo`. Verify that the output is the same on every node of the pool.
3. On each node, run `grep -m1 flags /proc/cpuinfo | md5sum`. Verify that the sum is the same.

## 8. Nested virtualization

Nested virtualization is needed only for microVMs. The charts use gVisor only, so you need no nested virtualization now.

## 9. Images and the snapshot store

1. Verify that the nodes pull from `ghcr.io` without a login. Run `docker manifest inspect ghcr.io/bbaliyan/kube-agent-substrate/substrate-install:<tag>` on a machine with no stored credentials.
2. Create the bucket for the snapshots before the install. RustFS 1.0.x cannot create a bucket on its own. Run a Job with a pinned AWS CLI image that calls `aws s3api create-bucket`.
3. If the actor image lives in a registry in the cluster, address it by the IP of its Service. `atelet` pulls the image itself, over plain HTTP, and only from a private address.

## 10. The GKE PodMonitoring CRD

`ate-setup` stops if the CRD `podmonitorings.monitoring.googleapis.com` is missing (upstream issue #2589). Apply `examples/onprem/podmonitoring-crd.yaml` before the install. It is a stub that holds no operator.

1. Run `kubectl apply -f examples/onprem/podmonitoring-crd.yaml`.
2. Verify with `kubectl get crd podmonitorings.monitoring.googleapis.com`.

## What the real run showed

- The install Job finished in 29 seconds once the images were on the node. The control plane, Postgres, RustFS and the two workers requested 2.7 CPUs in total with the sizing of `examples/onprem/`.
- Without `selinux.enabled`, `atelet` exited with `permission denied` on `/var/lib/ate/.cache-boot-id.tmp-*`. A worker without the policy exited with `permission denied` on the remount of `/sys/fs/cgroup`. Both ran with the switches on.
- gVisor ran with the `systrap` platform. No nested virtualization was needed.
- A sample actor started, suspended and resumed with its counters intact. It also resumed after a revert that dropped the node-local snapshot, so the restore came from RustFS.
- `kubectl ate proxy` creates a `PodCertificateRequest` and reads the `atenet-router` Service. An account that is not a cluster admin needs a Role for both in `ate-system`. The `ingressAllowedSPIFFEIDs` value must list `spiffe://cluster.local/ns/ate-system/sa/atenet-client` for that proxy.
- The idle-suspend chart was not run. It needs Prometheus to scrape the control plane.
