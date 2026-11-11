-- =============================================================================
-- Testes automatizados do banco (executar em banco DESCARTÁVEL com seed demo).
-- Cada bloco lança exceção se uma verificação falhar.
-- Data simulada: domingo 15/11/2026 20:00 (America/Sao_Paulo) — via chave "now".
-- =============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS DISTINCT FROM true THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
  RAISE NOTICE 'ok - %', msg;
END $$;

-- Segunda clínica para teste de isolamento entre clínicas
INSERT INTO ria.clinics(id, slug, name, address_line, whatsapp_phone_number_id)
VALUES ('99999999-9999-4999-8999-999999999999', 'outra-demo', 'Outra Clínica', 'Rua B, 2', '100000000000002')
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ctx(k text PRIMARY KEY, v jsonb);
SET client_min_messages = notice;

-- ---------------------------------------------------------------------------
-- 1. Disponibilidade: funcionamento, almoço, jornada, feriado, ocupação, antecedência
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  c uuid := '11111111-1111-4111-8111-111111111111';
  ana uuid := '22222222-0000-4000-8000-000000000001';
  bruno uuid := '22222222-0000-4000-8000-000000000002';
  aval uuid := '33333333-0000-4000-8000-000000000001';
  n int; first_local text; last_local text;
  now_ts timestamptz := '2026-11-15T20:00:00-03:00';
BEGIN
  SELECT count(*), min(to_char(starts_at AT TIME ZONE 'America/Sao_Paulo','HH24:MI')), max(to_char(starts_at AT TIME ZONE 'America/Sao_Paulo','HH24:MI'))
    INTO n, first_local, last_local
    FROM ria.fn_available_slots(c, aval, ARRAY[ana], '2026-11-16T00:00:00-03:00', '2026-11-17T00:00:00-03:00', '[]', now_ts);
  PERFORM pg_temp.ok(first_local = '08:00', 'primeiro horário de segunda é 08:00 (obtido ' || first_local || ')');
  PERFORM pg_temp.ok(last_local = '17:30', 'último início respeita a duração de 30 min (17:30)');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM ria.fn_available_slots(c, aval, ARRAY[ana], '2026-11-16T00:00:00-03:00', '2026-11-17T00:00:00-03:00', '[]', now_ts)
                                 WHERE (starts_at AT TIME ZONE 'America/Sao_Paulo')::time > '11:30' AND (starts_at AT TIME ZONE 'America/Sao_Paulo')::time < '13:30'),
                     'nenhum horário no almoço (12:00–13:30)');

  SELECT count(*) INTO n FROM ria.fn_available_slots(c, aval, ARRAY[bruno], '2026-11-16T00:00:00-03:00', '2026-11-17T00:00:00-03:00', '[]', now_ts);
  PERFORM pg_temp.ok(n = 0, 'Dr. Bruno não atende às segundas (jornada própria)');
  SELECT count(*) INTO n FROM ria.fn_available_slots(c, aval, ARRAY[bruno], '2026-11-17T00:00:00-03:00', '2026-11-18T00:00:00-03:00', '[]', now_ts);
  PERFORM pg_temp.ok(n > 0, 'Dr. Bruno atende às terças');

  SELECT count(*) INTO n FROM ria.fn_available_slots(c, aval, NULL, '2026-11-15T00:00:00-03:00', '2026-11-16T00:00:00-03:00', '[]', '2026-11-14T20:00:00-03:00');
  PERFORM pg_temp.ok(n = 0, 'domingo fechado');
  SELECT count(*) INTO n FROM ria.fn_available_slots(c, aval, NULL, '2026-12-25T00:00:00-03:00', '2026-12-26T00:00:00-03:00', '[]', now_ts);
  PERFORM pg_temp.ok(n = 0, 'feriado (25/12) fechado');
  SELECT count(*) INTO n FROM ria.fn_available_slots(c, aval, ARRAY[bruno], '2026-12-29T00:00:00-03:00', '2026-12-30T00:00:00-03:00', '[]', '2026-12-20T10:00:00-03:00');
  PERFORM pg_temp.ok(n = 0, 'bloqueio de férias do Dr. Bruno respeitado');

  -- ocupado no Google 09:00–10:00: avaliação (30 min + 10 de intervalo) não pode começar 08:30..09:59
  PERFORM pg_temp.ok(NOT EXISTS (
     SELECT 1 FROM ria.fn_available_slots(c, aval, ARRAY[ana], '2026-11-16T00:00:00-03:00', '2026-11-17T00:00:00-03:00',
        jsonb_build_array(jsonb_build_object('professional_id', ana, 'start', '2026-11-16T09:00:00-03:00', 'end', '2026-11-16T10:00:00-03:00')), now_ts)
     WHERE starts_at > '2026-11-16T08:20:00-03:00' AND starts_at < '2026-11-16T10:00:00-03:00'),
     'período ocupado no Google + intervalo entre pacientes é respeitado');
  PERFORM pg_temp.ok(EXISTS (
     SELECT 1 FROM ria.fn_available_slots(c, aval, ARRAY[ana], '2026-11-16T00:00:00-03:00', '2026-11-17T00:00:00-03:00',
        jsonb_build_array(jsonb_build_object('professional_id', ana, 'start', '2026-11-16T09:00:00-03:00', 'end', '2026-11-16T10:00:00-03:00')), now_ts)
     WHERE starts_at = '2026-11-16T10:00:00-03:00'), 'horário logo após o evento ocupado está livre');

  -- antecedência mínima (120 min): segunda 10:00 => primeiro horário 13:30
  SELECT min(to_char(starts_at AT TIME ZONE 'America/Sao_Paulo','HH24:MI')) INTO first_local
    FROM ria.fn_available_slots(c, aval, ARRAY[ana], '2026-11-16T00:00:00-03:00', '2026-11-17T00:00:00-03:00', '[]', '2026-11-16T10:00:00-03:00');
  PERFORM pg_temp.ok(first_local = '13:30', 'antecedência mínima respeitada (obtido ' || first_local || ')');

  -- limite de dias à frente (30)
  SELECT count(*) INTO n FROM ria.fn_available_slots(c, aval, NULL, '2027-02-01T00:00:00-03:00', '2027-02-02T00:00:00-03:00', '[]', now_ts);
  PERFORM pg_temp.ok(n = 0, 'não oferece além do limite de dias');
