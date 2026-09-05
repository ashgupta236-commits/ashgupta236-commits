#!/usr/bin/env bash
#
# Start the Docker daemon for this session.
#
# Why a SessionStart hook rather than a cloud-environment setup script:
# a setup script runs only when no environment cache exists, and the cache is a
# filesystem snapshot. It preserves installed files and pulled images, but not
# running processes. A daemon therefore has to be started once per session.
# See https://code.claude.com/docs/en/cloud-environments#environment-caching
#
# This script always exits 0. A SessionStart hook that fails must never stop a
# session from starting, and a machine without Docker is a normal case, not an
# error.

set -uo pipefail

LOG="${DOCKER_START_LOG:-/tmp/start-docker.log}"
TIMEOUT_SECS="${DOCKER_START_TIMEOUT_SECS:-30}"

log() { printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$LOG" 2>/dev/null || true; }

# Nothing to start where Docker is not installed, e.g. a local checkout.
if ! command -v dockerd >/dev/null 2>&1; then
  log "dockerd not installed; skipping"
  exit 0
fi

# Idempotent: a daemon that is already answering needs no second one.
if docker info >/dev/null 2>&1; then
  log "docker already running; nothing to do"
  exit 0
fi

# Binding /var/run/docker.sock needs root.
if [ "$(id -u)" -ne 0 ]; then
  log "not root; cannot start dockerd"
  exit 0
fi

log "starting dockerd"
nohup dockerd >>"$LOG" 2>&1 &

# Poll for readiness rather than sleeping a fixed amount. Observed cold start on
# a 4 vCPU cloud VM is well under a second, but the box may be busy at startup.
deadline=$(( $(date +%s) + TIMEOUT_SECS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if docker info >/dev/null 2>&1; then
    log "dockerd ready"
    exit 0
  fi
  sleep 0.5
done

log "dockerd did not become ready within ${TIMEOUT_SECS}s; see $LOG"
exit 0
