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
