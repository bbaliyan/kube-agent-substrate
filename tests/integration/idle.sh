#!/usr/bin/env bash
# The idle-suspend checks of the kind integration test. run.sh sources this file and calls
# idle_checks when the sample actor exists and is suspended.
#
# Why a script: like run.sh, the steps depend on each other and on the live cluster. What can be
# declared is declared: tests/integration/prometheus.yaml holds the Prometheus, and the chart
# holds the CronJob.
#
# It uses the helpers and the variables of run.sh. It needs no other file.
#
# What it proves: the chart's CronJob, its RBAC and its token reach the real control plane, run
# the real queries against a real Prometheus that scrapes the real router and atelet, and
# suspend only when every signal says idle.
# What it does not prove: the Prometheus here is not the one of a real cluster (no GMP, no
# authentication, 5 second scrape). The CPU signal reads a real measurement, but no step makes the
# actor busy by CPU alone, and no step holds a request in flight. Those branches have stub tests only.

idle_prometheus_url="http://prometheus.harness-monitoring.svc:9090"

# Runs a PromQL query through the API server proxy and prints the sample values.
idle_prom() {
  kubectl get --raw "/api/v1/namespaces/harness-monitoring/services/prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" |
    jq -r '.data.result[] | (.metric | tostring) + " " + .value[1]'
}

# suspend=true stops the schedule of the CronJob. The checks start each run by hand, so a run
# never starts in the middle of a step. The test does not prove that Kubernetes fires the schedule.
idle_install() {
  helm upgrade --install substrate-idle-suspend charts/substrate-idle-suspend -n "$release_ns" \
    --set "image.repository=$cluster_base/substrate-registration" --set "image.digest=$registration_digest" \
    --set "actors[0].atespace=harness" --set "actors[0].name=counter" \
    --set "prometheus.url=$idle_prometheus_url" \
    --set idleMinutes=1 --set suspend=true \
    "$@" >>"$logs/helm-idle.log" 2>&1
}

# Prints the series that the default queries read, so a drift of a metric name shows in the log.
idle_series() {
  local q
  for q in 'count(envoy_server_live == 1)'     'sum(atenet_router_route_duration_seconds_count)'     'sum(ate_actor_lifecycle_operation_duration_seconds_count{ate_actor_operation_name="resume"})'     'sum(envoy_cluster_upstream_rq_active{envoy_cluster_name=~"actor_.*"})'     'envoy_cluster_upstream_rq_active{envoy_cluster_name=~"actor_.*"}'     'max_over_time(envoy_cluster_upstream_rq_active{envoy_cluster_name=~"actor_.*"}[1m])'     'max_over_time((sum(envoy_cluster_upstream_rq_active{envoy_cluster_name=~"actor_.*"}) or vector(0))[1m:15s])'     'ate_actor_stats_cpu_time_seconds_total'; do
    printf 'series %s
' "$q"
    idle_prom "$q" | head -5 || true
  done
  printf 'metric names with stats or cpu:
'
  kubectl get --raw "/api/v1/namespaces/harness-monitoring/services/prometheus:9090/proxy/api/v1/label/__name__/values" | jq -r '.data[]' | grep -E 'stats|cpu' | head -20 || true
}

idle_run_n=0
# Starts one run of the CronJob now and waits for it. Prints the log to $logs/idle-run-N.log.
# Returns 0 when the Job succeeded and 1 when it failed.
idle_run() {
  idle_run_n=$((idle_run_n + 1))
  local job="idle-run-$idle_run_n" deadline=$((SECONDS + 180)) ok failed
  kubectl -n "$release_ns" create job "$job" --from=cronjob/substrate-idle-suspend >/dev/null
  while [ "$SECONDS" -lt "$deadline" ]; do
    ok="$(kubectl -n "$release_ns" get job "$job" -o jsonpath='{.status.succeeded}')"
    failed="$(kubectl -n "$release_ns" get job "$job" -o jsonpath='{.status.failed}')"
    if [ -n "$ok" ] || [ -n "$failed" ]; then break; fi
    sleep 2
  done
  kubectl -n "$release_ns" logs -l "job-name=$job" --tail=-1 >"$logs/$job.log" 2>&1 || true
  sed 's/^/    | /' "$logs/$job.log"
  if [ -z "$ok" ] && [ -z "$failed" ]; then fail "$job did not finish in 180 seconds"; fi
  [ "${ok:-0}" -ge 1 ]
}

