# Cluster requirements

This page lists what a cluster must provide before the charts work. Each requirement has a command that verifies it. Run each command on a machine with `kubectl` and a kubeconfig for the cluster, unless the step says "on the node".

The values in `examples/onprem/` assume these requirements. A manual run on a self-managed RKE2 cluster with Kubernetes 1.37 and SELinux enforcing met every requirement. See [What the manual run showed](#what-the-manual-run-showed).

## 1. Kubernetes version

The cluster must run Kubernetes 1.36 or later. Only 1.37 was verified.

1. Run `kubectl version`.
2. Verify that the server version is v1.36 or later.

If you turn on SELinux in the `substrate-workers` chart, the cluster must also serve `MutatingAdmissionPolicy` in `admissionregistration.k8s.io/v1`. The chart renders no beta version.

1. Run `kubectl api-resources --api-group=admissionregistration.k8s.io`.
2. Verify that the list holds `mutatingadmissionpolicies` with the version `admissionregistration.k8s.io/v1`.

## 2. Pod Certificate and ClusterTrustBundle APIs

The control plane gives each pod an identity through the `PodCertificateRequest` API. It shares trust roots through `ClusterTrustBundle` objects and projected volumes. Substrate v1.0.0 uses `certificates.k8s.io/v1` when the cluster serves it, and `v1beta1` otherwise.

- The manual run on Kubernetes 1.37 set no feature gate.
- The kind cluster of the integration test sets the feature gates `ClusterTrustBundle`, `ClusterTrustBundleProjection` and `PodCertificateRequest`, and `--runtime-config=certificates.k8s.io/v1beta1=true`. These are the settings of the upstream kind script.
- On a managed cluster you usually cannot set feature gates. The version must then serve both APIs by default.

To verify:

1. Run `kubectl api-resources --api-group=certificates.k8s.io`.
2. Verify that `clustertrustbundles` and `podcertificaterequests` are in the list.
3. Save this pod as `pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata: {name: probe, namespace: default}
   spec:
     containers: [{name: c, image: example, volumeMounts: [{name: v, mountPath: /v}]}]
     volumes:
       - name: v
         projected:
           sources:
             - clusterTrustBundle: {name: example, path: ctb.pem, optional: true}
             - podCertificate: {signerName: example.com/signer, keyType: ED25519, credentialBundlePath: cred.pem}
   ```

4. Run `kubectl apply --dry-run=server -o yaml -f pod.yaml`.
5. Verify that both sources are in the output. A server with a gate off removes the source.

## 3. Default StorageClass

The bundled Postgres asks for a `ReadWriteOnce` volume from the default StorageClass. The upstream size is 500 GiB. Set a smaller size in `postgres.storage` before the first install.

1. Run `kubectl get storageclass`.
2. Verify that exactly one class shows `(default)`.

## 4. Pod Security level

`atelet` mounts the host directories `/dev`, `/var/lib/ate` and the kubelet plugin directories. The worker pods need a host path volume and can need a SELinux type. The Baseline level blocks both, so the namespaces need the `privileged` level.

1. Create the namespace `ate-system` with the label `pod-security.kubernetes.io/enforce=privileged`.
2. Create the namespace of each worker pool with the same label.
3. Run `kubectl get ns ate-system -o jsonpath='{.metadata.labels}'`.
4. Verify that the output holds the label.
5. If the cluster has an admission configuration that enforces the restricted level by default, verify that it exempts these namespaces.

## 5. SELinux

Skip this section if the nodes do not enforce SELinux.

On nodes that enforce SELinux, pods run as `container_t` and cannot write `/var/lib/ate` (upstream issue #3597). Turn on `selinux.enabled` in both the `substrate-install` chart and the `substrate-workers` chart. The README section "SELinux" explains the values.

If you use `container_engine_t`, each node must label `/var/lib/ate` as `container_file_t` at level `s0`. A node image can do this at build time. New files in the directory inherit the label.

1. On the node, run `getenforce`.
2. If the output is `Enforcing`, turn both switches on.
3. After the install, run `kubectl -n ate-system get pods -l app=atelet`.
4. Verify that each pod is `Running`.
5. Run `kubectl -n <pool namespace> run probe --image=probe --dry-run=server -o jsonpath='{.spec.securityContext.seLinuxOptions.type}' -l ate.dev/worker-pool=<pool name>`.
6. Verify that the output is the `selinux.type` of the `substrate-workers` chart.
7. If you use `container_engine_t`, run `ps -eZ` on the node.
8. Verify that `atelet`, the object-store plugin and the workers run as `container_engine_t`.

## 6. Where `atelet` runs

`atelet` is a DaemonSet. A worker pod must run on a node that runs `atelet`. The DaemonSet tolerates the taint `ate.dev/sandboxClass:NoSchedule`, and the controller adds the same toleration to worker pods. A node with any other `NoSchedule` taint gets no `atelet`, so it can run no worker.

1. Run `kubectl -n ate-system get pods -l app=atelet -o wide`.
2. Verify that every node of each worker pool is in the list.

## 7. One CPU model for each worker pool

A gVisor snapshot depends on the CPU features of the worker that made it (upstream issue #1657). Every node of one pool must show the same CPU model and flags. On VMs, set a fixed named CPU model. Do not pass the host CPU through on mixed hardware.

1. On each node, run `grep -m1 'model name' /proc/cpuinfo`.
2. Verify that the output is the same on every node of the pool.
3. On each node, run `grep -m1 flags /proc/cpuinfo | md5sum`.
4. Verify that the sum is the same on every node of the pool.

## 8. Nested virtualization

Nested virtualization is needed only for microVMs. The charts install the gVisor class only, so you do not need it.

## 9. Images and the snapshot store

1. Run `docker manifest inspect ghcr.io/bbaliyan/kube-agent-substrate/substrate-install:main-<short commit>` on a machine with no stored registry credentials.
2. Verify that the command prints the manifest. The nodes can then pull the image without a login.
3. Create the snapshot bucket before the install. RustFS 1.0.x cannot create a bucket on its own, so run a Job with a pinned AWS CLI image that runs `aws s3api create-bucket`.
4. If the actor image is in a registry in the cluster, address it by the IP address of its Service. `atelet` pulls the image itself, and it pulls over plain HTTP only from a private address.

## 10. The GKE PodMonitoring CRD

`ate-setup` stops if the CRD `podmonitorings.monitoring.googleapis.com` is missing (upstream issue #2589). A cluster without the GKE managed Prometheus operator needs a stub. `examples/onprem/podmonitoring-crd.yaml` is a stub that holds no operator.

1. Run `kubectl apply -f examples/onprem/podmonitoring-crd.yaml`.
2. Run `kubectl get crd podmonitorings.monitoring.googleapis.com`.
3. Verify that the CRD exists.

## 11. Interactive `kubectl ate proxy`

Skip this section if you do not run `kubectl ate proxy`. The registration and idle-suspend charts do not need it.

`kubectl ate proxy` creates a `PodCertificateRequest` for the account `atenet-client` and reads the `atenet-router` Service. The router accepts the client only if its identity is in `config.ingressAllowedSPIFFEIDs`.

1. Add `spiffe://cluster.local/ns/ate-system/sa/atenet-client` to `config.ingressAllowedSPIFFEIDs`.
2. If your account is not a cluster admin, create a Role in `ate-system`. Allow `create`, `get`, `list`, `watch` and `delete` on `podcertificaterequests`.
3. Add `get` and `list` on `services`, `endpoints` and `pods` to the Role, and bind it to your account.
4. Run `kubectl ate proxy actor <name> 8081:80 -a <atespace>`.
5. Run `curl http://127.0.0.1:8081/`.
6. Verify that the actor answers.

## What the manual run showed

The run used a self-managed RKE2 cluster with Kubernetes 1.37, SELinux enforcing, RustFS and the values of `examples/onprem/`.

- The install Job finished in 29 seconds after the images were on the node.
- The control plane, Postgres, RustFS and two workers requested 2.7 CPUs in total.
- Without `selinux.enabled`, `atelet` exited with `permission denied` on `/var/lib/ate`. A worker without the policy exited with `permission denied` on the remount of `/sys/fs/cgroup`. Both ran with the switches on.
- gVisor ran with the `systrap` platform. It needed no nested virtualization.
- A sample actor started, suspended and resumed with its counters intact. It also resumed after a revert dropped the node-local snapshot, so the restore came from RustFS.
- A second run with `container_engine_t` passed the same steps. The node offered no `ate.dev/kvm` resource.
- The interactive proxy needed the steps of section 11.
- The idle-suspend chart, observability and several nodes were not run.