END $$;

-- ---------------------------------------------------------------------------
-- 2. Recepção: paciente novo, paciente existente, deduplicação, clínica desconhecida, equipe
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; r2 jsonb;
BEGIN
  r := ria.api_inbound_begin('{"phone_number_id":"100000000000001","wa_message_id":"wamid.T1","from":"5511988880001","profile_name":"Maria","msg_type":"text","wa_timestamp":"1794787200","now":"2026-11-15T20:00:00-03:00"}');
  PERFORM pg_temp.ok(r->>'status' = 'ok' AND (r->'patient'->>'is_new')::boolean, 'paciente novo cadastrado automaticamente');
  PERFORM pg_temp.ok(r->'conversation'->>'mode' = 'BOT' AND r->'conversation'->>'state' = 'idle', 'conversa inicia em BOT/idle');
  PERFORM pg_temp.ok(jsonb_array_length(r->'services') = 6 AND jsonb_array_length(r->'professionals') = 2, 'contexto traz serviços e profissionais');
  PERFORM pg_temp.ok((r->'clinic'->>'is_open_now')::boolean = false, 'domingo 20h: clínica fechada agora');
  INSERT INTO ctx VALUES ('maria', r);

  r2 := ria.api_inbound_begin('{"phone_number_id":"100000000000001","wa_message_id":"wamid.T1","from":"5511988880001","msg_type":"text","now":"2026-11-15T20:00:00-03:00"}');
  PERFORM pg_temp.ok(r2->>'status' = 'duplicate', 'mensagem duplicada (mesmo ID da Meta) é ignorada');

  r2 := ria.api_inbound_begin('{"phone_number_id":"100000000000001","wa_message_id":"wamid.T2","from":"5511988880001","msg_type":"text","now":"2026-11-15T20:01:00-03:00"}');
  PERFORM pg_temp.ok(r2->>'status' = 'ok' AND NOT (r2->'patient'->>'is_new')::boolean AND r2->'patient'->>'id' = r->'patient'->>'id', 'paciente já cadastrado é reconhecido');

  r2 := ria.api_inbound_begin('{"phone_number_id":"999","wa_message_id":"wamid.T3","from":"5511988880001","msg_type":"text"}');
  PERFORM pg_temp.ok(r2->>'status' = 'unknown_clinic', 'número de WhatsApp sem clínica é ignorado');

  r2 := ria.api_inbound_begin('{"phone_number_id":"100000000000001","wa_message_id":"wamid.T4","from":"5511900000001","msg_type":"text"}');
  PERFORM pg_temp.ok(r2->>'status' = 'staff', 'número da equipe é tratado como equipe');

  r2 := ria.api_inbound_begin('{"phone_number_id":"100000000000001","wa_message_id":"wamid.T5","from":"5511988880002","profile_name":"João","msg_type":"text","now":"2026-11-15T20:00:00-03:00"}');
  INSERT INTO ctx VALUES ('joao', r2);
  r2 := ria.api_inbound_begin('{"phone_number_id":"100000000000002","wa_message_id":"wamid.T6","from":"5511988880001","msg_type":"text","now":"2026-11-15T20:00:00-03:00"}');
  PERFORM pg_temp.ok(r2->'patient'->>'id' <> r->'patient'->>'id', 'mesmo telefone em outra clínica é outro cadastro (isolamento)');

  r2 := ria.api_set_patient_name(jsonb_build_object('clinic_id', r->'clinic'->>'id', 'patient_id', r->'patient'->>'id', 'name', 'maria DA silva'));
  PERFORM pg_temp.ok(r2->>'full_name' = 'Maria da Silva', 'nome normalizado (' || coalesce(r2->>'full_name','?') || ')');
  r2 := ria.api_set_patient_name(jsonb_build_object('clinic_id', r->'clinic'->>'id', 'patient_id', r->'patient'->>'id', 'name', 'DROP TABLE; 123'));
  PERFORM pg_temp.ok(r2->>'ok' = 'false', 'nome inválido é recusado');
