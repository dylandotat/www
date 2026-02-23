#!/usr/bin/env bash
set -euo pipefail

APP_SERVICE_NAME=""
POSTGRES_SERVICE_NAME="Postgres"
VAR_NAME="DATABASE_URL"
CREATE_DB=true
ENABLE_PR_DEPLOYS=true
ENABLE_BOT_PR_ENVS=false
TIMEOUT_SECONDS=120

usage() {
  cat <<'USAGE'
Usage:
  scripts/railway-bootstrap-postgres.sh --app-service <service-name> [options]

What it does:
  1) Ensures a Postgres service exists in the linked Railway project/environment
  2) Wires your app variable to Railway reference syntax:
     VAR_NAME=${{Postgres.DATABASE_URL}}
  3) Enables project PR deploys via Railway GraphQL API

Required:
  --app-service <name>          App service to receive the variable

Options:
  --postgres-service <name>     Postgres service name (default: Postgres)
  --var-name <name>             Variable key to set (default: DATABASE_URL)
  --no-create-db                Fail if Postgres does not already exist
  --no-enable-pr-deploys        Skip project PR deploy update
  --enable-bot-pr-envs          Also enable bot PR environments
  --timeout-seconds <n>         Wait timeout for DB creation (default: 120)
  -h, --help                    Show help

Prereqs:
  - railway CLI logged in and linked to a project/environment
  - jq installed
USAGE
}

log() {
  printf '[railway-bootstrap] %s\n' "$*"
}

die() {
  printf '[railway-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-service)
      APP_SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --postgres-service)
      POSTGRES_SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --var-name)
      VAR_NAME="${2:-}"
      shift 2
      ;;
    --no-create-db)
      CREATE_DB=false
      shift
      ;;
    --no-enable-pr-deploys)
      ENABLE_PR_DEPLOYS=false
      shift
      ;;
    --enable-bot-pr-envs)
      ENABLE_BOT_PR_ENVS=true
      shift
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$APP_SERVICE_NAME" ]] || die "--app-service is required"

require_cmd railway
require_cmd jq
require_cmd curl

STATUS_JSON=""
CONFIG_JSON=""
PROJECT_ID=""
APP_SERVICE_ID=""

refresh_state() {
  STATUS_JSON="$(railway status --json 2>/dev/null || true)"
  [[ -n "$STATUS_JSON" ]] || die "Could not read railway status. Run: railway login && railway link"

  PROJECT_ID="$(jq -r '.project.id // .id // empty' <<<"$STATUS_JSON")"
  [[ -n "$PROJECT_ID" ]] || die "Could not determine project ID from railway status --json"

  CONFIG_JSON="$(railway environment config --json 2>/dev/null || true)"
  [[ -n "$CONFIG_JSON" ]] || die "Could not read environment config. Ensure Railway CLI >= 4.27.3"
}

service_exists_by_name() {
  local name="$1"
  jq -e --arg name "$name" '
    def service_nodes:
      if (.project.services | type) == "array" then .project.services
      elif (.services | type) == "array" then .services
      elif (.services.edges | type) == "array" then .services.edges | map(.node)
      elif (.project.services.edges | type) == "array" then .project.services.edges | map(.node)
      else [] end;
    service_nodes | map(.name) | index($name) != null
  ' <<<"$STATUS_JSON" >/dev/null
}

get_service_name_by_id() {
  local sid="$1"
  jq -r --arg sid "$sid" '
    def service_nodes:
      if (.project.services | type) == "array" then .project.services
      elif (.services | type) == "array" then .services
      elif (.services.edges | type) == "array" then .services.edges | map(.node)
      elif (.project.services.edges | type) == "array" then .project.services.edges | map(.node)
      else [] end;
    service_nodes | map(select(.id == $sid)) | .[0].name // empty
  ' <<<"$STATUS_JSON"
}

get_service_id_by_name() {
  local name="$1"
  jq -r --arg name "$name" '
    def service_nodes:
      if (.project.services | type) == "array" then .project.services
      elif (.services | type) == "array" then .services
      elif (.services.edges | type) == "array" then .services.edges | map(.node)
      elif (.project.services.edges | type) == "array" then .project.services.edges | map(.node)
      else [] end;
    service_nodes | map(select(.name == $name)) | .[0].id // empty
  ' <<<"$STATUS_JSON"
}

