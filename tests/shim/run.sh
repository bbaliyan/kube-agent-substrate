#!/usr/bin/env bash
# Runs the webhook shim that the substrate-actor chart renders, in Docker, against a stand-in
# router that needs a client certificate. It checks the token rules and the mTLS hop.
# See the README, "Webhook shim".
#
# Why a script: the steps depend on each other (make certificates, start two containers,
# send requests, change the secret file, compare the answers). No declarative tool sequences
# them. The shim config comes from helm template, so the test runs what the chart renders.
#
# Needs docker, helm, openssl and curl. It uses the Envoy image that the chart pins.
set -euo pipefail

cd "$(dirname "$0")/../.."
here="$PWD/tests/shim"
values=charts/substrate-actor/ci/onprem-values.yaml
work="$(mktemp -d)"
net="shim-test-$$"
port=18080
secret=correct-horse-battery
hop=substrate-webhook-hop

cleanup() {
  docker rm -f "$net-shim" "$net-router" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

rendered="$(helm template x charts/substrate-actor -f "$values" -s templates/webhook.yaml)"
image="$(sed -n 's/^ *image: //p' <<<"$rendered")"
test -n "$image" || { echo "no shim image in the render" >&2; exit 1; }

mkdir -p "$work/config" "$work/secrets" "$work/router-client" "$work/router-certs"
for file in envoy.yaml sds-client.yaml sds-ca.yaml; do
  awk -v key="  $file: |" '$0 == key {f=1; next} f && /^    / {sub(/^    /, ""); print; next} f {exit}' <<<"$rendered" >"$work/config/$file"
  test -s "$work/config/$file" || { echo "no $file in the render" >&2; exit 1; }
done
printf '%s' "$secret" >"$work/secrets/WEBHOOK_SECRET"

host=atenet-router.ate-system.svc
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj "/CN=test-ca" \
  -keyout "$work/ca.key" -out "$work/router-client/router-ca.pem" 2>/dev/null
cp "$work/router-client/router-ca.pem" "$work/router-certs/ca.pem"
issue() { # name, subject alternative name
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
    -keyout "$work/$1.key" -out "$work/$1.csr" 2>/dev/null
  printf 'subjectAltName=%s\n' "$2" >"$work/$1.ext"
  openssl x509 -req -in "$work/$1.csr" -CA "$work/router-client/router-ca.pem" -CAkey "$work/ca.key" \
    -CAcreateserial -days 1 -extfile "$work/$1.ext" -out "$work/$1.pem" 2>/dev/null
}
issue server "DNS:$host"
issue shim "DNS:shim"
cp "$work/server.pem" "$work/router-certs/server.pem"
cp "$work/server.key" "$work/router-certs/server.key"
cat "$work/shim.key" "$work/shim.pem" >"$work/router-client/credential-bundle.pem"
chmod -R a+rX "$work"

docker network create "$net" >/dev/null
docker run -d --name "$net-router" --network "$net" --network-alias "$host" \
  -v "$here/router.yaml:/etc/envoy/envoy.yaml:ro" -v "$work/router-certs:/certs:ro" \
  "$image" -c /etc/envoy/envoy.yaml --disable-hot-restart >/dev/null
docker run -d --name "$net-shim" --network "$net" -p "127.0.0.1:$port:8080" \
  --user 101:101 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v "$work/config:/etc/envoy:ro" -v "$work/secrets:/secrets:ro" -v "$work/router-client:/run/router-client:ro" \
  "$image" -c /etc/envoy/envoy.yaml --disable-hot-restart >/dev/null

failures=0
check() { # name, expected status, expected body fragment, curl args...
  local name="$1" status="$2" fragment="$3" out code
  shift 3
  out="$(curl -s -m 20 -o - -w '\n%{http_code}' "$@" "http://127.0.0.1:$port${path:-/hook}" || true)"
  code="${out##*$'\n'}"
  if [ "$code" = "$status" ] && grep -qF -- "$fragment" <<<"$out"; then
    echo "ok: $name"
  else
    echo "FAIL: $name (status $code, want $status, output: $out)"
    failures=$((failures + 1))
  fi
}

for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/healthz" || true)" = 200 ] && break
  sleep 1
done

path=/healthz check "the health route answers without a token" 200 ok -X GET
check "no token is refused" 401 "unauthorized" -X POST -d '{}'
check "a wrong token is refused" 401 "unauthorized" -X POST -H "X-Gitlab-Token: wrong" -d '{}'
check "the right token plus extra bytes is refused" 401 "unauthorized" -X POST -H "X-Gitlab-Token: ${secret}x" -d '{}'
check "the right token reaches the router with the target and the hop token" 200 "actor=reviews/pr-review token=$hop" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
check "the real secret never reaches the router" 200 "token=$hop" -X POST -H "X-Gitlab-Token: $secret" -d '{}'

printf '%s' "rotated-secret" >"$work/secrets/WEBHOOK_SECRET"
check "after a rotation the old token is refused" 401 "unauthorized" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
check "after a rotation the new token is accepted" 200 "actor=reviews/pr-review" -X POST -H "X-Gitlab-Token: rotated-secret" -d '{}'

rm "$work/secrets/WEBHOOK_SECRET"
check "a missing secret file refuses every request" 401 "unauthorized" -X POST -H "X-Gitlab-Token: rotated-secret" -d '{}'

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  docker logs "$net-shim" 2>&1 | tail -20
  exit 1
fi
echo "all tests passed"