idle_checks() {
  step "Deploy a Prometheus that scrapes the router, the egress proxy and atelet"
  kubectl apply -f "$here/prometheus.yaml" >/dev/null
  kubectl -n harness-monitoring rollout status deployment/prometheus --timeout=300s >/dev/null
  idle_healthy() { [ "$(idle_prom 'count(envoy_server_live == 1)' | awk '{print $NF}')" -ge 1 ] 2>/dev/null; }
  wait_for 180 "Prometheus scrapes Envoy" idle_healthy

  step "Install the substrate-idle-suspend chart and grant its account the editor role of the atespace"
  idle_install || { tail -20 "$logs/helm-idle.log"; fail "the substrate-idle-suspend chart did not install"; }
  # Least privilege: the account edits one atespace. It is not a bootstrap owner.
  refresh_token
  cat >"$tmp/idle-policy.yaml" <<POLICY
metadata:
  name: default
bindings:
  - role: editor
    members:
      - user:system:serviceaccount:$release_ns:substrate-idle-suspend
POLICY
  if ! ate create access-policy -a harness -f "$tmp/idle-policy.yaml" >"$logs/idle-policy.log" 2>&1; then
    # An atespace may already have a default policy. Add the binding to it.
    ate get access-policy -a harness -o json >"$tmp/policy-live.json" 2>>"$logs/idle-policy.log" || { cat "$logs/idle-policy.log"; fail "kubectl ate could not create or read the access policy"; }
    jq --arg m "user:system:serviceaccount:$release_ns:substrate-idle-suspend" \
      '.bindings = ((.bindings // []) + [{role: "editor", members: [$m]}])' "$tmp/policy-live.json" >"$tmp/policy-new.json"
    ate update access-policy -a harness -f "$tmp/policy-new.json" >>"$logs/idle-policy.log" 2>&1 || { cat "$logs/idle-policy.log"; fail "kubectl ate could not update the access policy"; }
  fi

  step "Resume the actor with a request and verify that a busy actor is not suspended"
  # Earlier steps moved the actor to new templates, which restart its counters. Take a new baseline.
  ate resume actor counter -a harness >/dev/null
  wait_for 300 "the actor is RUNNING" actor_is ACTOR_STATE_RUNNING
  last_counters="$(counters)"
  ate suspend actor counter -a harness --mode=sync >/dev/null
  wait_for 300 "the actor is SUSPENDED" actor_is ACTOR_STATE_SUSPENDED
  # The router resumes the actor on the request. This is the same path as a real client.
  expect_continued "$last_counters"
  last_counters="$(counters)"
  actor_is ACTOR_STATE_RUNNING || fail "the actor is not RUNNING after a request"
  idle_series
  idle_run || fail "the run failed on a busy actor"
  grep -q "is busy" "$logs/idle-run-$idle_run_n.log" || fail "the run did not report the actor as busy"
  actor_is ACTOR_STATE_RUNNING || fail "the chart suspended a busy actor"
  log "the busy actor stayed RUNNING"

  step "Wait for the idle time, then verify that a failing signal query suspends nothing"
  # idleMinutes is 1. Wait until every signal has been quiet for one minute and the scrape has seen it.
  # The proxy of kubectl ate holds a CONNECT tunnel open. Envoy counts it as an active request of the
  # actor_connect cluster until it closes, and the chart treats an open tunnel as a busy actor. Close it.
  # Envoy closes an unused tunnel after 60 seconds (tunnelIdleTimeout in the router), and the window of
  # the in-flight signal is 1 minute, so the wait must be longer than 2 minutes.
  kill "$proxy_pid" 2>/dev/null || true
  wait "$proxy_pid" 2>/dev/null || true
  proxy_pid=
  sleep 135
  idle_series
  # A query that Prometheus refuses: every other signal says idle, so only the fail-safe keeps the actor.
  idle_install --set "queries.cpu=sum(" || fail "the upgrade with a broken query failed"
  if idle_run; then fail "the run passed with a query that Prometheus refuses"; fi
  grep -q "the cpu query failed" "$logs/idle-run-$idle_run_n.log" || fail "the run did not name the failed query"
  actor_is ACTOR_STATE_RUNNING || fail "the chart suspended an actor although a signal query failed"
  log "the failing query left the actor RUNNING and failed the run"

  step "Verify that an idle actor is suspended"
  idle_install || fail "the upgrade to the default queries failed"
  idle_run || fail "the run failed on an idle actor"
  grep -q "is idle" "$logs/idle-run-$idle_run_n.log" || { fail "the run did not report the actor as idle"; }
  wait_for 120 "the actor is SUSPENDED by the chart" actor_is ACTOR_STATE_SUSPENDED
  log "the chart suspended the idle actor"

  step "Verify that a suspended actor is left alone"
  idle_run || fail "the run failed on a suspended actor"
  grep -q "Nothing to do" "$logs/idle-run-$idle_run_n.log" || fail "the run did not report that there is nothing to do"

  step "Verify that the next request resumes the actor"
  # The proxy starts with a request to the actor, and the router resumes the actor for it.
  start_proxy
  actor_is ACTOR_STATE_RUNNING || fail "the actor is not RUNNING after the request"
  local after
  after="$(counters)"
  set -- $last_counters
  set -- "$1" "$2" $after
  [ "$3" -gt "$1" ] && [ "$4" -gt "$2" ] || fail "the actor lost state: counters were '$last_counters' before the suspend and '$after' after the resume"
  last_counters="$after"
  log "the actor resumed on the request and kept its state: $last_counters"
  # Leave the actor as the other steps expect it: suspended.
  helm -n "$release_ns" uninstall substrate-idle-suspend >/dev/null
  ate suspend actor counter -a harness --mode=sync >/dev/null
  wait_for 300 "the actor is SUSPENDED" actor_is ACTOR_STATE_SUSPENDED
}
