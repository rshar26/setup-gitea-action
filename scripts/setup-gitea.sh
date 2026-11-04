#!/usr/bin/env bash
set -Eeuo pipefail

: "${REPOSITORY_NAME:?REPOSITORY_NAME is required}"
: "${TRACKING_REF:?TRACKING_REF is required}"
: "${GITEA_IMAGE:?GITEA_IMAGE is required}"

log() { printf '[setup-gitea] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

if command -v microk8s >/dev/null 2>&1; then
  KUBECTL=(microk8s kubectl)
elif command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
else
  fail 'Neither microk8s nor kubectl is available. Check the operator environment setup.'
fi

for command in curl git jq openssl; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done

# The manifest is rendered here rather than relying on shell expansion in YAML.
TMP_MANIFEST="${RUNNER_TEMP:-/tmp}/gitea-${GITHUB_RUN_ID:-local}.yaml"
sed "s|\${GITEA_IMAGE}|${GITEA_IMAGE}|g" "$GITHUB_ACTION_PATH/resources/gitea.yaml" > "$TMP_MANIFEST"
"${KUBECTL[@]}" apply -f "$TMP_MANIFEST"
log 'Waiting for Gitea deployment to become ready...'
"${KUBECTL[@]}" -n gitea rollout status deployment/gitea --timeout=5m

GITEA_USERNAME='git-integrator-ci'
GITEA_ADMIN_PASSWORD="$(openssl rand -hex 24)"
echo "::add-mask::$GITEA_ADMIN_PASSWORD"
GITEA_TOKEN_NAME="git-integrator-${GITHUB_RUN_ID:-local}"

# Forward the in-cluster service to the runner so the setup script can use its API.
PORT_FORWARD_LOG="${RUNNER_TEMP:-/tmp}/gitea-port-forward.log"
"${KUBECTL[@]}" -n gitea port-forward service/gitea 3000:3000 --address 127.0.0.1 >"$PORT_FORWARD_LOG" 2>&1 &
PORT_FORWARD_PID=$!
printf '%s\n' "$PORT_FORWARD_PID" > "${RUNNER_TEMP:-/tmp}/gitea-port-forward.pid"

cleanup_on_error() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
}
trap cleanup_on_error ERR

GITEA_LOCAL_URL='http://127.0.0.1:3000'
for _ in $(seq 1 60); do
  if curl --silent --fail "$GITEA_LOCAL_URL/" >/dev/null; then
    break
  fi
  sleep 2
done
curl --silent --fail "$GITEA_LOCAL_URL/" >/dev/null || fail "Gitea did not become reachable. Port-forward log: $PORT_FORWARD_LOG"

log 'Creating temporary Gitea administrator...'
"${KUBECTL[@]}" -n gitea exec deployment/gitea -- \
  gitea admin user create \
  --username "$GITEA_USERNAME" \
  --password "$GITEA_ADMIN_PASSWORD" \
  --email 'git-integrator-ci@example.invalid' \
  --admin \
  --must-change-password=false

log 'Creating a scoped Gitea access token...'
TOKEN_RESPONSE="$(curl --silent --show-error --fail \
  --user "$GITEA_USERNAME:$GITEA_ADMIN_PASSWORD" \
  --header 'Content-Type: application/json' \
  --data "$(jq -n --arg name "$GITEA_TOKEN_NAME" '{name:$name, scopes:["write:repository","read:user"]}')" \
  "$GITEA_LOCAL_URL/api/v1/users/$GITEA_USERNAME/tokens")"
GITEA_TOKEN="$(jq -er '.sha1' <<<"$TOKEN_RESPONSE")"

log "Creating repository '$REPOSITORY_NAME'..."
curl --silent --show-error --fail \
  --header "Authorization: token $GITEA_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "$(jq -n --arg name "$REPOSITORY_NAME" '{name:$name, private:true, auto_init:false}')" \
  "$GITEA_LOCAL_URL/api/v1/user/repos" >/dev/null

log 'Creating and pushing sample repository content...'
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"; cleanup_on_error' EXIT
(
  cd "$WORK_DIR"
  git init --initial-branch="$TRACKING_REF"
  git config user.name 'Git integration test'
  git config user.email 'git-integrator-ci@example.invalid'
  cat > README.md <<'README'
# Git integration test repository

This repository is created automatically by setup-git-action.
It is used to verify that git-integrator can access a Git repository
and propagate its configuration through a Juju relation.
README
  mkdir -p test-data
  printf 'Repository seeded by GitHub Actions run %s\n' "${GITHUB_RUN_ID:-local}" > test-data/sample.txt
  git add README.md test-data/sample.txt
  git commit -m 'Add sample content for charm integration test'
  AUTH_HEADER="$(printf '%s' "$GITEA_USERNAME:$GITEA_TOKEN" | base64 -w0)"
  GIT_TERMINAL_PROMPT=0 git -c "http.extraheader=Authorization: Basic $AUTH_HEADER" \
    push "http://127.0.0.1:3000/$GITEA_USERNAME/$REPOSITORY_NAME.git" "$TRACKING_REF"
)

# The URL below is intentionally the Kubernetes service DNS name: it is the
# address git-integrator uses from inside the same Kubernetes cluster.
REPOSITORY_URL="http://gitea.gitea.svc.cluster.local:3000/$GITEA_USERNAME/$REPOSITORY_NAME.git"
{
  echo "repository-url=$REPOSITORY_URL"
  echo "repository-name=$REPOSITORY_NAME"
  echo "tracking-ref=$TRACKING_REF"
  echo "gitea-username=$GITEA_USERNAME"
} >> "$GITHUB_OUTPUT"

# Keep the token in the runner environment for subsequent composite steps; do not
# expose it as a public action output. Register it with GitHub log masking first.
echo "::add-mask::$GITEA_TOKEN"
echo "GITEA_TOKEN=$GITEA_TOKEN" >> "$GITHUB_ENV"
log 'Gitea is ready and the sample repository has been pushed.'
