#!/usr/bin/env bash
# Runs files/register.sh against a stub kubectl-ate that keeps its state in files.
# The stub exists because the script needs a control plane, which the checks do not have.
# It covers the swap rules and the no-change rerun. The kind harness covers the real client.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"/{atespaces,templates,actors,policies} "$work/actors/web"

cat >"$work/bin/kubectl-ate" <<'STUB'
#!/usr/bin/env bash
set -eu
s="$STATE"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --preview) shift ;;
    --token-file | -o | -a) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
missing() { echo "rpc error: code = NotFound desc = missing" >&2; exit 1; }
verb="$1"; kind="$2"; name="${3:-}"
case "$verb $kind" in
  "get atespaces") echo '{}' ;;
  "get atespace") [ -e "$s/atespaces/$name" ] || missing; echo '{}' ;;
  "create atespace") echo "create atespace $name" >>"$s/calls"; touch "$s/atespaces/$name" ;;
  "get actor-template") [ -e "$s/templates/$name" ] || missing; echo '{}' ;;
  "get actor-templates") { ls "$s/templates" || true; } | jq -R '{metadata:{name:.}}' | jq -s '{actorTemplates:.}' ;;
  "create actor-template")
    n="$(sed -n 's/^  name: //p' "$4")"
    echo "create actor-template $n" >>"$s/calls"; touch "$s/templates/$n" ;;
  "delete actor-template") echo "delete actor-template $name" >>"$s/calls"; rm -f "$s/templates/$name" ;;
  "get actor") [ -e "$s/actors/$name" ] || missing
    read -r t st <"$s/actors/$name"
    jq -n --arg t "$t" --arg st "$st" '{actorTemplate:{name:$t},status:{state:$st}}' ;;
  "create actor")
    echo "create actor $name $5" >>"$s/calls"; echo "$5 ACTOR_STATE_SUSPENDED" >"$s/actors/$name" ;;
  "update actor")
    echo "update actor $name $5" >>"$s/calls"
    if [ -e "$s/refuse-update" ]; then echo "rpc error: code = FailedPrecondition desc = snapshot location differs" >&2; exit 1; fi
    read -r _ st <"$s/actors/$name"; echo "$5 $st" >"$s/actors/$name" ;;
  "delete actor") echo "delete actor $name" >>"$s/calls"; rm -f "$s/actors/$name" "$s/policies/$name" ;;
  "get egress-policy") [ -e "$s/policies/$name" ] && jq '{metadata:{uid:"u1",version:"3"},rules:.rules}' "$s/policies/$name" || true ;;
  "create egress-policy") echo "create egress-policy $name" >>"$s/calls"; cp "$5" "$s/policies/$name" ;;
  "update egress-policy")
    jq -e '.metadata.uid == "u1" and .metadata.version == "3"' "$5" >/dev/null
    echo "update egress-policy $name" >>"$s/calls"; cp "$5" "$s/policies/$name" ;;
  "delete egress-policy") echo "delete egress-policy $name" >>"$s/calls"; rm -f "$s/policies/$name" ;;
  *) echo "stub: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/"*

run() {
  : >"$work/state/calls"
  PATH="$work/bin:$PATH" STATE="$work/state" ACTORS_DIR="$work/actors" PLAN="$work/plan" \
    POLL_SECONDS=0 WAIT_SECONDS=1 bash "$here/../files/register.sh" >"$work/out" 2>&1
}

pass() { run || { cat "$work/out"; echo "FAIL: $1 (the script failed)" >&2; exit 1; }; }

expect_calls() {
  if ! diff <(printf '%s' "$1") "$work/state/calls" >/dev/null; then
    echo "FAIL: $2. Expected calls:" >&2
    printf '%s' "$1" >&2
    echo "Got:" >&2
    cat "$work/state/calls" >&2
    exit 1
  fi
  echo "ok: $2"
}

