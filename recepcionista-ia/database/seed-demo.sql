-- ARQUIVO GERADO: dados FICTÍCIOS da clínica demo (config/clinica-exemplo.json).
-- NÃO use em produção com pacientes reais.
-- Gerado por scripts/gerar-sql-clinica.mjs — não edite à mão; edite o JSON.
BEGIN;
INSERT INTO ria.clinics (id, slug, name, address_line, city, state, postal_code, phone_display, maps_url, latitude, longitude, timezone,
  whatsapp_phone_number_id, whatsapp_waba_id, whatsapp_display_number, calendar_provider, external_calendar_base_url,
  min_booking_notice_minutes, max_booking_days_ahead, slot_step_minutes, offer_ttl_minutes, offer_max_options, hold_ttl_minutes,
  max_future_appointments, cancel_min_notice_hours, late_cancel_action, reschedule_min_notice_hours, reminder_hours_before,
  human_timeout_minutes, messages, reminder_template, staff_alert_template,
  retention_message_log_days, retention_audit_days, retention_inactive_patient_days)
VALUES ('11111111-1111-4111-8111-111111111111', 'sorriso-demo', 'Clínica Sorriso Demo', 'Av. Exemplo, 1000 - sala 12 - Centro, São Paulo - SP', 'São Paulo', 'SP', '01000-000', '(11) 3000-0000',
  'https://maps.google.com/?q=-23.550520,-46.633308', -23.55052, -46.633308, 'America/Sao_Paulo',
  '100000000000001', '200000000000001', '+55 11 3000-0000',
  'google', NULL,
  120, 30, 15, 15,
  3, 5, 2, 24,
  'allow', 12, 24,
  240, '{"welcome":"Olá! Eu sou a assistente virtual da Clínica Sorriso Demo. Posso ajudar com agendamentos, remarcações, cancelamentos e informações sobre a clínica.","privacy_notice":"Usamos seu nome e telefone apenas para organizar seus atendimentos. Não envie fotos, exames ou dados de saúde por aqui. Para não receber mensagens automáticas, responda PARAR.","cancel_policy":"Pedimos que cancelamentos sejam feitos com pelo menos 24 horas de antecedência, para liberarmos o horário a outro paciente.","return_policy":"Retornos de um mesmo tratamento em até 30 dias não são cobrados. A equipe confirma o retorno na consulta.","emergency":"Se houver sangramento intenso que não para, inchaço que dificulta respirar ou engolir, febre alta com inchaço no rosto ou trauma forte na boca ou rosto, procure agora um pronto-socorro ou ligue 192 (SAMU).","human_out_of_hours":"Nossa equipe responde no horário de funcionamento. Sua mensagem ficou registrada e será respondida assim que possível.","signature":"Clínica Sorriso Demo"}'::jsonb, '{"name":"lembrete_consulta","language":"pt_BR","body_params":["patient_first_name","clinic_name","date_label","time_label","professional_name"],"quick_reply_buttons":["CONFIRM","RESCHEDULE"]}'::jsonb, '{"name":"alerta_equipe","language":"pt_BR","body_params":["alert_text"]}'::jsonb,
  90, 365, NULL)