find_postgres_service_name() {
  local by_name=""
  local by_image_id=""
  local by_image_name=""

  if service_exists_by_name "$POSTGRES_SERVICE_NAME"; then
    echo "$POSTGRES_SERVICE_NAME"
    return 0
  fi

  by_image_id="$(jq -r '
    .services
    | to_entries
    | map(select((.value.source.image // "") | test("(^|/)(postgres)(:|$)|ghcr\\.io/railway/postgres"; "i")))
    | .[0].key // empty
  ' <<<"$CONFIG_JSON")"

  if [[ -n "$by_image_id" ]]; then
    by_image_name="$(get_service_name_by_id "$by_image_id")"
    if [[ -n "$by_image_name" ]]; then
      echo "$by_image_name"
      return 0
    fi
  fi

  echo ""
}

create_postgres_if_needed() {
  local detected_name="$1"

  if [[ -n "$detected_name" ]]; then
    log "Postgres service found: $detected_name"
    POSTGRES_SERVICE_NAME="$detected_name"
    return 0
  fi

  if [[ "$CREATE_DB" != true ]]; then
    die "No Postgres service found and --no-create-db was set"
  fi

  log "No Postgres service found. Creating one with name: $POSTGRES_SERVICE_NAME"
  if ! railway add --database postgres --service "$POSTGRES_SERVICE_NAME" --json >/dev/null 2>&1; then
    log "Creation with explicit service name failed; retrying with Railway-generated name"
    railway add --database postgres --json >/dev/null
  fi

  local elapsed=0
  local sleep_step=3
  while (( elapsed < TIMEOUT_SECONDS )); do
    refresh_state
    local found
    found="$(find_postgres_service_name)"
    if [[ -n "$found" ]]; then
      POSTGRES_SERVICE_NAME="$found"
      log "Postgres service is available: $POSTGRES_SERVICE_NAME"
      return 0
    fi
    sleep "$sleep_step"
    elapsed=$((elapsed + sleep_step))
  done

  die "Timed out waiting for Postgres service creation"
}

assert_app_service_exists() {
  if ! service_exists_by_name "$APP_SERVICE_NAME"; then
    die "App service '$APP_SERVICE_NAME' not found in linked project"
  fi
  APP_SERVICE_ID="$(get_service_id_by_name "$APP_SERVICE_NAME")"
  [[ -n "$APP_SERVICE_ID" ]] || die "Could not resolve service ID for '$APP_SERVICE_NAME'"
}

wire_database_url() {
  local ref="\${{${POSTGRES_SERVICE_NAME}.DATABASE_URL}}"
  log "Wiring $APP_SERVICE_NAME:$VAR_NAME -> $ref"
  railway variable set \
    --service "$APP_SERVICE_ID" \
    "${VAR_NAME}=${ref}" \
    --json >/dev/null

  refresh_state
  local current
  current="$(jq -r --arg sid "$APP_SERVICE_ID" --arg k "$VAR_NAME" '.services[$sid].variables[$k].value // empty' <<<"$CONFIG_JSON")"
  if [[ "$current" != "$ref" ]]; then
    die "Variable verification failed. Expected $VAR_NAME=$ref on service $APP_SERVICE_NAME"
  fi
}

railway_graphql() {
  local query="$1"
  local variables_json="${2:-}"
  local config_file="$HOME/.railway/config.json"

  [[ -f "$config_file" ]] || return 2

  local token
  token="$(jq -r '.user.token // empty' "$config_file")"
  [[ -n "$token" ]] || return 2

  local payload
  if [[ -n "$variables_json" ]]; then
    payload="$(jq -n --arg q "$query" --argjson v "$variables_json" '{query: $q, variables: $v}')"
  else
    payload="$(jq -n --arg q "$query" '{query: $q}')"
  fi

  curl -fsS https://backboard.railway.com/graphql/v2 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

enable_pr_deploys() {
  if [[ "$ENABLE_PR_DEPLOYS" != true ]]; then
    log "Skipping PR deploy enable step"
    return 0
  fi

  local input_json
  if [[ "$ENABLE_BOT_PR_ENVS" == true ]]; then
    input_json='{"prDeploys":true,"botPrEnvironments":true}'
  else
    input_json='{"prDeploys":true}'
  fi

  local vars
  vars="$(jq -n --arg id "$PROJECT_ID" --argjson input "$input_json" '{id: $id, input: $input}')"

  local resp
  if ! resp="$(railway_graphql 'mutation updateProject($id: String!, $input: ProjectUpdateInput!) { projectUpdate(id: $id, input: $input) { name prDeploys botPrEnvironments } }' "$vars")"; then
    log "Could not enable PR deploys automatically (missing token or API error)."
    log "Manual fallback: set prDeploys=true in Railway project settings."
    return 0
  fi

  if jq -e '.errors and (.errors | length > 0)' >/dev/null <<<"$resp"; then
    log "PR deploy update returned errors. Response: $(jq -c '.errors' <<<"$resp")"
    log "Manual fallback: set prDeploys=true in Railway project settings."
    return 0
  fi

  local enabled
  enabled="$(jq -r '.data.projectUpdate.prDeploys // empty' <<<"$resp")"
  if [[ "$enabled" == "true" ]]; then
    log "PR deploys enabled on project"
  else
    log "PR deploy enable request did not confirm enabled state"
  fi
}

refresh_state
assert_app_service_exists
create_postgres_if_needed "$(find_postgres_service_name)"
wire_database_url
enable_pr_deploys

log "Done. $APP_SERVICE_NAME now uses \${{${POSTGRES_SERVICE_NAME}.DATABASE_URL}} via $VAR_NAME"