END $$;

-- ---------------------------------------------------------------------------
-- 3. Oferta, escolha, reserva, concorrência, confirmação
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  m jsonb := (SELECT v FROM ctx WHERE k = 'maria');
  j jsonb := (SELECT v FROM ctx WHERE k = 'joao');
  prep jsonb; offer jsonb; offer2 jsonb; ch jsonb; res jsonb; res2 jsonb; conf jsonb;
  t1 timestamptz; t2 timestamptz; t3 timestamptz;
  now_ts text := '2026-11-15T20:00:00-03:00';
BEGIN
  prep := ria.api_offer_prepare(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'service_code', 'avaliacao', 'date_from', '2026-11-16', 'now', now_ts));
  PERFORM pg_temp.ok(prep->>'status' = 'ok' AND jsonb_array_length(prep->'professionals') = 2, 'preparação: 2 dentistas fazem avaliação');

  prep := ria.api_offer_prepare(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'service_code', 'canal', 'now', now_ts));
  PERFORM pg_temp.ok(prep->>'status' = 'service_requires_human', 'tratamento de canal exige humano');

  prep := ria.api_offer_prepare(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'service_code', 'avaliacao', 'date_from', '2026-11-16', 'now', now_ts));
  offer := ria.api_offer_create(jsonb_build_object(
      'clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id',
      'service_id', prep->'service'->>'id', 'professional_ids_json', prep->'professionals',
      'window_from', prep->>'window_from', 'window_to', prep->>'window_to', 'search_to', prep->>'search_to',
      'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok(offer->>'status' = 'ok' AND jsonb_array_length(offer->'options') = 3, 'oferta com 3 horários');
  t1 := (offer->'options'->0->>'starts_at')::timestamptz; t2 := (offer->'options'->1->>'starts_at')::timestamptz; t3 := (offer->'options'->2->>'starts_at')::timestamptz;
  PERFORM pg_temp.ok(t2 - t1 >= interval '90 minutes' AND t3 - t2 >= interval '90 minutes', 'horários oferecidos são variados (>= 90 min)');
  PERFORM pg_temp.ok((offer->'options'->0->>'label') LIKE 'seg, 16/11 às 08:00', 'rótulo pt-BR: ' || (offer->'options'->0->>'label'));

  -- preferência por período da tarde
  offer2 := ria.api_offer_create(jsonb_build_object(
      'clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id',
      'service_id', prep->'service'->>'id', 'professional_ids_json', prep->'professionals',
      'window_from', prep->>'window_from', 'window_to', prep->>'window_to', 'search_to', prep->>'search_to',
      'period', 'afternoon', 'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(offer2->'options') o
                                  WHERE ((o->>'starts_at')::timestamptz AT TIME ZONE 'America/Sao_Paulo')::time < '12:00'),
                     'preferência "tarde" respeitada');
  -- a oferta anterior foi substituída
  ch := ria.api_offer_choose(jsonb_build_object('conversation_id', m->'conversation'->>'id', 'patient_id', m->'patient'->>'id',
                                                'option_id', offer->'options'->0->>'option_id', 'now', now_ts));
  PERFORM pg_temp.ok(ch->>'status' = 'expired', 'oferta substituída não pode mais ser usada');

  -- Maria escolhe a opção 1 da oferta nova; João recebe oferta com o MESMO horário
  ch := ria.api_offer_choose(jsonb_build_object('conversation_id', m->'conversation'->>'id', 'patient_id', m->'patient'->>'id', 'option_number', 1, 'now', now_ts));
  PERFORM pg_temp.ok(ch->>'status' = 'ok', 'escolha por número resolvida');
  INSERT INTO ctx VALUES ('maria_choice', ch);

  -- João não pode escolher opção da oferta da Maria (dados de terceiro)
  res := ria.api_offer_choose(jsonb_build_object('conversation_id', j->'conversation'->>'id', 'patient_id', j->'patient'->>'id', 'option_id', ch->>'option_id', 'now', now_ts));
  PERFORM pg_temp.ok(res->>'status' = 'invalid', 'paciente não consegue usar oferta de outro paciente');
  res := ria.api_reserve(jsonb_build_object('option_id', ch->>'option_id', 'patient_id', j->'patient'->>'id', 'conversation_id', j->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok(res->>'status' = 'invalid', 'paciente não consegue reservar com oferta de outro paciente');

  offer2 := ria.api_offer_create(jsonb_build_object(
      'clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'conversation_id', j->'conversation'->>'id',
      'service_id', prep->'service'->>'id', 'professional_ids_json', jsonb_build_array(jsonb_build_object('id', ch->>'professional_id')),
      'window_from', prep->>'window_from', 'window_to', prep->>'window_to', 'search_to', prep->>'search_to',
      'period', 'afternoon', 'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok((offer2->'options'->0->>'starts_at') = (ch->>'starts_at'), 'João recebeu o mesmo horário (cenário de disputa)');
  INSERT INTO ctx VALUES ('joao_offer', offer2);

  -- Google mostra o horário ocupado (alteração manual): reserva recusada
  res := ria.api_reserve(jsonb_build_object('option_id', ch->>'option_id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id',
        'busy', jsonb_build_array(jsonb_build_object('professional_id', ch->>'professional_id', 'start', ch->>'starts_at', 'end', ch->>'ends_at')), 'now', now_ts));
  PERFORM pg_temp.ok(res->>'status' = 'slot_taken', 'revalidação: horário ocupado manualmente no Google é recusado');

  res := ria.api_reserve(jsonb_build_object('option_id', ch->>'option_id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok(res->>'status' = 'held' AND length(res->>'calendar_event_id') = 32, 'Maria reservou (held) com ID de evento determinístico');
  res2 := ria.api_reserve(jsonb_build_object('option_id', offer2->'options'->0->>'option_id', 'patient_id', j->'patient'->>'id', 'conversation_id', j->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok(res2->>'status' = 'slot_taken', 'João recebe slot_taken no mesmo horário');

  conf := ria.api_appointment_confirm(jsonb_build_object('appointment_id', res->>'appointment_id', 'calendar_event_id', res->>'calendar_event_id'));
  PERFORM pg_temp.ok(conf->>'status' = 'confirmed', 'confirmação após criar evento');
  conf := ria.api_appointment_confirm(jsonb_build_object('appointment_id', res->>'appointment_id', 'calendar_event_id', res->>'calendar_event_id'));
  PERFORM pg_temp.ok(conf->>'status' = 'confirmed' AND (conf->>'already')::boolean, 'confirmação é idempotente');
  PERFORM pg_temp.ok((SELECT reminders_opt_in FROM ria.patients WHERE id = (m->'patient'->>'id')::uuid), 'opt-in de lembretes registrado ao agendar');
  INSERT INTO ctx VALUES ('maria_appt', res);

  -- Overbooking direto no banco é impossível
  BEGIN
    INSERT INTO ria.appointments(clinic_id, patient_id, professional_id, service_id, starts_at, ends_at, block_until, status)
    VALUES ((m->'clinic'->>'id')::uuid, (j->'patient'->>'id')::uuid, (ch->>'professional_id')::uuid, (prep->'service'->>'id')::uuid,
            (ch->>'starts_at')::timestamptz + interval '10 minutes', (ch->>'ends_at')::timestamptz + interval '10 minutes',
            (ch->>'ends_at')::timestamptz + interval '20 minutes', 'confirmed');
    RAISE EXCEPTION 'FALHOU: banco aceitou sobreposição';
  EXCEPTION WHEN exclusion_violation THEN
    PERFORM pg_temp.ok(true, 'restrição de exclusão impede sobreposição mesmo via SQL direto');
  END;

  -- Duplicidade: Maria tenta outra avaliação
  prep := ria.api_offer_prepare(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'service_code', 'avaliacao', 'date_from', '2026-11-17', 'now', now_ts));
  offer := ria.api_offer_create(jsonb_build_object(
      'clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id',
      'service_id', prep->'service'->>'id', 'professional_ids_json', prep->'professionals',
      'window_from', prep->>'window_from', 'window_to', prep->>'window_to', 'search_to', prep->>'search_to', 'busy', '[]'::jsonb, 'now', now_ts));
  res := ria.api_reserve(jsonb_build_object('option_id', offer->'options'->0->>'option_id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok(res->>'status' = 'patient_already_booked', 'impede agendamento duplicado do mesmo serviço');

  -- oferta vencida
  res := ria.api_offer_choose(jsonb_build_object('conversation_id', m->'conversation'->>'id', 'patient_id', m->'patient'->>'id', 'option_number', 1, 'now', '2026-11-15T21:00:00-03:00'));
  PERFORM pg_temp.ok(res->>'status' = 'expired', 'oferta expira após o prazo de validade');
END $$;

-- ---------------------------------------------------------------------------
-- 4. Remarcação (mantém a original até confirmar a nova) e cancelamento
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  m jsonb := (SELECT v FROM ctx WHERE k = 'maria');
  j jsonb := (SELECT v FROM ctx WHERE k = 'joao');
  a jsonb := (SELECT v FROM ctx WHERE k = 'maria_appt');
  chk jsonb; prep jsonb; offer jsonb; res jsonb; conf jsonb; lst jsonb; c jsonb;
  now_ts text := '2026-11-15T20:00:00-03:00';
BEGIN
  lst := ria.api_patient_appointments(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'now', now_ts));
  PERFORM pg_temp.ok(jsonb_array_length(lst->'appointments') = 1, 'Maria tem 1 consulta futura');
  lst := ria.api_patient_appointments(jsonb_build_object('clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'now', now_ts));
  PERFORM pg_temp.ok(jsonb_array_length(lst->'appointments') = 0, 'João não vê a consulta da Maria');

  c := ria.api_cancel_request(jsonb_build_object('clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'appointment_id', a->>'appointment_id', 'now', now_ts));
  PERFORM pg_temp.ok(c->>'status' = 'not_found', 'João não consegue cancelar a consulta da Maria');
  c := ria.api_attendance_confirm(jsonb_build_object('clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'appointment_id', a->>'appointment_id'));
  PERFORM pg_temp.ok(c->>'status' = 'not_found', 'João não consegue confirmar presença da consulta da Maria');

  chk := ria.api_reschedule_check(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'appointment_id', a->>'appointment_id', 'now', now_ts));
  PERFORM pg_temp.ok(chk->>'status' = 'ok', 'remarcação permitida');
  prep := ria.api_offer_prepare(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'service_id', chk->>'service_id', 'date_from', '2026-11-18', 'now', now_ts));
  offer := ria.api_offer_create(jsonb_build_object(
      'clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id',
      'service_id', prep->'service'->>'id', 'professional_ids_json', prep->'professionals', 'reschedule_of', a->>'appointment_id',
      'window_from', prep->>'window_from', 'window_to', prep->>'window_to', 'search_to', prep->>'search_to', 'busy', '[]'::jsonb, 'now', now_ts));
  res := ria.api_reserve(jsonb_build_object('option_id', offer->'options'->0->>'option_id', 'patient_id', m->'patient'->>'id', 'conversation_id', m->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', now_ts));
  PERFORM pg_temp.ok(res->>'status' = 'held' AND res->>'reschedule_of' = a->>'appointment_id', 'nova reserva da remarcação criada');
  PERFORM pg_temp.ok((SELECT status FROM ria.appointments WHERE id = (a->>'appointment_id')::uuid) = 'confirmed', 'consulta original continua confirmada durante a remarcação');
  conf := ria.api_appointment_confirm(jsonb_build_object('appointment_id', res->>'appointment_id', 'calendar_event_id', res->>'calendar_event_id'));
  PERFORM pg_temp.ok(conf->'old_appointment'->>'appointment_id' = a->>'appointment_id', 'confirmação devolve a consulta antiga para remover da agenda');
  PERFORM pg_temp.ok((SELECT status FROM ria.appointments WHERE id = (a->>'appointment_id')::uuid) = 'cancel_requested', 'consulta antiga em cancel_requested');
  c := ria.api_cancel_finalize(jsonb_build_object('appointment_id', a->>'appointment_id', 'calendar_ok', true));
  PERFORM pg_temp.ok(c->>'status' = 'cancelled', 'consulta antiga cancelada após remoção na agenda');
  INSERT INTO ctx VALUES ('maria_appt2', res);

  -- Cancelamento com falha na agenda => reverter
  c := ria.api_cancel_request(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'appointment_id', res->>'appointment_id', 'now', now_ts));
  PERFORM pg_temp.ok(c->>'status' = 'ok', 'pedido de cancelamento aceito');
  c := ria.api_cancel_revert(jsonb_build_object('appointment_id', res->>'appointment_id'));
  PERFORM pg_temp.ok((SELECT status FROM ria.appointments WHERE id = (res->>'appointment_id')::uuid) = 'confirmed', 'falha na agenda reverte para confirmada');
END $$;

-- ---------------------------------------------------------------------------
-- 5. Lembretes: janela de 24h, sem duplicidade, sem canceladas, opt-out
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  a jsonb := (SELECT v FROM ctx WHERE k = 'maria_appt2');
  st timestamptz := (SELECT starts_at FROM ria.appointments WHERE id = ((SELECT v FROM ctx WHERE k='maria_appt2')->>'appointment_id')::uuid);
  r jsonb; r2 jsonb;
BEGIN
  r := ria.api_reminders_claim(jsonb_build_object('now', st - interval '30 hours'));
  PERFORM pg_temp.ok(jsonb_array_length(r->'reminders') = 0, 'sem lembrete 30h antes');
  r := ria.api_reminders_claim(jsonb_build_object('now', st - interval '23 hours 50 minutes'));
  PERFORM pg_temp.ok(jsonb_array_length(r->'reminders') = 1, 'lembrete reivindicado ~24h antes');
  PERFORM pg_temp.ok(r->'reminders'->0->>'status' = 'sending' AND (r->'reminders'->0->>'in_session_window')::boolean = false,
                     'fora da janela de 24h => usará template aprovado');
  r2 := ria.api_reminders_claim(jsonb_build_object('now', st - interval '23 hours'));
  PERFORM pg_temp.ok(jsonb_array_length(r2->'reminders') = 0, 'lembrete não é disparado duas vezes');
  PERFORM ria.api_reminder_result(jsonb_build_object('reminder_id', r->'reminders'->0->>'reminder_id', 'status', 'sent', 'channel', 'template', 'wa_message_id', 'wamid.R1'));
  PERFORM pg_temp.ok((SELECT status FROM ria.reminders WHERE id = (r->'reminders'->0->>'reminder_id')::uuid) = 'sent', 'resultado do envio registrado');
  PERFORM ria.api_outbound_record(jsonb_build_object('clinic_id', '11111111-1111-4111-8111-111111111111', 'wa_message_id', 'wamid.R1', 'kind', 'template', 'purpose', 'reminder', 'status', 'accepted'));
  PERFORM ria.api_status_update('{"wa_message_id":"wamid.R1","status":"failed","error_code":"131049","error_title":"Message not delivered to +55 11 98888-0001"}');
  PERFORM pg_temp.ok((SELECT status FROM ria.reminders WHERE wa_message_id = 'wamid.R1') = 'failed', 'falha de entrega atualiza o lembrete');
  PERFORM pg_temp.ok((SELECT message FROM ria.integration_errors ORDER BY id DESC LIMIT 1) NOT LIKE '%98888%', 'log de erro não contém telefone');
END $$;

DO $$
DECLARE j jsonb := (SELECT v FROM ctx WHERE k = 'joao'); o jsonb; res jsonb; r jsonb; st timestamptz; n int;
BEGIN
  -- João agenda limpeza, depois pede PARAR => lembrete não é enviado
  o := ria.api_offer_create(jsonb_build_object(
      'clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'conversation_id', j->'conversation'->>'id',
      'service_id', '33333333-0000-4000-8000-000000000002', 'window_from', '2026-11-19T00:00:00-03:00', 'window_to', '2026-11-20T00:00:00-03:00',
      'busy', '[]'::jsonb, 'now', '2026-11-15T20:00:00-03:00'));
  res := ria.api_reserve(jsonb_build_object('option_id', o->'options'->0->>'option_id', 'patient_id', j->'patient'->>'id', 'conversation_id', j->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', '2026-11-15T20:00:00-03:00'));
  PERFORM ria.api_appointment_confirm(jsonb_build_object('appointment_id', res->>'appointment_id', 'calendar_event_id', res->>'calendar_event_id'));
  PERFORM ria.api_consent(jsonb_build_object('clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'kind', 'opt_out', 'evidence', 'wamid.X'));
  st := (res->>'starts_at')::timestamptz;
  r := ria.api_reminders_claim(jsonb_build_object('now', st - interval '23 hours 30 minutes'));
  SELECT count(*) INTO n FROM jsonb_array_elements(r->'reminders') x WHERE x->>'appointment_id' = res->>'appointment_id' AND x->>'status' = 'skipped_opt_out';
  PERFORM pg_temp.ok(n = 1, 'opt-out impede lembrete');

  -- consulta cancelada não recebe lembrete
  PERFORM ria.api_consent(jsonb_build_object('clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'kind', 'opt_in_again'));
  o := ria.api_offer_create(jsonb_build_object(
      'clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'conversation_id', j->'conversation'->>'id',
      'service_id', '33333333-0000-4000-8000-000000000003', 'window_from', '2026-11-21T00:00:00-03:00', 'window_to', '2026-11-22T00:00:00-03:00',
      'busy', '[]'::jsonb, 'now', '2026-11-15T20:00:00-03:00'));
  res := ria.api_reserve(jsonb_build_object('option_id', o->'options'->0->>'option_id', 'patient_id', j->'patient'->>'id', 'conversation_id', j->'conversation'->>'id', 'busy', '[]'::jsonb, 'now', '2026-11-15T20:00:00-03:00'));
  PERFORM pg_temp.ok(res->>'status' = 'held', 'clareamento reservado com Dr. Bruno no sábado: ' || coalesce(res->>'status',''));
  PERFORM ria.api_appointment_confirm(jsonb_build_object('appointment_id', res->>'appointment_id', 'calendar_event_id', res->>'calendar_event_id'));
  PERFORM ria.api_cancel_request(jsonb_build_object('clinic_id', j->'clinic'->>'id', 'patient_id', j->'patient'->>'id', 'appointment_id', res->>'appointment_id', 'now', '2026-11-15T20:00:00-03:00'));
  PERFORM ria.api_cancel_finalize(jsonb_build_object('appointment_id', res->>'appointment_id', 'calendar_ok', true));
  r := ria.api_reminders_claim(jsonb_build_object('now', (res->>'starts_at')::timestamptz - interval '23 hours'));
  SELECT count(*) INTO n FROM jsonb_array_elements(r->'reminders') x WHERE x->>'appointment_id' = res->>'appointment_id';
  PERFORM pg_temp.ok(n = 0, 'consulta cancelada não recebe lembrete');
END $$;

-- ---------------------------------------------------------------------------
-- 6. Atendimento humano BOT <-> HUMAN
-- ---------------------------------------------------------------------------
DO $$
DECLARE m jsonb := (SELECT v FROM ctx WHERE k = 'maria'); h jsonb; a jsonb; r jsonb; s jsonb;
BEGIN
  h := ria.api_handoff_open(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'conversation_id', m->'conversation'->>'id', 'reason', 'urgency', 'priority', 'urgent'));
  PERFORM pg_temp.ok(h->>'status' = 'ok' AND length(h->>'code') = 4, 'transferência criada com código ' || (h->>'code'));
  PERFORM pg_temp.ok(jsonb_array_length(h->'staff') = 1, 'recepção recebe a transferência (admin não)');
  r := ria.api_inbound_begin('{"phone_number_id":"100000000000001","wa_message_id":"wamid.H1","from":"5511988880001","msg_type":"text"}');
  PERFORM pg_temp.ok(r->'conversation'->>'mode' = 'HUMAN', 'conversa em modo HUMANO');
  s := ria.api_conversation_save(jsonb_build_object('conversation_id', m->'conversation'->>'id', 'clinic_id', m->'clinic'->>'id', 'state', 'awaiting_service'));
  PERFORM pg_temp.ok((s->>'saved')::boolean = false, 'robô não altera estado em modo HUMANO');
  a := ria.api_handoff_action(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'staff_id', '44444444-0000-4000-8000-000000000001', 'action', 'assign', 'code', lower(h->>'code')));
  PERFORM pg_temp.ok(a->>'status' = 'ok' AND a->>'patient_wa_id' = '5511988880001', 'recepcionista assume pelo código');
  a := ria.api_handoff_action(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'staff_id', '00000000-0000-4000-8000-000000000000', 'action', 'release', 'code', h->>'code'));
  PERFORM pg_temp.ok(a->>'status' = 'forbidden', 'quem não é da equipe não devolve atendimento');
  a := ria.api_handoff_action(jsonb_build_object('clinic_id', '99999999-9999-4999-8999-999999999999', 'staff_id', '44444444-0000-4000-8000-000000000001', 'action', 'release', 'code', h->>'code'));
  PERFORM pg_temp.ok(a->>'status' = 'forbidden', 'equipe de outra clínica não acessa o atendimento');
  a := ria.api_handoff_action(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'staff_id', '44444444-0000-4000-8000-000000000001', 'action', 'list'));
  PERFORM pg_temp.ok(jsonb_array_length(a->'handoffs') = 1, 'fila de atendimentos');
  a := ria.api_handoff_action(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'staff_id', '44444444-0000-4000-8000-000000000001', 'action', 'release', 'code', h->>'code'));
  PERFORM pg_temp.ok(a->>'status' = 'ok', 'recepcionista devolve ao robô');
  r := ria.api_inbound_begin('{"phone_number_id":"100000000000001","wa_message_id":"wamid.H2","from":"5511988880001","msg_type":"text"}');
  PERFORM pg_temp.ok(r->'conversation'->>'mode' = 'BOT', 'conversa voltou para o robô');

  -- devolução automática por inatividade
  h := ria.api_handoff_open(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'conversation_id', m->'conversation'->>'id', 'reason', 'patient_request', 'now', (now() - interval '5 hours')::text));
  UPDATE ria.conversations SET human_last_activity_at = now() - interval '5 hours' WHERE id = (m->'conversation'->>'id')::uuid;
  r := ria.api_janitor('{}');
  PERFORM pg_temp.ok((r->>'conversations_returned_to_bot')::int = 1, 'retorno automático ao robô após inatividade');
END $$;

-- ---------------------------------------------------------------------------
-- 7. Reconciliação com o Google Calendar
-- ---------------------------------------------------------------------------
DO $$
DECLARE a uuid := ((SELECT v FROM ctx WHERE k = 'maria_appt2')->>'appointment_id')::uuid; ap ria.appointments; r jsonb;
BEGIN
  SELECT * INTO ap FROM ria.appointments WHERE id = a;
  -- evento removido manualmente
  r := ria.api_reconcile(jsonb_build_object('professional_id', ap.professional_id, 'time_min', ap.starts_at - interval '1 day', 'time_max', ap.starts_at + interval '1 day', 'events', '[]'::jsonb));
  PERFORM pg_temp.ok(r->'issues'->0->>'issue' = 'missing_in_calendar', 'detecta evento removido manualmente');
  -- evento movido manualmente
  r := ria.api_reconcile(jsonb_build_object('professional_id', ap.professional_id, 'time_min', ap.starts_at - interval '1 day', 'time_max', ap.starts_at + interval '1 day',
        'events', jsonb_build_array(jsonb_build_object('id', ap.calendar_event_id, 'start', ap.starts_at + interval '1 hour', 'end', ap.ends_at + interval '1 hour'))));
  PERFORM pg_temp.ok(r->'issues'->0->>'issue' = 'time_mismatch', 'detecta horário alterado manualmente');
  -- evento manual sobreposto
  r := ria.api_reconcile(jsonb_build_object('professional_id', ap.professional_id, 'time_min', ap.starts_at - interval '1 day', 'time_max', ap.starts_at + interval '1 day',
        'events', jsonb_build_array(jsonb_build_object('id', ap.calendar_event_id, 'start', ap.starts_at, 'end', ap.ends_at),
                                    jsonb_build_object('id', 'manual1', 'start', ap.starts_at, 'end', ap.ends_at))));
  PERFORM pg_temp.ok(r->'issues'->0->>'issue' = 'conflict', 'detecta conflito com evento manual');
  PERFORM ria.api_alerts_collect('{}');
  r := ria.api_reconcile(jsonb_build_object('professional_id', ap.professional_id, 'time_min', ap.starts_at - interval '1 day', 'time_max', ap.starts_at + interval '1 day',
        'events', jsonb_build_array(jsonb_build_object('id', ap.calendar_event_id, 'start', ap.starts_at, 'end', ap.ends_at))));
  PERFORM pg_temp.ok(jsonb_array_length(r->'issues') = 0 AND (SELECT sync_status FROM ria.appointments WHERE id = a) = 'synced', 'agenda sincronizada volta a synced');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM ria.admin_alerts WHERE kind = 'calendar_sync'), 'alerta de divergência gerado');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM ria.admin_alerts WHERE message ~ '\d{8,}'), 'alertas sem telefone');
END $$;

-- ---------------------------------------------------------------------------
-- 8. Métricas, retenção e anonimização
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; m jsonb := (SELECT v FROM ctx WHERE k = 'maria');
BEGIN
  r := ria.api_daily_metrics(jsonb_build_object('day', to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD')));
  PERFORM pg_temp.ok(jsonb_array_length(r->'metrics') >= 1, 'métricas diárias calculadas');
  r := ria.api_retention('{}');
  PERFORM pg_temp.ok(r ? 'processed_messages', 'retenção executa');
  r := ria.api_anonymize_patient(jsonb_build_object('clinic_id', m->'clinic'->>'id', 'patient_id', m->'patient'->>'id', 'requested_by', 'teste'));
  PERFORM pg_temp.ok(r->>'status' = 'has_future_appointments', 'anonimização exige cancelar consultas futuras antes');
  r := ria.api_anonymize_patient(jsonb_build_object('clinic_id', '99999999-9999-4999-8999-999999999999',
        'patient_id', (SELECT id FROM ria.patients WHERE clinic_id = '99999999-9999-4999-8999-999999999999' LIMIT 1), 'requested_by', 'teste'));
  PERFORM pg_temp.ok(r->>'status' = 'anonymized', 'paciente sem consultas é anonimizado');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM ria.patients WHERE clinic_id = '99999999-9999-4999-8999-999999999999' AND wa_id ~ '^\d+$'), 'telefone removido na anonimização');
END $$;

\echo 'TODOS OS TESTES DO BANCO PASSARAM'
