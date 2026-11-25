#!/usr/bin/env bash
# Runs the steps of the install Job inside the install image, against the real release checkout:
# the credential provider patches, the storage patch of each ci values file, and the Postgres sizing
# patch (see the comment of the target test-image in the Makefile). A script, because the cases need
# loops and files that a Makefile recipe cannot hold readably.
# Usage: IMAGE=substrate-install:local tests/install-image/test.sh   (needs docker, helm and awk on the host)
set -euo pipefail

image="${IMAGE:?set IMAGE to the install image}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

docker run --rm --entrypoint sh -v "$root/charts/substrate-install/patches:/patches:ro" "$image" -euc '\
  mkdir /tmp/work && cp -a /opt/substrate/. /tmp/work/ && \
  mkdir /tmp/work/manifests/ate-install/patches && cp -r /patches/. /tmp/work/manifests/ate-install/patches/ && \
  cd /tmp/work/manifests/ate-install/base && \
  render="kustomize build --load-restrictor LoadRestrictionsNone ." && \
  before=$($render | grep -c image-credential-provider || true) && \
  kustomize edit add component $(printf "../patches/%s " $(ls ../patches)) && \
  after=$($render | grep -c image-credential-provider || true) && \
  echo "credential provider lines: before=$before after=$after" && \
  test "$before" -gt 0 && test "$after" -eq 0 && \
  ate-setup --help >/dev/null'
for profile in aws onprem; do \
  dir=build/storage-$profile; mkdir -p "$dir/20-storage-profile"; \
  cp -r charts/substrate-install/patches/. "$dir/"; \
  helm template r charts/substrate-install -f charts/substrate-install/ci/$profile-values.yaml -s templates/configmap.yaml \
    | awk '/^  patch-20-storage-profile: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' > "$dir/20-storage-profile/kustomization.yaml"; \
  helm template r charts/substrate-install -f charts/substrate-install/ci/$profile-values.yaml -s templates/configmap.yaml \
    | awk '/^  patch-25-atelet-selinux: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' > "$dir.selinux"; \
  if [ -s "$dir.selinux" ]; then mkdir "$dir/25-atelet-selinux" && mv "$dir.selinux" "$dir/25-atelet-selinux/kustomization.yaml"; fi; \
  docker run --rm --entrypoint sh -e PROFILE=$profile -v "$root/$dir:/patches:ro" "$image" -euc '\
    mkdir /tmp/work && cp -a /opt/substrate/. /tmp/work/ && \
    mkdir /tmp/work/manifests/ate-install/patches && cp -r /patches/. /tmp/work/manifests/ate-install/patches/ && \
    cd /tmp/work/manifests/ate-install/base && \
    kustomize edit add component $(printf "../patches/%s " $(ls ../patches)) && \
    kustomize build --load-restrictor LoadRestrictionsNone . > /tmp/out.yaml && \
    keys=0 && if [ "$PROFILE" = onprem ]; then keys=2; fi && \
    spc=0 && if [ "$PROFILE" = onprem ]; then spc=1; fi && \
    test "$(grep -c "type: spc_t$" /tmp/out.yaml)" -eq $spc && \
    test "$(grep -c "name: ATE_STORAGE_BACKEND$" /tmp/out.yaml)" -eq 2 && \
    test "$(grep -A1 "name: ATE_STORAGE_BACKEND$" /tmp/out.yaml | grep -c "value: s3$")" -eq 2 && \
    test "$(grep -c "value: gcs$" /tmp/out.yaml)" -eq 0 && \
    test "$(grep -c "name: AWS_REGION$" /tmp/out.yaml)" -eq 2 && \
    test "$(grep -c "name: AWS_ENDPOINT_URL$" /tmp/out.yaml)" -eq $keys && \
    test "$(grep -c "name: AWS_ACCESS_KEY_ID$" /tmp/out.yaml)" -eq $keys && \
    echo "profile $PROFILE: backend set on both plugin sidecars, spc_t on $spc atelet pod spec"' || exit 1; \
done
for case in default changed renamed; do \
  case $case in \
    default|renamed) sets=""; req='cpu: "2" memory: 1Gi'; lim='cpu: "16" memory: 2Gi'; storage=500Gi;; \
    changed) sets="--set postgres.resources.requests.cpu=500m --set postgres.resources.requests.memory=512Mi --set-string postgres.resources.limits.cpu=4 --set postgres.resources.limits.memory=3Gi --set postgres.storage=5Gi"; req='cpu: 500m memory: 512Mi'; lim='cpu: "4" memory: 3Gi'; storage=5Gi;; \
  esac; \
  dir=build/postgres-$case; mkdir -p "$dir/patches/30-postgres-sizing" "$dir/pg-build"; \
  cp -r charts/substrate-install/patches/. "$dir/patches/"; \
  helm template r charts/substrate-install -f charts/substrate-install/ci/aws-values.yaml $sets -s templates/configmap.yaml > "$dir/configmap.yaml"; \
  awk '/^  patch-30-postgres-sizing: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' "$dir/configmap.yaml" > "$dir/patches/30-postgres-sizing/kustomization.yaml"; \
  awk '/^  pg-build: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' "$dir/configmap.yaml" > "$dir/pg-build/kustomization.yaml"; \
  cmd=$(helm template r charts/substrate-install -f charts/substrate-install/ci/aws-values.yaml $sets -s templates/job.yaml | awk '/name: patch-postgres/{f=1} f&&/command:/{c=1;next} c&&/^ +- /{sub(/^ +- /,"");print;next} c{exit}'); \
  test -n "$cmd" || { echo "no patch-postgres command in the Job"; exit 1; }; \
  docker run --rm --user 0 --entrypoint sh -e CASE=$case -e REQ="$req" -e LIM="$lim" -e STORAGE="$storage" -v "$root/$dir:/in:ro" "$image" -euc '\
    mkdir /work && cp -a /opt/substrate/. /work/ && \
    mkdir /work/manifests/ate-install/patches /work/manifests/ate-install/pg-build && \
    cp -r /in/patches/. /work/manifests/ate-install/patches/ && \
    cp /in/pg-build/kustomization.yaml /work/manifests/ate-install/pg-build/ && \
    if [ "$CASE" = renamed ]; then \
      sed -i "s/^  name: postgres\$/  name: postgres-renamed/" /work/manifests/ate-install/postgres/postgres.yaml && \
      if "$@"; then echo "the Job command passed although no StatefulSet is named postgres"; exit 1; fi && \
      echo "renamed StatefulSet: the Job command fails, as it must" && exit 0; \
    fi && \
    "$@" && \
    flat=$(tr -s " \n" " " < /work/manifests/ate-install/postgres/postgres.yaml) && \
    case "$flat" in *"requests: $REQ limits: $LIM"*|*"limits: $LIM requests: $REQ"*) ;; *) echo "postgres sizing $REQ / $LIM not found"; exit 1;; esac && \
    case "$flat" in *"storage: $STORAGE "*) ;; *) echo "storage $STORAGE not found"; exit 1;; esac && \
    echo "postgres sizing $REQ / $LIM, storage $STORAGE: written over the postgres manifest by the command of the Job"' sh $cmd || exit 1; \
done
