#!/usr/bin/env bash
# Proves that agents can reach Fleet: completes the first-run setup if needed,
# then enrols a throwaway osquery container over TLS and waits for it to show
# up as a host. The agent runs outside the cluster, like a real endpoint would.
set -euo pipefail

FLEET_URL="${FLEET_URL:-https://localhost:8443}"
CA_FILE="${CA_FILE:-fleet-ca.crt}"
AGENT_NAME="${AGENT_NAME:-fleet-test-agent}"
OSQUERY_IMAGE="${OSQUERY_IMAGE:-osquery/osquery:5.17.0-ubuntu24.04}"
CREDS_FILE="$(dirname "$0")/.admin.env"

api() { curl -fsS --cacert "$CA_FILE" -H 'Content-Type: application/json' "$@"; }

if [ -f "$CREDS_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CREDS_FILE"
else
  ADMIN_EMAIL=admin@example.com
  ADMIN_PASSWORD="$(openssl rand -hex 12)#1a"
  api -X POST "$FLEET_URL/api/v1/setup" -o /dev/null -d "$(jq -n \
    --arg email "$ADMIN_EMAIL" --arg password "$ADMIN_PASSWORD" --arg url "$FLEET_URL" \
    '{admin: {admin: true, email: $email, name: "Admin", password: $password},
      org_info: {org_name: "Local"}, server_url: $url}')"
  (umask 077; printf 'ADMIN_EMAIL=%s\nADMIN_PASSWORD=%s\n' "$ADMIN_EMAIL" "$ADMIN_PASSWORD" > "$CREDS_FILE")
  echo "Fleet set up; admin credentials saved to $CREDS_FILE"
fi

token=$(api -X POST "$FLEET_URL/api/v1/fleet/login" \
  -d "$(jq -n --arg email "$ADMIN_EMAIL" --arg password "$ADMIN_PASSWORD" '{email: $email, password: $password}')" | jq -r .token)
auth=(-H "Authorization: Bearer $token")
secret=$(api "${auth[@]}" "$FLEET_URL/api/v1/fleet/spec/enroll_secret" | jq -r '.spec.secrets[0].secret')

# From inside a container the host's published port is host.docker.internal.
port="${FLEET_URL##*:}"
docker rm -f "$AGENT_NAME" >/dev/null 2>&1 || true
docker run -d --name "$AGENT_NAME" --hostname "$AGENT_NAME" --platform linux/amd64 \
  --add-host host.docker.internal:host-gateway \
  -e ENROLL_SECRET="$secret" -v "$(cd "$(dirname "$CA_FILE")" && pwd)/$(basename "$CA_FILE"):/fleet-ca.crt:ro" \
  "$OSQUERY_IMAGE" osqueryd \
  --tls_hostname="host.docker.internal:$port" --tls_server_certs=/fleet-ca.crt \
  --host_identifier=hostname --enroll_secret_env=ENROLL_SECRET \
  --enroll_tls_endpoint=/api/v1/osquery/enroll \
  --config_plugin=tls --config_tls_endpoint=/api/v1/osquery/config --config_refresh=10 \
  --logger_plugin=tls --logger_tls_endpoint=/api/v1/osquery/log \
  --disable_distributed=false --distributed_plugin=tls --distributed_interval=10 \
  --distributed_tls_read_endpoint=/api/v1/osquery/distributed/read \
  --distributed_tls_write_endpoint=/api/v1/osquery/distributed/write >/dev/null

echo "Waiting for $AGENT_NAME to enrol..."
for _ in $(seq 1 30); do
  if api "${auth[@]}" "$FLEET_URL/api/v1/fleet/hosts" | jq -e --arg h "$AGENT_NAME" '.hosts[] | select(.hostname == $h or .computer_name == $h or .osquery_host_id == $h)' >/dev/null; then
    api "${auth[@]}" "$FLEET_URL/api/v1/fleet/hosts" | jq -r '.hosts[] | "enrolled: \(.hostname) (\(.os_version), osquery \(.osquery_version), status \(.status))"'
    exit 0
  fi
  sleep 5
done
echo "Agent did not enrol; see: docker logs $AGENT_NAME" >&2
exit 1
