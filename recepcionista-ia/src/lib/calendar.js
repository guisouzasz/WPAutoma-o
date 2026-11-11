// calendar.js — contrato normalizado de agenda (Google Calendar ou software odontológico).
// Toda a lógica de horários livres está no PostgreSQL; aqui apenas convertemos formatos.
// Requer: util.js

// ---------- Google Calendar ----------
function googleFreeBusyBody(pros, timeMin, timeMax, tz) {
  return { timeMin, timeMax, timeZone: tz || 'America/Sao_Paulo', items: pros.filter((p) => p.calendar_id).map((p) => ({ id: p.calendar_id })) };
}

// Converte a resposta do FreeBusy em ocupações por profissional.
// Se algum calendário falhar, o profissional fica "não verificado" e NÃO é oferecido.
function normalizeGoogleFreeBusy(resp, pros) {
  const cals = (resp && resp.calendars) || {};
  const busy = [];
  const verified = [];
  const failed = [];
  for (const p of pros) {
    const cal = p.calendar_id ? cals[p.calendar_id] : null;
    if (!cal || (Array.isArray(cal.errors) && cal.errors.length)) { failed.push(p.id); continue; }
    verified.push(p.id);
    for (const b of cal.busy || []) if (b.start && b.end) busy.push({ professional_id: p.id, start: b.start, end: b.end });
  }
  return { busy, verified, failed };
}

function googleEventBody(hold) {
  return {
    id: hold.calendar_event_id, // ID determinístico: repetir a criação não duplica o evento
    summary: `${hold.service_name} — ${hold.patient_name}`,
    description: `Agendado pela Recepcionista IA (WhatsApp).\nPaciente: ${hold.patient_name}\nTelefone: ${hold.patient_phone}\nServiço: ${hold.service_name}\nProfissional: ${hold.professional_name}\nRef.: ${hold.appointment_id}`,
    start: { dateTime: hold.starts_at, timeZone: hold.timezone },
    end: { dateTime: hold.ends_at, timeZone: hold.timezone },
    transparency: 'opaque',
    extendedProperties: { private: { ria_appointment_id: hold.appointment_id, ria_source: 'recepcionista-ia' } },
  };
}

function normalizeGoogleEvents(resp) {
  return ((resp && resp.items) || [])
    .filter((e) => e && e.start && e.start.dateTime && e.transparency !== 'transparent')
    .map((e) => ({
      id: e.id, status: e.status || 'confirmed', start: e.start.dateTime, end: (e.end && e.end.dateTime) || e.start.dateTime,
      ria_appointment_id: (e.extendedProperties && e.extendedProperties.private && e.extendedProperties.private.ria_appointment_id) || null,
    }));
}

// ---------- Adaptador para software odontológico (API própria da clínica) ----------
// Contrato esperado (documentado em docs/ADAPTADOR-AGENDA.md):
//  POST   {base}/availability  {professional_refs[], time_min, time_max} -> {busy:[{professional_ref,start,end}]}
//  POST   {base}/appointments  {id, professional_ref, start, end, patient_name, patient_phone, service_code} -> {event_id}
//  DELETE {base}/appointments/{event_id}
//  GET    {base}/appointments?professional_ref=&time_min=&time_max= -> {events:[{id,start,end,status,ria_appointment_id}]}
function externalAvailabilityBody(pros, timeMin, timeMax) {
  return { professional_refs: pros.filter((p) => p.external_ref).map((p) => p.external_ref), time_min: timeMin, time_max: timeMax };
}

function normalizeExternalBusy(resp, pros) {
  const byRef = {};
  for (const p of pros) if (p.external_ref) byRef[p.external_ref] = p.id;
  if (!resp || !Array.isArray(resp.busy)) return { busy: [], verified: [], failed: pros.map((p) => p.id) };
  const busy = resp.busy.filter((b) => byRef[b.professional_ref]).map((b) => ({ professional_id: byRef[b.professional_ref], start: b.start, end: b.end }));
  return { busy, verified: pros.filter((p) => p.external_ref).map((p) => p.id), failed: pros.filter((p) => !p.external_ref).map((p) => p.id) };
}

function externalEventBody(hold) {
  return { id: hold.calendar_event_id, professional_ref: hold.external_ref, start: hold.starts_at, end: hold.ends_at,
    patient_name: hold.patient_name, patient_phone: hold.patient_phone, service_code: hold.service_code, ria_appointment_id: hold.appointment_id };
}
