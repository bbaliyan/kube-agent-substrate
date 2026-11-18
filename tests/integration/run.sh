#!/usr/bin/env bash
# The kind integration test. It installs Agent Substrate with the charts of this
# repo and the production images, registers a sample actor, and checks that the
# actor starts, suspends and resumes. See the README for what it covers.
#
# Why a script: the steps depend on each other and on the cluster (build, push,
# install, wait, read the live state, compare). No declarative tool sequences
# them. What can be declared is declared: the manifests and values in this
# directory hold every setting, and the script only applies them in order.
#
# Needs docker, kubectl, helm, jq and curl. Set KEEP_CLUSTER=1 to keep the
# cluster and the registry. Set KIND to use a kind binary that you already have.
set -euo pipefail

cd "$(dirname "$0")/../.."
root="$PWD"
here="$root/tests/integration"

pinned() { sed -n "s/^$1: *//p" "$here/versions.yaml"; }

cluster="${KIND_CLUSTER_NAME:-substrate-int}"
registry_name="$cluster-registry"
tmp="$(mktemp -d)"
logs="${LOG_DIR:-$tmp/logs}"
mkdir -p "$logs"
# Its own kubeconfig, so no kubectl call here can reach another cluster.
export KUBECONFIG="$tmp/kubeconfig"
export ATE_NAMESPACE=ate-system
network="${KIND_EXPERIMENTAL_DOCKER_NETWORK:-kind}"
kind_bin="${KIND:-$tmp/kind}"
release_ns=substrate-system
substrate_tag="$(sed -n 's/^ARG SUBSTRATE_TAG=//p' images/substrate-install/Dockerfile | head -1)"
started=$SECONDS
timings=()

step() {
  local now=$((SECONDS - started))
  printf '\n== [%4ss] %s\n' "$now" "$*"
  timings+=("$now $*")
}
log() { printf '%s\n' "$*"; }
fail() {
  log "FAIL: $*"
  exit 1
}

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    diagnose || true
  fi
  if [ "${KEEP_CLUSTER:-0}" != 1 ]; then
    "$kind_bin" delete cluster --name "$cluster" >/dev/null 2>&1 || true
    docker rm -f "$registry_name" >/dev/null 2>&1 || true
    rm -rf "$tmp"
  else
    log "Kept the cluster $cluster, the registry $registry_name and $tmp (kubeconfig, logs)."
  fi
}
trap cleanup EXIT

