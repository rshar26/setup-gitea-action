#!/usr/bin/env bash
set -Eeuo pipefail

: "${JUJU_MODEL:?JUJU_MODEL is required}"
: "${GIT_INTEGRATOR_CHANNEL:?GIT_INTEGRATOR_CHANNEL is required}"
: "${REPOSITORY_URL:?REPOSITORY_URL is required}"
: "${TRACKING_REF:?TRACKING_REF is required}"
: "${REPOSITORY_PATH:?REPOSITORY_PATH is required}"
: "${GITEA_USERNAME:?GITEA_USERNAME is required}"
: "${GITEA_TOKEN:?GITEA_TOKEN is required}"

log() { printf '[deploy-git-integrator] %s\n' "$*"; }

command -v juju >/dev/null 2>&1 || { echo 'juju CLI is not available' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo 'openssl is not available' >&2; exit 1; }

APP_NAME='git-integrator'
SECRET_NAME="git-integrator-gitea-${GITHUB_RUN_ID:-local}"

log 'Creating Juju model...'
if ! juju models --format=json | jq -e --arg model "$JUJU_MODEL" '.models[]? | select(.name == $model)' >/dev/null; then
  juju add-model "$JUJU_MODEL" microk8s
fi
juju switch "$JUJU_MODEL"

log "Deploying git-integrator from channel $GIT_INTEGRATOR_CHANNEL..."
if ! juju status --format=json | jq -e --arg app "$APP_NAME" '.applications[$app]' >/dev/null; then
  juju deploy git-integrator --channel="$GIT_INTEGRATOR_CHANNEL"
fi

log 'Creating and granting the Juju secret...'
SECRET_URI="$(juju add-secret "$SECRET_NAME" credentials-personal-access-token="$GITEA_TOKEN" | tail -n1 | tr -d '\r')"
if [[ "$SECRET_URI" != secret:* ]]; then
  # Juju versions can print informational text around the URI. Find the URI
  # without ever printing the token value.
  SECRET_URI="$(juju secrets --format=json | jq -r --arg name "$SECRET_NAME" '.[] | select(.name == $name) | .uri' | head -n1)"
fi
[[ "$SECRET_URI" == secret:* ]] || { echo 'Could not determine the URI of the newly created Juju secret.' >&2; exit 1; }
juju grant-secret "$SECRET_NAME" "$APP_NAME"

log 'Configuring git-integrator...'
juju config "$APP_NAME" \
  authentication_method=personal-access-token \
  credentials_username="$GITEA_USERNAME" \
  credentials_personal_access_token_secret="$SECRET_URI" \
  repository_url="$REPOSITORY_URL" \
  tracking_ref="$TRACKING_REF" \
  path="$REPOSITORY_PATH"

log 'Waiting for git-integrator to become active...'
juju wait-for application "$APP_NAME" \
  --query='forEach(units, unit => unit.workload-status == "active")' \
  --timeout=20m0s

{
  echo "git-integrator-app=$APP_NAME"
  echo "juju-model=$JUJU_MODEL"
} >> "$GITHUB_OUTPUT"

log 'git-integrator is active and configured.'
