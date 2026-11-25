#!/usr/bin/env bash
# Runs files/register.sh against a stub kubectl-ate that keeps its state in files.
# The stub exists because the script needs a control plane, which the checks do not have.
# It covers the swap rules and the no-change rerun. The kind harness covers the real client.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"/{atespaces,templates,actors,policies,access} "$work/actors/web"

cat >"$work/bin/kubectl-ate" <<'STUB'
#!/usr/bin/env bash
set -eu
s="$STATE"
args=()
preview=0
while [ $# -gt 0 ]; do
  case "$1" in
    --preview) preview=1; shift ;;
    --token-file | -o) shift 2 ;;
    -a) atespace_arg="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
missing() { echo "rpc error: code = NotFound desc = missing" >&2; exit 1; }
verb="$1"; kind="$2"; name="${3:-}"
case "$verb $kind" in
  "get atespaces")
    # A hook that holds roles in its own atespaces only is not allowed the global list.
    if [ -e "$s/deny-global" ]; then echo "rpc error: code = PermissionDenied desc = lacks can_list_atespaces on global:root" >&2; exit 1; fi
    echo '{}' ;;
  "get atespace") [ ! -e "$s/deny-atespace" ] || { echo "rpc error: code = PermissionDenied desc = lacks can_get_atespace" >&2; exit 1; }
    [ -e "$s/atespaces/$name" ] || missing; echo '{}' ;;
  "create atespace") echo "create atespace $name" >>"$s/calls"; touch "$s/atespaces/$name" ;;
  "get actor-template") [ -e "$s/templates/$name" ] || missing; echo '{}' ;;
  "get actor-templates") { ls "$s/templates" || true; } | jq -R '{metadata:{name:.}}' | jq -s '{actorTemplates:.}' ;;
  "create actor-template")
    # The server forbids a snapshot location unless the client sends the preview flag.
    [ "$preview" = 1 ] || { echo "rpc error: code = InvalidArgument desc = actor_template.snapshot_config.storage_location: Forbidden" >&2; exit 1; }
    n="$(sed -n 's/^  name: //p' "$4")"
    echo "create actor-template $n" >>"$s/calls"; touch "$s/templates/$n" ;;
  "delete actor-template")
    # The server answers Aborted once while it is busy with the template.
    if [ -e "$s/abort-delete" ]; then rm "$s/abort-delete"; echo "rpc error: code = Aborted desc = another operation is in progress" >&2; exit 1; fi
    echo "delete actor-template $name" >>"$s/calls"; rm -f "$s/templates/$name" ;;
  "get actor") [ -e "$s/actors/$name" ] || missing
    read -r t st <"$s/actors/$name"
    jq -n --arg t "$t" --arg st "$st" '{actorTemplate:{name:$t},status:{state:$st}}' ;;
  "create actor")
    echo "create actor $name $5" >>"$s/calls"; echo "$5 ACTOR_STATE_SUSPENDED" >"$s/actors/$name" ;;
  "update actor")
    echo "update actor $name $5" >>"$s/calls"
    if [ -e "$s/refuse-update" ]; then echo "rpc error: code = FailedPrecondition desc = snapshot location differs" >&2; exit 1; fi
    read -r _ st <"$s/actors/$name"; echo "$5 $st" >"$s/actors/$name" ;;
  "revert actor")
    echo "revert actor $name" >>"$s/calls"
    if [ -e "$s/refuse-revert" ]; then echo "rpc error: code = FailedPrecondition desc = no snapshot to revert to" >&2; exit 1; fi
    if [ -e "$s/fail-revert" ]; then echo "rpc error: code = Unavailable desc = control plane busy" >&2; exit 1; fi
    read -r t _ <"$s/actors/$name"; echo "$t ACTOR_STATE_SUSPENDED" >"$s/actors/$name" ;;
  "resume actor")
    echo "resume actor $name" >>"$s/calls"
    read -r t _ <"$s/actors/$name"; echo "$t ACTOR_STATE_RUNNING" >"$s/actors/$name" ;;
  "delete actor") [ ! -e "$s/fail-delete" ] || { echo "rpc error: code = Unavailable desc = control plane busy" >&2; exit 1; }
    [ -e "$s/actors/$name" ] || missing
    echo "delete actor $name" >>"$s/calls"; rm -f "$s/actors/$name" "$s/policies/$name" ;;
  "delete atespace") [ -e "$s/atespaces/$name" ] || missing
    # An atespace with an actor or a template is not empty. The server answers FailedPrecondition.
    if [ -n "$(ls -A "$s/actors" "$s/templates" | grep -v ':$' || true)" ]; then echo "rpc error: code = FailedPrecondition desc = atespace is not empty" >&2; exit 1; fi
    echo "delete atespace $name" >>"$s/calls"; rm -f "$s/atespaces/$name" "$s/access/$name" ;;
  "get egress-policy") [ -e "$s/policies/$name" ] && jq '{metadata:{uid:"u1",version:"3"},rules:.rules}' "$s/policies/$name" || true ;;
  "create egress-policy") echo "create egress-policy $name" >>"$s/calls"; cp "$5" "$s/policies/$name" ;;
  "update egress-policy")
    jq -e '.metadata.uid == "u1" and .metadata.version == "3"' "$5" >/dev/null
    echo "update egress-policy $name" >>"$s/calls"; cp "$5" "$s/policies/$name" ;;
  "get access-policy")
    [ ! -e "$s/fail-policy-get" ] || { echo "rpc error: code = Unavailable desc = control plane busy" >&2; exit 1; }
    # A missing policy is an empty result with exit code 0, as the real client answers.
    if [ -e "$s/access/$atespace_arg" ]; then cat "$s/access/$atespace_arg"; else echo "atespace \"$atespace_arg\" has no access policy" >&2; fi ;;
  "create access-policy")
    echo "create access-policy $atespace_arg" >>"$s/calls"
    # Another client writes the policy first: ours is refused, and the other write stays.
    if [ -e "$s/race-create" ]; then
      echo '{"bindings":[{"role":"editor","members":["user:other"]}],"metadata":{"uid":"p1","version":"1"}}' >"$s/access/$atespace_arg"
      rm "$s/race-create"
      echo "rpc error: code = AlreadyExists desc = AccessPolicy already exists" >&2; exit 1
    fi
    jq '. + {metadata: {uid: "p1", version: "1"}}' "$4" >"$s/access/$atespace_arg" ;;
  "update access-policy")
    jq -e '.metadata.uid == "p1" and .metadata.version == "1"' "$4" >/dev/null
    echo "update access-policy $atespace_arg" >>"$s/calls"
    # The policy changed after the read: the server answers Aborted once, and the other write is stored.
    if [ -e "$s/race-update" ]; then
      echo '{"bindings":[{"role":"editor","members":["user:other"]}],"metadata":{"uid":"p1","version":"1"}}' >"$s/access/$atespace_arg"
      rm "$s/race-update"
      echo "rpc error: code = Aborted desc = AccessPolicy version conflict" >&2; exit 1
    fi
    cp "$4" "$s/access/$atespace_arg" ;;
  "delete egress-policy") echo "delete egress-policy $name" >>"$s/calls"; rm -f "$s/policies/$name" ;;
  *) echo "stub: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/"*