ON CONFLICT (id) DO UPDATE SET slug = EXCLUDED.slug, name = EXCLUDED.name, address_line = EXCLUDED.address_line, city = EXCLUDED.city,
  state = EXCLUDED.state, postal_code = EXCLUDED.postal_code, phone_display = EXCLUDED.phone_display, maps_url = EXCLUDED.maps_url,
  latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude, timezone = EXCLUDED.timezone,
  whatsapp_phone_number_id = EXCLUDED.whatsapp_phone_number_id, whatsapp_waba_id = EXCLUDED.whatsapp_waba_id,
  whatsapp_display_number = EXCLUDED.whatsapp_display_number, calendar_provider = EXCLUDED.calendar_provider,
  external_calendar_base_url = EXCLUDED.external_calendar_base_url,
  min_booking_notice_minutes = EXCLUDED.min_booking_notice_minutes, max_booking_days_ahead = EXCLUDED.max_booking_days_ahead,
  slot_step_minutes = EXCLUDED.slot_step_minutes, offer_ttl_minutes = EXCLUDED.offer_ttl_minutes, offer_max_options = EXCLUDED.offer_max_options,
  hold_ttl_minutes = EXCLUDED.hold_ttl_minutes, max_future_appointments = EXCLUDED.max_future_appointments,
  cancel_min_notice_hours = EXCLUDED.cancel_min_notice_hours, late_cancel_action = EXCLUDED.late_cancel_action,
  reschedule_min_notice_hours = EXCLUDED.reschedule_min_notice_hours, reminder_hours_before = EXCLUDED.reminder_hours_before,
  human_timeout_minutes = EXCLUDED.human_timeout_minutes, messages = EXCLUDED.messages, reminder_template = EXCLUDED.reminder_template,
  staff_alert_template = EXCLUDED.staff_alert_template, retention_message_log_days = EXCLUDED.retention_message_log_days,
  retention_audit_days = EXCLUDED.retention_audit_days, retention_inactive_patient_days = EXCLUDED.retention_inactive_patient_days;
DELETE FROM ria.business_hours WHERE clinic_id = '11111111-1111-4111-8111-111111111111';
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 1, '08:00', '12:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 1, '13:30', '18:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 2, '08:00', '12:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 2, '13:30', '18:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 3, '08:00', '12:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 3, '13:30', '18:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 4, '08:00', '12:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 4, '13:30', '18:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 5, '08:00', '12:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 5, '13:30', '18:00');
INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES ('11111111-1111-4111-8111-111111111111', 6, '08:00', '12:00');
DELETE FROM ria.holidays WHERE clinic_id = '11111111-1111-4111-8111-111111111111';
INSERT INTO ria.holidays (clinic_id, day, name) VALUES ('11111111-1111-4111-8111-111111111111', '2026-12-25', 'Natal');
INSERT INTO ria.holidays (clinic_id, day, name) VALUES ('11111111-1111-4111-8111-111111111111', '2027-01-01', 'Confraternização Universal');
INSERT INTO ria.services (id, clinic_id, code, name, description, price_info, duration_minutes, buffer_after_minutes, bookable_by_bot, synonyms, active)
VALUES ('33333333-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'avaliacao', 'Avaliação odontológica', 'Primeira consulta para avaliar a saúde bucal e montar o plano de tratamento.', 'A avaliação custa R$ 120,00 e o valor é abatido se o tratamento for feito na clínica.', 30, 10,
  true, ARRAY['consulta','primeira consulta','check-up','orçamento','avaliar']::text[], true)
