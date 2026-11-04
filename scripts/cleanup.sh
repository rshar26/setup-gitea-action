#!/usr/bin/env bash
set -Eeuo pipefail

KUBECTL=(kubectl)
if command -v microk8s >/dev/null 2>&1; then
  KUBECTL=(microk8s kubectl)
fi

if [[ -f "${RUNNER_TEMP:-/tmp}/gitea-port-forward.pid" ]]; then
  kill "$(cat "${RUNNER_TEMP:-/tmp}/gitea-port-forward.pid")" 2>/dev/null || true
fi

if command -v juju >/dev/null 2>&1 && [[ -n "${JUJU_MODEL:-}" ]]; then
  juju destroy-model "$JUJU_MODEL" --destroy-storage --force --no-prompt || true
fi

"${KUBECTL[@]}" delete namespace gitea --ignore-not-found=true --wait=false || true
