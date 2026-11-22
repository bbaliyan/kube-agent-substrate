#!/usr/bin/env bash
# Runs the patch-egress step of the install Job, as the chart renders it, inside the install image
# against the real release manifest. A shell script because the check needs a few files and cases that a
# Makefile recipe cannot hold readably. Usage: IMAGE=substrate-install:local tests/egress-ca/test-image.sh
set -euo pipefail

image="${IMAGE:?set IMAGE to the install image}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
build="$root/build/egress-ca"
values="$root/charts/substrate-install/ci/aws-values.yaml"
render=(helm template r "$root/charts/substrate-install" -f "$values" --set-string "egress.trustedCaPem=-----BEGIN CERTIFICATE-----TEST")

rm -rf "$build"
mkdir -p "$build/patches/26-egress-trusted-ca" "$build/egress-build"
cp -r "$root/charts/substrate-install/patches/." "$build/patches/"

# Each file below is what the chart puts in the config map or the Job, cut out by its key.
"${render[@]}" -s templates/configmap.yaml > "$build/configmap.yaml"
awk '/^  patch-26-egress-trusted-ca: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' "$build/configmap.yaml" > "$build/patches/26-egress-trusted-ca/kustomization.yaml"
awk '/^  egress-build: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' "$build/configmap.yaml" > "$build/egress-build/kustomization.yaml"
"${render[@]}" -s templates/job.yaml | awk '/name: patch-egress/{f=1} f&&/- \|$/{s=1;next} s&&/^              /{sub(/^              /,"");print;next} s{exit}' > "$build/step.sh"
for file in patches/26-egress-trusted-ca/kustomization.yaml egress-build/kustomization.yaml step.sh; do
  test -s "$build/$file" || { echo "the chart renders no $file for the egress CA"; exit 1; }
done

docker run --rm --user 0 --entrypoint sh -v "$build:/in:ro" "$image" -euc '
  setup() {
    rm -rf /work && mkdir /work && cp -a /opt/substrate/. /work/ &&
    mkdir /work/manifests/ate-install/patches /work/manifests/ate-install/egress-build &&
    cp -r /in/patches/. /work/manifests/ate-install/patches/ &&
    cp /in/egress-build/kustomization.yaml /work/manifests/ate-install/egress-build/
  }
  egress=/work/manifests/ate-install/atenet-egress.yaml

  setup
  count() { grep -c -- "$1" "$egress" || true; }
  kinds_before=$(count "^kind:")
  filter_before=$(count "^ *#ATE_MITM_EXTPROC_FILTER")
  cluster_before=$(count "^ *#ATE_MITM_EXTPROC_CLUSTER")
  image_before=$(grep -cF "\${ENVOY_DATAPLANE_IMAGE}" "$egress" || true)
  envoy_before=$(grep -cF "  envoy.yaml: |" "$egress" || true)
  test "$filter_before" -eq 2 && test "$cluster_before" -eq 1 && test "$image_before" -eq 1 && test "$envoy_before" -eq 1
  flag_indent=$(grep -- "--envoy-admin-address" "$egress" | head -1 | sed "s/-.*//" | tr -d "\n" | wc -c)
  sh -ec "$(cat /in/step.sh)"
  test "$(grep -c "^ *#ATE_EGRESS_INJECT_FLAGS" "$egress")" -eq 1
  marker_indent=$(grep "^ *#ATE_EGRESS_INJECT_FLAGS" "$egress" | sed "s/#.*//" | tr -d "\n" | wc -c)
  test "$marker_indent" -eq "$flag_indent"
  test "$(grep -c "mountPath: /etc/ssl/certs/ca-certificates.crt" "$egress")" -eq 1
  test "$(grep -c "name: egress-ca-bundle" "$egress")" -eq 3
  test "$(grep -c "egress-ca-sha256:" "$egress")" -eq 1
  test "$(count "^kind:")" -eq "$kinds_before"
  test "$(count "^ *#ATE_MITM_EXTPROC_FILTER")" -eq "$filter_before"
  test "$(count "^ *#ATE_MITM_EXTPROC_CLUSTER")" -eq "$cluster_before"
  test "$(grep -cF "\${ENVOY_DATAPLANE_IMAGE}" "$egress" || true)" -eq "$image_before"
  test "$(grep -cF "  envoy.yaml: |" "$egress" || true)" -eq "$envoy_before"
  echo "patch-egress: the credential marker stays once at the indent of the flags, the bundle is mounted, and every marker and placeholder that ate-setup replaces later is still there"

  setup
  sed -i "s|/etc/ssl/certs/ca-certificates.crt|/etc/ssl/certs/other.crt|" "$egress"
  cp "$egress" /tmp/before.yaml
  if err=$(sh -ec "$(cat /in/step.sh)" 2>&1); then echo "the step passed although the manifest no longer reads the CA file"; exit 1; fi
  case "$err" in *"no longer reads"*) ;; *) echo "the step failed for another reason: $err"; exit 1;; esac
  cmp -s "$egress" /tmp/before.yaml || { echo "the failed step changed the manifest"; exit 1; }
  echo "patch-egress: fails with its message when the manifest stops reading the CA file, and leaves the manifest alone"

  setup
  sed -i "/#ATE_EGRESS_INJECT_FLAGS/d" "$egress"
  cp "$egress" /tmp/before.yaml
  if sh -ec "$(cat /in/step.sh)" >/dev/null 2>&1; then echo "the step passed although the marker is missing"; exit 1; fi
  cmp -s "$egress" /tmp/before.yaml || { echo "the failed step changed the manifest"; exit 1; }
  echo "patch-egress: fails when the credential flag marker is missing, and leaves the manifest alone"
'
