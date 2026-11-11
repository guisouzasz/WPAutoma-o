#!/usr/bin/env bash
# Teste de concorrência: N pacientes confirmam o MESMO horário ao mesmo tempo,
# cada um em uma conexão PostgreSQL diferente (como execuções paralelas do n8n).
# Esperado: exatamente 1 reserva 'held' e N-1 'slot_taken'.
# Uso: PGHOST=... PGPORT=... PGUSER=... tests/testes-de-concorrencia/corrida-mesmo-horario.sh [N]
set -euo pipefail
cd "$(dirname "$0")/../.."
N="${1:-20}"
DB="ria_conc_$$"
PSQL="psql -v ON_ERROR_STOP=1 -qAt"
WORK="$(mktemp -d)"
$PSQL -d postgres -c "CREATE DATABASE $DB" >/dev/null
trap '$PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
$PSQL -d "$DB" -f database/schema.sql >/dev/null 2>&1
$PSQL -d "$DB" -f database/seed-demo.sql >/dev/null

NOW='2026-11-15T20:00:00-03:00'
SLOT='2026-11-24T09:00:00-03:00'   # terça-feira
ANA='22222222-0000-4000-8000-000000000001'
for i in $(seq 1 "$N"); do
  phone=$(printf '55119777%05d' "$i")
  $PSQL -d "$DB" -c "
    WITH b AS (SELECT ria.api_inbound_begin(jsonb_build_object('phone_number_id','100000000000001','wa_message_id','wamid.C$i',
                 'from','$phone','msg_type','text','now','$NOW')) r),
         o AS (SELECT ria.api_offer_create(jsonb_build_object('clinic_id', r->'clinic'->>'id', 'patient_id', r->'patient'->>'id',
                 'conversation_id', r->'conversation'->>'id', 'service_id','33333333-0000-4000-8000-000000000001',
                 'professional_ids', jsonb_build_array('$ANA'), 'window_from','$SLOT',
                 'window_to', ('$SLOT'::timestamptz + interval '1 minute')::text, 'busy','[]'::jsonb, 'now','$NOW')) x, r FROM b)
    SELECT jsonb_build_object('option_id', x->'options'->0->>'option_id', 'patient_id', r->'patient'->>'id',
                              'conversation_id', r->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', '$NOW')
    FROM o" > "$WORK/req_$i.json"
done

# Disparo simultâneo
for i in $(seq 1 "$N"); do
  ( echo "SELECT ria.api_reserve(:'req'::jsonb)->>'status';" | $PSQL -d "$DB" -v req="$(cat "$WORK/req_$i.json")" > "$WORK/res_$i.txt" ) &
done
wait

HELD=$(cat "$WORK"/res_*.txt | grep -c '^held$' || true)
TAKEN=$(cat "$WORK"/res_*.txt | grep -c '^slot_taken$' || true)
ROWS=$($PSQL -d "$DB" -c "SELECT count(*) FROM ria.appointments WHERE starts_at = '$SLOT' AND status IN ('held','confirmed')")
echo "Concorrência com $N pacientes: held=$HELD slot_taken=$TAKEN linhas_ativas_no_banco=$ROWS"
if [ "$HELD" = "1" ] && [ "$TAKEN" = "$((N-1))" ] && [ "$ROWS" = "1" ]; then
  echo "PASSOU: apenas um paciente conseguiu o horário"
else
  echo "FALHOU"; exit 1
fi