ON CONFLICT (clinic_id, code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, price_info = EXCLUDED.price_info,
  duration_minutes = EXCLUDED.duration_minutes, buffer_after_minutes = EXCLUDED.buffer_after_minutes,
  bookable_by_bot = EXCLUDED.bookable_by_bot, synonyms = EXCLUDED.synonyms, active = EXCLUDED.active;
INSERT INTO ria.services (id, clinic_id, code, name, description, price_info, duration_minutes, buffer_after_minutes, bookable_by_bot, synonyms, active)
VALUES ('33333333-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'limpeza', 'Limpeza (profilaxia)', 'Limpeza profissional com remoção de tártaro e polimento.', NULL, 45, 15,
  true, ARRAY['profilaxia','tartaro','tártaro','limpar os dentes']::text[], true)
ON CONFLICT (clinic_id, code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, price_info = EXCLUDED.price_info,
  duration_minutes = EXCLUDED.duration_minutes, buffer_after_minutes = EXCLUDED.buffer_after_minutes,
  bookable_by_bot = EXCLUDED.bookable_by_bot, synonyms = EXCLUDED.synonyms, active = EXCLUDED.active;
INSERT INTO ria.services (id, clinic_id, code, name, description, price_info, duration_minutes, buffer_after_minutes, bookable_by_bot, synonyms, active)
VALUES ('33333333-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'clareamento', 'Clareamento dental', 'Fazemos clareamento em consultório e caseiro supervisionado. É necessário passar por avaliação antes.', NULL, 60, 15,
  true, ARRAY['clarear','branqueamento','dentes brancos']::text[], true)
ON CONFLICT (clinic_id, code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, price_info = EXCLUDED.price_info,
  duration_minutes = EXCLUDED.duration_minutes, buffer_after_minutes = EXCLUDED.buffer_after_minutes,
  bookable_by_bot = EXCLUDED.bookable_by_bot, synonyms = EXCLUDED.synonyms, active = EXCLUDED.active;
INSERT INTO ria.services (id, clinic_id, code, name, description, price_info, duration_minutes, buffer_after_minutes, bookable_by_bot, synonyms, active)
VALUES ('33333333-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'restauracao', 'Restauração', 'Restauração de dentes (obturação).', NULL, 60, 10,
  true, ARRAY['obturação','obturacao','massinha','cárie','carie']::text[], true)
ON CONFLICT (clinic_id, code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, price_info = EXCLUDED.price_info,
  duration_minutes = EXCLUDED.duration_minutes, buffer_after_minutes = EXCLUDED.buffer_after_minutes,
  bookable_by_bot = EXCLUDED.bookable_by_bot, synonyms = EXCLUDED.synonyms, active = EXCLUDED.active;
INSERT INTO ria.services (id, clinic_id, code, name, description, price_info, duration_minutes, buffer_after_minutes, bookable_by_bot, synonyms, active)
VALUES ('33333333-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', 'manutencao_aparelho', 'Manutenção de aparelho', 'Manutenção mensal de aparelho ortodôntico.', NULL, 30, 0,
  true, ARRAY['aparelho','ortodontia','manutenção','manutencao']::text[], true)
ON CONFLICT (clinic_id, code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, price_info = EXCLUDED.price_info,
  duration_minutes = EXCLUDED.duration_minutes, buffer_after_minutes = EXCLUDED.buffer_after_minutes,
  bookable_by_bot = EXCLUDED.bookable_by_bot, synonyms = EXCLUDED.synonyms, active = EXCLUDED.active;
INSERT INTO ria.services (id, clinic_id, code, name, description, price_info, duration_minutes, buffer_after_minutes, bookable_by_bot, synonyms, active)
VALUES ('33333333-0000-4000-8000-000000000006', '11111111-1111-4111-8111-111111111111', 'canal', 'Tratamento de canal', 'Tratamento endodôntico. O agendamento é feito pela equipe após avaliação.', NULL, 90, 15,
  false, ARRAY['endodontia','canal']::text[], true)
ON CONFLICT (clinic_id, code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, price_info = EXCLUDED.price_info,
  duration_minutes = EXCLUDED.duration_minutes, buffer_after_minutes = EXCLUDED.buffer_after_minutes,
  bookable_by_bot = EXCLUDED.bookable_by_bot, synonyms = EXCLUDED.synonyms, active = EXCLUDED.active;
INSERT INTO ria.professionals (id, clinic_id, name, display_name, specialty, calendar_id, external_ref, active)
VALUES ('22222222-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Ana Paula Lima', 'Dra. Ana Lima', 'Clínica geral e ortodontia', 'ana.demo@group.calendar.google.com', NULL, true)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, display_name = EXCLUDED.display_name, specialty = EXCLUDED.specialty,
  calendar_id = EXCLUDED.calendar_id, external_ref = EXCLUDED.external_ref, active = EXCLUDED.active;
DELETE FROM ria.professional_services WHERE professional_id = '22222222-0000-4000-8000-000000000001';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000001', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'avaliacao';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000001', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'limpeza';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000001', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'restauracao';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000001', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'manutencao_aparelho';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000001', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'canal';
DELETE FROM ria.professional_hours WHERE professional_id = '22222222-0000-4000-8000-000000000001';
INSERT INTO ria.professionals (id, clinic_id, name, display_name, specialty, calendar_id, external_ref, active)
VALUES ('22222222-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'Bruno Costa', 'Dr. Bruno Costa', 'Dentística e estética', 'bruno.demo@group.calendar.google.com', NULL, true)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, display_name = EXCLUDED.display_name, specialty = EXCLUDED.specialty,
  calendar_id = EXCLUDED.calendar_id, external_ref = EXCLUDED.external_ref, active = EXCLUDED.active;
DELETE FROM ria.professional_services WHERE professional_id = '22222222-0000-4000-8000-000000000002';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'avaliacao';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'limpeza';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'clareamento';
INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT '11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', id FROM ria.services WHERE clinic_id = '11111111-1111-4111-8111-111111111111' AND code = 'restauracao';
DELETE FROM ria.professional_hours WHERE professional_id = '22222222-0000-4000-8000-000000000002';
INSERT INTO ria.professional_hours (clinic_id, professional_id, weekday, start_time, end_time) VALUES ('11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', 2, '08:00', '18:00');
INSERT INTO ria.professional_hours (clinic_id, professional_id, weekday, start_time, end_time) VALUES ('11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', 4, '08:00', '18:00');
INSERT INTO ria.professional_hours (clinic_id, professional_id, weekday, start_time, end_time) VALUES ('11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', 6, '08:00', '12:00');
DELETE FROM ria.schedule_blocks WHERE clinic_id = '11111111-1111-4111-8111-111111111111';
INSERT INTO ria.schedule_blocks (clinic_id, professional_id, starts_at, ends_at, reason) VALUES ('11111111-1111-4111-8111-111111111111', '22222222-0000-4000-8000-000000000002', '2026-12-28T00:00:00-03:00', '2027-01-03T00:00:00-03:00', 'Férias');
DELETE FROM ria.faqs WHERE clinic_id = '11111111-1111-4111-8111-111111111111';
INSERT INTO ria.faqs (clinic_id, question, answer, keywords) VALUES ('11111111-1111-4111-8111-111111111111', 'Vocês atendem convênio?', 'Atendemos particular e os convênios OdontoDemo e SorriPlus. Traga a carteirinha na consulta.', ARRAY['convênio','convenio','plano']::text[]);
INSERT INTO ria.faqs (clinic_id, question, answer, keywords) VALUES ('11111111-1111-4111-8111-111111111111', 'Quais as formas de pagamento?', 'Aceitamos Pix, cartões de débito e crédito (até 10x sem juros acima de R$ 500).', ARRAY['pagamento','pix','cartão','parcela']::text[]);
INSERT INTO ria.faqs (clinic_id, question, answer, keywords) VALUES ('11111111-1111-4111-8111-111111111111', 'Tem estacionamento?', 'Sim, há estacionamento conveniado no prédio, com 1 hora gratuita.', ARRAY['estacionamento','carro','vaga']::text[]);
INSERT INTO ria.faqs (clinic_id, question, answer, keywords) VALUES ('11111111-1111-4111-8111-111111111111', 'Atendem crianças?', 'Sim, a partir de 3 anos, sempre com um responsável.', ARRAY['criança','crianca','filho','infantil']::text[]);
INSERT INTO ria.staff_members (id, clinic_id, name, wa_id, role, receives_handoffs, receives_alerts, active)
VALUES ('44444444-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Recepção Demo', '5511900000001', 'receptionist', true,
  false, true)
ON CONFLICT (clinic_id, wa_id) DO UPDATE SET name = EXCLUDED.name, role = EXCLUDED.role, receives_handoffs = EXCLUDED.receives_handoffs,
  receives_alerts = EXCLUDED.receives_alerts, active = EXCLUDED.active;
INSERT INTO ria.staff_members (id, clinic_id, name, wa_id, role, receives_handoffs, receives_alerts, active)
VALUES ('44444444-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'Gestor Demo', '5511900000002', 'admin', false,
  true, true)
ON CONFLICT (clinic_id, wa_id) DO UPDATE SET name = EXCLUDED.name, role = EXCLUDED.role, receives_handoffs = EXCLUDED.receives_handoffs,
  receives_alerts = EXCLUDED.receives_alerts, active = EXCLUDED.active;
COMMIT;