# Writes the state of the cluster to the log directory and prints the end of the
# logs that most often explain a failure.
diagnose() {
  log "== Diagnosis"
  {
    kubectl get pods -A -o wide
    kubectl get events -A --sort-by=.lastTimestamp | tail -60
    kubectl -n "$release_ns" get jobs,pods
  } >"$logs/diagnosis.txt" 2>&1 || true
  for job in $(kubectl -n "$release_ns" get jobs -o name 2>/dev/null); do
    kubectl -n "$release_ns" logs "$job" --all-containers --tail=-1 >"$logs/$(basename "$job").log" 2>&1 || true
  done
  for ns in ate-system; do
    for pod in $(kubectl -n "$ns" get pods -o name 2>/dev/null); do
      kubectl -n "$ns" logs "$pod" --all-containers --tail=200 >"$logs/$(basename "$pod").log" 2>&1 || true
    done
  done
  log "Pods that are not ready:"
  kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | head -20 || true
  for f in "$logs"/*.log; do
    [ -f "$f" ] || continue
    log "-- last lines of $(basename "$f")"
    tail -n 12 "$f"
  done
  log "Full logs: $logs (kept only with KEEP_CLUSTER=1 or LOG_DIR)"
}

# Runs a command until it succeeds or the time is up.
wait_for() {
  local seconds="$1" what="$2" deadline
  shift 2
  deadline=$((SECONDS + seconds))
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || fail "timed out after ${seconds}s: $what"
    sleep 3
  done
}

# kubectl-ate with the token of the registration service account, like the Job.
ate() {
  kubectl-ate --token-file "$tmp/token" "$@"
}
refresh_token() {
  kubectl -n "$release_ns" create token substrate-registration --audience "api.ate-system.svc" --duration 2h >"$tmp/token"
}
actor_state() { ate get actor counter -a harness -o json | jq -r '.status.state // ""'; }
actor_is() { [ "$(actor_state)" = "$1" ]; }

for tool in docker kubectl helm jq curl; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done

# --- Cluster -----------------------------------------------------------------

step "Fetch kind $(pinned kindVersion)"
if [ -z "${KIND:-}" ]; then
  case "$(uname -m)" in
    x86_64) arch=amd64 sum="$(pinned kindSha256Amd64)" ;;
    aarch64 | arm64) arch=arm64 sum="$(pinned kindSha256Arm64)" ;;
    *) fail "unsupported architecture $(uname -m)" ;;
  esac
  curl -sSfL -o "$kind_bin" "https://github.com/kubernetes-sigs/kind/releases/download/$(pinned kindVersion)/kind-linux-$arch"
  echo "$sum  $kind_bin" | sha256sum -c - >/dev/null
  chmod +x "$kind_bin"
fi

step "Prepare the image builds"
# The Dockerfiles use $BUILDPLATFORM, which the legacy builder lacks. A Docker CLI that is
# only the binary (the Dev box mounts just that) has no buildx plugin, so fetch one.
if ! docker buildx version >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64) arch=amd64 sum="$(pinned buildxSha256Amd64)" ;;
    aarch64 | arm64) arch=arm64 sum="$(pinned buildxSha256Arm64)" ;;
    *) fail "unsupported architecture $(uname -m)" ;;
  esac
  export DOCKER_CONFIG="$tmp/docker-config"
  mkdir -p "$DOCKER_CONFIG/cli-plugins"
  curl -sSfL -o "$DOCKER_CONFIG/cli-plugins/docker-buildx" "https://github.com/docker/buildx/releases/download/$(pinned buildxVersion)/buildx-$(pinned buildxVersion).linux-$arch"
  echo "$sum  $DOCKER_CONFIG/cli-plugins/docker-buildx" | sha256sum -c - >/dev/null
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-buildx"
fi

step "Build the images in the background"
# The three builds share nothing, so they run together. The registry takes the pushes.
docker rm -f "$registry_name" >/dev/null 2>&1 || true
docker run -d --name "$registry_name" -p 127.0.0.1::5000 "$(pinned registryImage)" >/dev/null
registry_port="$(docker port "$registry_name" 5000/tcp | head -1 | sed 's/.*://')"
push_base="localhost:$registry_port"
make --no-print-directory image IMAGE="$push_base/substrate-install:$substrate_tag" >"$logs/build-install.log" 2>&1 &
build_install=$!
make --no-print-directory image-registration REGISTRATION_IMAGE="$push_base/substrate-registration:$substrate_tag" >"$logs/build-registration.log" 2>&1 &
build_registration=$!
docker build --tag "$push_base/counter:$substrate_tag" tests/integration/counter >"$logs/build-counter.log" 2>&1 &
build_counter=$!

step "Create the kind cluster"
"$kind_bin" create cluster --name "$cluster" --image "$(pinned kindNodeImage)" --config "$here/kind-config.yaml" --wait 180s >"$logs/kind.log" 2>&1
# The caps of the Dev box reach the node after it starts. Verify what the node got.
node="$cluster-control-plane"
# gVisor needs proxy ARP on the node for pod-to-pod networking on loopback (hack/create-kind-cluster.sh).
docker exec "$node" sysctl -w net.ipv4.conf.all.proxy_arp=1 >/dev/null
docker exec "$node" sysctl -e -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null

# Pods and atelet reach the registry by its address on the cluster network.
# atelet pulls the actor image itself over plain HTTP, and only for a private address.
docker network connect "$network" "$registry_name"
registry_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$registry_name")"
[ -n "$registry_ip" ] || fail "the registry has no address on the network $network"
docker exec "$node" mkdir -p "/etc/containerd/certs.d/$registry_ip:5000"
printf '[host."http://%s:5000"]\n' "$registry_ip" | docker exec -i "$node" tee "/etc/containerd/certs.d/$registry_ip:5000/hosts.toml" >/dev/null
cluster_base="$registry_ip:5000"

step "Wait for the builds and push the images"
wait "$build_install" || { tail -20 "$logs/build-install.log"; fail "the install image build failed"; }
wait "$build_registration" || { tail -20 "$logs/build-registration.log"; fail "the registration image build failed"; }
wait "$build_counter" || { tail -20 "$logs/build-counter.log"; fail "the counter image build failed"; }
digest_of() {
  docker push "$push_base/$1:$substrate_tag" 2>&1 | tee -a "$logs/push.log" | sed -n 's/.*digest: \(sha256:[0-9a-f]*\).*/\1/p' | tail -1
}
install_digest="$(digest_of substrate-install)"
registration_digest="$(digest_of substrate-registration)"
counter_digest="$(digest_of counter)"
[ -n "$install_digest" ] && [ -n "$registration_digest" ] && [ -n "$counter_digest" ] || fail "a push gave no digest (see $logs/push.log)"
log "install $install_digest registration $registration_digest counter $counter_digest"
counter_image="$cluster_base/counter@$counter_digest"

