#!/usr/bin/env bash
# Prepara um ambiente de teste ponta a ponta LOCAL (sem credenciais reais):
#  - banco PostgreSQL descartável com schema + seed demo, apontando as APIs para o servidor mock
#  - n8n (SQLite próprio) com credenciais FALSAS, todos os workflows importados e publicados
# Variáveis: PGHOST PGPORT PGUSER (Postgres), N8N_BIN (binário do n8n), E2E_DIR (pasta de trabalho), MOCK_PORT
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${N8N_BIN:?defina N8N_BIN com o caminho do executável n8n}"
E2E_DIR="${E2E_DIR:-$(mktemp -d)}"
MOCK_PORT="${MOCK_PORT:-18080}"
DB="${E2E_DB:-ria_e2e}"
PSQL="psql -v ON_ERROR_STOP=1 -q"
mkdir -p "$E2E_DIR/n8n" "$E2E_DIR/wf"

echo "==> Banco $DB"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null
$PSQL -d "$DB" -f database/schema.sql >/dev/null 2>&1
$PSQL -d "$DB" -f database/seed-demo.sql >/dev/null
$PSQL -d "$DB" <<SQL >/dev/null
UPDATE ria.app_settings SET value = to_jsonb('http://127.0.0.1:$MOCK_PORT'::text) WHERE key = 'graph_api_base';
UPDATE ria.app_settings SET value = to_jsonb('http://127.0.0.1:$MOCK_PORT/v1'::text) WHERE key = 'openai_base';
UPDATE ria.app_settings SET value = to_jsonb('http://127.0.0.1:$MOCK_PORT/calendar/v3'::text) WHERE key = 'google_calendar_base';
SQL

echo "==> Credenciais de TESTE (valores falsos)"
cat > "$E2E_DIR/credenciais-teste.json" <<JSON
[
 {"id":"RiaCredPostgres1","name":"Recepcionista IA - PostgreSQL","type":"postgres","data":{"host":"${PGHOST_TCP:-127.0.0.1}","port":${PGPORT:-5432},"database":"$DB","user":"${PGUSER:-postgres}","password":"${PGPASSWORD:-x}","ssl":"disable"}},
 {"id":"RiaCredWhatsApp1","name":"Recepcionista IA - WhatsApp Cloud API","type":"whatsAppApi","data":{"accessToken":"token-falso-de-teste","businessAccountId":"200000000000001"}},
 {"id":"RiaCredWppTrigg1","name":"Recepcionista IA - WhatsApp Webhook (App Meta)","type":"whatsAppTriggerApi","data":{"clientId":"123","clientSecret":"segredo-falso"}},
 {"id":"RiaCredOpenAI001","name":"Recepcionista IA - OpenAI","type":"openAiApi","data":{"apiKey":"chave-falsa-de-teste","url":"http://127.0.0.1:$MOCK_PORT/v1"}},
 {"id":"RiaCredGoogleCal","name":"Recepcionista IA - Google Calendar","type":"googleCalendarOAuth2Api","data":{"clientId":"x","clientSecret":"y","oauthTokenData":{"access_token":"token-google-falso","token_type":"Bearer","expires_in":3599,"refresh_token":"r"}}},
 {"id":"RiaCredAgendaExt","name":"Recepcionista IA - API Agenda Externa","type":"httpHeaderAuth","data":{"name":"Authorization","value":"Bearer falso"}},
 {"id":"RiaCredAdminApi1","name":"Recepcionista IA - API Administrativa","type":"httpHeaderAuth","data":{"name":"X-Admin-Token","value":"admin-teste"}}
]
JSON

echo "==> Workflows"
node scripts/build-workflows.mjs >/dev/null
for f in workflows/*.json; do
  case "$f" in *01-whatsapp-recepcao.json) ;; *) cp "$f" "$E2E_DIR/wf/";; esac
done
cp tests/e2e/workflows/*.json "$E2E_DIR/wf/"

export N8N_USER_FOLDER="$E2E_DIR/n8n" N8N_ENCRYPTION_KEY="chave-de-teste-e2e" DB_TYPE=sqlite \
       N8N_DIAGNOSTICS_ENABLED=false N8N_PERSONALIZATION_ENABLED=false N8N_LOG_LEVEL=warn
"$N8N_BIN" import:credentials --input="$E2E_DIR/credenciais-teste.json" >/dev/null
"$N8N_BIN" import:workflow --separate --input="$E2E_DIR/wf" >/dev/null
# Ordem: sub-workflows antes de quem os chama (exigência do n8n 2.x)
for id in RiaWf00EnviarWpp RiaWf08AdaptAgen RiaWf06Monitoram RiaWf05Humano000 RiaWf02Agendamen RiaWf03Remarcaca RiaWf04Lembretes RiaWf07Reconcili RiaWf01RecepTest RiaWf99GatilhoTs; do
  "$N8N_BIN" publish:workflow --id="$id" >/dev/null
done
echo "E2E_DIR=$E2E_DIR"
echo "Pronto. Inicie: node tests/mocks/servidor-mock.mjs  e  N8N_USER_FOLDER=$E2E_DIR/n8n N8N_ENCRYPTION_KEY=chave-de-teste-e2e $N8N_BIN start"
