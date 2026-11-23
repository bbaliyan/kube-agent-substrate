#!/usr/bin/env bash
# Registers the actors of the substrate-actor chart in a running control plane.
#
# Why a script: ActorTemplates, Actors and EgressPolicies are rows in the control
# plane database, not Kubernetes resources. Only `kubectl ate` writes them, and no
# declarative tool reconciles them. Each step reads the live state first, so a
# repeat run on unchanged input makes no change.
#
# Input: /scripts/plan holds one line for each actor: name, atespace, template
# name and egress hash. /actors/<name>/ holds template-name, egress-hash,
# template.yaml and, if the actor has egress rules, egress-policy.json.
# The template name carries a hash of the template. A different name on a live
# actor means the actor must move to a new template. The egress policy has no
# name hash: the script compares it with the live policy and updates it in place.
set -euo pipefail

NS="${SUBSTRATE_NAMESPACE:-ate-system}"
ACTORS_DIR="${ACTORS_DIR:-/actors}"
PLAN="${PLAN:-/scripts/plan}"
TOKEN_FILE="${TOKEN_FILE:-/var/run/ate/token}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-5}"
WORK="$(mktemp -d)"
export ATE_NAMESPACE="$NS"

BUSY=()
SEEN_ATESPACES=" "
LAST_ERROR=""

log() { printf '%s\n' "$*"; }
# --preview lets the client use the preview features that the server enables. The template
# of the substrate-actor chart names its own snapshot location, which needs the gate
# PerTemplateSnapshotLocation on the server and the client flag.
ate() { kubectl-ate --preview --token-file "$TOKEN_FILE" "$@"; }

# Fails with the error text, except when the error says the object is missing.
# The text of a gRPC status error holds its code. Only stdout is parsed as JSON.
fetch() {
  if FETCHED=$(ate "$@" -o json 2>"$WORK/stderr"); then
    return 0
  fi
  case "$(cat "$WORK/stderr")" in
    *NotFound*) return 1 ;;
  esac
  cat "$WORK/stderr" >&2
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
      [ -z "$LAST_ERROR" ] || log "Last error: $LAST_ERROR"
      exit 1
    fi
    sleep "$POLL_SECONDS"
  done
}

# kubectl ate finds a ready pod of ate-api-server, so a successful read shows the API is up.
api_available() {
  LAST_ERROR=$(ate get atespaces -o json 2>&1 >/dev/null) || return 1
}

# The ConfigMap of the substrate-actor chart is current when it holds the expected hashes.
actor_data_current() {
  [ "$(cat "$ACTORS_DIR/$1/template-name" 2>/dev/null)" = "$2" ] &&
    [ "$(cat "$ACTORS_DIR/$1/egress-hash" 2>/dev/null)" = "$3" ]
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

# Brings the egress policy of the actor to the rules in the ConfigMap, in place.
reconcile_egress_policy() {
  local actor="$1" atespace="$2" desired="$ACTORS_DIR/$actor/egress-policy.json" live
  live=$(ate get egress-policy "$actor" -a "$atespace" -o json 2>/dev/null || true)
  if [ ! -f "$desired" ]; then
    if [ -n "$live" ]; then
      log "Delete egress policy of $atespace/$actor"
      ate delete egress-policy "$actor" -a "$atespace"
    fi
    return 0
  fi
  if [ -z "$live" ]; then
    log "Create egress policy of $atespace/$actor"
    create egress-policy "$actor" -a "$atespace" -f "$desired"
    return 0
  fi
  if [ "$(jq -S -c '.rules // []' <<<"$live")" = "$(jq -S -c '.rules // []' "$desired")" ]; then
    return 0
  fi
  log "Update egress policy of $atespace/$actor"
  # An update must carry the uid and the version of the stored policy.
  jq --argjson live "$(jq -c '.metadata | {uid, version}' <<<"$live")" '.metadata += $live' "$desired" >"$WORK/egress-update.json"
  ate update egress-policy "$actor" -a "$atespace" -f "$WORK/egress-update.json"
}

# Deletes a template. Right after an actor moves away, the server can still be busy with the
# old template and answers Aborted, so retry for a short time.
delete_template() {
  local name="$1" atespace="$2" out tries=0
  until out=$(ate delete actor-template "$name" -a "$atespace" 2>&1); do
    case "$out" in
      *Aborted*) ;;
      *)
        printf '%s
' "$out" >&2
        exit 1
        ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      printf '%s
' "$out" >&2
      exit 1
    fi
    sleep "$POLL_SECONDS"
  done
}

