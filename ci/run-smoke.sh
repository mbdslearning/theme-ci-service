#!/usr/bin/env bash
set -euo pipefail

THEME_ROOT="${1:?theme_root required}"
THEME_SLUG="${2:?theme_slug required}"
WORKDIR="${3:?workdir required}"

LOG_DIR="${WORKDIR}/logs"
mkdir -p "${LOG_DIR}"

SMOKE_LOG="${LOG_DIR}/smoke.log"
REPORT_MD="${WORKDIR}/report.md"

# Choose actual theme directory to mount
if [[ -d "${THEME_ROOT}/${THEME_SLUG}" ]]; then
  THEME_SRC="$(cd "${THEME_ROOT}/${THEME_SLUG}" && pwd)"
else
  THEME_SRC="$(cd "${THEME_ROOT}" && pwd)"
fi

WP_PORT="8089"

# Compose env for substitution
cat > "${WORKDIR}/.smoke.env" <<EOF
THEME_SRC=${THEME_SRC}
THEME_SLUG=${THEME_SLUG}
WP_PORT=${WP_PORT}
EOF

echo "" >> "${REPORT_MD}"
echo "## Smoke test" >> "${REPORT_MD}"
echo "- Using docker compose with WordPress + MySQL + WP-CLI" >> "${REPORT_MD}"
echo "- WP port: ${WP_PORT}" >> "${REPORT_MD}"
echo "- Theme mount: ${THEME_SRC} -> wp-content/themes/${THEME_SLUG}" >> "${REPORT_MD}"

# Start stack
echo "== Starting WP stack ==" | tee "${SMOKE_LOG}"
docker compose \
  --env-file "${WORKDIR}/.smoke.env" \
  -f ci/docker-compose.smoke.yml \
  up -d --quiet-pull >> "${SMOKE_LOG}" 2>&1

cleanup() {
  docker compose \
    --env-file "${WORKDIR}/.smoke.env" \
    -f ci/docker-compose.smoke.yml \
    down -v >> "${SMOKE_LOG}" 2>&1 || true
}
trap cleanup EXIT

# Wait for WP HTTP
echo "== Waiting for WordPress HTTP ==" | tee -a "${SMOKE_LOG}"
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:${WP_PORT}" >/dev/null 2>>"${SMOKE_LOG}"; then
    break
  fi
  sleep 2
done

# WP install (idempotent) + theme activation
echo "== WP-CLI install + activate theme ==" | tee -a "${SMOKE_LOG}"
docker compose \
  --env-file "${WORKDIR}/.smoke.env" \
  -f ci/docker-compose.smoke.yml \
  run --rm cli \
  "wp core is-installed || wp core install --url=http://localhost:${WP_PORT} --title=CI --admin_user=admin --admin_password=admin --admin_email=admin@example.com" \
  >> "${SMOKE_LOG}" 2>&1

docker compose \
  --env-file "${WORKDIR}/.smoke.env" \
  -f ci/docker-compose.smoke.yml \
  run --rm cli \
  "wp theme activate ${THEME_SLUG}" \
  >> "${SMOKE_LOG}" 2>&1

# Hit routes (basic)
echo "== Hitting routes ==" | tee -a "${SMOKE_LOG}"
curl -fsS "http://localhost:${WP_PORT}/" >> "${SMOKE_LOG}" 2>&1
curl -fsS "http://localhost:${WP_PORT}/?p=999999" >> "${SMOKE_LOG}" 2>&1 || true

echo "- ✅ Smoke test PASS" >> "${REPORT_MD}"
echo "- Logs: \`logs/smoke.log\`" >> "${REPORT_MD}"
