#!/usr/bin/env bash
# Runs files/idle-suspend.sh with the config that the chart renders, against a stub of
# kubectl-ate and a stub of curl. The stubs exist because the script needs a control plane and
# Prometheus, which the checks do not have. They cover every branch: idle, each busy signal,
# each kind of query error, an actor that is not running and an actor that is missing.
# The kind harness covers the real client and the real query path.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="$here/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state/actors" "$work/config"

cat >"$work/bin/kubectl-ate" <<'STUB'
#!/usr/bin/env bash
set -eu
s="$STATE"
args=()
atespace=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preview) shift ;;
    --token-file | -o | --mode) [ "$1" != --mode ] || echo "mode $2" >>"$s/calls"; shift 2 ;;
    -a) atespace="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
case "$1 $2" in
  "get actor")
    f="$s/actors/$atespace.$3"
    if [ -e "$s/get-error" ]; then echo "rpc error: code = Unavailable desc = down" >&2; exit 1; fi
    [ -e "$f" ] || { echo "rpc error: code = NotFound desc = actor not found" >&2; exit 1; }
    read -r state template <"$f"
    jq -n --arg st "$state" --arg t "$template" --arg a "$atespace" '{actorTemplate:{name:$t,atespace:$a},status:{state:$st}}' ;;
  "suspend actor")
    echo "suspend actor $3 -a $atespace" >>"$s/calls"
    [ ! -e "$s/suspend-error" ] || { echo "rpc error: code = Internal desc = failed" >&2; exit 1; } ;;
  *) echo "stub: unexpected $*" >&2; exit 2 ;;
esac
STUB

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Answers a Prometheus query. The signal is named by the metric in the query. A file
# $STATE/value.<signal> holds the answer: a number, or ERR, EMPTY, MANY or NAN.
set -eu
s="$STATE"
query="" stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data-urlencode) query="${2#query=}"; shift 2 ;;
    -K) stdin=1; shift 2 ;;
    --max-time | --cacert) shift 2 ;;
    *) shift ;;
  esac
done
[ "$stdin" = 0 ] || cat >"$s/curl-stdin"
printf '%s\n' "$query" >>"$s/queries"
case "$query" in
  *envoy_server_live*) signal=health ;;
  *atenet_router_route_duration*) signal=routed ;;
  *lifecycle_operation*) signal=resumed ;;
  *envoy_cluster_upstream_rq_active*) signal=inflight ;;
  *ate_actor_stats_cpu_time*) signal=cpu ;;
  *) echo "stub: unknown query $query" >&2; exit 2 ;;
esac
echo "$signal" >>"$s/signals"
value="$(cat "$s/value.$signal")"
case "$value" in
  ERR) echo "curl: (22) The requested URL returned error: 503" >&2; exit 22 ;;
  EMPTY) echo '{"status":"success","data":{"resultType":"vector","result":[]}}' ;;
  MANY) echo '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"0"]},{"metric":{},"value":[1,"0"]}]}}' ;;
  BAD) echo '{"status":"error","errorType":"bad_data","error":"parse error"}' ;;
  *) printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"%s"]}]}}\n' "$value" ;;
esac
STUB
chmod +x "$work/bin/"*

# The config that the chart renders for the aws values file, one file for each ConfigMap key.
helm template r "$chart" -f "$chart/ci/aws-values.yaml" -s templates/configmap.yaml |
  awk -v dir="$work/config" '
    /^  [A-Za-z.-]+: \|$/ { if (out) close(out); name = $1; sub(/:$/, "", name); out = dir "/" name; printf "" > out; next }
    out && /^    / { sub(/^    /, ""); print > out; next }
    out && /^[^ ]/ { close(out); out = "" }
  '
for f in actors config.env query.health query.routed query.resumed query.inflight query.cpu; do
  test -s "$work/config/$f" || { echo "FAIL: the chart did not render $f"; exit 1; }
done

