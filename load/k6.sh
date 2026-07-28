#!/usr/bin/env bash

set -euo pipefail

export BASE_URL="${BASE_URL:-http://localhost:4000}"
export LOW_VUS="${LOW_VUS:-10}"
export MEDIUM_VUS="${MEDIUM_VUS:-70}"
export PEAK_VUS="${PEAK_VUS:-150}"

echo "==> [k6 Test] Target URL: ${BASE_URL}"
echo "==> [k6 Test] Configured VUs -> LOW: ${LOW_VUS}, MEDIUM: ${MEDIUM_VUS}, PEAK: ${PEAK_VUS}"

exec k6 run load/k6/local_whatsapp.js
