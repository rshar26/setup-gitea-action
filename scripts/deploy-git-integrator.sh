#!/usr/bin/env bash
set -euo pipefail

: "${JUJU_MODEL:?JUJU_MODEL is required}"
: "${GIT_INTEGRATOR_CHANNEL:?GIT_INTEGRATOR_CHANNEL is required}"
: "${REPOSITORY_URL:?REPOSITORY_URL is required}"
: "${TRACKING_REF:?TRACKING_REF is required}"
: "${REPOSITORY_PATH:?REPOSITORY_PATH is required}"
: "${GITEA_USERNAME:?GITEA_USERNAME is required}"
: "${GITEA_TOKEN:?GITEA_TOKEN is required}"

APP_NAME="git-integrator"
SECRET_NAME="git-integrator-credentials"

echo "=== Deploying ${APP_NAME} ==="
if ! juju status "${APP_NAME}" --model="${JUJU_MODEL}" >/dev/null 2>&1; then
    juju deploy \
        "${APP_NAME}" \
        --channel="${GIT_INTEGRATOR_CHANNEL}" \
        --model="${JUJU_MODEL}"
fi

echo "=== Creating Juju secret ==="
SECRET_URI="$(
    juju add-secret \
        --model="${JUJU_MODEL}" \
        "${SECRET_NAME}" \
        "credentials-personal-access-token=${GITEA_TOKEN}" \
        | awk '/^secret:/ {print $1}'
)"

if [[ -z "${SECRET_URI}" ]]; then
    echo "::error::Failed to create Juju secret."
    exit 1
fi

echo "=== Granting Juju secret ==="
juju grant-secret \
    --model="${JUJU_MODEL}" \
    "${SECRET_URI}" \
    "${APP_NAME}"

echo "=== Configuring ${APP_NAME} ==="
juju config \
    --model="${JUJU_MODEL}" \
    "${APP_NAME}" \
    authentication_method="personal-access-token" \
    credentials_personal_access_token_secret="${SECRET_URI}" \
    credentials_username="${GITEA_USERNAME}" \
    repository_url="${REPOSITORY_URL}" \
    path="${REPOSITORY_PATH}" \
    tracking_ref="${TRACKING_REF}"

echo "=== Waiting for ${APP_NAME} ==="
juju wait-for application \
    "${APP_NAME}" \
    --model="${JUJU_MODEL}" \
    --timeout=10m

echo "git-integrator is ready."

echo "git-integrator-app=${APP_NAME}" >> "${GITHUB_OUTPUT}"
