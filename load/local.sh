#!/usr/bin/env bash

set -euo pipefail

export WAJADI_LOAD_TEST="${WAJADI_LOAD_TEST:-true}"
export PHX_SERVER="${PHX_SERVER:-true}"
export PORT="${PORT:-4000}"

echo "==> [Load Test] Preparing database..."
mix ecto.create --quiet || true
mix ecto.migrate --quiet

echo "==> [Load Test] Starting Phoenix server on port ${PORT}..."
exec mix phx.server