# The tag of the counter build must be the release that the install image holds.
test "$(sed -n 's/^ARG SUBSTRATE_COMMIT=//p' tests/integration/counter/Dockerfile)" = "$(sed -n 's/^ARG SUBSTRATE_COMMIT=//p' images/substrate-install/Dockerfile | head -1)" ||
  fail "tests/integration/counter/Dockerfile pins another Substrate commit than images/substrate-install/Dockerfile"

# --- Storage -----------------------------------------------------------------

step "Deploy RustFS and create the snapshot bucket"
kubectl create namespace ate-system >/dev/null
# Test values only. The Secret lives in the cluster of this run and nowhere else.
kubectl -n ate-system create secret generic snapshot-store-keys \
  --from-literal=access-key-id=test-access-key --from-literal=secret-access-key=test-secret-key >/dev/null
kubectl apply -f "$here/rustfs.yaml" >/dev/null
kubectl -n ate-system rollout status deployment/rustfs --timeout=300s >/dev/null
kubectl -n ate-system wait --for=condition=complete job/rustfs-bucket-init --timeout=300s >/dev/null

# --- Install -----------------------------------------------------------------

step "Install the control plane with the substrate-install chart"
kubectl apply -f "$here/podmonitoring-crd.yaml" >/dev/null
kubectl wait --for=condition=Established --timeout=60s crd/podmonitorings.monitoring.googleapis.com >/dev/null
kubectl create namespace "$release_ns" >/dev/null
install_chart() {
  helm upgrade --install substrate-install charts/substrate-install -n "$release_ns" \
    -f "$here/install-values.yaml" \
    --set "image.repository=$cluster_base/substrate-install" --set "image.digest=$install_digest" \
    --wait --wait-for-jobs --timeout 20m "$@"
}
install_chart >"$logs/helm-install.log" 2>&1 || fail "the install did not finish (see the job logs)"
kubectl -n ate-system get pods >"$logs/pods-after-install.txt"

step "Start the sample worker pool"
kubectl apply -f "$here/workerpool.yaml" >/dev/null
wait_for 600 "the worker pool is ready" kubectl -n harness-workers wait --for=condition=Ready pod --all --timeout=5s

# --- Actor -------------------------------------------------------------------

step "Extract kubectl-ate from the registration image"
cid="$(docker create "$push_base/substrate-registration:$substrate_tag")"
docker cp "$cid:/usr/local/bin/kubectl-ate" "$tmp/kubectl-ate" >/dev/null
docker rm "$cid" >/dev/null
export PATH="$tmp:$PATH"

actors_args=(-f "$here/actors-values.yaml" --set "actors[0].image=$counter_image")
install_actor() {
  helm upgrade --install substrate-actor charts/substrate-actor -n "$release_ns" "${actors_args[@]}" "$@" >>"$logs/helm-actor.log" 2>&1
}
install_registration() {
  helm upgrade --install substrate-registration charts/substrate-registration -n "$release_ns" "${actors_args[@]}" \
    --set "image.repository=$cluster_base/substrate-registration" --set "image.digest=$registration_digest" \
    --set waitSeconds=300 --set backoffLimit=0 --set job.annotations=null \
    --wait --wait-for-jobs --timeout 15m "$@" >>"$logs/helm-registration.log" 2>&1
}
# Runs the registration Job again on the same inputs: delete the finished Job, apply the chart.
registration_job_log() {
  kubectl -n "$release_ns" logs -l app.kubernetes.io/part-of=substrate-registration --tail=-1
}
rerun_registration() {
  kubectl -n "$release_ns" delete job -l app.kubernetes.io/part-of=substrate-registration --wait >/dev/null
  install_registration "$@"
}

