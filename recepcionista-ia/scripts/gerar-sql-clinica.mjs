#!/usr/bin/env node
// Gera SQL idempotente (pode rodar várias vezes) a partir de um JSON de clínica.
// Uso: node scripts/gerar-sql-clinica.mjs config/clinica-exemplo.json > database/clinica.sql
//      psql "$DATABASE_URL" -f database/clinica.sql
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const file = process.argv[2];
if (!file) {
  console.error('Uso: node scripts/gerar-sql-clinica.mjs <arquivo.json>');
  process.exit(1);
}
const c = JSON.parse(readFileSync(file, 'utf8'));

const q = (v) => (v === null || v === undefined ? 'NULL' : `'${String(v).replace(/'/g, "''")}'`);
const n = (v) => (v === null || v === undefined || v === '' ? 'NULL' : Number(v));
const j = (v) => `${q(JSON.stringify(v ?? {}))}::jsonb`;
const arr = (a) => `ARRAY[${(a || []).map(q).join(',')}]::text[]`;
const uuidFrom = (seed) => {
  const h = createHash('sha1').update(seed).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const fail = (m) => { console.error('Erro de validação:', m); process.exit(2); };

// ---- validações básicas -----------------------------------------------------
if (!/^[a-z0-9-]{3,60}$/.test(c.slug || '')) fail('slug inválido');
if (!c.name || !c.address_line) fail('name e address_line são obrigatórios');
const time = /^\d{2}:\d{2}$/;
for (const h of c.business_hours || []) {
  if (!(h.weekday >= 0 && h.weekday <= 6) || !time.test(h.open) || !time.test(h.close) || h.close <= h.open) fail(`horário inválido: ${JSON.stringify(h)}`);
}
const serviceCodes = new Set((c.services || []).map((s) => s.code));
for (const p of c.professionals || []) {
  for (const s of p.services || []) if (!serviceCodes.has(s)) fail(`profissional ${p.display_name}: serviço desconhecido ${s}`);
}
for (const s of c.staff || []) if (!/^[0-9]{10,15}$/.test(s.wa_id)) fail(`telefone da equipe inválido (use só dígitos com DDI): ${s.name}`);

const clinicId = c.id || uuidFrom(`clinic:${c.slug}`);
const r = c.rules || {};
const ret = c.retention || {};
const out = [];
out.push('-- Gerado por scripts/gerar-sql-clinica.mjs — não edite à mão; edite o JSON.');
out.push('BEGIN;');
out.push(`INSERT INTO ria.clinics (id, slug, name, address_line, city, state, postal_code, phone_display, maps_url, latitude, longitude, timezone,
  whatsapp_phone_number_id, whatsapp_waba_id, whatsapp_display_number, calendar_provider, external_calendar_base_url,
  min_booking_notice_minutes, max_booking_days_ahead, slot_step_minutes, offer_ttl_minutes, offer_max_options, hold_ttl_minutes,
  max_future_appointments, cancel_min_notice_hours, late_cancel_action, reschedule_min_notice_hours, reminder_hours_before,
  human_timeout_minutes, messages, reminder_template, staff_alert_template,
  retention_message_log_days, retention_audit_days, retention_inactive_patient_days)
VALUES (${q(clinicId)}, ${q(c.slug)}, ${q(c.name)}, ${q(c.address_line)}, ${q(c.city)}, ${q(c.state)}, ${q(c.postal_code)}, ${q(c.phone_display)},
  ${q(c.maps_url)}, ${n(c.latitude)}, ${n(c.longitude)}, ${q(c.timezone || 'America/Sao_Paulo')},
  ${q(c.whatsapp?.phone_number_id)}, ${q(c.whatsapp?.waba_id)}, ${q(c.whatsapp?.display_number)},
  ${q(c.calendar_provider || 'google')}, ${q(c.external_calendar_base_url)},
  ${n(r.min_booking_notice_minutes ?? 120)}, ${n(r.max_booking_days_ahead ?? 30)}, ${n(r.slot_step_minutes ?? 15)}, ${n(r.offer_ttl_minutes ?? 15)},
  ${n(r.offer_max_options ?? 3)}, ${n(r.hold_ttl_minutes ?? 5)}, ${n(r.max_future_appointments ?? 2)}, ${n(r.cancel_min_notice_hours ?? 24)},
  ${q(r.late_cancel_action || 'allow')}, ${n(r.reschedule_min_notice_hours ?? 12)}, ${n(r.reminder_hours_before ?? 24)},
  ${n(r.human_timeout_minutes ?? 240)}, ${j(c.messages)}, ${j(c.reminder_template)}, ${j(c.staff_alert_template)},
  ${n(ret.message_log_days ?? 90)}, ${n(ret.audit_days ?? 365)}, ${n(ret.inactive_patient_days)})
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
  retention_audit_days = EXCLUDED.retention_audit_days, retention_inactive_patient_days = EXCLUDED.retention_inactive_patient_days;`);

out.push(`DELETE FROM ria.business_hours WHERE clinic_id = ${q(clinicId)};`);
for (const h of c.business_hours || []) {
  out.push(`INSERT INTO ria.business_hours (clinic_id, weekday, open_time, close_time) VALUES (${q(clinicId)}, ${h.weekday}, ${q(h.open)}, ${q(h.close)});`);
}
out.push(`DELETE FROM ria.holidays WHERE clinic_id = ${q(clinicId)};`);
for (const h of c.holidays || []) {
  out.push(`INSERT INTO ria.holidays (clinic_id, day, name) VALUES (${q(clinicId)}, ${q(h.day)}, ${q(h.name)});`);
}

const svcId = {};
for (const s of c.services || []) {
  const id = s.id || uuidFrom(`service:${c.slug}:${s.code}`);
  svcId[s.code] = id;
  out.push(`INSERT INTO ria.services (id, clinic_id, code, name, description, price_info, duration_minutes, buffer_after_minutes, bookable_by_bot, synonyms, active)
VALUES (${q(id)}, ${q(clinicId)}, ${q(s.code)}, ${q(s.name)}, ${q(s.description)}, ${q(s.price_info)}, ${n(s.duration_minutes)}, ${n(s.buffer_after_minutes ?? 0)},
  ${s.bookable_by_bot === false ? 'false' : 'true'}, ${arr(s.synonyms)}, ${s.active === false ? 'false' : 'true'})
ON CONFLICT (clinic_id, code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, price_info = EXCLUDED.price_info,
  duration_minutes = EXCLUDED.duration_minutes, buffer_after_minutes = EXCLUDED.buffer_after_minutes,
  bookable_by_bot = EXCLUDED.bookable_by_bot, synonyms = EXCLUDED.synonyms, active = EXCLUDED.active;`);
}

const proId = {};
for (const p of c.professionals || []) {
  const id = p.id || uuidFrom(`professional:${c.slug}:${p.key || p.name}`);
  proId[p.key || p.name] = id;
  out.push(`INSERT INTO ria.professionals (id, clinic_id, name, display_name, specialty, calendar_id, external_ref, active)
VALUES (${q(id)}, ${q(clinicId)}, ${q(p.name)}, ${q(p.display_name)}, ${q(p.specialty)}, ${q(p.calendar_id)}, ${q(p.external_ref)}, ${p.active === false ? 'false' : 'true'})
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, display_name = EXCLUDED.display_name, specialty = EXCLUDED.specialty,
  calendar_id = EXCLUDED.calendar_id, external_ref = EXCLUDED.external_ref, active = EXCLUDED.active;`);
  out.push(`DELETE FROM ria.professional_services WHERE professional_id = ${q(id)};`);
  for (const code of p.services || []) {
    out.push(`INSERT INTO ria.professional_services (clinic_id, professional_id, service_id) SELECT ${q(clinicId)}, ${q(id)}, id FROM ria.services WHERE clinic_id = ${q(clinicId)} AND code = ${q(code)};`);
  }
  out.push(`DELETE FROM ria.professional_hours WHERE professional_id = ${q(id)};`);
  for (const h of p.hours || []) {
    out.push(`INSERT INTO ria.professional_hours (clinic_id, professional_id, weekday, start_time, end_time) VALUES (${q(clinicId)}, ${q(id)}, ${h.weekday}, ${q(h.start)}, ${q(h.end)});`);
  }
}

out.push(`DELETE FROM ria.schedule_blocks WHERE clinic_id = ${q(clinicId)};`);
for (const b of c.blocks || []) {
  const pid = b.professional ? proId[b.professional] : null;
  if (b.professional && !pid) fail(`bloqueio: profissional desconhecido ${b.professional}`);
  out.push(`INSERT INTO ria.schedule_blocks (clinic_id, professional_id, starts_at, ends_at, reason) VALUES (${q(clinicId)}, ${q(pid)}, ${q(b.starts_at)}, ${q(b.ends_at)}, ${q(b.reason)});`);
}

out.push(`DELETE FROM ria.faqs WHERE clinic_id = ${q(clinicId)};`);
for (const f of c.faqs || []) {
  out.push(`INSERT INTO ria.faqs (clinic_id, question, answer, keywords) VALUES (${q(clinicId)}, ${q(f.question)}, ${q(f.answer)}, ${arr(f.keywords)});`);
}

for (const s of c.staff || []) {
  const id = s.id || uuidFrom(`staff:${c.slug}:${s.wa_id}`);
  out.push(`INSERT INTO ria.staff_members (id, clinic_id, name, wa_id, role, receives_handoffs, receives_alerts, active)
VALUES (${q(id)}, ${q(clinicId)}, ${q(s.name)}, ${q(s.wa_id)}, ${q(s.role || 'receptionist')}, ${s.receives_handoffs === false ? 'false' : 'true'},
  ${s.receives_alerts ? 'true' : 'false'}, ${s.active === false ? 'false' : 'true'})
ON CONFLICT (clinic_id, wa_id) DO UPDATE SET name = EXCLUDED.name, role = EXCLUDED.role, receives_handoffs = EXCLUDED.receives_handoffs,
  receives_alerts = EXCLUDED.receives_alerts, active = EXCLUDED.active;`);
}
out.push('COMMIT;');
process.stdout.write(out.join('\n') + '\n');
