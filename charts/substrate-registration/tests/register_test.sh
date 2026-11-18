#!/usr/bin/env bash
# Runs files/register.sh against a stub kubectl-ate that keeps its state in files.
# The stub exists because the script needs a control plane, which the checks do not have.
# It covers the idle gate and the no-change rerun. The kind harness covers the real client.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"/{atespaces,templates,actors,policies} "$work/actors/web"

cat >"$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat >"$work/bin/kubectl-ate" <<'STUB'
#!/usr/bin/env bash
set -eu
s="$STATE"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --token-file | -o | -a) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
missing() { echo "rpc error: code = NotFound desc = missing" >&2; exit 1; }
verb="$1"; kind="$2"; name="${3:-}"
case "$verb $kind" in
  "get atespace") [ -e "$s/atespaces/$name" ] || missing; echo '{}' ;;
  "create atespace") echo "create atespace $name" >>"$s/calls"; touch "$s/atespaces/$name" ;;
  "get actor-template") [ -e "$s/templates/$name" ] || missing; echo '{}' ;;
  "get actor-templates") ls "$s/templates" | jq -R '{metadata:{name:.}}' | jq -s '{actorTemplates:.}' ;;
  "create actor-template")
    f="$4"; [ "$3" = "-f" ] && f="$4"
    n="$(sed -n 's/^  name: //p' "$f")"
    echo "create actor-template $n" >>"$s/calls"; touch "$s/templates/$n" ;;
  "delete actor-template") echo "delete actor-template $name" >>"$s/calls"; rm -f "$s/templates/$name" ;;
  "get actor") [ -e "$s/actors/$name" ] || missing
    read -r t st <"$s/actors/$name"
    jq -n --arg t "$t" --arg st "$st" '{actorTemplate:{name:$t},status:{state:$st}}' ;;
  "create actor")
    t="$5"; echo "create actor $name $t" >>"$s/calls"; echo "$t ACTOR_STATE_SUSPENDED" >"$s/actors/$name" ;;
  "delete actor") echo "delete actor $name" >>"$s/calls"; rm -f "$s/actors/$name"; rm -f "$s/policies/$name" ;;
  "get egress-policy") [ -e "$s/policies/$name" ] && echo '{}' || true ;;
  "create egress-policy") echo "create egress-policy $name" >>"$s/calls"; touch "$s/policies/$name" ;;
  *) echo "stub: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/"*

run() {
  : >"$work/state/calls"
  PATH="$work/bin:$PATH" STATE="$work/state" ACTORS_DIR="$work/actors" PLAN="$work/plan" \
    POLL_SECONDS=0 WAIT_SECONDS=2 bash "$here/../files/register.sh" >"$work/out" 2>&1 || { cat "$work/out"; exit 1; }
}

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

use_version() {
  printf '%s\n' "web apps web-$1" >"$work/plan"
  printf '%s' "web-$1" >"$work/actors/web/template-name"
  printf 'metadata:\n  atespace: apps\n  name: web-%s\n' "$1" >"$work/actors/web/template.yaml"
  printf 'metadata:\n  name: default\nrules: []\n' >"$work/actors/web/egress-policy.yaml"
}

h1=aaaaaaaaaa
h2=bbbbbbbbbb

use_version "$h1"
run
expect_calls "create atespace apps
create actor-template web-$h1
create actor web web-$h1
create egress-policy web
" "a new actor gets its atespace, template, actor and egress policy"

run
expect_calls "" "a rerun on unchanged input changes nothing"

use_version "$h2"
echo "web-$h1 ACTOR_STATE_RUNNING" >"$work/state/actors/web"
run
expect_calls "" "a busy actor is left for the next sync"
grep -q "busy" "$work/out"

echo "web-$h1 ACTOR_STATE_SUSPENDED" >"$work/state/actors/web"
run
expect_calls "delete actor web
create actor-template web-$h2
create actor web web-$h2
create egress-policy web
delete actor-template web-$h1
" "an idle actor swaps to the new template and the old template goes"

run
expect_calls "" "a rerun after the swap changes nothing"

use_version "$h1"
rm "$work/actors/web/template-name"
if PATH="$work/bin:$PATH" STATE="$work/state" ACTORS_DIR="$work/actors" PLAN="$work/plan" POLL_SECONDS=0 WAIT_SECONDS=1 bash "$here/../files/register.sh" >/dev/null 2>&1; then
  echo "FAIL: the script ran on a ConfigMap that is not current" >&2
  exit 1
fi
echo "ok: the script refuses a ConfigMap that does not hold the planned template"
