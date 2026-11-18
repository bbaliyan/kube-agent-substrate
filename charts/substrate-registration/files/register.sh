#!/usr/bin/env bash
# Registers the actors of the substrate-actor chart in a running control plane.
#
# Why a script: ActorTemplates, Actors and EgressPolicies are rows in the control
# plane database, not Kubernetes resources. Only `kubectl ate` writes them, and no
# declarative tool reconciles them. Each step reads the live state first, so a
# repeat run on unchanged input makes no change.
#
# Input: /scripts/plan holds one line for each actor: name, atespace, template name.
# /actors/<name>/ holds template-name, template.yaml and egress-policy.yaml.
# The template name carries a hash of the template and the egress rules. A
# different name on a live actor means the actor must swap to a new template.
set -euo pipefail

NS="${SUBSTRATE_NAMESPACE:-ate-system}"
ACTORS_DIR="${ACTORS_DIR:-/actors}"
PLAN="${PLAN:-/scripts/plan}"
TOKEN_FILE="${TOKEN_FILE:-/var/run/ate/token}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-5}"
export ATE_NAMESPACE="$NS"

BUSY=0
SEEN_ATESPACES=" "

log() { printf '%s\n' "$*"; }
ate() { kubectl-ate --token-file "$TOKEN_FILE" "$@"; }

# Fails with the error text, except when the error says the object is missing.
# The text of a gRPC status error holds its code.
fetch() {
  local out
  if out=$(ate "$@" -o json 2>&1); then
    FETCHED="$out"
    return 0
  fi
  case "$out" in
    *NotFound*) return 1 ;;
  esac
  printf '%s\n' "$out" >&2
  exit 1
}

# Runs a create command and accepts "already exists", which a parallel run can cause.
create() {
  local out
  if ! out=$(ate create "$@" 2>&1); then
    case "$out" in
      *AlreadyExists*) return 0 ;;
    esac
    printf '%s\n' "$out" >&2
    exit 1
  fi
  log "$out"
}

wait_until() {
  local what="$1" deadline=$((SECONDS + WAIT_SECONDS))
  shift
  until "$@"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "Timed out after $WAIT_SECONDS seconds: $what"
      exit 1
    fi
    sleep "$POLL_SECONDS"
  done
}

api_available() {
  kubectl -n "$NS" wait --for=condition=Available --timeout=10s deployment/ate-api-server >/dev/null 2>&1
}

# The ConfigMap of the substrate-actor chart is current when it holds the expected template name.
actor_data_current() {
  [ "$(cat "$ACTORS_DIR/$1/template-name" 2>/dev/null)" = "$2" ]
}

ensure_atespace() {
  case "$SEEN_ATESPACES" in *" $1 "*) return 0 ;; esac
  SEEN_ATESPACES="$SEEN_ATESPACES$1 "
  if ! fetch get atespace "$1"; then
    log "Create atespace $1"
    create atespace "$1"
  fi
}

ensure_template() {
  local actor="$1" atespace="$2" template="$3"
  if ! fetch get actor-template "$template" -a "$atespace"; then
    log "Create template $atespace/$template"
    create actor-template -f "$ACTORS_DIR/$actor/template.yaml"
  fi
}

ensure_egress_policy() {
  local actor="$1" atespace="$2" policy
  [ -f "$ACTORS_DIR/$actor/egress-policy.yaml" ] || return 0
  policy=$(ate get egress-policy "$actor" -a "$atespace" -o json 2>/dev/null || true)
  if [ -z "$policy" ]; then
    log "Create egress policy of $atespace/$actor"
    create egress-policy "$actor" -a "$atespace" -f "$ACTORS_DIR/$actor/egress-policy.yaml"
  fi
}

# Deletes the older templates of this actor. Their names are the actor name and 10 hex characters.
delete_old_templates() {
  local actor="$1" atespace="$2" keep="$3" name
  fetch get actor-templates -a "$atespace" || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    log "Delete old template $atespace/$name"
    ate delete actor-template "$name" -a "$atespace"
  done < <(jq -r --arg pattern "^${actor}-[0-9a-f]{10}\$" --arg keep "$keep" \
    '.actorTemplates[]? | .metadata.name | select(test($pattern) and . != $keep)' <<<"$FETCHED")
}

create_actor() {
  local actor="$1" atespace="$2" template="$3"
  ensure_template "$actor" "$atespace" "$template"
  log "Create actor $atespace/$actor from $template"
  create actor "$actor" --template "$template" -a "$atespace"
  ensure_egress_policy "$actor" "$atespace"
  delete_old_templates "$actor" "$atespace" "$template"
}

reconcile() {
  local actor="$1" atespace="$2" template="$3" current state
  wait_until "ConfigMap of actor $actor holds $template" actor_data_current "$actor" "$template"
  ensure_atespace "$atespace"

  if ! fetch get actor "$actor" -a "$atespace"; then
    create_actor "$actor" "$atespace" "$template"
    return 0
  fi
  current=$(jq -r '.actorTemplate.name // ""' <<<"$FETCHED")
  state=$(jq -r '.status.state // ""' <<<"$FETCHED")

  if [ "$current" = "$template" ]; then
    ensure_egress_policy "$actor" "$atespace"
    delete_old_templates "$actor" "$atespace" "$template"
    log "Actor $atespace/$actor is current"
    return 0
  fi

  # An idle actor holds no worker. SUSPENDED and CRASHED are idle. A swap deletes the actor and its state.
  case "$state" in
    ACTOR_STATE_SUSPENDED | ACTOR_STATE_CRASHED) ;;
    *)
      log "Actor $atespace/$actor is busy ($state). Leave it for the next sync."
      BUSY=$((BUSY + 1))
      return 0
      ;;
  esac
  log "Swap actor $atespace/$actor from $current to $template"
  ate delete actor "$actor" -a "$atespace"
  create_actor "$actor" "$atespace" "$template"
}

wait_until "ate-api-server in $NS is not available" api_available
while read -r -u 3 actor atespace template; do
  [ -n "$actor" ] || continue
  reconcile "$actor" "$atespace" "$template"
done 3<"$PLAN"

if [ "$BUSY" -gt 0 ]; then
  log "$BUSY busy actor(s) are not swapped yet."
fi
log "Registration done."
