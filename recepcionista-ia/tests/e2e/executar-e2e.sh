#!/usr/bin/env bash
# Executa TODA a bateria ponta a ponta localmente: prepara ambiente, sobe mock + n8n,
# roda os cenários e encerra os processos.
# Requisitos: PostgreSQL acessível (PGHOST/PGPORT/PGUSER), n8n instalado (N8N_BIN; o n8n 2.x exige Node 24).
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${N8N_BIN:?defina N8N_BIN}"
export E2E_DIR="${E2E_DIR:-$(mktemp -d)}"
tests/e2e/preparar-ambiente.sh
node tests/mocks/servidor-mock.mjs > "$E2E_DIR/mock.log" 2>&1 & MOCK_PID=$!
N8N_USER_FOLDER="$E2E_DIR/n8n" N8N_ENCRYPTION_KEY=chave-de-teste-e2e DB_TYPE=sqlite N8N_PORT=5678 N8N_LISTEN_ADDRESS=127.0.0.1 \
  N8N_DIAGNOSTICS_ENABLED=false N8N_SECURE_COOKIE=false "$N8N_BIN" start > "$E2E_DIR/n8n.log" 2>&1 & N8N_PID=$!
trap 'kill $MOCK_PID $N8N_PID 2>/dev/null || true; pkill -f "^n8n task-runner" 2>/dev/null || true' EXIT
for i in $(seq 1 90); do grep -aq "Finished building workflow dependency" "$E2E_DIR/n8n.log" && break; sleep 2; done
sleep 2
node tests/e2e/rodar-e2e.mjs