step "Register the sample actor with the substrate-registration chart"
install_actor || fail "the substrate-actor chart did not install"
install_registration || { registration_job_log | tail -30; fail "the registration Job failed"; }
registration_job_log >"$logs/registration-run1.log"
grep -q "Create actor harness/counter" "$logs/registration-run1.log" || fail "the first run did not create the actor"
grep -q "Create egress policy of harness/counter" "$logs/registration-run1.log" || fail "the first run did not create the egress policy"
grep -q "Registration done." "$logs/registration-run1.log" || fail "the Job did not end with Registration done."
refresh_token
ate get actor counter -a harness -o json >"$logs/actor-after-register.json"
ate get egress-policy counter -a harness -o json >"$logs/egress-after-register.json"
ate get actor-templates -a harness -o json >"$logs/templates-after-register.json"

step "Check that the actor starts"
actor_settled() { case "$(actor_state)" in ACTOR_STATE_SUSPENDED | ACTOR_STATE_RUNNING) return 0 ;; *) return 1 ;; esac; }
wait_for 300 "the registered actor settles" actor_settled
log "state after registration: $(actor_state)"
if actor_is ACTOR_STATE_SUSPENDED; then
  ate resume actor counter -a harness >"$logs/resume1.log" 2>&1 || { cat "$logs/resume1.log"; fail "kubectl ate resume failed"; }
fi
wait_for 300 "the actor is RUNNING" actor_is ACTOR_STATE_RUNNING
log "worker of the actor: $(ate get actor counter -a harness -o json | jq -c '.status')"

step "Check that the actor suspends"
ate suspend actor counter -a harness --mode=sync >"$logs/suspend1.log" 2>&1 || { cat "$logs/suspend1.log"; fail "kubectl ate suspend failed"; }
wait_for 300 "the actor is SUSPENDED" actor_is ACTOR_STATE_SUSPENDED

step "Check that the actor resumes"
ate resume actor counter -a harness >"$logs/resume2.log" 2>&1 || { cat "$logs/resume2.log"; fail "kubectl ate resume failed"; }
wait_for 300 "the actor is RUNNING again" actor_is ACTOR_STATE_RUNNING
ate suspend actor counter -a harness --mode=sync >"$logs/suspend2.log" 2>&1 || fail "the second suspend failed"
wait_for 300 "the actor is SUSPENDED again" actor_is ACTOR_STATE_SUSPENDED
log "the actor ran, suspended, resumed and suspended again"

# --- Idempotency -------------------------------------------------------------

# What a rerun of the install must leave alone: the revision of each workload,
# the identity and the restarts of each control plane pod, and the secrets.
fingerprint() {
  {
    kubectl -n ate-system get deploy,ds,sts -o json | jq -S '[.items[] | {kind, name: .metadata.name, generation: .metadata.generation}]'
    kubectl -n ate-system get pods -o json | jq -S '[.items[] | {name: .metadata.name, uid: .metadata.uid, restarts: ([.status.containerStatuses[]?.restartCount] | add)}]'
    kubectl -n ate-system get secrets -o json | jq -S '[.items[] | {name: .metadata.name, uid: .metadata.uid, data: (.data | tojson | length)}]'
    kubectl get crd -o json | jq -S '[.items[] | select(.spec.group | endswith("ate.dev")) | {name: .metadata.name, generation: .metadata.generation}]'
  } | sha256sum | cut -d' ' -f1
}

step "Run the install Job again and verify that nothing changes"
before="$(fingerprint)"
kubectl -n "$release_ns" delete job -l app.kubernetes.io/part-of=substrate-install --wait >/dev/null
install_chart >>"$logs/helm-install.log" 2>&1 || fail "the second install did not finish"
after="$(fingerprint)"
kubectl -n "$release_ns" logs -l app.kubernetes.io/part-of=substrate-install --all-containers --tail=-1 >"$logs/install-run2.log" 2>&1 || true
[ "$before" = "$after" ] || fail "the second install changed the control plane (before $before, after $after)"
log "control plane unchanged: $after"

step "Run the registration Job again and verify that nothing changes"
ate get actor counter -a harness -o json | jq -S . >"$tmp/actor-before.json"
ate get egress-policy counter -a harness -o json | jq -S . >"$tmp/egress-before.json"
ate get actor-templates -a harness -o json | jq -S . >"$tmp/templates-before.json"
rerun_registration || { registration_job_log | tail -30; fail "the second registration failed"; }
registration_job_log >"$logs/registration-run2.log"
if grep -E "^(Create|Update|Delete|Move)" "$logs/registration-run2.log"; then fail "the second registration run changed something"; fi
grep -q "Actor harness/counter is current" "$logs/registration-run2.log" || fail "the second run did not report the actor as current"
ate get actor counter -a harness -o json | jq -S . | diff - "$tmp/actor-before.json" >/dev/null || fail "the actor changed on the second run"
ate get egress-policy counter -a harness -o json | jq -S . | diff - "$tmp/egress-before.json" >/dev/null || fail "the egress policy changed on the second run"
ate get actor-templates -a harness -o json | jq -S . | diff - "$tmp/templates-before.json" >/dev/null || fail "the templates changed on the second run"
log "actor, egress policy and templates are the same after the second run"

