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
