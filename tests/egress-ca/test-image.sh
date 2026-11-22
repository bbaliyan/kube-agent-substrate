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
  flag_indent=$(grep -- "--envoy-admin-address" "$egress" | head -1 | sed "s/-.*//" | tr -d "\n" | wc -c)
  sh -ec "$(cat /in/step.sh)"
  test "$(grep -c "^ *#ATE_EGRESS_INJECT_FLAGS" "$egress")" -eq 1
  marker_indent=$(grep "^ *#ATE_EGRESS_INJECT_FLAGS" "$egress" | sed "s/#.*//" | tr -d "\n" | wc -c)
  test "$marker_indent" -eq "$flag_indent"
  test "$(grep -c "mountPath: /etc/ssl/certs/ca-certificates.crt" "$egress")" -eq 1
  test "$(grep -c "name: egress-ca-bundle" "$egress")" -eq 3
  test "$(grep -c "egress-ca-sha256:" "$egress")" -eq 1
  test "$(grep -c "^kind:" "$egress")" -eq 4
  echo "patch-egress: the marker stays once at the indent of the flags, the bundle is mounted, all 4 documents remain"

  setup
  sed -i "s|/etc/ssl/certs/ca-certificates.crt|/etc/ssl/certs/other.crt|" "$egress"
  if sh -ec "$(cat /in/step.sh)" 2>/dev/null; then echo "the step passed although the manifest no longer reads the CA file"; exit 1; fi
  echo "patch-egress: fails when the manifest stops reading the CA file, as it must"

  setup
  sed -i "/#ATE_EGRESS_INJECT_FLAGS/d" "$egress"
  if sh -ec "$(cat /in/step.sh)" 2>/dev/null; then echo "the step passed although the marker is missing"; exit 1; fi
  echo "patch-egress: fails when the credential flag marker is missing, as it must"
'