# Deletes the older templates of this actor. Their names are the actor name,
# cut to the length that the chart uses, and 10 hex characters.
delete_old_templates() {
  local actor="$1" atespace="$2" keep="$3" prefix name
  prefix="${actor:0:52}"
  prefix="${prefix%-}"
  fetch get actor-templates -a "$atespace" || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    log "Delete old template $atespace/$name"
    delete_template "$name" "$atespace"
  done < <(jq -r --arg pattern "^${prefix}-[0-9a-f]{10}\$" --arg keep "$keep" \
    '.actorTemplates[]? | .metadata.name | select(test($pattern) and . != $keep)' <<<"$FETCHED")
}

create_actor() {
  local actor="$1" atespace="$2" template="$3"
  ensure_template "$actor" "$atespace" "$template"
  log "Create actor $atespace/$actor from $template"
  create actor "$actor" --template "$template" -a "$atespace"
}

# Moves an idle actor to the new template. A suspended actor keeps its identity and
# its durable volumes with an update. Its memory and root filesystem restart from the
# new template (measured on kind: the counters of the demo actor restart at 1). The server refuses the update when the snapshot location or the
# volumes differ. Then, and for a crashed actor, the script deletes the actor and
# its state and creates it again.
swap_template() {
  local actor="$1" atespace="$2" template="$3" state="$4" out
  ensure_template "$actor" "$atespace" "$template"
  if [ "$state" = "ACTOR_STATE_SUSPENDED" ]; then
    if out=$(ate update actor "$actor" --template "$template" -a "$atespace" 2>&1); then
      log "Moved actor $atespace/$actor to $template in place"
      return 0
    fi
    case "$out" in
      *FailedPrecondition*) log "The server refused an in-place update: $out" ;;
      *)
        printf '%s\n' "$out" >&2
        exit 1
        ;;
    esac
  fi
  log "Delete actor $atespace/$actor and create it from $template. Its state is lost."
  ate delete actor "$actor" -a "$atespace"
  create_actor "$actor" "$atespace" "$template"
}

reconcile() {
  local actor="$1" atespace="$2" template="$3" egress_hash="$4" current state
  wait_until "ConfigMap of actor $actor holds $template and $egress_hash" actor_data_current "$actor" "$template" "$egress_hash"
  ensure_atespace "$atespace"

  if ! fetch get actor "$actor" -a "$atespace"; then
    create_actor "$actor" "$atespace" "$template"
  else
    current=$(jq -r '.actorTemplate.name // ""' <<<"$FETCHED")
    state=$(jq -r '.status.state // ""' <<<"$FETCHED")
    if [ "$state" = "ACTOR_STATE_DELETING" ]; then
      # An earlier delete did not finish. Run it again, which is safe.
      log "Actor $atespace/$actor is deleting. Run the delete again."
      ate delete actor "$actor" -a "$atespace"
      create_actor "$actor" "$atespace" "$template"
    elif [ "$state" = "ACTOR_STATE_CRASHED" ] && [ "$current" = "$template" ]; then
      # A crash loses the worker of the actor, as a roll of the worker pods does. The template is
      # current, so nothing else would repair it.
      log "Actor $atespace/$actor crashed. Delete it and create it again from $template. Its state is lost."
      ate delete actor "$actor" -a "$atespace"
      create_actor "$actor" "$atespace" "$template"
    elif [ "$current" != "$template" ]; then
      case "$state" in
        ACTOR_STATE_SUSPENDED | ACTOR_STATE_CRASHED)
          log "Move actor $atespace/$actor from $current to $template"
          swap_template "$actor" "$atespace" "$template" "$state"
          ;;
        *)
          log "Actor $atespace/$actor is busy ($state) and uses $current."
          BUSY+=("$atespace/$actor")
          return 0
          ;;
      esac
    fi
  fi
  reconcile_egress_policy "$actor" "$atespace"
  delete_old_templates "$actor" "$atespace" "$template"
  log "Actor $atespace/$actor is current"
}

wait_until "ate-api-server in $NS is not available" api_available
while read -r -u 3 actor atespace template egress_hash; do
  [ -n "$actor" ] || continue
  reconcile "$actor" "$atespace" "$template" "$egress_hash"
done 3<"$PLAN"

# A busy actor keeps its old template. The Job fails so the drift is visible in Argo CD.
# A retry or a later sync moves the actor once it is suspended.
if [ "${#BUSY[@]}" -gt 0 ]; then
  log "FAILED: busy actors were not moved to their new template: ${BUSY[*]}. Suspend them, or wait until they suspend, and sync again."
  exit 1
fi
log "Registration done."