# Sets what the ConfigMap holds: a template version and the host in the egress rule.
configure() {
  local template="$1" host="$2"
  printf 'web apps web-%s egress-%s\n' "$template" "$host" >"$work/plan"
  printf 'web-%s' "$template" >"$work/actors/web/template-name"
  printf 'egress-%s' "$host" >"$work/actors/web/egress-hash"
  printf 'metadata:\n  atespace: apps\n  name: web-%s\n' "$template" >"$work/actors/web/template.yaml"
  printf '{"metadata":{"atespace":"apps","name":"default"},"rules":[{"https":{"hostnames":["%s"]}}]}' "$host" >"$work/actors/web/egress-policy.json"
}

t1=aaaaaaaaaa
t2=bbbbbbbbbb

configure "$t1" one
pass "new actor"
expect_calls "create atespace apps
create actor-template web-$t1
create actor web web-$t1
create egress-policy web
" "a new actor gets its atespace, template, actor and egress policy"

pass "rerun"
expect_calls "" "a rerun on unchanged input changes nothing"

configure "$t1" two
pass "egress change"
expect_calls "update egress-policy web
" "an egress-only change updates the policy in place and leaves the actor alone"

configure "$t2" two
echo "web-$t1 ACTOR_STATE_RUNNING" >"$work/state/actors/web"
if run; then echo "FAIL: a busy actor did not fail the Job" >&2; exit 1; fi
grep -q "FAILED: busy actors" "$work/out"
expect_calls "" "a busy actor is left alone and fails the Job with a message"

echo "web-$t1 ACTOR_STATE_SUSPENDED" >"$work/state/actors/web"
pass "suspended swap"
expect_calls "create actor-template web-$t2
update actor web web-$t2
delete actor-template web-$t1
" "a suspended actor moves to the new template in place and keeps its state"

pass "rerun after swap"
expect_calls "" "a rerun after the swap changes nothing"

configure "$t1" two
touch "$work/state/refuse-update"
pass "refused update"
expect_calls "create actor-template web-$t1
update actor web web-$t1
delete actor web
create actor web web-$t1
create egress-policy web
delete actor-template web-$t2
" "a suspended actor is recreated when the server refuses the in-place update"
rm "$work/state/refuse-update"

configure "$t2" two
echo "web-$t1 ACTOR_STATE_CRASHED" >"$work/state/actors/web"
pass "crashed swap"
expect_calls "create actor-template web-$t2
delete actor web
create actor web web-$t2
create egress-policy web
delete actor-template web-$t1
" "a crashed actor is deleted and created again"

echo "web-$t2 ACTOR_STATE_DELETING" >"$work/state/actors/web"
pass "deleting"
expect_calls "delete actor web
create actor web web-$t2
create egress-policy web
" "an actor stuck in deleting gets its delete again"

configure "$t1" two
rm "$work/actors/web/template-name"
if run; then
  echo "FAIL: the script ran on a ConfigMap that is not current" >&2
  exit 1
fi
echo "ok: the script refuses a ConfigMap that does not hold the planned template"

long=$(printf 'a%.0s' {1..60})
mkdir -p "$work/actors/$long"
printf '%s apps %s-cccccccccc egress-x\n' "$long" "${long:0:52}" >"$work/plan"
printf '%s-cccccccccc' "${long:0:52}" >"$work/actors/$long/template-name"
printf 'egress-x' >"$work/actors/$long/egress-hash"
printf 'metadata:\n  name: %s-cccccccccc\n' "${long:0:52}" >"$work/actors/$long/template.yaml"
rm -f "$work/state/actors/web" "$work/state/policies/web" "$work/state/templates"/*
touch "$work/state/templates/${long:0:52}-dddddddddd"
pass "long name"
expect_calls "create actor-template ${long:0:52}-cccccccccc
create actor $long ${long:0:52}-cccccccccc
delete actor-template ${long:0:52}-dddddddddd
" "an old template of an actor with a long name is deleted"