run() {
  : >"$work/state/calls"
  PATH="$work/bin:$PATH" STATE="$work/state" ACTORS_DIR="$work/actors" PLAN="$work/plan" BINDINGS="$work/bindings" \
    POLL_SECONDS=0 WAIT_SECONDS=1 bash "$here/../files/register.sh" >"$work/out" 2>&1
}

run_unregister() {
  : >"$work/state/calls"
  PATH="$work/bin:$PATH" STATE="$work/state" ACTORS_DIR="$work/actors" PLAN="$work/plan" BINDINGS="$work/bindings"     POLL_SECONDS=0 WAIT_SECONDS=1 bash "$here/../files/register.sh" unregister >"$work/out" 2>&1
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
expect_calls "revert actor web
create actor-template web-$t2
update actor web web-$t2
delete actor-template web-$t1
" "a crashed actor with an old template is reverted, and then moves in place"

echo "web-$t2 ACTOR_STATE_CRASHED" >"$work/state/actors/web"
pass "crashed, template current"
expect_calls "revert actor web
" "a crashed actor with the current template is reverted and keeps its identity"

touch "$work/state/refuse-revert"
echo "web-$t2 ACTOR_STATE_CRASHED" >"$work/state/actors/web"
pass "crashed, no snapshot"
expect_calls "revert actor web
delete actor web
create actor web web-$t2
create egress-policy web
" "a crashed actor that cannot be reverted is deleted and created again"

configure "$t1" two
echo "web-$t2 ACTOR_STATE_CRASHED" >"$work/state/actors/web"
pass "crashed, no snapshot, old template"
expect_calls "revert actor web
create actor-template web-$t1
delete actor web
create actor web web-$t1
create egress-policy web
delete actor-template web-$t2
" "a crashed actor with an old template that cannot be reverted is deleted and created again"
rm "$work/state/refuse-revert"

touch "$work/state/fail-revert"
echo "web-$t1 ACTOR_STATE_CRASHED" >"$work/state/actors/web"
if run; then echo "FAIL: a revert error other than FailedPrecondition did not fail the Job" >&2; exit 1; fi
expect_calls "revert actor web
" "a revert that fails for another reason fails the Job and deletes nothing"
rm "$work/state/fail-revert"

configure "$t2" two
rm -f "$work/state/templates"/* && touch "$work/state/templates/web-$t2"
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

# A warm actor is resumed when it is suspended, and left alone when it runs.
configure "$t1" two
printf 'web apps web-%s egress-%s warm
' "$t1" two >"$work/plan"
rm -f "$work/state/actors/web" "$work/state/policies/web" "$work/state/templates"/*
pass "warm, new"
expect_calls "create actor-template web-$t1
create actor web web-$t1
create egress-policy web
resume actor web
" "a new warm actor is resumed after it is created"
pass "warm, running"
expect_calls "" "a warm actor that runs is left alone"
echo "web-$t1 ACTOR_STATE_SUSPENDED" >"$work/state/actors/web"
pass "warm, suspended"
expect_calls "resume actor web
" "a warm actor that was suspended is resumed"
printf 'web apps web-%s egress-%s cold
' "$t1" two >"$work/plan"
echo "web-$t1 ACTOR_STATE_SUSPENDED" >"$work/state/actors/web"
pass "cold, suspended"
expect_calls "" "a cold actor that is suspended stays suspended"

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

# A delete that the server answers with Aborted is tried again.
rm -f "$work/state/actors/$long" "$work/state/policies/$long" "$work/state/templates"/*
touch "$work/state/templates/${long:0:52}-eeeeeeeeee"
touch "$work/state/abort-delete"
pass "retry after Aborted"
expect_calls "create actor-template ${long:0:52}-cccccccccc
create actor $long ${long:0:52}-cccccccccc
delete actor-template ${long:0:52}-eeeeeeeeee
" "a delete that the server answers with Aborted is tried again"

# Access bindings: the Job grants a role to a member and changes nothing when the member has it.
: >"$work/plan"
member=user:system:serviceaccount:pr-agent:substrate-idle-suspend
printf 'ops editor %s
' "$member" >"$work/bindings"
pass "binding, no policy"
expect_calls "create atespace ops
create access-policy ops
" "a binding in an atespace with no policy creates the atespace and the policy"
pass "binding rerun"
expect_calls "" "a rerun of a binding that holds changes nothing"

printf 'ops editor %s
ops editor user:system:serviceaccount:pr-agent:other
' "$member" >"$work/bindings"
pass "binding, second member"
expect_calls "update access-policy ops
" "a second member of the same role is added to the binding, and the first stays"
check_policy() { jq -e "$1" "$work/state/access/ops" >/dev/null || { echo "FAIL: $2" >&2; cat "$work/state/access/ops" >&2; exit 1; }; echo "ok: $2"; }
check_policy '.bindings | length == 1 and (.[0].members | length == 2)' "the two members share one binding"

printf 'ops viewer %s
' "$member" >>"$work/bindings"
pass "binding, second role"
expect_calls "update access-policy ops
" "a member of a new role adds a binding and removes nobody"
check_policy '.bindings | length == 2 and (.[0].members | length == 2)' "the first binding is unchanged"
pass "binding, rerun after update"
expect_calls "" "a rerun after the updates changes nothing"

touch "$work/state/fail-policy-get"
if run; then echo "FAIL: a failed read of the access policy did not fail the Job" >&2; exit 1; fi
expect_calls "" "a failed read of the access policy fails the Job and writes nothing"
rm "$work/state/fail-policy-get"

# A create that loses a race: the member is added to the policy that the other client wrote.
check_access() { jq -e "$2" "$work/state/access/$1" >/dev/null || { echo "FAIL: $3" >&2; cat "$work/state/access/$1" >&2; exit 1; }; echo "ok: $3"; }
printf 'race editor %s\n' "$member" >"$work/bindings"
touch "$work/state/race-create"
pass "binding, lost create"
expect_calls "create atespace race
create access-policy race
update access-policy race
" "a create that finds a policy written first adds the member to it"
check_access race '(.bindings[0].members | length) == 2 and (.bindings[0].members | index("user:other") != null)' "the write of the other client stays"

# An update that loses a race: the Job reads again, and the other write and the grant are both there.
printf 'race editor user:system:serviceaccount:pr-agent:third\n' >"$work/bindings"
touch "$work/state/race-update"
pass "binding, aborted update"
expect_calls "update access-policy race
update access-policy race
" "an update that the server aborts is read again and applied to the newer policy"
check_access race '(.bindings[0].members | sort) == ["user:other", "user:system:serviceaccount:pr-agent:third"]' "the write of the other client and the grant are both there"

# A live policy with no bindings key, and a binding with no members list.
printf '{"metadata":{"uid":"p1","version":"1"}}\n' >"$work/state/access/bare"
touch "$work/state/atespaces/bare"
printf 'bare editor %s\n' "$member" >"$work/bindings"
pass "binding, policy without bindings"
expect_calls "update access-policy bare
" "a policy with no bindings key gets its first binding"
printf '{"bindings":[{"role":"editor"}],"metadata":{"uid":"p1","version":"1"}}\n' >"$work/state/access/bare"
pass "binding, role without members"
expect_calls "update access-policy bare
" "a binding with no members list takes the member"
check_access bare '.bindings[0].members == ["user:system:serviceaccount:pr-agent:substrate-idle-suspend"]' "the member is the only one of the binding"

# Unregister: the actor, then its templates, then the atespace when it is empty. NotFound is success.
configure "$t1" two
rm -rf "$work/state"/{actors,templates,policies,access,atespaces}/*
pass "unregister setup"
: >"$work/state/calls"
run_unregister || { cat "$work/out"; echo "FAIL: unregister failed" >&2; exit 1; }
expect_calls "delete actor web
delete actor-template web-$t1
delete atespace apps
" "unregister deletes the actor, then its template, then the empty atespace"
[ ! -e "$work/state/atespaces/apps" ] || { echo "FAIL: the atespace is still there" >&2; exit 1; }

run_unregister || { cat "$work/out"; echo "FAIL: a repeat of unregister failed" >&2; exit 1; }
expect_calls "" "a repeat of unregister finds nothing and succeeds"

# Two actors share an atespace: it is deleted once, after both actors.
printf 'web apps web-%s egress-two
web2 apps web2-%s egress-two
' "$t1" "$t1" >"$work/plan"
touch "$work/state/atespaces/apps" "$work/state/actors/web" "$work/state/actors/web2" "$work/state/templates/web-$t1" "$work/state/templates/web2-$t1"
run_unregister || { cat "$work/out"; echo "FAIL: unregister of two actors failed" >&2; exit 1; }
expect_calls "delete actor web
delete actor-template web-$t1
delete actor web2
delete actor-template web2-$t1
delete atespace apps
" "two actors in one atespace are deleted before the atespace, which is deleted once"

# Another agent still uses the atespace: the server answers FailedPrecondition and the script leaves it.
printf 'web apps web-%s egress-two
' "$t1" >"$work/plan"
touch "$work/state/atespaces/apps" "$work/state/actors/web" "$work/state/templates/web-$t1" "$work/state/actors/other"
run_unregister || { cat "$work/out"; echo "FAIL: a shared atespace failed the hook" >&2; exit 1; }
expect_calls "delete actor web
delete actor-template web-$t1
" "an atespace that is not empty stays, and the hook still succeeds"
grep -q "not empty" "$work/out"
echo "ok: the hook says why the atespace stays"

# Any other error fails the hook, so Argo CD does not delete the Application over live objects.
touch "$work/state/fail-delete" "$work/state/actors/web"
if run_unregister; then echo "FAIL: an unexpected error did not fail the hook" >&2; exit 1; fi
expect_calls "" "an error other than NotFound and FailedPrecondition fails the hook"
rm "$work/state/fail-delete"

# The hook is not allowed the global list. It reads its own atespace instead, so it does not wait.
rm -rf "$work/state"/{actors,templates}/*
touch "$work/state/atespaces/apps" "$work/state/actors/web" "$work/state/templates/web-$t1" "$work/state/deny-global"
run_unregister || { cat "$work/out"; echo "FAIL: unregister waited on the global list" >&2; exit 1; }
expect_calls "delete actor web
delete actor-template web-$t1
delete atespace apps
" "unregister works when the global list answers PermissionDenied"
# The atespace is gone now: NotFound still shows the API is up.
run_unregister || { cat "$work/out"; echo "FAIL: NotFound on the atespace read failed the hook" >&2; exit 1; }
expect_calls "" "a repeat with the atespace gone succeeds"
# PermissionDenied on the atespace read means not available: the hook logs once, then times out with the error.
touch "$work/state/deny-atespace" "$work/state/atespaces/apps"
if run_unregister; then echo "FAIL: a denied atespace read did not fail the hook" >&2; exit 1; fi
grep -q "Waiting up to" "$work/out" && grep -q "Last error: .*PermissionDenied" "$work/out"
echo "ok: a stuck hook logs the wait and the last error"
rm "$work/state/deny-global" "$work/state/deny-atespace"