state="$work/state"
reset() {
  rm -f "$state"/calls "$state"/queries "$state"/signals "$state"/value.* "$state"/get-error "$state"/suspend-error "$state"/curl-stdin "$state"/actors/*
  : >"$state/calls"
  : >"$state/queries"
  : >"$state/signals"
  local s
  for s in health routed resumed inflight cpu; do echo 0 >"$state/value.$s"; done
  echo 1 >"$state/value.health"
  echo 0.001 >"$state/value.cpu"
  # The aws values file lists reviews/pr-review.
  echo "ACTOR_STATE_RUNNING pr-review-0123456789" >"$state/actors/reviews.pr-review"
}

run() {
  PATH="$work/bin:$PATH" STATE="$state" CONFIG_DIR="$work/config" TOKEN_FILE="$work/token" \
    PROMETHEUS_TOKEN_FILE="${PROMETHEUS_TOKEN_FILE:-}" \
    bash "$chart/files/idle-suspend.sh" >"$work/out" 2>&1
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- output" >&2
  cat "$work/out" >&2
  echo "--- calls" >&2
  cat "$state/calls" >&2
  exit 1
}
suspended() { grep -q '^suspend actor' "$state/calls"; }

expect_suspend() {
  run || fail "$1 (the script failed)"
  suspended || fail "$1 (nothing was suspended)"
  echo "ok: $1"
}
expect_no_suspend() {
  run || fail "$1 (the script failed)"
  ! suspended || fail "$1 (the actor was suspended)"
  echo "ok: $1"
}
expect_failure_no_suspend() {
  if run; then fail "$1 (the script passed)"; fi
  ! suspended || fail "$1 (the actor was suspended)"
  echo "ok: $1"
}

echo "pr-review" >"$work/token"

reset
expect_suspend "an idle running actor is suspended"
grep -qx 'mode async' "$state/calls" || fail "the suspend did not pass the mode"
grep -q 'suspend actor pr-review -a reviews' "$state/calls" || fail "the suspend named the wrong actor"
grep -q 'ate_template_name="pr-review-0123456789"' "$state/queries" || fail "the queries did not name the template of the actor"
grep -q 'offset 30m' "$state/queries" || fail "the queries did not use the idle time"
grep -q '@' "$state/queries" && fail "a placeholder is left in a query"

reset
echo 0.05 >"$state/value.cpu"
expect_suspend "a CPU use equal to the threshold counts as idle"

for signal in routed resumed inflight; do
  reset
  echo 1 >"$state/value.$signal"
  expect_no_suspend "the $signal signal alone keeps the actor"
done
reset
echo 0.06 >"$state/value.cpu"
expect_no_suspend "a CPU use above the threshold keeps the actor"
grep -q 'is busy ( cpu )' "$work/out" || fail "the output did not name the busy signal"

reset
echo 1 >"$state/value.routed"; echo 1 >"$state/value.cpu"
expect_no_suspend "several busy signals keep the actor"

for signal in health routed resumed inflight cpu; do
  for mode in ERR EMPTY MANY NAN BAD; do
    reset
    echo "$mode" >"$state/value.$signal"
    expect_failure_no_suspend "a $mode answer to the $signal query fails the run"
  done
done

reset
echo 0 >"$state/value.health"
expect_failure_no_suspend "a metrics source that reports no scrape fails the run"
grep -q 'not healthy' "$work/out" || fail "the output did not name the unhealthy source"

reset
echo "ACTOR_STATE_SUSPENDED pr-review-0123456789" >"$state/actors/reviews.pr-review"
expect_no_suspend "a suspended actor is left alone"
test ! -s "$state/queries" || fail "the script queried Prometheus for an actor that is not running"
for other in ACTOR_STATE_RESUMING ACTOR_STATE_SUSPENDING ACTOR_STATE_CRASHED ACTOR_STATE_REVERTING; do
  echo "$other pr-review-0123456789" >"$state/actors/reviews.pr-review"
  expect_no_suspend "an actor in $other is left alone"
done

reset
rm "$state/actors/reviews.pr-review"
expect_failure_no_suspend "a missing actor fails the run"
grep -q 'does not exist' "$work/out" || fail "the output did not say that the actor is missing"

reset
touch "$state/get-error"
expect_failure_no_suspend "an error from the control plane fails the run"

reset
touch "$state/suspend-error"
if run; then fail "a failed suspend passed"; fi
echo "ok: a failed suspend fails the run"

reset
echo "ACTOR_STATE_RUNNING bad\"name" >"$state/actors/reviews.pr-review"
expect_failure_no_suspend "a template name that is not a plain name fails the run"
test ! -s "$state/queries" || fail "a bad template name reached a query"

reset
PROMETHEUS_TOKEN_FILE="$work/prom-token"
printf 's3cret\n' >"$PROMETHEUS_TOKEN_FILE"
expect_suspend "an idle actor is suspended with a bearer token"
grep -qx 'header = "Authorization: Bearer s3cret"' "$state/curl-stdin" || fail "the token did not reach curl on stdin"
PROMETHEUS_TOKEN_FILE=""

# A second actor in the list: one failing actor must not stop the other, and the run still fails.
reset
printf 'reviews/pr-review\nreviews/second\n' >"$work/config/actors"
echo "ACTOR_STATE_RUNNING second-0123456789" >"$state/actors/reviews.second"
rm "$state/actors/reviews.pr-review"
if run; then fail "a run with a missing actor passed"; fi
grep -q 'suspend actor second -a reviews' "$state/calls" || fail "the missing actor stopped the check of the other actor"
! grep -q 'suspend actor pr-review' "$state/calls" || fail "a missing actor was suspended"
grep -q 'FAILED: reviews/pr-review' "$work/out" || fail "the output did not name the failed actor"
echo "ok: a failing actor does not stop the next actor, and the run fails"

reset
: >"$work/config/actors"
expect_failure_no_suspend "an empty actor list fails the run"