step "Verify that the live egress policy matches the rules that the chart renders"
helm template substrate-actor charts/substrate-actor -n "$release_ns" "${actors_args[@]}" |
  awk '/^  egress-policy.json: \|/{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' >"$tmp/rendered-egress.json"
[ -s "$tmp/rendered-egress.json" ] || fail "the chart rendered no egress policy"
live_rules="$(ate get egress-policy counter -a harness -o json | jq -S -c '.rules // []')"
chart_rules="$(jq -S -c '.rules // []' "$tmp/rendered-egress.json")"
log "live:  $live_rules"
log "chart: $chart_rules"
[ "$live_rules" = "$chart_rules" ] || fail "the live egress rules differ from the rendered rules: the Job would update the policy on every run"

# --- Template swap -----------------------------------------------------------

step "Change the template and verify that a suspended actor keeps its state"
uid_before="$(ate get actor counter -a harness -o json | jq -r '.metadata.uid')"
template_before="$(ate get actor counter -a harness -o json | jq -r '.actorTemplate.name')"
actors_args+=(--set "actors[0].env.GREETING=second")
install_actor
rerun_registration || { registration_job_log | tail -30; fail "the template swap failed"; }
registration_job_log >"$logs/registration-swap.log"
grep -q "kept its state" "$logs/registration-swap.log" || fail "the swap did not keep the state of the actor"
template_after="$(ate get actor counter -a harness -o json | jq -r '.actorTemplate.name')"
uid_after="$(ate get actor counter -a harness -o json | jq -r '.metadata.uid')"
[ "$template_before" != "$template_after" ] || fail "the actor still uses $template_before"
[ "$uid_before" = "$uid_after" ] || fail "the actor was recreated: its uid changed"
actor_is ACTOR_STATE_SUSPENDED || fail "the actor is not SUSPENDED after the swap"
ate resume actor counter -a harness >/dev/null
wait_for 300 "the actor with the new template is RUNNING" actor_is ACTOR_STATE_RUNNING
log "the actor moved from $template_before to $template_after, kept its uid and runs"

step "Verify that a running actor is left alone and the Job fails"
actors_args+=(--set "actors[0].env.GREETING=third")
install_actor
if rerun_registration; then fail "the registration Job passed with a running actor"; fi
registration_job_log >"$logs/registration-busy.log"
grep -q "is busy" "$logs/registration-busy.log" || fail "the Job did not report the busy actor"
ate suspend actor counter -a harness --mode=sync >/dev/null
wait_for 300 "the actor is SUSPENDED" actor_is ACTOR_STATE_SUSPENDED
rerun_registration || { registration_job_log | tail -30; fail "the registration after the suspend failed"; }
registration_job_log | grep -q "kept its state" || fail "the actor did not move after it suspended"

step "Change the egress rules only and verify that the policy updates in place"
uid_before="$(ate get actor counter -a harness -o json | jq -r '.metadata.uid')"
actors_args+=(--set "actors[0].egress[0].hostnames[0]=example.net")
install_actor
rerun_registration || { registration_job_log | tail -30; fail "the egress update failed"; }
registration_job_log >"$logs/registration-egress.log"
grep -q "Update egress policy of harness/counter" "$logs/registration-egress.log" || fail "the Job did not update the egress policy"
grep -q "Create actor" "$logs/registration-egress.log" && fail "an egress change recreated the actor"
[ "$uid_before" = "$(ate get actor counter -a harness -o json | jq -r '.metadata.uid')" ] || fail "an egress change recreated the actor"
rerun_registration
if registration_job_log | grep -E "^(Create|Update|Delete|Move)"; then fail "a rerun after the egress update changed something"; fi

step "Done"
log "Passed in $((SECONDS - started)) seconds."
printf '%s\n' "${timings[@]}" >"$logs/timings.txt"
