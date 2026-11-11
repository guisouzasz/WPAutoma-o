-- ARQUIVO GERADO por scripts/montar-schema.sh a partir de database/migrations/*.sql
-- Para instalação nova: psql "$DATABASE_URL" -f database/schema.sql

-- >>> database/migrations/001_estrutura.sql
-- =============================================================================
-- Recepcionista IA — Migração 001: estrutura (tabelas, tipos, índices)
-- PostgreSQL 14+ (testado em 16). Todas as tabelas ficam no schema "ria".
-- Não armazena conteúdo de mensagens, prontuários, diagnósticos ou transcrições.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid(), digest()
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- restrição de exclusão (anti-overbooking)

CREATE SCHEMA IF NOT EXISTS ria;

CREATE TABLE IF NOT EXISTS ria.schema_migrations (
  version     text PRIMARY KEY,
  applied_at  timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Configurações globais NÃO secretas (modelos de IA, versões de API, URLs base).
-- Segredos ficam somente no cofre de credenciais do n8n ou no .env.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.app_settings (
  key          text PRIMARY KEY,
  value        jsonb NOT NULL,
  description  text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Clínicas (tenant). Toda tabela de negócio referencia clinic_id.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.clinics (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                        text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]{3,60}$'),
  name                        text NOT NULL,
  address_line                text NOT NULL,
  city                        text,
  state                       text,
  postal_code                 text,
  phone_display               text,
  maps_url                    text,
  latitude                    numeric(9,6),
  longitude                   numeric(9,6),
  timezone                    text NOT NULL DEFAULT 'America/Sao_Paulo',
  status                      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  -- WhatsApp Cloud API (identificadores públicos; o token fica no n8n)
  whatsapp_phone_number_id    text UNIQUE,
  whatsapp_waba_id            text,
  whatsapp_display_number     text,
  -- Agenda: 'google' (Google Calendar) ou 'external' (API de software odontológico)
  calendar_provider           text NOT NULL DEFAULT 'google' CHECK (calendar_provider IN ('google','external')),
  external_calendar_base_url  text,
  -- Regras de agendamento
  min_booking_notice_minutes  int  NOT NULL DEFAULT 120 CHECK (min_booking_notice_minutes >= 0),
  max_booking_days_ahead      int  NOT NULL DEFAULT 30  CHECK (max_booking_days_ahead BETWEEN 1 AND 180),
  slot_step_minutes           int  NOT NULL DEFAULT 15  CHECK (slot_step_minutes BETWEEN 5 AND 120),
  offer_ttl_minutes           int  NOT NULL DEFAULT 15  CHECK (offer_ttl_minutes BETWEEN 2 AND 120),
  offer_max_options           int  NOT NULL DEFAULT 3   CHECK (offer_max_options BETWEEN 1 AND 3),
  hold_ttl_minutes            int  NOT NULL DEFAULT 5   CHECK (hold_ttl_minutes BETWEEN 1 AND 30),
  max_future_appointments     int  NOT NULL DEFAULT 2   CHECK (max_future_appointments BETWEEN 1 AND 10),
  cancel_min_notice_hours     int  NOT NULL DEFAULT 24  CHECK (cancel_min_notice_hours >= 0),
  late_cancel_action          text NOT NULL DEFAULT 'allow' CHECK (late_cancel_action IN ('allow','handoff')),
  reschedule_min_notice_hours int  NOT NULL DEFAULT 12  CHECK (reschedule_min_notice_hours >= 0),
  reminder_hours_before       int  NOT NULL DEFAULT 24  CHECK (reminder_hours_before BETWEEN 1 AND 72),
  human_timeout_minutes       int  NOT NULL DEFAULT 240 CHECK (human_timeout_minutes BETWEEN 10 AND 10080),
  -- Textos autorizados pela clínica (boas-vindas, políticas, etc.)
  messages                    jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Template Utility aprovado na Meta para lembretes (nome, idioma, parâmetros)
  reminder_template           jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Template Utility para avisar a equipe fora da janela de 24h
  staff_alert_template        jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Retenção (LGPD), em dias
  retention_message_log_days  int  NOT NULL DEFAULT 90  CHECK (retention_message_log_days BETWEEN 7 AND 3650),
  retention_audit_days        int  NOT NULL DEFAULT 365 CHECK (retention_audit_days BETWEEN 30 AND 3650),
  retention_inactive_patient_days int CHECK (retention_inactive_patient_days IS NULL OR retention_inactive_patient_days >= 180),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now()
);

-- Horário de funcionamento: várias faixas por dia (ex.: 08-12 e 13:30-18 => almoço implícito)
CREATE TABLE IF NOT EXISTS ria.business_hours (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id   uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6), -- 0=domingo (EXTRACT(DOW))
  open_time   time NOT NULL,
  close_time  time NOT NULL,
  CHECK (close_time > open_time)
);
CREATE INDEX IF NOT EXISTS business_hours_clinic_idx ON ria.business_hours(clinic_id, weekday);

-- Feriados (dia inteiro fechado)
CREATE TABLE IF NOT EXISTS ria.holidays (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id   uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  day         date NOT NULL,
  name        text NOT NULL,
  UNIQUE (clinic_id, day)
);

-- Profissionais
CREATE TABLE IF NOT EXISTS ria.professionals (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id             uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  name                  text NOT NULL,
  display_name          text NOT NULL,
  specialty             text,
  calendar_id           text,          -- ID do Google Calendar do profissional
  external_ref          text,          -- ID no software odontológico (adaptador)
  active                boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, clinic_id),
  UNIQUE (clinic_id, calendar_id)
);

-- Jornada específica do profissional (opcional). Sem linhas => segue a clínica.
-- O horário efetivo é a INTERSEÇÃO entre clínica e profissional.
CREATE TABLE IF NOT EXISTS ria.professional_hours (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id        uuid NOT NULL,
  professional_id  uuid NOT NULL,
  weekday          smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_time       time NOT NULL,
  end_time         time NOT NULL,
  CHECK (end_time > start_time),
  FOREIGN KEY (professional_id, clinic_id) REFERENCES ria.professionals(id, clinic_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS professional_hours_idx ON ria.professional_hours(professional_id, weekday);

-- Bloqueios (férias, congresso, manutenção). professional_id NULL => clínica toda.
CREATE TABLE IF NOT EXISTS ria.schedule_blocks (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id        uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  professional_id  uuid,
  starts_at        timestamptz NOT NULL,
  ends_at          timestamptz NOT NULL,
  reason           text,
  CHECK (ends_at > starts_at),
  FOREIGN KEY (professional_id, clinic_id) REFERENCES ria.professionals(id, clinic_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS schedule_blocks_idx ON ria.schedule_blocks USING gist (clinic_id, tstzrange(starts_at, ends_at));

-- Serviços / procedimentos administrativos
CREATE TABLE IF NOT EXISTS ria.services (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id             uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  code                  text NOT NULL CHECK (code ~ '^[a-z0-9_]{2,40}$'),
  name                  text NOT NULL,
  description           text,               -- texto autorizado pela clínica
  price_info            text,               -- texto autorizado (opcional)
  duration_minutes      int  NOT NULL CHECK (duration_minutes BETWEEN 5 AND 480),
  buffer_after_minutes  int  NOT NULL DEFAULT 0 CHECK (buffer_after_minutes BETWEEN 0 AND 120),
  bookable_by_bot       boolean NOT NULL DEFAULT true,  -- false => encaminha para humano
  synonyms              text[] NOT NULL DEFAULT '{}',
  active                boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (clinic_id, code),
  UNIQUE (id, clinic_id)
);

CREATE TABLE IF NOT EXISTS ria.professional_services (
  clinic_id        uuid NOT NULL,
  professional_id  uuid NOT NULL,
  service_id       uuid NOT NULL,
  PRIMARY KEY (professional_id, service_id),
  FOREIGN KEY (professional_id, clinic_id) REFERENCES ria.professionals(id, clinic_id) ON DELETE CASCADE,
  FOREIGN KEY (service_id, clinic_id) REFERENCES ria.services(id, clinic_id) ON DELETE CASCADE
);

-- Perguntas frequentes com respostas AUTORIZADAS pela clínica
CREATE TABLE IF NOT EXISTS ria.faqs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id   uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  question    text NOT NULL,
  answer      text NOT NULL,
  keywords    text[] NOT NULL DEFAULT '{}',
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS faqs_clinic_idx ON ria.faqs(clinic_id) WHERE active;

-- Equipe (recepção/administração) — recebe transferências e alertas pelo WhatsApp oficial
CREATE TABLE IF NOT EXISTS ria.staff_members (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id          uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  name               text NOT NULL,
  wa_id              text NOT NULL CHECK (wa_id ~ '^[0-9]{10,15}$'),
  role               text NOT NULL DEFAULT 'receptionist' CHECK (role IN ('receptionist','admin')),
  receives_handoffs  boolean NOT NULL DEFAULT true,
  receives_alerts    boolean NOT NULL DEFAULT false,
  active             boolean NOT NULL DEFAULT true,
  last_inbound_at    timestamptz,     -- controla a janela de 24h do WhatsApp
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (clinic_id, wa_id),
  UNIQUE (id, clinic_id)
);

-- -----------------------------------------------------------------------------
-- Pacientes: dados mínimos (nome e telefone). Nada clínico.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.patients (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id              uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  wa_id                  text NOT NULL,                 -- número no formato da Meta (só dígitos)
  full_name              text,
  name_source            text CHECK (name_source IN ('informed','whatsapp_profile')),
  whatsapp_profile_name  text,
  status                 text NOT NULL DEFAULT 'active' CHECK (status IN ('active','anonymized')),
  reminders_opt_in       boolean NOT NULL DEFAULT false,
  opted_out_at           timestamptz,                   -- pediu para não receber mensagens ativas
  privacy_notice_at      timestamptz,                   -- aviso de privacidade exibido
  first_contact_at       timestamptz NOT NULL DEFAULT now(),
  last_inbound_at        timestamptz,
  last_outbound_at       timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (clinic_id, wa_id),
  UNIQUE (id, clinic_id)
);

-- Registro de autorizações (opt-in / opt-out / aviso de privacidade)
CREATE TABLE IF NOT EXISTS ria.consent_events (
  id           bigserial PRIMARY KEY,
  clinic_id    uuid NOT NULL,
  patient_id   uuid NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('privacy_notice','reminders_opt_in','opt_out','opt_in_again','anonymized')),
  source       text NOT NULL,           -- ex.: 'whatsapp_inbound', 'booking', 'staff'
  evidence     text,                    -- ex.: id da mensagem da Meta (sem conteúdo)
  created_at   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (patient_id, clinic_id) REFERENCES ria.patients(id, clinic_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS consent_events_patient_idx ON ria.consent_events(patient_id, created_at);

-- -----------------------------------------------------------------------------
-- Conversas: uma por paciente/clínica, com máquina de estados.
-- mode:  BOT | HUMAN
-- state: idle | awaiting_name | awaiting_service | awaiting_slot_choice |
--        awaiting_appointment_choice | awaiting_cancel_confirmation
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.conversations (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id          uuid NOT NULL,
  patient_id         uuid NOT NULL,
  mode               text NOT NULL DEFAULT 'BOT' CHECK (mode IN ('BOT','HUMAN')),
  state              text NOT NULL DEFAULT 'idle' CHECK (state IN (
                       'idle','awaiting_name','awaiting_service','awaiting_slot_choice',
                       'awaiting_appointment_choice','awaiting_cancel_confirmation')),
  context            jsonb NOT NULL DEFAULT '{}'::jsonb,  -- somente IDs e preferências, sem texto livre
  version            int  NOT NULL DEFAULT 0,             -- controle otimista
  ai_failures        int  NOT NULL DEFAULT 0,
  unknown_count      int  NOT NULL DEFAULT 0,
  human_since        timestamptz,
  human_last_activity_at timestamptz,
  assigned_staff_id  uuid,
  last_inbound_at    timestamptz,
  last_bot_reply_at  timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (clinic_id, patient_id),
  UNIQUE (id, clinic_id),
  FOREIGN KEY (patient_id, clinic_id) REFERENCES ria.patients(id, clinic_id) ON DELETE CASCADE,
  FOREIGN KEY (assigned_staff_id, clinic_id) REFERENCES ria.staff_members(id, clinic_id)
);
CREATE INDEX IF NOT EXISTS conversations_human_idx ON ria.conversations(clinic_id) WHERE mode = 'HUMAN';

-- -----------------------------------------------------------------------------
-- Mensagens processadas (deduplicação pelo ID da Meta). SEM conteúdo.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.processed_messages (
  wa_message_id   text PRIMARY KEY,
  clinic_id       uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  patient_id      uuid,
  staff_id        uuid,
  msg_type        text NOT NULL,
  status          text NOT NULL DEFAULT 'received' CHECK (status IN ('received','processed','ignored','failed')),
  intent          text,
  route           text,
  error_code      text,
  wa_timestamp    timestamptz,
  received_at     timestamptz NOT NULL DEFAULT now(),
  processed_at    timestamptz
);
CREATE INDEX IF NOT EXISTS processed_messages_clinic_time_idx ON ria.processed_messages(clinic_id, received_at);

-- Mensagens enviadas (para acompanhar status de entrega). SEM conteúdo.
CREATE TABLE IF NOT EXISTS ria.outbound_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id       uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  patient_id      uuid,
  staff_id        uuid,
  wa_message_id   text UNIQUE,
  kind            text NOT NULL CHECK (kind IN ('text','interactive','template','location')),
  purpose         text NOT NULL DEFAULT 'reply' CHECK (purpose IN ('reply','reminder','handoff','staff_relay','alert','confirmation')),
  status          text NOT NULL CHECK (status IN ('accepted','sent','delivered','read','failed','error')),
  error_code      text,
  error_title     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS outbound_messages_clinic_time_idx ON ria.outbound_messages(clinic_id, created_at);

-- -----------------------------------------------------------------------------
-- Ofertas de horários (com validade) e suas opções
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.slot_offers (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id                uuid NOT NULL,
  patient_id               uuid NOT NULL,
  conversation_id          uuid NOT NULL,
  service_id               uuid NOT NULL,
  reschedule_of            uuid,           -- consulta original (remarcação)
  status                   text NOT NULL DEFAULT 'open' CHECK (status IN ('open','used','expired','superseded')),
  expires_at               timestamptz NOT NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (patient_id, clinic_id) REFERENCES ria.patients(id, clinic_id) ON DELETE CASCADE,
  FOREIGN KEY (conversation_id, clinic_id) REFERENCES ria.conversations(id, clinic_id) ON DELETE CASCADE,
  FOREIGN KEY (service_id, clinic_id) REFERENCES ria.services(id, clinic_id)
);
CREATE INDEX IF NOT EXISTS slot_offers_open_idx ON ria.slot_offers(conversation_id) WHERE status = 'open';

CREATE TABLE IF NOT EXISTS ria.slot_offer_options (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  offer_id         uuid NOT NULL REFERENCES ria.slot_offers(id) ON DELETE CASCADE,
  clinic_id        uuid NOT NULL,
  option_number    smallint NOT NULL CHECK (option_number BETWEEN 1 AND 3),
  professional_id  uuid NOT NULL,
  starts_at        timestamptz NOT NULL,
  ends_at          timestamptz NOT NULL,
  UNIQUE (offer_id, option_number),
  FOREIGN KEY (professional_id, clinic_id) REFERENCES ria.professionals(id, clinic_id)
);

-- -----------------------------------------------------------------------------
-- Agendamentos
-- status:
--   held             reserva temporária enquanto o evento é criado na agenda
--   confirmed        confirmado (banco + agenda)
--   cancel_requested cancelamento em andamento (ainda bloqueia o horário)
--   cancelled        cancelado
--   expired          reserva expirada/liberada (falha ou abandono)
--   completed | no_show  (atualização manual/futura)
-- sync_status: situação perante a agenda externa (reconciliação)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.appointments (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id                uuid NOT NULL,
  patient_id               uuid NOT NULL,
  professional_id          uuid NOT NULL,
  service_id               uuid NOT NULL,
  starts_at                timestamptz NOT NULL,
  ends_at                  timestamptz NOT NULL,
  block_until              timestamptz NOT NULL,   -- ends_at + intervalo entre pacientes
  status                   text NOT NULL CHECK (status IN ('held','confirmed','cancel_requested','cancelled','expired','completed','no_show')),
  sync_status              text NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending','synced','missing_in_calendar','time_mismatch','conflict','delete_pending','deleted')),
  source                   text NOT NULL DEFAULT 'bot' CHECK (source IN ('bot','staff','import')),
  calendar_provider        text NOT NULL DEFAULT 'google',
  calendar_id              text,
  calendar_event_id        text,
  offer_option_id          uuid,
  rescheduled_from_id      uuid REFERENCES ria.appointments(id),
  rescheduled_to_id        uuid REFERENCES ria.appointments(id),
  hold_expires_at          timestamptz,
  attendance_confirmed_at  timestamptz,
  cancelled_at             timestamptz,
  cancel_reason            text,
  cancelled_by             text CHECK (cancelled_by IN ('patient','staff','system')),
  sync_checked_at          timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at),
  CHECK (block_until >= ends_at),
  UNIQUE (id, clinic_id),
  FOREIGN KEY (patient_id, clinic_id) REFERENCES ria.patients(id, clinic_id),
  FOREIGN KEY (professional_id, clinic_id) REFERENCES ria.professionals(id, clinic_id),
  FOREIGN KEY (service_id, clinic_id) REFERENCES ria.services(id, clinic_id),
  -- PROTEÇÃO CONTRA OVERBOOKING: o banco recusa (SQLSTATE 23P01) qualquer
  -- sobreposição de horário ativo do mesmo profissional, mesmo sob concorrência.
  CONSTRAINT appointments_no_overlap EXCLUDE USING gist (
    professional_id WITH =,
    tstzrange(starts_at, block_until, '[)') WITH &&
  ) WHERE (status IN ('held','confirmed','cancel_requested'))
);
CREATE INDEX IF NOT EXISTS appointments_patient_idx ON ria.appointments(patient_id, starts_at);
CREATE INDEX IF NOT EXISTS appointments_clinic_time_idx ON ria.appointments(clinic_id, starts_at);
CREATE INDEX IF NOT EXISTS appointments_held_idx ON ria.appointments(hold_expires_at) WHERE status = 'held';
CREATE UNIQUE INDEX IF NOT EXISTS appointments_event_uidx ON ria.appointments(calendar_event_id) WHERE calendar_event_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Lembretes (um por consulta e tipo => impede disparo duplicado)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.reminders (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id        uuid NOT NULL,
  appointment_id   uuid NOT NULL,
  kind             text NOT NULL DEFAULT '24h',
  status           text NOT NULL CHECK (status IN ('sending','sent','delivered','read','failed','skipped_opt_out','skipped_no_template','skipped_cancelled')),
  channel          text CHECK (channel IN ('template','session')),
  wa_message_id    text,
  error_code       text,
  attempts         int NOT NULL DEFAULT 1,
  claimed_at       timestamptz NOT NULL DEFAULT now(),
  finished_at      timestamptz,
  UNIQUE (appointment_id, kind),
  FOREIGN KEY (appointment_id, clinic_id) REFERENCES ria.appointments(id, clinic_id) ON DELETE CASCADE
);

-- -----------------------------------------------------------------------------
-- Atendimento humano
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.handoffs (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id          uuid NOT NULL,
  conversation_id    uuid NOT NULL,
  patient_id         uuid NOT NULL,
  code               text NOT NULL,          -- código curto usado pela equipe (#A7K2)
  reason             text NOT NULL CHECK (reason IN ('patient_request','urgency','emergency','complaint','out_of_scope','booking_problem','technical_failure','policy','staff_takeover')),
  priority           text NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','high','urgent')),
  status             text NOT NULL DEFAULT 'open' CHECK (status IN ('open','assigned','closed')),
  assigned_staff_id  uuid,
  opened_at          timestamptz NOT NULL DEFAULT now(),
  assigned_at        timestamptz,
  closed_at          timestamptz,
  closed_by          text,
  FOREIGN KEY (conversation_id, clinic_id) REFERENCES ria.conversations(id, clinic_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS handoffs_open_code_uidx ON ria.handoffs(clinic_id, code) WHERE status <> 'closed';
CREATE UNIQUE INDEX IF NOT EXISTS handoffs_one_open_per_conv_uidx ON ria.handoffs(conversation_id) WHERE status <> 'closed';

-- -----------------------------------------------------------------------------
-- Auditoria, erros, alertas e métricas
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ria.audit_events (
  id           bigserial PRIMARY KEY,
  clinic_id    uuid,
  actor_type   text NOT NULL CHECK (actor_type IN ('patient','bot','staff','system')),
  actor_id     uuid,
  action       text NOT NULL,
  entity_type  text,
  entity_id    uuid,
  details      jsonb NOT NULL DEFAULT '{}'::jsonb,   -- nunca conteúdo de mensagem
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_events_clinic_time_idx ON ria.audit_events(clinic_id, created_at);

CREATE TABLE IF NOT EXISTS ria.integration_errors (
  id             bigserial PRIMARY KEY,
  clinic_id      uuid,
  source         text NOT NULL CHECK (source IN ('whatsapp','openai','calendar','database','n8n','other')),
  workflow       text,
  node           text,
  error_code     text,
  message        text,          -- higienizada e truncada
  execution_id   text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS integration_errors_time_idx ON ria.integration_errors(created_at);

CREATE TABLE IF NOT EXISTS ria.admin_alerts (
  id          bigserial PRIMARY KEY,
  clinic_id   uuid,
  kind        text NOT NULL,
  dedup_key   text NOT NULL UNIQUE,
  message     text NOT NULL,    -- sem dados clínicos e sem telefone completo
  created_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz
);

CREATE TABLE IF NOT EXISTS ria.daily_metrics (
  clinic_id                uuid NOT NULL REFERENCES ria.clinics(id) ON DELETE CASCADE,
  day                      date NOT NULL,
  messages_in              int NOT NULL DEFAULT 0,
  audio_messages           int NOT NULL DEFAULT 0,
  patients_served          int NOT NULL DEFAULT 0,
  new_patients             int NOT NULL DEFAULT 0,
  appointments_confirmed   int NOT NULL DEFAULT 0,
  appointments_cancelled   int NOT NULL DEFAULT 0,
  appointments_rescheduled int NOT NULL DEFAULT 0,
  handoffs                 int NOT NULL DEFAULT 0,
  reminders_sent           int NOT NULL DEFAULT 0,
  integration_errors       int NOT NULL DEFAULT 0,
  delivery_failures        int NOT NULL DEFAULT 0,
  computed_at              timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (clinic_id, day)
);

INSERT INTO ria.schema_migrations(version) VALUES ('001_estrutura') ON CONFLICT DO NOTHING;

-- >>> database/migrations/002_funcoes.sql
-- =============================================================================
-- Recepcionista IA — Migração 002: funções de negócio
--
-- Convenção:
--   ria.fn_*   funções internas tipadas
--   ria.api_*  "API" chamada pelo n8n: recebe UM jsonb e devolve UM jsonb.
--              O n8n sempre executa:  SELECT ria.api_x($1::jsonb) AS result
--              com o parâmetro enviado por "Query Parameters" (SQL parametrizado,
--              sem concatenação de strings).
-- Todas as funções que recebem clinic_id/patient_id filtram por eles: um
-- paciente nunca enxerga ou altera dados de outro paciente ou de outra clínica.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Utilitários
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.setting(p_key text, p_default jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT value FROM ria.app_settings WHERE key = p_key), p_default)
$$;

CREATE OR REPLACE FUNCTION ria.audit(p_clinic uuid, p_actor_type text, p_actor_id uuid, p_action text,
                                     p_entity_type text, p_entity_id uuid, p_details jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO ria.audit_events(clinic_id, actor_type, actor_id, action, entity_type, entity_id, details)
  VALUES (p_clinic, p_actor_type, p_actor_id, p_action, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb))
$$;

-- Mascara sequências longas de dígitos (telefones, CPF) e e-mails em textos de log
CREATE OR REPLACE FUNCTION ria.sanitize_log(p_text text, p_max int DEFAULT 500)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT left(
    regexp_replace(
      regexp_replace(coalesce(p_text, ''), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]', 'g'),
      '\+?\d[\d\s().-]{7,}\d', '[numero]', 'g'),
    p_max)
$$;

-- Mascara telefone para alertas: 5511987654321 -> ****4321
CREATE OR REPLACE FUNCTION ria.mask_phone(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p IS NULL THEN NULL ELSE '****' || right(p, 4) END
$$;

-- Rótulo amigável em pt-BR: "qui, 13/11 às 09:00"
CREATE OR REPLACE FUNCTION ria.slot_label(p_ts timestamptz, p_tz text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT (ARRAY['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow FROM (p_ts AT TIME ZONE p_tz))::int + 1]
         || ', ' || to_char(p_ts AT TIME ZONE p_tz, 'DD/MM') || ' às ' || to_char(p_ts AT TIME ZONE p_tz, 'HH24:MI')
$$;

-- Rótulo curto para botões do WhatsApp (máx. 20 caracteres): "qui 13/11 09:00"
CREATE OR REPLACE FUNCTION ria.slot_short_label(p_ts timestamptz, p_tz text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT (ARRAY['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow FROM (p_ts AT TIME ZONE p_tz))::int + 1]
         || ' ' || to_char(p_ts AT TIME ZONE p_tz, 'DD/MM HH24:MI')
$$;

-- Código curto para atendimento humano (sem caracteres ambíguos)
CREATE OR REPLACE FUNCTION ria.short_code(p_len int DEFAULT 4) RETURNS text LANGUAGE sql VOLATILE AS $$
  SELECT string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
  FROM generate_series(1, p_len)
$$;

-- Valida fuso horário da clínica
CREATE OR REPLACE FUNCTION ria.trg_clinic_validate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) THEN
    RAISE EXCEPTION 'Fuso horário inválido: %', NEW.timezone USING ERRCODE = '22023';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS clinic_validate ON ria.clinics;
CREATE TRIGGER clinic_validate BEFORE INSERT OR UPDATE ON ria.clinics
  FOR EACH ROW EXECUTE FUNCTION ria.trg_clinic_validate();

-- -----------------------------------------------------------------------------
-- Horário de funcionamento: texto resumido, aberto agora?, próxima abertura
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.fn_hours_summary(p_clinic uuid)
RETURNS text LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT weekday,
           string_agg(to_char(open_time,'HH24:MI') || '–' || to_char(close_time,'HH24:MI'), ' e ' ORDER BY open_time) AS faixas
    FROM ria.business_hours WHERE clinic_id = p_clinic GROUP BY weekday
  )
  SELECT coalesce(string_agg(
           (ARRAY['domingo','segunda','terça','quarta','quinta','sexta','sábado'])[weekday + 1] || ': ' || faixas,
           '; ' ORDER BY CASE WHEN weekday = 0 THEN 7 ELSE weekday END), 'horário não cadastrado')
  FROM d
$$;

CREATE OR REPLACE FUNCTION ria.fn_is_open(p_clinic uuid, p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ria.clinics c
    JOIN ria.business_hours bh ON bh.clinic_id = c.id
    WHERE c.id = p_clinic
      AND bh.weekday = extract(dow FROM (p_at AT TIME ZONE c.timezone))
      AND (p_at AT TIME ZONE c.timezone)::time >= bh.open_time
      AND (p_at AT TIME ZONE c.timezone)::time <  bh.close_time
      AND NOT EXISTS (SELECT 1 FROM ria.holidays h WHERE h.clinic_id = c.id AND h.day = (p_at AT TIME ZONE c.timezone)::date)
  )
$$;

CREATE OR REPLACE FUNCTION ria.fn_next_opening(p_clinic uuid, p_at timestamptz DEFAULT now())
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT min((d::date + bh.open_time) AT TIME ZONE c.timezone)
  FROM ria.clinics c
  CROSS JOIN generate_series((p_at AT TIME ZONE c.timezone)::date, (p_at AT TIME ZONE c.timezone)::date + 14, interval '1 day') d
  JOIN ria.business_hours bh ON bh.clinic_id = c.id AND bh.weekday = extract(dow FROM d)
  WHERE c.id = p_clinic
    AND ((d::date + bh.open_time) AT TIME ZONE c.timezone) > p_at
    AND NOT EXISTS (SELECT 1 FROM ria.holidays h WHERE h.clinic_id = c.id AND h.day = d::date)
$$;

-- -----------------------------------------------------------------------------
-- DISPONIBILIDADE REAL
-- Gera horários livres respeitando: funcionamento da clínica, jornada do
-- profissional, almoço (lacuna entre faixas), feriados, bloqueios, duração do
-- serviço, intervalo entre pacientes, antecedência mínima, limite máximo de
-- dias, agendamentos no banco (inclusive reservas temporárias) e os períodos
-- ocupados informados pela agenda externa (p_busy = Google FreeBusy normalizado:
-- [{"professional_id": "...", "start": "...", "end": "..."}]).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.fn_available_slots(
  p_clinic_id uuid, p_service_id uuid, p_professional_ids uuid[],
  p_from timestamptz, p_to timestamptz, p_busy jsonb DEFAULT '[]'::jsonb, p_now timestamptz DEFAULT now())
RETURNS TABLE(professional_id uuid, starts_at timestamptz, ends_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH c AS (
    SELECT * FROM ria.clinics WHERE id = p_clinic_id AND status = 'active'
  ), s AS (
    SELECT * FROM ria.services WHERE id = p_service_id AND clinic_id = p_clinic_id AND active
  ), pros AS (
    SELECT p.id FROM ria.professionals p
    JOIN ria.professional_services ps ON ps.professional_id = p.id AND ps.service_id = p_service_id
    WHERE p.clinic_id = p_clinic_id AND p.active
      AND (p_professional_ids IS NULL OR cardinality(p_professional_ids) = 0 OR p.id = ANY(p_professional_ids))
  ), b AS (
    SELECT greatest(p_from, p_now + make_interval(mins => c.min_booking_notice_minutes)) AS lo,
           least(p_to, p_now + make_interval(days => c.max_booking_days_ahead)) AS hi,
           c.timezone AS tz, c.slot_step_minutes AS step
    FROM c
  ), days AS (
    SELECT d::date AS day FROM b,
      generate_series((b.lo AT TIME ZONE b.tz)::date, (b.hi AT TIME ZONE b.tz)::date, interval '1 day') d
    WHERE b.hi > b.lo
  ), clinic_windows AS (
    SELECT days.day, bh.open_time, bh.close_time
    FROM days JOIN ria.business_hours bh
      ON bh.clinic_id = p_clinic_id AND bh.weekday = extract(dow FROM days.day)
    WHERE NOT EXISTS (SELECT 1 FROM ria.holidays h WHERE h.clinic_id = p_clinic_id AND h.day = days.day)
  ), prof_windows AS (
    SELECT pr.id AS professional_id, cw.day,
           CASE WHEN ph.id IS NULL THEN cw.open_time  ELSE greatest(cw.open_time,  ph.start_time) END AS w_start,
           CASE WHEN ph.id IS NULL THEN cw.close_time ELSE least(cw.close_time,    ph.end_time)   END AS w_end
    FROM pros pr CROSS JOIN clinic_windows cw
    LEFT JOIN ria.professional_hours ph
      ON ph.professional_id = pr.id AND ph.weekday = extract(dow FROM cw.day)
    WHERE ph.id IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM ria.professional_hours x WHERE x.professional_id = pr.id)
  ), cand AS (
    SELECT pw.professional_id, (ts AT TIME ZONE b.tz) AS st
    FROM prof_windows pw CROSS JOIN b CROSS JOIN s,
         generate_series(pw.day + pw.w_start,
                         pw.day + pw.w_end - make_interval(mins => s.duration_minutes),
                         make_interval(mins => b.step)) ts
    WHERE pw.w_end > pw.w_start
  ), busy AS (
    SELECT (e->>'professional_id')::uuid AS pid,
           tstzrange((e->>'start')::timestamptz, (e->>'end')::timestamptz, '[)') AS r
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_busy) = 'array' THEN p_busy ELSE '[]'::jsonb END) e
    WHERE (e->>'end')::timestamptz > (e->>'start')::timestamptz
  )
  SELECT cand.professional_id, cand.st, cand.st + make_interval(mins => s.duration_minutes)
  FROM cand CROSS JOIN s CROSS JOIN b
  WHERE cand.st >= b.lo AND cand.st <= b.hi
    AND NOT EXISTS (
      SELECT 1 FROM ria.schedule_blocks sb
      WHERE sb.clinic_id = p_clinic_id
        AND (sb.professional_id IS NULL OR sb.professional_id = cand.professional_id)
        AND tstzrange(sb.starts_at, sb.ends_at, '[)') &&
            tstzrange(cand.st, cand.st + make_interval(mins => s.duration_minutes), '[)'))
    AND NOT EXISTS (
      SELECT 1 FROM ria.appointments a
      WHERE a.professional_id = cand.professional_id
        AND a.status IN ('held','confirmed','cancel_requested')
        AND tstzrange(a.starts_at, a.block_until, '[)') &&
            tstzrange(cand.st, cand.st + make_interval(mins => s.duration_minutes + s.buffer_after_minutes), '[)'))
    AND NOT EXISTS (
      SELECT 1 FROM busy
      WHERE busy.pid = cand.professional_id
        AND busy.r && tstzrange(cand.st, cand.st + make_interval(mins => s.duration_minutes + s.buffer_after_minutes), '[)'))
  ORDER BY cand.st, cand.professional_id
$$;

-- -----------------------------------------------------------------------------
-- Contexto da mensagem recebida: dedup + paciente + conversa + configuração
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.fn_clinic_public(p_clinic uuid, p_now timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id', c.id, 'slug', c.slug, 'name', c.name, 'address', c.address_line,
    'city', c.city, 'state', c.state, 'maps_url', c.maps_url,
    'latitude', c.latitude, 'longitude', c.longitude, 'phone_display', c.phone_display,
    'timezone', c.timezone, 'calendar_provider', c.calendar_provider,
    'external_calendar_base_url', c.external_calendar_base_url,
    'whatsapp_phone_number_id', c.whatsapp_phone_number_id,
    'messages', c.messages,
    'hours_summary', ria.fn_hours_summary(c.id),
    'is_open_now', ria.fn_is_open(c.id, p_now),
    'next_opening', ria.fn_next_opening(c.id, p_now),
    'next_opening_label', ria.slot_label(ria.fn_next_opening(c.id, p_now), c.timezone),
    'now_local', to_char(p_now AT TIME ZONE c.timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'today_local', to_char(p_now AT TIME ZONE c.timezone, 'YYYY-MM-DD'),
    'weekday_local', (ARRAY['domingo','segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado'])[extract(dow FROM p_now AT TIME ZONE c.timezone)::int + 1],
    'policies', jsonb_build_object(
      'min_booking_notice_minutes', c.min_booking_notice_minutes,
      'max_booking_days_ahead', c.max_booking_days_ahead,
      'cancel_min_notice_hours', c.cancel_min_notice_hours,
      'late_cancel_action', c.late_cancel_action,
      'reschedule_min_notice_hours', c.reschedule_min_notice_hours,
      'offer_ttl_minutes', c.offer_ttl_minutes,
      'offer_max_options', c.offer_max_options),
    'reminder_template', c.reminder_template,
    'staff_alert_template', c.staff_alert_template
  ) FROM ria.clinics c WHERE c.id = p_clinic
$$;

CREATE OR REPLACE FUNCTION ria.fn_patient_appointments(p_clinic uuid, p_patient uuid, p_now timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'starts_at', a.starts_at, 'ends_at', a.ends_at, 'status', a.status,
      'label', ria.slot_label(a.starts_at, c.timezone),
      'short_label', ria.slot_short_label(a.starts_at, c.timezone),
      'service_id', s.id, 'service_code', s.code, 'service_name', s.name,
      'professional_id', p.id, 'professional_name', p.display_name,
      'attendance_confirmed', a.attendance_confirmed_at IS NOT NULL
    ) ORDER BY a.starts_at), '[]'::jsonb)
  FROM ria.appointments a
  JOIN ria.clinics c ON c.id = a.clinic_id
  JOIN ria.services s ON s.id = a.service_id
  JOIN ria.professionals p ON p.id = a.professional_id
  WHERE a.clinic_id = p_clinic AND a.patient_id = p_patient
    AND a.status = 'confirmed' AND a.starts_at > p_now
$$;

CREATE OR REPLACE FUNCTION ria.api_inbound_begin(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_clinic   ria.clinics%ROWTYPE;
  v_staff    ria.staff_members%ROWTYPE;
  v_patient  ria.patients%ROWTYPE;
  v_conv     ria.conversations%ROWTYPE;
  v_from     text := regexp_replace(coalesce(p->>'from', ''), '\D', '', 'g');
  v_msg_id   text := p->>'wa_message_id';
  v_ts       timestamptz := CASE WHEN coalesce(p->>'wa_timestamp','') ~ '^\d+$' THEN to_timestamp((p->>'wa_timestamp')::bigint) END;
  v_now      timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_inserted int;
  v_is_new   boolean := false;
  v_offer    jsonb;
  v_profile  text := left(nullif(trim(p->>'profile_name'), ''), 80);
BEGIN
  IF v_msg_id IS NULL OR v_from !~ '^[0-9]{8,15}$' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  SELECT * INTO v_clinic FROM ria.clinics
   WHERE whatsapp_phone_number_id = p->>'phone_number_id' AND status = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unknown_clinic');
  END IF;

  -- Deduplicação pelo ID da Meta (reentregas do webhook não geram nova resposta)
  INSERT INTO ria.processed_messages(wa_message_id, clinic_id, msg_type, wa_timestamp, received_at)
  VALUES (v_msg_id, v_clinic.id, coalesce(p->>'msg_type', 'unknown'), v_ts, v_now)
  ON CONFLICT (wa_message_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted = 0 THEN
    RETURN jsonb_build_object('status', 'duplicate', 'clinic_id', v_clinic.id);
  END IF;

  -- Mensagem de alguém da equipe => comandos de atendimento humano
  SELECT * INTO v_staff FROM ria.staff_members WHERE clinic_id = v_clinic.id AND wa_id = v_from AND active;
  IF FOUND THEN
    UPDATE ria.staff_members SET last_inbound_at = v_now WHERE id = v_staff.id;
    UPDATE ria.processed_messages SET staff_id = v_staff.id WHERE wa_message_id = v_msg_id;
    RETURN jsonb_build_object(
      'status', 'staff',
      'clinic', ria.fn_clinic_public(v_clinic.id, v_now),
      'settings', ria.fn_settings(),
      'staff', jsonb_build_object('id', v_staff.id, 'name', v_staff.name, 'wa_id', v_staff.wa_id, 'role', v_staff.role));
  END IF;

  -- Paciente: cadastro automático com dados mínimos
  INSERT INTO ria.patients(clinic_id, wa_id, whatsapp_profile_name, last_inbound_at, first_contact_at)
  VALUES (v_clinic.id, v_from, v_profile, v_now, v_now)
  ON CONFLICT (clinic_id, wa_id) DO NOTHING
  RETURNING * INTO v_patient;
  IF FOUND THEN
    v_is_new := true;
    PERFORM ria.audit(v_clinic.id, 'system', v_patient.id, 'patient_created', 'patient', v_patient.id, '{}'::jsonb);
  ELSE
    UPDATE ria.patients SET last_inbound_at = v_now,
           whatsapp_profile_name = coalesce(v_profile, whatsapp_profile_name), updated_at = v_now
     WHERE clinic_id = v_clinic.id AND wa_id = v_from
    RETURNING * INTO v_patient;
  END IF;
  UPDATE ria.processed_messages SET patient_id = v_patient.id WHERE wa_message_id = v_msg_id;

  -- Conversa (uma por paciente) com bloqueio de linha para serializar o estado
  INSERT INTO ria.conversations(clinic_id, patient_id) VALUES (v_clinic.id, v_patient.id)
  ON CONFLICT (clinic_id, patient_id) DO NOTHING;
  SELECT * INTO v_conv FROM ria.conversations
   WHERE clinic_id = v_clinic.id AND patient_id = v_patient.id FOR UPDATE;

  -- Devolução automática ao robô após inatividade humana
  IF v_conv.mode = 'HUMAN'
     AND coalesce(v_conv.human_last_activity_at, v_conv.human_since) < v_now - make_interval(mins => v_clinic.human_timeout_minutes) THEN
    UPDATE ria.handoffs SET status = 'closed', closed_at = v_now, closed_by = 'timeout'
     WHERE conversation_id = v_conv.id AND status <> 'closed';
    UPDATE ria.conversations SET mode = 'BOT', state = 'idle', context = '{}'::jsonb, human_since = NULL,
           assigned_staff_id = NULL, version = version + 1, updated_at = v_now
     WHERE id = v_conv.id RETURNING * INTO v_conv;
    PERFORM ria.audit(v_clinic.id, 'system', NULL, 'handoff_timeout_return_to_bot', 'conversation', v_conv.id, '{}'::jsonb);
  END IF;

  UPDATE ria.conversations SET last_inbound_at = v_now,
         human_last_activity_at = CASE WHEN mode = 'HUMAN' THEN human_last_activity_at ELSE human_last_activity_at END
   WHERE id = v_conv.id;

  -- Ofertas vencidas
  UPDATE ria.slot_offers SET status = 'expired'
   WHERE conversation_id = v_conv.id AND status = 'open' AND expires_at <= v_now;

  SELECT jsonb_build_object(
           'id', o.id, 'expires_at', o.expires_at, 'service_id', o.service_id, 'reschedule_of', o.reschedule_of,
           'options', (SELECT jsonb_agg(jsonb_build_object(
                          'option_id', oo.id, 'option_number', oo.option_number,
                          'professional_id', oo.professional_id, 'professional_name', pr.display_name,
                          'starts_at', oo.starts_at, 'label', ria.slot_label(oo.starts_at, v_clinic.timezone)) ORDER BY oo.option_number)
                       FROM ria.slot_offer_options oo JOIN ria.professionals pr ON pr.id = oo.professional_id
                       WHERE oo.offer_id = o.id))
    INTO v_offer
    FROM ria.slot_offers o
   WHERE o.conversation_id = v_conv.id AND o.status = 'open'
   ORDER BY o.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'status', 'ok',
    'clinic', ria.fn_clinic_public(v_clinic.id, v_now),
    'settings', ria.fn_settings(),
    'patient', jsonb_build_object(
        'id', v_patient.id, 'wa_id', v_patient.wa_id, 'is_new', v_is_new,
        'full_name', v_patient.full_name, 'profile_name', v_patient.whatsapp_profile_name,
        'first_name', split_part(coalesce(v_patient.full_name, ''), ' ', 1),
        'opted_out', v_patient.opted_out_at IS NOT NULL,
        'privacy_notice_shown', v_patient.privacy_notice_at IS NOT NULL),
    'conversation', jsonb_build_object(
        'id', v_conv.id, 'mode', v_conv.mode, 'state', v_conv.state, 'context', v_conv.context,
        'version', v_conv.version, 'ai_failures', v_conv.ai_failures, 'unknown_count', v_conv.unknown_count,
        'handoff_code', (SELECT code FROM ria.handoffs WHERE conversation_id = v_conv.id AND status <> 'closed' LIMIT 1)),
    'offer', v_offer,
    'appointments', ria.fn_patient_appointments(v_clinic.id, v_patient.id, v_now),
    'services', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'code', s.code, 'name', s.name, 'description', s.description,
                    'price_info', s.price_info, 'duration_minutes', s.duration_minutes,
                    'bookable_by_bot', s.bookable_by_bot, 'synonyms', s.synonyms) ORDER BY s.name), '[]'::jsonb)
                 FROM ria.services s WHERE s.clinic_id = v_clinic.id AND s.active),
    'professionals', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'id', pr.id, 'name', pr.display_name, 'specialty', pr.specialty,
                    'service_codes', (SELECT coalesce(jsonb_agg(s.code), '[]'::jsonb) FROM ria.professional_services ps
                                       JOIN ria.services s ON s.id = ps.service_id WHERE ps.professional_id = pr.id AND s.active))
                    ORDER BY pr.display_name), '[]'::jsonb)
                 FROM ria.professionals pr WHERE pr.clinic_id = v_clinic.id AND pr.active),
    'faqs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'question', f.question, 'answer', f.answer, 'keywords', f.keywords)), '[]'::jsonb)
             FROM ria.faqs f WHERE f.clinic_id = v_clinic.id AND f.active)
  );
END $$;

CREATE OR REPLACE FUNCTION ria.fn_settings() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb) FROM ria.app_settings
$$;

-- Finaliza o processamento da mensagem (sem conteúdo)
CREATE OR REPLACE FUNCTION ria.api_message_finish(p jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  UPDATE ria.processed_messages
     SET status = coalesce(p->>'status', 'processed'), intent = left(p->>'intent', 40),
         route = left(p->>'route', 60), error_code = left(p->>'error_code', 80), processed_at = now()
   WHERE wa_message_id = p->>'wa_message_id'
  RETURNING jsonb_build_object('ok', true)
$$;

-- Salva o estado da conversa (controle otimista por versão), finaliza o registro
-- da mensagem, registra aviso de privacidade e erros técnicos — em uma só chamada.
CREATE OR REPLACE FUNCTION ria.api_conversation_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_row ria.conversations%ROWTYPE; v_saved boolean := false; e jsonb;
BEGIN
  IF nullif(p->>'wa_message_id','') IS NOT NULL THEN
    UPDATE ria.processed_messages
       SET status = coalesce(p->>'message_status', 'processed'), intent = left(p->>'intent', 40),
           route = left(p->>'route', 60), error_code = left(p->>'error_code', 80), processed_at = now()
     WHERE wa_message_id = p->>'wa_message_id';
  END IF;

  FOR e IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'errors') = 'array' THEN p->'errors' ELSE '[]'::jsonb END) LOOP
    PERFORM ria.api_log_error(e || jsonb_build_object('clinic_id', p->>'clinic_id'));
  END LOOP;

  IF coalesce((p->>'privacy_notice')::boolean, false) AND nullif(p->>'patient_id','') IS NOT NULL THEN
    PERFORM ria.api_consent(jsonb_build_object('clinic_id', p->>'clinic_id', 'patient_id', p->>'patient_id',
                                               'kind', 'privacy_notice', 'evidence', p->>'wa_message_id'))
      WHERE EXISTS (SELECT 1 FROM ria.patients WHERE id = (p->>'patient_id')::uuid AND privacy_notice_at IS NULL);
  END IF;

  IF coalesce((p->>'injection_suspected')::boolean, false) THEN
    PERFORM ria.audit((p->>'clinic_id')::uuid, 'patient', nullif(p->>'patient_id','')::uuid, 'prompt_injection_suspected',
                      'conversation', (p->>'conversation_id')::uuid, '{}'::jsonb);
  END IF;

  IF nullif(p->>'conversation_id','') IS NOT NULL AND p ? 'state' THEN
    UPDATE ria.conversations SET
        state = coalesce(p->>'state', state),
        context = coalesce(p->'context', context),
        ai_failures = CASE WHEN (p->>'ai_failed')::boolean THEN ai_failures + 1
                           WHEN (p->>'ai_ok')::boolean THEN 0 ELSE ai_failures END,
        unknown_count = CASE WHEN (p->>'unknown')::boolean THEN unknown_count + 1
                             WHEN (p->>'understood')::boolean THEN 0 ELSE unknown_count END,
        last_bot_reply_at = CASE WHEN (p->>'replied')::boolean THEN now() ELSE last_bot_reply_at END,
        version = version + 1, updated_at = now()
     WHERE id = (p->>'conversation_id')::uuid AND clinic_id = (p->>'clinic_id')::uuid
       AND mode = 'BOT'
       AND (p->>'expected_version' IS NULL OR version = (p->>'expected_version')::int)
    RETURNING * INTO v_row;
    v_saved := FOUND;
  END IF;
  IF NOT v_saved THEN
    RETURN jsonb_build_object('saved', false, 'reason', 'version_conflict_or_human_mode');
  END IF;
  RETURN jsonb_build_object('saved', true, 'version', v_row.version, 'state', v_row.state);
END $$;

-- Registra nome informado pelo paciente (dado mínimo)
CREATE OR REPLACE FUNCTION ria.api_set_patient_name(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_name text := regexp_replace(trim(coalesce(p->>'name', '')), '\s+', ' ', 'g');
BEGIN
  IF v_name = '' THEN RETURN jsonb_build_object('ok', NULL); END IF;
  IF v_name !~ '^[[:alpha:]][[:alpha:] .''-]{1,79}$' OR array_length(regexp_split_to_array(v_name, ' '), 1) > 8 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name');
  END IF;
  -- Normaliza capitalização simples
  v_name := initcap(lower(v_name));
  SELECT string_agg(CASE WHEN w IN ('Da','De','Do','Das','Dos','E') AND ord > 1 THEN lower(w) ELSE w END, ' ' ORDER BY ord)
    INTO v_name FROM regexp_split_to_table(v_name, ' ') WITH ORDINALITY AS t(w, ord);
  UPDATE ria.patients SET full_name = v_name, name_source = 'informed', updated_at = now()
   WHERE id = (p->>'patient_id')::uuid AND clinic_id = (p->>'clinic_id')::uuid AND status = 'active';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  RETURN jsonb_build_object('ok', true, 'full_name', v_name, 'first_name', split_part(v_name, ' ', 1));
END $$;

-- -----------------------------------------------------------------------------
-- OFERTA DE HORÁRIOS
-- -----------------------------------------------------------------------------
-- Prepara a busca: valida serviço, profissionais elegíveis e janela de datas.
CREATE OR REPLACE FUNCTION ria.api_offer_prepare(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_clinic  ria.clinics%ROWTYPE;
  v_service ria.services%ROWTYPE;
  v_now     timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_today   date;
  v_from_d  date;
  v_to_d    date;
  v_ext_d   date;
  v_pros    jsonb;
BEGIN
  SELECT * INTO v_clinic FROM ria.clinics WHERE id = (p->>'clinic_id')::uuid AND status = 'active';
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'unknown_clinic'); END IF;
  v_today := (v_now AT TIME ZONE v_clinic.timezone)::date;

  SELECT * INTO v_service FROM ria.services
   WHERE clinic_id = v_clinic.id AND active
     AND (id = (nullif(p->>'service_id',''))::uuid OR code = p->>'service_code');
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'service_required'); END IF;
  IF NOT v_service.bookable_by_bot THEN
    RETURN jsonb_build_object('status', 'service_requires_human', 'service_name', v_service.name);
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.display_name,
                                               'calendar_id', pr.calendar_id, 'external_ref', pr.external_ref)), '[]'::jsonb)
    INTO v_pros
    FROM ria.professionals pr
    JOIN ria.professional_services ps ON ps.professional_id = pr.id AND ps.service_id = v_service.id
   WHERE pr.clinic_id = v_clinic.id AND pr.active
     AND (nullif(p->>'professional_id','') IS NULL OR pr.id = (p->>'professional_id')::uuid);
  IF jsonb_array_length(v_pros) = 0 THEN
    RETURN jsonb_build_object('status', 'no_professional', 'service_name', v_service.name);
  END IF;

  v_from_d := CASE WHEN coalesce(p->>'date_from','') ~ '^\d{4}-\d{2}-\d{2}$' THEN (p->>'date_from')::date ELSE v_today END;
  IF v_from_d < v_today THEN v_from_d := v_today; END IF;
  v_to_d := CASE WHEN coalesce(p->>'date_to','') ~ '^\d{4}-\d{2}-\d{2}$' THEN (p->>'date_to')::date
                 WHEN coalesce(p->>'date_from','') ~ '^\d{4}-\d{2}-\d{2}$' THEN v_from_d
                 ELSE v_from_d + 6 END;
  IF v_to_d < v_from_d THEN v_to_d := v_from_d; END IF;
  v_ext_d := least(greatest(v_to_d, v_from_d + 13), v_today + v_clinic.max_booking_days_ahead);
  IF v_to_d > v_ext_d THEN v_to_d := v_ext_d; END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'clinic_id', v_clinic.id, 'timezone', v_clinic.timezone,
    'calendar_provider', v_clinic.calendar_provider,
    'service', jsonb_build_object('id', v_service.id, 'code', v_service.code, 'name', v_service.name,
                                  'duration_minutes', v_service.duration_minutes, 'buffer_after_minutes', v_service.buffer_after_minutes),
    'professionals', v_pros,
    'window_from', (v_from_d::timestamp AT TIME ZONE v_clinic.timezone),
    'window_to',   ((v_to_d + 1)::timestamp AT TIME ZONE v_clinic.timezone),
    'search_to',   ((v_ext_d + 1)::timestamp AT TIME ZONE v_clinic.timezone),
    'out_of_range', v_from_d > v_today + v_clinic.max_booking_days_ahead
  );
END $$;

-- Cria a oferta com 2-3 horários reais e variados, válida por offer_ttl_minutes.
CREATE OR REPLACE FUNCTION ria.api_offer_create(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_clinic   ria.clinics%ROWTYPE;
  v_now      timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_conv     uuid := (p->>'conversation_id')::uuid;
  v_patient  uuid := (p->>'patient_id')::uuid;
  v_service  uuid := (p->>'service_id')::uuid;
  v_pros     uuid[];
  v_from     timestamptz := (p->>'window_from')::timestamptz;
  v_to       timestamptz := (p->>'window_to')::timestamptz;
  v_search   timestamptz := coalesce((p->>'search_to')::timestamptz, (p->>'window_to')::timestamptz);
  v_period   text := nullif(p->>'period', '');
  v_time     time := CASE WHEN coalesce(p->>'time','') ~ '^\d{1,2}:\d{2}$' THEN (p->>'time')::time END;
  v_resched  uuid := nullif(p->>'reschedule_of', '')::uuid;
  v_offer_id uuid;
  v_picked   timestamptz[] := '{}';
  v_count    int := 0;
  v_alt      boolean := false;
  v_period_relaxed boolean := false;
  v_opts     jsonb := '[]'::jsonb;
  r          record;
  v_round    int;
  v_ok       boolean;
  v_lt       time;
BEGIN
  SELECT * INTO v_clinic FROM ria.clinics WHERE id = (p->>'clinic_id')::uuid AND status = 'active';
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'unknown_clinic'); END IF;

  -- a conversa precisa pertencer ao paciente e à clínica
  PERFORM 1 FROM ria.conversations WHERE id = v_conv AND patient_id = v_patient AND clinic_id = v_clinic.id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'invalid'); END IF;

  IF v_resched IS NOT NULL THEN
    PERFORM 1 FROM ria.appointments WHERE id = v_resched AND patient_id = v_patient AND clinic_id = v_clinic.id AND status = 'confirmed';
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'invalid_reschedule'); END IF;
  END IF;

  SELECT array_agg((x->>'id')::uuid) INTO v_pros
    FROM jsonb_array_elements(coalesce(p->'professional_ids_json', '[]'::jsonb)) x;
  IF v_pros IS NULL THEN
    SELECT array_agg(x::uuid) INTO v_pros FROM jsonb_array_elements_text(coalesce(p->'professional_ids', '[]'::jsonb)) x;
  END IF;

  IF to_regclass('pg_temp._ria_slots') IS NULL THEN
    CREATE TEMP TABLE _ria_slots(professional_id uuid, starts_at timestamptz, ends_at timestamptz) ON COMMIT DROP;
  END IF;
  TRUNCATE _ria_slots;
  INSERT INTO _ria_slots
    SELECT * FROM ria.fn_available_slots(v_clinic.id, v_service, v_pros, v_from, v_search, coalesce(p->'busy', '[]'::jsonb), v_now);

  -- Se não houver nada na janela pedida, usa a janela estendida (alternativas)
  IF NOT EXISTS (SELECT 1 FROM _ria_slots WHERE starts_at < v_to) THEN
    v_alt := true;
  ELSE
    DELETE FROM _ria_slots WHERE starts_at >= v_to;
  END IF;

  -- Preferência de período: manhã (<12h), tarde (12h-18h), noite (>=18h)
  IF v_period IN ('morning','afternoon','evening') THEN
    IF EXISTS (SELECT 1 FROM _ria_slots s WHERE
         CASE v_period WHEN 'morning' THEN (s.starts_at AT TIME ZONE v_clinic.timezone)::time < '12:00'
                       WHEN 'afternoon' THEN (s.starts_at AT TIME ZONE v_clinic.timezone)::time >= '12:00' AND (s.starts_at AT TIME ZONE v_clinic.timezone)::time < '18:00'
                       ELSE (s.starts_at AT TIME ZONE v_clinic.timezone)::time >= '18:00' END) THEN
      DELETE FROM _ria_slots s WHERE NOT
         CASE v_period WHEN 'morning' THEN (s.starts_at AT TIME ZONE v_clinic.timezone)::time < '12:00'
                       WHEN 'afternoon' THEN (s.starts_at AT TIME ZONE v_clinic.timezone)::time >= '12:00' AND (s.starts_at AT TIME ZONE v_clinic.timezone)::time < '18:00'
                       ELSE (s.starts_at AT TIME ZONE v_clinic.timezone)::time >= '18:00' END;
    ELSE
      v_period_relaxed := true;
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM _ria_slots) THEN
    RETURN jsonb_build_object('status', 'no_slots', 'searched_until', v_search,
                              'hours_summary', ria.fn_hours_summary(v_clinic.id));
  END IF;

  -- Seleção variada: 1ª rodada exige >= 90 min de distância (ou outro dia);
  -- 2ª rodada completa com o que houver.
  FOR v_round IN 1..2 LOOP
    FOR r IN
      SELECT s.*, (s.starts_at AT TIME ZONE v_clinic.timezone) AS lts FROM _ria_slots s
      ORDER BY (s.starts_at AT TIME ZONE v_clinic.timezone)::date,
               CASE WHEN v_time IS NULL THEN 0
                    ELSE abs(extract(epoch FROM ((s.starts_at AT TIME ZONE v_clinic.timezone)::time - v_time))) END,
               s.starts_at, s.professional_id
    LOOP
      EXIT WHEN v_count >= v_clinic.offer_max_options;
      CONTINUE WHEN r.starts_at = ANY(v_picked);
      v_ok := true;
      IF v_round = 1 THEN
        SELECT bool_and(abs(extract(epoch FROM (r.starts_at - x))) >= 5400
                        OR (x AT TIME ZONE v_clinic.timezone)::date <> r.lts::date)
          INTO v_ok FROM unnest(v_picked) x;
        v_ok := coalesce(v_ok, true);
      END IF;
      CONTINUE WHEN NOT v_ok;
      v_picked := v_picked || r.starts_at;
      v_count := v_count + 1;
      v_opts := v_opts || jsonb_build_object('professional_id', r.professional_id, 'starts_at', r.starts_at, 'ends_at', r.ends_at);
    END LOOP;
  END LOOP;

  -- Ordena opções cronologicamente para exibição
  SELECT jsonb_agg(x ORDER BY (x->>'starts_at')::timestamptz) INTO v_opts FROM jsonb_array_elements(v_opts) x;

  UPDATE ria.slot_offers SET status = 'superseded' WHERE conversation_id = v_conv AND status = 'open';
  INSERT INTO ria.slot_offers(clinic_id, patient_id, conversation_id, service_id, reschedule_of, expires_at)
  VALUES (v_clinic.id, v_patient, v_conv, v_service, v_resched, v_now + make_interval(mins => v_clinic.offer_ttl_minutes))
  RETURNING id INTO v_offer_id;

  INSERT INTO ria.slot_offer_options(offer_id, clinic_id, option_number, professional_id, starts_at, ends_at)
  SELECT v_offer_id, v_clinic.id, ord::smallint, (x->>'professional_id')::uuid, (x->>'starts_at')::timestamptz, (x->>'ends_at')::timestamptz
  FROM jsonb_array_elements(v_opts) WITH ORDINALITY AS t(x, ord);

  PERFORM ria.audit(v_clinic.id, 'bot', NULL, 'offer_created', 'slot_offer', v_offer_id,
                    jsonb_build_object('options', jsonb_array_length(v_opts), 'alternative', v_alt));

  RETURN jsonb_build_object(
    'status', 'ok', 'offer_id', v_offer_id,
    'expires_at', v_now + make_interval(mins => v_clinic.offer_ttl_minutes),
    'alternative_dates', v_alt, 'period_relaxed', v_period_relaxed,
    'reschedule_of', v_resched,
    'options', (SELECT jsonb_agg(jsonb_build_object(
                  'option_id', oo.id, 'option_number', oo.option_number,
                  'professional_id', oo.professional_id, 'professional_name', pr.display_name,
                  'starts_at', oo.starts_at, 'ends_at', oo.ends_at,
                  'label', ria.slot_label(oo.starts_at, v_clinic.timezone),
                  'short_label', ria.slot_short_label(oo.starts_at, v_clinic.timezone)) ORDER BY oo.option_number)
                FROM ria.slot_offer_options oo JOIN ria.professionals pr ON pr.id = oo.professional_id
                WHERE oo.offer_id = v_offer_id));
END $$;

-- Resolve a escolha do paciente (número 1-3 ou ID do botão) dentro da oferta aberta
CREATE OR REPLACE FUNCTION ria.api_offer_choose(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_now timestamptz := coalesce((p->>'now')::timestamptz, now());
  r record;
BEGIN
  SELECT oo.*, o.status AS offer_status, o.expires_at, o.patient_id, o.service_id, o.reschedule_of,
         pr.calendar_id, pr.external_ref, pr.display_name AS professional_name, c.timezone, c.calendar_provider,
         s.buffer_after_minutes
    INTO r
    FROM ria.slot_offer_options oo
    JOIN ria.slot_offers o ON o.id = oo.offer_id
    JOIN ria.professionals pr ON pr.id = oo.professional_id
    JOIN ria.clinics c ON c.id = o.clinic_id
    JOIN ria.services s ON s.id = o.service_id
   WHERE o.conversation_id = (p->>'conversation_id')::uuid
     AND o.patient_id = (p->>'patient_id')::uuid
     AND ((nullif(p->>'option_id','') IS NOT NULL AND oo.id = (p->>'option_id')::uuid)
          OR (nullif(p->>'option_id','') IS NULL AND o.status = 'open' AND oo.option_number = (p->>'option_number')::int))
   ORDER BY o.created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'invalid'); END IF;
  IF r.offer_status <> 'open' OR r.expires_at <= v_now THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;
  RETURN jsonb_build_object('status', 'ok', 'option_id', r.id, 'option_number', r.option_number,
    'professional_id', r.professional_id, 'professional_name', r.professional_name,
    'calendar_id', r.calendar_id, 'external_ref', r.external_ref, 'calendar_provider', r.calendar_provider,
    'starts_at', r.starts_at, 'ends_at', r.ends_at,
    'check_from', r.starts_at, 'check_to', r.ends_at + make_interval(mins => r.buffer_after_minutes),
    'service_id', r.service_id, 'reschedule_of', r.reschedule_of,
    'label', ria.slot_label(r.starts_at, r.timezone));
END $$;

-- -----------------------------------------------------------------------------
-- RESERVA PROTEGIDA (controle de concorrência)
-- 1) trava a oferta; 2) revalida regras + ocupação recém-consultada na agenda;
-- 3) INSERT com status 'held' protegido pela restrição de exclusão GiST.
-- Dois pacientes no mesmo horário: o segundo recebe 'slot_taken'.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_reserve(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_now      timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_opt      ria.slot_offer_options%ROWTYPE;
  v_offer    ria.slot_offers%ROWTYPE;
  v_clinic   ria.clinics%ROWTYPE;
  v_service  ria.services%ROWTYPE;
  v_pro      ria.professionals%ROWTYPE;
  v_patient  ria.patients%ROWTYPE;
  v_appt_id  uuid;
  v_future   int;
BEGIN
  SELECT * INTO v_opt FROM ria.slot_offer_options WHERE id = (p->>'option_id')::uuid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'invalid'); END IF;
  SELECT * INTO v_offer FROM ria.slot_offers WHERE id = v_opt.offer_id FOR UPDATE;
  IF v_offer.patient_id <> (p->>'patient_id')::uuid OR v_offer.conversation_id <> (p->>'conversation_id')::uuid THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF v_offer.status <> 'open' OR v_offer.expires_at <= v_now THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;

  SELECT * INTO v_clinic  FROM ria.clinics WHERE id = v_offer.clinic_id;
  SELECT * INTO v_service FROM ria.services WHERE id = v_offer.service_id;
  SELECT * INTO v_pro     FROM ria.professionals WHERE id = v_opt.professional_id;
  -- serializa reservas do mesmo paciente (evita duplicidade por mensagens paralelas)
  SELECT * INTO v_patient FROM ria.patients WHERE id = v_offer.patient_id FOR UPDATE;

  -- Duplicidade: mesmo serviço já agendado no futuro (exceto a consulta sendo remarcada)
  IF EXISTS (SELECT 1 FROM ria.appointments a
              WHERE a.patient_id = v_patient.id AND a.service_id = v_service.id
                AND a.status IN ('held','confirmed') AND a.starts_at > v_now
                AND (v_offer.reschedule_of IS NULL OR a.id <> v_offer.reschedule_of)) THEN
    RETURN jsonb_build_object('status', 'patient_already_booked');
  END IF;
  SELECT count(*) INTO v_future FROM ria.appointments a
   WHERE a.patient_id = v_patient.id AND a.status IN ('held','confirmed') AND a.starts_at > v_now
     AND (v_offer.reschedule_of IS NULL OR a.id <> v_offer.reschedule_of);
  IF v_future >= v_clinic.max_future_appointments THEN
    RETURN jsonb_build_object('status', 'too_many_appointments');
  END IF;
  -- Paciente não pode ter duas consultas sobrepostas
  IF EXISTS (SELECT 1 FROM ria.appointments a
              WHERE a.patient_id = v_patient.id AND a.status IN ('held','confirmed','cancel_requested')
                AND (v_offer.reschedule_of IS NULL OR a.id <> v_offer.reschedule_of)
                AND tstzrange(a.starts_at, a.ends_at) && tstzrange(v_opt.starts_at, v_opt.ends_at)) THEN
    RETURN jsonb_build_object('status', 'patient_overlap');
  END IF;

  -- Libera reservas temporárias vencidas desse profissional
  UPDATE ria.appointments SET status = 'expired', updated_at = v_now
   WHERE professional_id = v_pro.id AND status = 'held' AND hold_expires_at <= v_now;

  -- Revalidação completa das regras + ocupação atual da agenda externa
  IF NOT EXISTS (
      SELECT 1 FROM ria.fn_available_slots(v_clinic.id, v_service.id, ARRAY[v_pro.id],
                                           v_opt.starts_at, v_opt.starts_at + interval '1 minute',
                                           coalesce(p->'busy', '[]'::jsonb), v_now) f
       WHERE f.starts_at = v_opt.starts_at AND f.professional_id = v_pro.id) THEN
    RETURN jsonb_build_object('status', 'slot_taken');
  END IF;

  BEGIN
    INSERT INTO ria.appointments(clinic_id, patient_id, professional_id, service_id, starts_at, ends_at, block_until,
                                 status, calendar_provider, calendar_id, offer_option_id, rescheduled_from_id, hold_expires_at)
    VALUES (v_clinic.id, v_patient.id, v_pro.id, v_service.id, v_opt.starts_at, v_opt.ends_at,
            v_opt.ends_at + make_interval(mins => v_service.buffer_after_minutes),
            'held', v_clinic.calendar_provider, v_pro.calendar_id, v_opt.id, v_offer.reschedule_of,
            v_now + make_interval(mins => v_clinic.hold_ttl_minutes))
    RETURNING id INTO v_appt_id;
  EXCEPTION WHEN exclusion_violation THEN
    RETURN jsonb_build_object('status', 'slot_taken');
  END;

  UPDATE ria.slot_offers SET status = 'used' WHERE id = v_offer.id;
  PERFORM ria.audit(v_clinic.id, 'patient', v_patient.id, 'appointment_held', 'appointment', v_appt_id, '{}'::jsonb);

  RETURN jsonb_build_object(
    'status', 'held',
    'appointment_id', v_appt_id,
    'calendar_event_id', replace(v_appt_id::text, '-', ''),   -- ID determinístico => criação idempotente no Google
    'calendar_provider', v_clinic.calendar_provider,
    'calendar_id', v_pro.calendar_id, 'external_ref', v_pro.external_ref,
    'starts_at', v_opt.starts_at, 'ends_at', v_opt.ends_at, 'timezone', v_clinic.timezone,
    'label', ria.slot_label(v_opt.starts_at, v_clinic.timezone),
    'professional_name', v_pro.display_name, 'service_name', v_service.name, 'service_code', v_service.code,
    'patient_name', coalesce(v_patient.full_name, v_patient.whatsapp_profile_name, 'Paciente'),
    'patient_phone', '+' || v_patient.wa_id,
    'reschedule_of', v_offer.reschedule_of,
    'clinic_name', v_clinic.name);
END $$;

-- Confirma após a criação do evento na agenda. Se a reserva expirou nesse meio
-- tempo, tenta reativar (a restrição de exclusão ainda protege).
CREATE OR REPLACE FUNCTION ria.api_appointment_confirm(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_now   timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_appt  ria.appointments%ROWTYPE;
  v_old   ria.appointments%ROWTYPE;
  v_old_json jsonb := NULL;
BEGIN
  SELECT * INTO v_appt FROM ria.appointments WHERE id = (p->>'appointment_id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_appt.status = 'confirmed' THEN
    RETURN jsonb_build_object('status', 'confirmed', 'appointment_id', v_appt.id, 'already', true);
  END IF;
  IF v_appt.status NOT IN ('held','expired') THEN
    RETURN jsonb_build_object('status', 'hold_lost');
  END IF;
  BEGIN
    UPDATE ria.appointments SET status = 'confirmed', sync_status = 'synced',
           calendar_event_id = nullif(p->>'calendar_event_id', ''),
           calendar_id = coalesce(nullif(p->>'calendar_id', ''), calendar_id),
           hold_expires_at = NULL, sync_checked_at = v_now, updated_at = v_now
     WHERE id = v_appt.id;
  EXCEPTION WHEN exclusion_violation THEN
    UPDATE ria.appointments SET status = 'expired', updated_at = v_now WHERE id = v_appt.id;
    RETURN jsonb_build_object('status', 'hold_lost');
  END;

  -- Registro de autorização: paciente agendou pelo WhatsApp e foi informado dos lembretes
  UPDATE ria.patients SET reminders_opt_in = true, updated_at = v_now
   WHERE id = v_appt.patient_id AND NOT reminders_opt_in AND opted_out_at IS NULL;
  IF FOUND THEN
    INSERT INTO ria.consent_events(clinic_id, patient_id, kind, source, evidence)
    VALUES (v_appt.clinic_id, v_appt.patient_id, 'reminders_opt_in', 'booking', v_appt.id::text);
  END IF;

  -- Remarcação: a consulta antiga só é liberada DEPOIS que a nova foi confirmada
  IF v_appt.rescheduled_from_id IS NOT NULL THEN
    UPDATE ria.appointments SET status = 'cancel_requested', cancel_reason = 'rescheduled',
           cancelled_by = 'patient', rescheduled_to_id = v_appt.id, updated_at = v_now
     WHERE id = v_appt.rescheduled_from_id AND status = 'confirmed'
    RETURNING * INTO v_old;
    IF FOUND THEN
      v_old_json := jsonb_build_object('appointment_id', v_old.id, 'calendar_id', v_old.calendar_id,
                                       'calendar_event_id', v_old.calendar_event_id, 'calendar_provider', v_old.calendar_provider);
    END IF;
  END IF;

  PERFORM ria.audit(v_appt.clinic_id, 'bot', NULL,
                    CASE WHEN v_appt.rescheduled_from_id IS NULL THEN 'appointment_confirmed' ELSE 'appointment_rescheduled' END,
                    'appointment', v_appt.id, jsonb_build_object('rescheduled_from', v_appt.rescheduled_from_id));
  RETURN jsonb_build_object('status', 'confirmed', 'appointment_id', v_appt.id, 'old_appointment', v_old_json);
END $$;

-- Libera reserva (falha na agenda externa, abandono, conflito)
CREATE OR REPLACE FUNCTION ria.api_appointment_release(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE ria.appointments SET status = 'expired', cancel_reason = left(coalesce(p->>'reason', 'released'), 80), updated_at = now()
   WHERE id = (p->>'appointment_id')::uuid AND status = 'held';
  IF FOUND THEN
    PERFORM ria.audit(clinic_id, 'system', NULL, 'appointment_hold_released', 'appointment', id,
                      jsonb_build_object('reason', p->>'reason'))
       FROM ria.appointments WHERE id = (p->>'appointment_id')::uuid;
  END IF;
  RETURN jsonb_build_object('ok', FOUND);
END $$;

-- -----------------------------------------------------------------------------
-- CONSULTAS DO PACIENTE / CANCELAMENTO / REMARCAÇÃO
-- Sempre filtrando por patient_id: impede alterar consultas de terceiros.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_patient_appointments(p jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('appointments',
    ria.fn_patient_appointments((p->>'clinic_id')::uuid, (p->>'patient_id')::uuid, coalesce((p->>'now')::timestamptz, now())))
$$;

CREATE OR REPLACE FUNCTION ria.fn_own_appointment(p_clinic uuid, p_patient uuid, p_appt uuid)
RETURNS ria.appointments LANGUAGE sql STABLE AS $$
  SELECT * FROM ria.appointments WHERE id = p_appt AND clinic_id = p_clinic AND patient_id = p_patient
$$;

CREATE OR REPLACE FUNCTION ria.api_cancel_check(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_now  timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_a    ria.appointments%ROWTYPE;
  v_c    ria.clinics%ROWTYPE;
  v_late boolean;
BEGIN
  v_a := ria.fn_own_appointment((p->>'clinic_id')::uuid, (p->>'patient_id')::uuid, (p->>'appointment_id')::uuid);
  IF v_a.id IS NULL OR v_a.status <> 'confirmed' OR v_a.starts_at <= v_now THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  SELECT * INTO v_c FROM ria.clinics WHERE id = v_a.clinic_id;
  v_late := v_a.starts_at < v_now + make_interval(hours => v_c.cancel_min_notice_hours);
  RETURN jsonb_build_object(
    'status', CASE WHEN v_late AND v_c.late_cancel_action = 'handoff' THEN 'policy_handoff' ELSE 'ok' END,
    'late', v_late, 'appointment_id', v_a.id,
    'label', ria.slot_label(v_a.starts_at, v_c.timezone),
    'cancel_min_notice_hours', v_c.cancel_min_notice_hours);
END $$;

CREATE OR REPLACE FUNCTION ria.api_cancel_request(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_chk jsonb := ria.api_cancel_check(p);
  v_a   ria.appointments%ROWTYPE;
BEGIN
  IF v_chk->>'status' <> 'ok' THEN RETURN v_chk; END IF;
  UPDATE ria.appointments SET status = 'cancel_requested', cancelled_by = coalesce(p->>'actor', 'patient'),
         cancel_reason = left(coalesce(p->>'reason', 'patient_request'), 80), updated_at = now()
   WHERE id = (v_chk->>'appointment_id')::uuid AND status = 'confirmed'
  RETURNING * INTO v_a;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  RETURN v_chk || jsonb_build_object('status', 'ok', 'calendar_provider', v_a.calendar_provider,
                                     'calendar_id', v_a.calendar_id, 'calendar_event_id', v_a.calendar_event_id);
END $$;

-- Conclui cancelamento depois da remoção na agenda (ou marca pendente p/ reconciliação)
CREATE OR REPLACE FUNCTION ria.api_cancel_finalize(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_a ria.appointments%ROWTYPE;
BEGIN
  UPDATE ria.appointments
     SET status = 'cancelled', cancelled_at = now(), updated_at = now(),
         sync_status = CASE WHEN coalesce((p->>'calendar_ok')::boolean, false) THEN 'deleted' ELSE 'delete_pending' END
   WHERE id = (p->>'appointment_id')::uuid AND status = 'cancel_requested'
  RETURNING * INTO v_a;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  -- lembrete ainda não enviado não deve sair
  UPDATE ria.reminders SET status = 'skipped_cancelled', finished_at = now()
   WHERE appointment_id = v_a.id AND status = 'sending';
  PERFORM ria.audit(v_a.clinic_id, CASE WHEN v_a.cancelled_by = 'patient' THEN 'patient' ELSE 'system' END, v_a.patient_id,
                    CASE WHEN v_a.cancel_reason = 'rescheduled' THEN 'appointment_replaced' ELSE 'appointment_cancelled' END,
                    'appointment', v_a.id, jsonb_build_object('calendar_ok', p->'calendar_ok'));
  RETURN jsonb_build_object('status', 'cancelled', 'sync_status', v_a.sync_status);
END $$;

-- Desfaz o pedido de cancelamento (falha na agenda): consulta segue válida
CREATE OR REPLACE FUNCTION ria.api_cancel_revert(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE ria.appointments SET status = 'confirmed', cancelled_by = NULL, cancel_reason = NULL, updated_at = now()
   WHERE id = (p->>'appointment_id')::uuid AND status = 'cancel_requested' AND rescheduled_to_id IS NULL;
  RETURN jsonb_build_object('ok', FOUND);
END $$;

CREATE OR REPLACE FUNCTION ria.api_reschedule_check(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_now timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_a   ria.appointments%ROWTYPE;
  v_c   ria.clinics%ROWTYPE;
  v_s   ria.services%ROWTYPE;
BEGIN
  v_a := ria.fn_own_appointment((p->>'clinic_id')::uuid, (p->>'patient_id')::uuid, (p->>'appointment_id')::uuid);
  IF v_a.id IS NULL OR v_a.status <> 'confirmed' OR v_a.starts_at <= v_now THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  SELECT * INTO v_c FROM ria.clinics WHERE id = v_a.clinic_id;
  SELECT * INTO v_s FROM ria.services WHERE id = v_a.service_id;
  IF v_a.starts_at < v_now + make_interval(hours => v_c.reschedule_min_notice_hours) THEN
    RETURN jsonb_build_object('status', 'policy_handoff', 'label', ria.slot_label(v_a.starts_at, v_c.timezone),
                              'reschedule_min_notice_hours', v_c.reschedule_min_notice_hours);
  END IF;
  RETURN jsonb_build_object('status', 'ok', 'appointment_id', v_a.id, 'service_id', v_a.service_id,
                            'service_code', v_s.code, 'professional_id', v_a.professional_id,
                            'label', ria.slot_label(v_a.starts_at, v_c.timezone));
END $$;

CREATE OR REPLACE FUNCTION ria.api_attendance_confirm(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_a ria.appointments%ROWTYPE; v_c ria.clinics%ROWTYPE;
BEGIN
  v_a := ria.fn_own_appointment((p->>'clinic_id')::uuid, (p->>'patient_id')::uuid, (p->>'appointment_id')::uuid);
  IF v_a.id IS NULL OR v_a.status <> 'confirmed' OR v_a.starts_at <= now() THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  UPDATE ria.appointments SET attendance_confirmed_at = coalesce(attendance_confirmed_at, now()), updated_at = now() WHERE id = v_a.id;
  SELECT * INTO v_c FROM ria.clinics WHERE id = v_a.clinic_id;
  PERFORM ria.audit(v_a.clinic_id, 'patient', v_a.patient_id, 'attendance_confirmed', 'appointment', v_a.id, '{}'::jsonb);
  RETURN jsonb_build_object('status', 'ok', 'label', ria.slot_label(v_a.starts_at, v_c.timezone));
END $$;

-- -----------------------------------------------------------------------------
-- OPT-OUT / AVISO DE PRIVACIDADE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_consent(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_kind text := p->>'kind'; v_pid uuid := (p->>'patient_id')::uuid; v_cid uuid := (p->>'clinic_id')::uuid;
BEGIN
  IF v_kind = 'opt_out' THEN
    UPDATE ria.patients SET opted_out_at = now(), reminders_opt_in = false, updated_at = now() WHERE id = v_pid AND clinic_id = v_cid;
  ELSIF v_kind = 'opt_in_again' THEN
    UPDATE ria.patients SET opted_out_at = NULL, reminders_opt_in = true, updated_at = now() WHERE id = v_pid AND clinic_id = v_cid;
  ELSIF v_kind = 'privacy_notice' THEN
    UPDATE ria.patients SET privacy_notice_at = coalesce(privacy_notice_at, now()) WHERE id = v_pid AND clinic_id = v_cid;
  ELSE
    RETURN jsonb_build_object('ok', false);
  END IF;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
  INSERT INTO ria.consent_events(clinic_id, patient_id, kind, source, evidence)
  VALUES (v_cid, v_pid, v_kind, coalesce(p->>'source', 'whatsapp_inbound'), left(p->>'evidence', 120));
  RETURN jsonb_build_object('ok', true);
END $$;

-- -----------------------------------------------------------------------------
-- ATENDIMENTO HUMANO (estados BOT / HUMAN)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_handoff_open(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_conv   ria.conversations%ROWTYPE;
  v_h      ria.handoffs%ROWTYPE;
  v_code   text;
  v_try    int := 0;
  v_now    timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_pat    ria.patients%ROWTYPE;
BEGIN
  SELECT * INTO v_conv FROM ria.conversations
   WHERE id = (p->>'conversation_id')::uuid AND clinic_id = (p->>'clinic_id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  SELECT * INTO v_pat FROM ria.patients WHERE id = v_conv.patient_id;

  SELECT * INTO v_h FROM ria.handoffs WHERE conversation_id = v_conv.id AND status <> 'closed';
  IF NOT FOUND THEN
    LOOP
      v_try := v_try + 1;
      v_code := ria.short_code(4);
      BEGIN
        INSERT INTO ria.handoffs(clinic_id, conversation_id, patient_id, code, reason, priority)
        VALUES (v_conv.clinic_id, v_conv.id, v_conv.patient_id, v_code,
                coalesce(p->>'reason', 'patient_request'), coalesce(p->>'priority', 'normal'))
        RETURNING * INTO v_h;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        IF v_try > 20 THEN RAISE; END IF;
      END;
    END LOOP;
  ELSIF coalesce(p->>'priority','normal') = 'urgent' AND v_h.priority <> 'urgent' THEN
    UPDATE ria.handoffs SET priority = 'urgent', reason = coalesce(p->>'reason', reason) WHERE id = v_h.id RETURNING * INTO v_h;
  END IF;

  UPDATE ria.conversations SET mode = 'HUMAN', state = 'idle', context = '{}'::jsonb,
         human_since = coalesce(human_since, v_now), human_last_activity_at = v_now,
         version = version + 1, updated_at = v_now
   WHERE id = v_conv.id;
  UPDATE ria.slot_offers SET status = 'superseded' WHERE conversation_id = v_conv.id AND status = 'open';

  PERFORM ria.audit(v_conv.clinic_id, 'bot', NULL, 'handoff_opened', 'handoff', v_h.id,
                    jsonb_build_object('reason', v_h.reason, 'priority', v_h.priority));

  RETURN jsonb_build_object(
    'status', 'ok', 'handoff_id', v_h.id, 'code', v_h.code, 'reason', v_h.reason, 'priority', v_h.priority,
    'patient_name', coalesce(v_pat.full_name, v_pat.whatsapp_profile_name, 'Paciente'),
    'patient_phone_masked', ria.mask_phone(v_pat.wa_id),
    'patient_wa_id', v_pat.wa_id,
    'is_open_now', ria.fn_is_open(v_conv.clinic_id, v_now),
    'next_opening_label', ria.slot_label(ria.fn_next_opening(v_conv.clinic_id, v_now), (SELECT timezone FROM ria.clinics WHERE id = v_conv.clinic_id)),
    'staff', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'id', s.id, 'name', s.name, 'wa_id', s.wa_id,
                'in_window', s.last_inbound_at IS NOT NULL AND s.last_inbound_at > v_now - interval '23 hours 50 minutes')), '[]'::jsonb)
              FROM ria.staff_members s WHERE s.clinic_id = v_conv.clinic_id AND s.active AND s.receives_handoffs));
END $$;

-- Comandos da equipe: assumir / devolver / responder / fila
CREATE OR REPLACE FUNCTION ria.api_handoff_action(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_clinic uuid := (p->>'clinic_id')::uuid;
  v_staff  ria.staff_members%ROWTYPE;
  v_h      ria.handoffs%ROWTYPE;
  v_pat    ria.patients%ROWTYPE;
  v_action text := p->>'action';
  v_code   text := upper(regexp_replace(coalesce(p->>'code', ''), '[^A-Za-z0-9]', '', 'g'));
  v_now    timestamptz := now();
BEGIN
  SELECT * INTO v_staff FROM ria.staff_members
   WHERE clinic_id = v_clinic AND active
     AND (id = nullif(p->>'staff_id','')::uuid OR (nullif(p->>'staff_id','') IS NULL AND role = 'admin' AND (p->>'via') = 'admin_api'));
  IF NOT FOUND AND coalesce(p->>'via','') <> 'admin_api' THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;

  IF v_action = 'list' THEN
    RETURN jsonb_build_object('status', 'ok', 'handoffs', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'code', h.code, 'reason', h.reason, 'priority', h.priority, 'status', h.status,
               'patient_name', coalesce(pt.full_name, pt.whatsapp_profile_name, 'Paciente'),
               'opened_at', to_char(h.opened_at AT TIME ZONE c.timezone, 'DD/MM HH24:MI'),
               'assigned_to', st.name) ORDER BY h.opened_at), '[]'::jsonb)
        FROM ria.handoffs h JOIN ria.patients pt ON pt.id = h.patient_id
        JOIN ria.clinics c ON c.id = h.clinic_id
        LEFT JOIN ria.staff_members st ON st.id = h.assigned_staff_id
       WHERE h.clinic_id = v_clinic AND h.status <> 'closed'));
  END IF;

  IF v_action = 'takeover' THEN
    -- Equipe assume uma conversa que estava com o robô (sem pedido do paciente)
    SELECT pt.* INTO v_pat FROM ria.patients pt
     WHERE pt.clinic_id = v_clinic AND pt.wa_id = regexp_replace(coalesce(p->>'patient_wa_id',''), '\D', '', 'g');
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    INSERT INTO ria.conversations(clinic_id, patient_id) VALUES (v_clinic, v_pat.id) ON CONFLICT DO NOTHING;
    RETURN ria.api_handoff_open(jsonb_build_object(
             'clinic_id', v_clinic, 'reason', 'staff_takeover', 'priority', 'normal',
             'conversation_id', (SELECT id FROM ria.conversations WHERE clinic_id = v_clinic AND patient_id = v_pat.id)))
           || jsonb_build_object('action', 'takeover');
  END IF;

  SELECT * INTO v_h FROM ria.handoffs WHERE clinic_id = v_clinic AND code = v_code AND status <> 'closed' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found', 'code', v_code); END IF;
  SELECT * INTO v_pat FROM ria.patients WHERE id = v_h.patient_id;

  IF v_action IN ('assign', 'reply') THEN
    UPDATE ria.handoffs SET status = 'assigned',
           assigned_staff_id = coalesce(assigned_staff_id, v_staff.id), assigned_at = coalesce(assigned_at, v_now)
     WHERE id = v_h.id RETURNING * INTO v_h;
    UPDATE ria.conversations SET assigned_staff_id = coalesce(assigned_staff_id, v_staff.id), human_last_activity_at = v_now
     WHERE id = v_h.conversation_id;
    IF v_action = 'assign' THEN
      PERFORM ria.audit(v_clinic, 'staff', v_staff.id, 'handoff_assigned', 'handoff', v_h.id, '{}'::jsonb);
    END IF;
  ELSIF v_action = 'release' THEN
    UPDATE ria.handoffs SET status = 'closed', closed_at = v_now, closed_by = coalesce(v_staff.name, 'admin_api') WHERE id = v_h.id;
    UPDATE ria.conversations SET mode = 'BOT', state = 'idle', context = '{}'::jsonb, human_since = NULL,
           assigned_staff_id = NULL, unknown_count = 0, ai_failures = 0, version = version + 1, updated_at = v_now
     WHERE id = v_h.conversation_id;
    PERFORM ria.audit(v_clinic, 'staff', v_staff.id, 'handoff_released_to_bot', 'handoff', v_h.id, '{}'::jsonb);
  ELSE
    RETURN jsonb_build_object('status', 'invalid_action');
  END IF;

  RETURN jsonb_build_object('status', 'ok', 'action', v_action, 'code', v_h.code,
                            'patient_id', v_pat.id, 'patient_wa_id', v_pat.wa_id,
                            'patient_in_window', v_pat.last_inbound_at > v_now - interval '23 hours 50 minutes',
                            'patient_name', coalesce(v_pat.full_name, v_pat.whatsapp_profile_name, 'Paciente'),
                            'staff_name', v_staff.name);
END $$;

-- Mensagem do paciente enquanto em atendimento humano: para quem repassar
CREATE OR REPLACE FUNCTION ria.api_handoff_relay_targets(p jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  WITH h AS (
    UPDATE ria.conversations SET human_last_activity_at = human_last_activity_at
     WHERE id = (p->>'conversation_id')::uuid RETURNING id
  )
  SELECT jsonb_build_object(
    'code', hd.code, 'priority', hd.priority,
    'staff', coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'wa_id', s.wa_id,
                          'in_window', s.last_inbound_at > now() - interval '23 hours 50 minutes'))
                       FROM ria.staff_members s
                       WHERE s.clinic_id = hd.clinic_id AND s.active AND s.receives_handoffs
                         AND (hd.assigned_staff_id IS NULL OR s.id = hd.assigned_staff_id)), '[]'::jsonb))
  FROM ria.handoffs hd
  WHERE hd.conversation_id = (p->>'conversation_id')::uuid AND hd.clinic_id = (p->>'clinic_id')::uuid AND hd.status <> 'closed'
  LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- MENSAGENS ENVIADAS / STATUS DE ENTREGA
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_outbound_record(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ria.outbound_messages(clinic_id, patient_id, staff_id, wa_message_id, kind, purpose, status, error_code, error_title)
  VALUES ((p->>'clinic_id')::uuid, nullif(p->>'patient_id','')::uuid, nullif(p->>'staff_id','')::uuid,
          nullif(p->>'wa_message_id',''), coalesce(p->>'kind','text'), coalesce(p->>'purpose','reply'),
          coalesce(p->>'status','accepted'), left(p->>'error_code', 40), ria.sanitize_log(p->>'error_title', 200))
  ON CONFLICT (wa_message_id) DO NOTHING;
  IF coalesce(p->>'status','accepted') = 'accepted' AND nullif(p->>'patient_id','') IS NOT NULL THEN
    UPDATE ria.patients SET last_outbound_at = now() WHERE id = (p->>'patient_id')::uuid;
  END IF;
  IF p->>'status' = 'error' THEN
    INSERT INTO ria.integration_errors(clinic_id, source, workflow, node, error_code, message)
    VALUES ((p->>'clinic_id')::uuid, 'whatsapp', '00-enviar-whatsapp', 'Enviar', left(p->>'error_code', 40),
            ria.sanitize_log(p->>'error_title', 300));
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Atualizações de status vindas do webhook (sent/delivered/read/failed)
CREATE OR REPLACE FUNCTION ria.api_status_update(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_msg ria.outbound_messages%ROWTYPE; v_status text := p->>'status';
BEGIN
  IF v_status NOT IN ('sent','delivered','read','failed') THEN RETURN jsonb_build_object('ok', false); END IF;
  UPDATE ria.outbound_messages
     SET status = CASE WHEN status = 'failed' THEN status
                       WHEN v_status = 'sent' AND status IN ('delivered','read') THEN status
                       WHEN v_status = 'delivered' AND status = 'read' THEN status
                       ELSE v_status END,
         error_code = coalesce(left(p->>'error_code', 40), error_code),
         error_title = coalesce(ria.sanitize_log(p->>'error_title', 200), error_title),
         updated_at = now()
   WHERE wa_message_id = p->>'wa_message_id'
  RETURNING * INTO v_msg;
  UPDATE ria.reminders SET status = CASE WHEN v_status = 'failed' THEN 'failed'
                                         WHEN v_status IN ('delivered','read') THEN v_status ELSE status END,
         error_code = CASE WHEN v_status = 'failed' THEN left(p->>'error_code', 40) ELSE error_code END
   WHERE wa_message_id = p->>'wa_message_id' AND status IN ('sent','delivered');
  IF v_status = 'failed' THEN
    INSERT INTO ria.integration_errors(clinic_id, source, workflow, node, error_code, message)
    VALUES (v_msg.clinic_id, 'whatsapp', '01-whatsapp-recepcao', 'status', left(p->>'error_code', 40),
            'Falha de entrega: ' || ria.sanitize_log(p->>'error_title', 200));
  END IF;
  RETURN jsonb_build_object('ok', true, 'found', v_msg.id IS NOT NULL);
END $$;

CREATE OR REPLACE FUNCTION ria.api_log_error(p jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  INSERT INTO ria.integration_errors(clinic_id, source, workflow, node, error_code, message, execution_id)
  VALUES (nullif(p->>'clinic_id','')::uuid,
          CASE WHEN p->>'source' IN ('whatsapp','openai','calendar','database','n8n') THEN p->>'source' ELSE 'other' END,
          left(p->>'workflow', 120), left(p->>'node', 120), left(p->>'error_code', 80),
          ria.sanitize_log(p->>'message', 500), left(p->>'execution_id', 60))
  RETURNING jsonb_build_object('ok', true, 'id', id)
$$;

-- -----------------------------------------------------------------------------
-- LEMBRETES
-- Reivindica (claim) lembretes devidos de forma atômica: a UNIQUE
-- (appointment_id, kind) garante no máximo um disparo por consulta, mesmo com
-- execuções simultâneas do agendador.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_reminders_claim(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_now   timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_limit int := coalesce((p->>'limit')::int, 50);
  v_out   jsonb;
BEGIN
  WITH due AS (
    SELECT a.id, a.clinic_id
      FROM ria.appointments a
      JOIN ria.clinics c ON c.id = a.clinic_id AND c.status = 'active'
     WHERE a.status = 'confirmed'
       AND a.starts_at > v_now + interval '2 hours'
       AND a.starts_at <= v_now + make_interval(hours => c.reminder_hours_before)
       AND a.created_at < a.starts_at - make_interval(hours => c.reminder_hours_before)  -- agendada dentro da janela: confirmação já basta
       AND NOT EXISTS (SELECT 1 FROM ria.reminders r WHERE r.appointment_id = a.id AND r.kind = '24h')
     ORDER BY a.starts_at
     LIMIT v_limit
     FOR UPDATE OF a SKIP LOCKED
  ), ins AS (
    INSERT INTO ria.reminders(clinic_id, appointment_id, kind, status)
    SELECT d.clinic_id, d.id, '24h',
           CASE WHEN pt.opted_out_at IS NOT NULL OR NOT pt.reminders_opt_in OR pt.status <> 'active' THEN 'skipped_opt_out'
                WHEN (pt.last_inbound_at IS NULL OR pt.last_inbound_at <= v_now - interval '23 hours 50 minutes')
                     AND coalesce(c.reminder_template->>'name', '') = '' THEN 'skipped_no_template'
                ELSE 'sending' END
      FROM due d JOIN ria.appointments a ON a.id = d.id
      JOIN ria.patients pt ON pt.id = a.patient_id
      JOIN ria.clinics c ON c.id = a.clinic_id
    ON CONFLICT (appointment_id, kind) DO NOTHING
    RETURNING *
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'reminder_id', ins.id, 'status', ins.status, 'appointment_id', a.id,
           'clinic_id', c.id, 'clinic_name', c.name, 'phone_number_id', c.whatsapp_phone_number_id,
           'patient_id', pt.id, 'patient_wa_id', pt.wa_id,
           'patient_first_name', split_part(coalesce(pt.full_name, pt.whatsapp_profile_name, ''), ' ', 1),
           'in_session_window', pt.last_inbound_at > v_now - interval '23 hours 50 minutes',
           'label', ria.slot_label(a.starts_at, c.timezone),
           'date_label', to_char(a.starts_at AT TIME ZONE c.timezone, 'DD/MM/YYYY'),
           'time_label', to_char(a.starts_at AT TIME ZONE c.timezone, 'HH24:MI'),
           'professional_name', pr.display_name, 'service_name', s.name,
           'address', c.address_line, 'maps_url', c.maps_url,
           'template', c.reminder_template)), '[]'::jsonb)
    INTO v_out
    FROM ins
    JOIN ria.appointments a ON a.id = ins.appointment_id
    JOIN ria.clinics c ON c.id = a.clinic_id
    JOIN ria.patients pt ON pt.id = a.patient_id
    JOIN ria.professionals pr ON pr.id = a.professional_id
    JOIN ria.services s ON s.id = a.service_id;
  RETURN jsonb_build_object('reminders', v_out, 'settings', ria.fn_settings());
END $$;

CREATE OR REPLACE FUNCTION ria.api_reminder_result(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE ria.reminders SET status = CASE WHEN p->>'status' IN ('sent','failed') THEN p->>'status' ELSE 'failed' END,
         channel = CASE WHEN p->>'channel' IN ('template','session') THEN p->>'channel' END,
         wa_message_id = nullif(p->>'wa_message_id',''), error_code = left(p->>'error_code', 40), finished_at = now()
   WHERE id = (p->>'reminder_id')::uuid AND status = 'sending';
  RETURN jsonb_build_object('ok', FOUND);
END $$;

-- -----------------------------------------------------------------------------
-- MANUTENÇÃO, MÉTRICAS, ALERTAS, RETENÇÃO, LGPD
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_janitor(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_now timestamptz := coalesce((p->>'now')::timestamptz, now());
  v_offers int; v_holds int; v_human int; v_rem int;
BEGIN
  UPDATE ria.slot_offers SET status = 'expired' WHERE status = 'open' AND expires_at <= v_now;
  GET DIAGNOSTICS v_offers = ROW_COUNT;
  UPDATE ria.appointments SET status = 'expired', cancel_reason = 'hold_timeout', updated_at = v_now
   WHERE status = 'held' AND hold_expires_at <= v_now - interval '2 minutes';
  GET DIAGNOSTICS v_holds = ROW_COUNT;
  WITH t AS (
    SELECT cv.id FROM ria.conversations cv JOIN ria.clinics c ON c.id = cv.clinic_id
     WHERE cv.mode = 'HUMAN'
       AND coalesce(cv.human_last_activity_at, cv.human_since) < v_now - make_interval(mins => c.human_timeout_minutes)
  ), h AS (
    UPDATE ria.handoffs SET status = 'closed', closed_at = v_now, closed_by = 'timeout'
     WHERE conversation_id IN (SELECT id FROM t) AND status <> 'closed'
  )
  UPDATE ria.conversations SET mode = 'BOT', state = 'idle', context = '{}'::jsonb, human_since = NULL,
         assigned_staff_id = NULL, version = version + 1, updated_at = v_now
   WHERE id IN (SELECT id FROM t);
  GET DIAGNOSTICS v_human = ROW_COUNT;
  -- lembretes travados em 'sending' por queda do n8n
  UPDATE ria.reminders SET status = 'failed', error_code = 'stuck_sending', finished_at = v_now
   WHERE status = 'sending' AND claimed_at < v_now - interval '30 minutes';
  GET DIAGNOSTICS v_rem = ROW_COUNT;
  RETURN jsonb_build_object('offers_expired', v_offers, 'holds_expired', v_holds,
                            'conversations_returned_to_bot', v_human, 'reminders_unstuck', v_rem);
END $$;

CREATE OR REPLACE FUNCTION ria.api_daily_metrics(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_out jsonb;
BEGIN
  WITH d AS (
    SELECT c.id AS clinic_id, c.name, c.timezone,
           coalesce((p->>'day')::date, ((now() AT TIME ZONE c.timezone)::date - 1)) AS day
      FROM ria.clinics c WHERE c.status = 'active'
  ), r AS (
    SELECT d.*, (d.day::timestamp AT TIME ZONE d.timezone) AS t0, ((d.day + 1)::timestamp AT TIME ZONE d.timezone) AS t1 FROM d
  ), m AS (
    SELECT r.clinic_id, r.day, r.name,
      (SELECT count(*) FROM ria.processed_messages x WHERE x.clinic_id = r.clinic_id AND x.received_at >= r.t0 AND x.received_at < r.t1 AND x.patient_id IS NOT NULL) AS messages_in,
      (SELECT count(*) FROM ria.processed_messages x WHERE x.clinic_id = r.clinic_id AND x.received_at >= r.t0 AND x.received_at < r.t1 AND x.msg_type = 'audio') AS audio_messages,
      (SELECT count(DISTINCT x.patient_id) FROM ria.processed_messages x WHERE x.clinic_id = r.clinic_id AND x.received_at >= r.t0 AND x.received_at < r.t1) AS patients_served,
      (SELECT count(*) FROM ria.patients x WHERE x.clinic_id = r.clinic_id AND x.created_at >= r.t0 AND x.created_at < r.t1) AS new_patients,
      (SELECT count(*) FROM ria.audit_events x WHERE x.clinic_id = r.clinic_id AND x.created_at >= r.t0 AND x.created_at < r.t1 AND x.action = 'appointment_confirmed') AS appointments_confirmed,
      (SELECT count(*) FROM ria.audit_events x WHERE x.clinic_id = r.clinic_id AND x.created_at >= r.t0 AND x.created_at < r.t1 AND x.action = 'appointment_cancelled') AS appointments_cancelled,
      (SELECT count(*) FROM ria.audit_events x WHERE x.clinic_id = r.clinic_id AND x.created_at >= r.t0 AND x.created_at < r.t1 AND x.action = 'appointment_rescheduled') AS appointments_rescheduled,
      (SELECT count(*) FROM ria.handoffs x WHERE x.clinic_id = r.clinic_id AND x.opened_at >= r.t0 AND x.opened_at < r.t1) AS handoffs,
      (SELECT count(*) FROM ria.reminders x WHERE x.clinic_id = r.clinic_id AND x.finished_at >= r.t0 AND x.finished_at < r.t1 AND x.status IN ('sent','delivered','read')) AS reminders_sent,
      (SELECT count(*) FROM ria.integration_errors x WHERE x.clinic_id = r.clinic_id AND x.created_at >= r.t0 AND x.created_at < r.t1) AS integration_errors,
      (SELECT count(*) FROM ria.outbound_messages x WHERE x.clinic_id = r.clinic_id AND x.updated_at >= r.t0 AND x.updated_at < r.t1 AND x.status IN ('failed','error')) AS delivery_failures
    FROM r
  ), up AS (
    INSERT INTO ria.daily_metrics AS dm (clinic_id, day, messages_in, audio_messages, patients_served, new_patients,
        appointments_confirmed, appointments_cancelled, appointments_rescheduled, handoffs, reminders_sent,
        integration_errors, delivery_failures, computed_at)
    SELECT clinic_id, day, messages_in, audio_messages, patients_served, new_patients, appointments_confirmed,
           appointments_cancelled, appointments_rescheduled, handoffs, reminders_sent, integration_errors, delivery_failures, now()
      FROM m
    ON CONFLICT (clinic_id, day) DO UPDATE SET
      messages_in = EXCLUDED.messages_in, audio_messages = EXCLUDED.audio_messages,
      patients_served = EXCLUDED.patients_served, new_patients = EXCLUDED.new_patients,
      appointments_confirmed = EXCLUDED.appointments_confirmed, appointments_cancelled = EXCLUDED.appointments_cancelled,
      appointments_rescheduled = EXCLUDED.appointments_rescheduled, handoffs = EXCLUDED.handoffs,
      reminders_sent = EXCLUDED.reminders_sent, integration_errors = EXCLUDED.integration_errors,
      delivery_failures = EXCLUDED.delivery_failures, computed_at = now()
    RETURNING dm.*
  )
  SELECT coalesce(jsonb_agg(to_jsonb(up) || jsonb_build_object(
           'clinic_name', (SELECT name FROM ria.clinics WHERE id = up.clinic_id),
           'admins', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'wa_id', s.wa_id, 'name', s.name,
                              'in_window', s.last_inbound_at > now() - interval '23 hours 50 minutes')), '[]'::jsonb)
                      FROM ria.staff_members s WHERE s.clinic_id = up.clinic_id AND s.active AND s.receives_alerts),
           'phone_number_id', (SELECT whatsapp_phone_number_id FROM ria.clinics WHERE id = up.clinic_id))), '[]'::jsonb)
    INTO v_out FROM up;
  RETURN jsonb_build_object('metrics', v_out, 'settings', ria.fn_settings());
END $$;

-- Gera alertas administrativos (deduplicados por hora) SEM dados clínicos
CREATE OR REPLACE FUNCTION ria.api_alerts_collect(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_threshold int := coalesce((p->>'error_threshold')::int, (ria.setting('alert_error_threshold', '5'))::text::int);
  v_hour text := to_char(now(), 'YYYYMMDDHH24');
  v_out jsonb;
BEGIN
  -- Erros de integração na última hora
  INSERT INTO ria.admin_alerts(clinic_id, kind, dedup_key, message)
  SELECT e.clinic_id, 'integration_errors', 'err:' || coalesce(e.clinic_id::text, 'global') || ':' || e.source || ':' || v_hour,
         format('Alerta: %s erro(s) de integração (%s) na última hora.', count(*), e.source)
    FROM ria.integration_errors e
   WHERE e.created_at > now() - interval '1 hour'
   GROUP BY e.clinic_id, e.source HAVING count(*) >= v_threshold
  ON CONFLICT (dedup_key) DO NOTHING;

  -- Falhas de entrega
  INSERT INTO ria.admin_alerts(clinic_id, kind, dedup_key, message)
  SELECT o.clinic_id, 'delivery_failures', 'dlv:' || o.clinic_id || ':' || v_hour,
         format('Alerta: %s mensagem(ns) não entregue(s) na última hora.', count(*))
    FROM ria.outbound_messages o
   WHERE o.status IN ('failed','error') AND o.updated_at > now() - interval '1 hour'
   GROUP BY o.clinic_id HAVING count(*) >= greatest(1, v_threshold / 2)
  ON CONFLICT (dedup_key) DO NOTHING;

  -- Divergências de agenda (uma vez por consulta e tipo)
  INSERT INTO ria.admin_alerts(clinic_id, kind, dedup_key, message)
  SELECT a.clinic_id, 'calendar_sync', 'sync:' || a.id || ':' || a.sync_status,
         format('Agenda divergente (%s): consulta de %s com %s. Verifique o calendário.',
                CASE a.sync_status WHEN 'missing_in_calendar' THEN 'evento removido manualmente'
                                   WHEN 'time_mismatch' THEN 'horário alterado manualmente'
                                   WHEN 'conflict' THEN 'conflito com outro evento'
                                   ELSE 'exclusão pendente' END,
                ria.slot_label(a.starts_at, c.timezone), pr.display_name)
    FROM ria.appointments a JOIN ria.clinics c ON c.id = a.clinic_id JOIN ria.professionals pr ON pr.id = a.professional_id
   WHERE a.sync_status IN ('missing_in_calendar','time_mismatch','conflict','delete_pending')
     AND a.starts_at > now() - interval '1 day'
  ON CONFLICT (dedup_key) DO NOTHING;

  -- Atendimentos urgentes sem resposta humana há mais de 15 min
  INSERT INTO ria.admin_alerts(clinic_id, kind, dedup_key, message)
  SELECT h.clinic_id, 'urgent_handoff_waiting', 'urg:' || h.id,
         format('Atendimento prioritário #%s aguardando a equipe há mais de 15 minutos.', h.code)
    FROM ria.handoffs h
   WHERE h.status = 'open' AND h.priority = 'urgent' AND h.opened_at < now() - interval '15 minutes'
  ON CONFLICT (dedup_key) DO NOTHING;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'alert_id', al.id, 'kind', al.kind, 'message', al.message, 'clinic_id', al.clinic_id,
           'phone_number_id', c.whatsapp_phone_number_id,
           'admins', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'wa_id', s.wa_id, 'name', s.name,
                              'in_window', s.last_inbound_at > now() - interval '23 hours 50 minutes')), '[]'::jsonb)
                      FROM ria.staff_members s WHERE s.clinic_id = al.clinic_id AND s.active AND s.receives_alerts))), '[]'::jsonb)
    INTO v_out
    FROM ria.admin_alerts al LEFT JOIN ria.clinics c ON c.id = al.clinic_id
   WHERE al.sent_at IS NULL AND al.created_at > now() - interval '1 day';
  RETURN jsonb_build_object('alerts', v_out, 'settings', ria.fn_settings());
END $$;

CREATE OR REPLACE FUNCTION ria.api_alert_sent(p jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  UPDATE ria.admin_alerts SET sent_at = now() WHERE id = (p->>'alert_id')::bigint
  RETURNING jsonb_build_object('ok', true)
$$;

-- Política de retenção configurável por clínica
CREATE OR REPLACE FUNCTION ria.api_retention(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_msgs int := 0; v_out int := 0; v_audit int := 0; v_err int := 0; v_anon int := 0; v_offers int := 0; n int; r record;
BEGIN
  FOR r IN SELECT * FROM ria.clinics LOOP
    DELETE FROM ria.processed_messages WHERE clinic_id = r.id AND received_at < now() - make_interval(days => r.retention_message_log_days);
    GET DIAGNOSTICS n = ROW_COUNT; v_msgs := v_msgs + n;
    DELETE FROM ria.outbound_messages WHERE clinic_id = r.id AND created_at < now() - make_interval(days => r.retention_message_log_days);
    GET DIAGNOSTICS n = ROW_COUNT; v_out := v_out + n;
    DELETE FROM ria.slot_offers WHERE clinic_id = r.id AND status <> 'open' AND created_at < now() - interval '30 days';
    GET DIAGNOSTICS n = ROW_COUNT; v_offers := v_offers + n;
    DELETE FROM ria.audit_events WHERE clinic_id = r.id AND created_at < now() - make_interval(days => r.retention_audit_days);
    GET DIAGNOSTICS n = ROW_COUNT; v_audit := v_audit + n;
    IF r.retention_inactive_patient_days IS NOT NULL THEN
      WITH x AS (
        SELECT pt.id FROM ria.patients pt
         WHERE pt.clinic_id = r.id AND pt.status = 'active'
           AND coalesce(pt.last_inbound_at, pt.created_at) < now() - make_interval(days => r.retention_inactive_patient_days)
           AND NOT EXISTS (SELECT 1 FROM ria.appointments a WHERE a.patient_id = pt.id
                             AND a.starts_at > now() - make_interval(days => r.retention_inactive_patient_days))
      )
      SELECT count(*) INTO n FROM x, LATERAL ria.api_anonymize_patient(jsonb_build_object('clinic_id', r.id, 'patient_id', x.id, 'requested_by', 'retention_policy')) y
       WHERE y->>'status' = 'anonymized';
      v_anon := v_anon + n;
    END IF;
  END LOOP;
  DELETE FROM ria.integration_errors WHERE created_at < now() - interval '180 days';
  GET DIAGNOSTICS v_err = ROW_COUNT;
  DELETE FROM ria.admin_alerts WHERE created_at < now() - interval '180 days';
  RETURN jsonb_build_object('processed_messages', v_msgs, 'outbound_messages', v_out, 'slot_offers', v_offers,
                            'audit_events', v_audit, 'integration_errors', v_err, 'patients_anonymized', v_anon);
END $$;

-- Anonimização (pedido do titular via clínica, ou retenção). Recusa se houver
-- consulta futura ativa: ela deve ser cancelada antes (inclusive na agenda).
CREATE OR REPLACE FUNCTION ria.api_anonymize_patient(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_pt ria.patients%ROWTYPE; v_hash text;
BEGIN
  SELECT * INTO v_pt FROM ria.patients
   WHERE id = (p->>'patient_id')::uuid AND clinic_id = (p->>'clinic_id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_pt.status = 'anonymized' THEN RETURN jsonb_build_object('status', 'anonymized', 'already', true); END IF;
  IF EXISTS (SELECT 1 FROM ria.appointments WHERE patient_id = v_pt.id AND status IN ('held','confirmed','cancel_requested') AND starts_at > now()) THEN
    RETURN jsonb_build_object('status', 'has_future_appointments');
  END IF;
  v_hash := 'anon-' || left(encode(digest(v_pt.id::text || v_pt.wa_id || clock_timestamp()::text, 'sha256'), 'hex'), 20);
  UPDATE ria.patients SET wa_id = v_hash, full_name = NULL, whatsapp_profile_name = NULL, name_source = NULL,
         status = 'anonymized', reminders_opt_in = false, updated_at = now()
   WHERE id = v_pt.id;
  UPDATE ria.conversations SET context = '{}'::jsonb, state = 'idle', mode = 'BOT' WHERE patient_id = v_pt.id;
  DELETE FROM ria.processed_messages WHERE patient_id = v_pt.id;
  DELETE FROM ria.slot_offers WHERE patient_id = v_pt.id;
  INSERT INTO ria.consent_events(clinic_id, patient_id, kind, source, evidence)
  VALUES (v_pt.clinic_id, v_pt.id, 'anonymized', coalesce(p->>'requested_by', 'clinic'), NULL);
  PERFORM ria.audit(v_pt.clinic_id, 'system', NULL, 'patient_anonymized', 'patient', v_pt.id,
                    jsonb_build_object('requested_by', p->>'requested_by'));
  RETURN jsonb_build_object('status', 'anonymized');
END $$;

-- -----------------------------------------------------------------------------
-- RECONCILIAÇÃO COM A AGENDA (alterações manuais no Google Calendar)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ria.api_reconcile_targets(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('settings', ria.fn_settings(), 'targets', coalesce(jsonb_agg(jsonb_build_object(
           'clinic_id', c.id, 'professional_id', pr.id, 'calendar_id', pr.calendar_id,
           'calendar_provider', c.calendar_provider, 'external_ref', pr.external_ref,
           'external_calendar_base_url', c.external_calendar_base_url,
           'time_min', now() - interval '1 hour',
           'time_max', now() + make_interval(days => least(c.max_booking_days_ahead, 60)))), '[]'::jsonb))
  FROM ria.clinics c JOIN ria.professionals pr ON pr.clinic_id = c.id AND pr.active
  WHERE c.status = 'active' AND pr.calendar_id IS NOT NULL
$$;

-- p.events = [{"id": "...", "status": "confirmed|cancelled", "start": "...", "end": "...", "ria_appointment_id": "..."}]
CREATE OR REPLACE FUNCTION ria.api_reconcile(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_pro   uuid := (p->>'professional_id')::uuid;
  v_min   timestamptz := (p->>'time_min')::timestamptz;
  v_max   timestamptz := (p->>'time_max')::timestamptz;
  v_issues jsonb := '[]'::jsonb;
  v_retry  jsonb := '[]'::jsonb;
  v_orphans jsonb := '[]'::jsonb;
  r record;
BEGIN
  IF to_regclass('pg_temp._ria_ev') IS NULL THEN
    CREATE TEMP TABLE _ria_ev(id text, status text, st timestamptz, en timestamptz, ria_id text) ON COMMIT DROP;
  END IF;
  TRUNCATE _ria_ev;
  INSERT INTO _ria_ev
  SELECT e->>'id', coalesce(e->>'status', 'confirmed'), (e->>'start')::timestamptz, (e->>'end')::timestamptz, nullif(e->>'ria_appointment_id', '')
    FROM jsonb_array_elements(coalesce(p->'events', '[]'::jsonb)) e
   WHERE e->>'start' IS NOT NULL AND e->>'end' IS NOT NULL;

  FOR r IN
    SELECT a.*, ev.id AS ev_id, ev.status AS ev_status, ev.st AS ev_st, ev.en AS ev_en
      FROM ria.appointments a
      LEFT JOIN _ria_ev ev ON ev.id = a.calendar_event_id
     WHERE a.professional_id = v_pro AND a.status = 'confirmed'
       AND a.starts_at >= v_min AND a.starts_at < v_max
  LOOP
    IF r.ev_id IS NULL OR r.ev_status = 'cancelled' THEN
      UPDATE ria.appointments SET sync_status = 'missing_in_calendar', sync_checked_at = now() WHERE id = r.id;
      v_issues := v_issues || jsonb_build_object('appointment_id', r.id, 'issue', 'missing_in_calendar');
    ELSIF r.ev_st <> r.starts_at OR r.ev_en <> r.ends_at THEN
      UPDATE ria.appointments SET sync_status = 'time_mismatch', sync_checked_at = now() WHERE id = r.id;
      v_issues := v_issues || jsonb_build_object('appointment_id', r.id, 'issue', 'time_mismatch');
    ELSIF EXISTS (SELECT 1 FROM _ria_ev o
                   WHERE o.id <> r.ev_id AND o.status <> 'cancelled'
                     AND tstzrange(o.st, o.en) && tstzrange(r.starts_at, r.ends_at)) THEN
      UPDATE ria.appointments SET sync_status = 'conflict', sync_checked_at = now() WHERE id = r.id;
      v_issues := v_issues || jsonb_build_object('appointment_id', r.id, 'issue', 'conflict');
    ELSE
      UPDATE ria.appointments SET sync_status = 'synced', sync_checked_at = now() WHERE id = r.id;
    END IF;
  END LOOP;

  -- Exclusões pendentes (cancelamentos cuja remoção na agenda falhou)
  SELECT coalesce(jsonb_agg(jsonb_build_object('appointment_id', a.id, 'calendar_id', a.calendar_id,
                                               'calendar_event_id', a.calendar_event_id)), '[]'::jsonb)
    INTO v_retry
    FROM ria.appointments a
   WHERE a.professional_id = v_pro AND a.calendar_event_id IS NOT NULL
     AND ((a.status = 'cancelled' AND a.sync_status = 'delete_pending')
          OR (a.status = 'cancel_requested' AND a.updated_at < now() - interval '10 minutes'))
     AND EXISTS (SELECT 1 FROM _ria_ev ev WHERE ev.id = a.calendar_event_id AND ev.status <> 'cancelled');

  -- Eventos criados pelo robô cuja reserva expirou/falhou (sobras de falha parcial)
  SELECT coalesce(jsonb_agg(jsonb_build_object('calendar_event_id', ev.id, 'appointment_id', a.id)), '[]'::jsonb)
    INTO v_orphans
    FROM _ria_ev ev JOIN ria.appointments a ON replace(a.id::text, '-', '') = ev.id
   WHERE ev.status <> 'cancelled' AND a.status IN ('expired') AND a.professional_id = v_pro;

  -- Cancelamentos cujo evento já não existe: concluir
  UPDATE ria.appointments a SET status = 'cancelled', sync_status = 'deleted', cancelled_at = coalesce(cancelled_at, now())
   WHERE a.professional_id = v_pro AND a.status = 'cancel_requested' AND a.updated_at < now() - interval '10 minutes'
     AND NOT EXISTS (SELECT 1 FROM _ria_ev ev WHERE ev.id = a.calendar_event_id AND ev.status <> 'cancelled');
  UPDATE ria.appointments a SET sync_status = 'deleted'
   WHERE a.professional_id = v_pro AND a.status = 'cancelled' AND a.sync_status = 'delete_pending'
     AND NOT EXISTS (SELECT 1 FROM _ria_ev ev WHERE ev.id = a.calendar_event_id AND ev.status <> 'cancelled');

  RETURN jsonb_build_object('issues', v_issues, 'retry_deletes', v_retry, 'orphan_events', v_orphans);
END $$;

-- Marca exclusão concluída em reconciliação
CREATE OR REPLACE FUNCTION ria.api_mark_calendar_deleted(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE ria.appointments SET sync_status = 'deleted',
         status = CASE WHEN status = 'cancel_requested' THEN 'cancelled' ELSE status END,
         cancelled_at = CASE WHEN status = 'cancel_requested' THEN now() ELSE cancelled_at END
   WHERE id = (p->>'appointment_id')::uuid AND status IN ('cancelled','cancel_requested','expired');
  RETURN jsonb_build_object('ok', FOUND);
END $$;

INSERT INTO ria.schema_migrations(version) VALUES ('002_funcoes') ON CONFLICT DO NOTHING;

-- >>> database/migrations/003_configuracoes_padrao.sql
-- =============================================================================
-- Recepcionista IA — Migração 003: configurações globais padrão (NÃO secretas)
-- Ajuste com: UPDATE ria.app_settings SET value = '"gpt-4.1-mini"' WHERE key = 'openai_model';
-- =============================================================================
INSERT INTO ria.app_settings(key, value, description) VALUES
  ('graph_api_base',          '"https://graph.facebook.com"',              'URL base da Graph API (WhatsApp Cloud API)'),
  ('graph_api_version',       '"v23.0"',                                   'Versão da Graph API usada nas chamadas'),
  ('openai_base',             '"https://api.openai.com/v1"',               'URL base da API OpenAI'),
  ('openai_model',            '"gpt-4.1-mini"',                            'Modelo de chat para classificar intenções (saída JSON estruturada)'),
  ('openai_transcribe_model', '"gpt-4o-mini-transcribe"',                  'Modelo de transcrição de áudio'),
  ('openai_timeout_ms',       '20000',                                     'Timeout das chamadas OpenAI (ms)'),
  ('google_calendar_base',    '"https://www.googleapis.com/calendar/v3"',  'URL base da Google Calendar API'),
  ('http_timeout_ms',         '15000',                                     'Timeout padrão das chamadas HTTP (ms)'),
  ('audio_max_bytes',         '2000000',                                   'Áudios maiores (≈10 min) são recusados educadamente'),
  ('ai_max_failures',         '2',                                         'Falhas seguidas da IA antes de transferir para humano'),
  ('unknown_max',             '2',                                         'Mensagens não compreendidas seguidas antes de oferecer humano'),
  ('alert_error_threshold',   '5',                                         'Erros/hora que disparam alerta administrativo')
ON CONFLICT (key) DO NOTHING;

INSERT INTO ria.schema_migrations(version) VALUES ('003_configuracoes_padrao') ON CONFLICT DO NOTHING;
