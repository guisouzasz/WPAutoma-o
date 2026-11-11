import { Workflow, WF } from './_dsl.mjs';

// 07 — Reconciliação da agenda: detecta alterações manuais no Google Calendar
// (evento apagado, movido ou sobreposto) e conclui exclusões pendentes.
export default function build() {
  const w = new Workflow(WF.reconciliacao, 'Recepcionista IA - 07 Reconciliação de Agenda', { settings: { errorWorkflow: WF.monitoramento, timezone: 'America/Sao_Paulo' } });
  w.note('Sobre', [-60, -300], '## 07 · Reconciliação\nA cada 30 min lista os eventos de cada profissional (WF08) e compara com `ria.appointments`:\n- evento removido manualmente → `missing_in_calendar`\n- horário alterado → `time_mismatch`\n- outro evento sobreposto → `conflict`\n(alertas enviados pelo WF06; o robô não cancela nada sozinho).\nTambém repete exclusões que falharam e remove eventos "órfãos" de reservas que expiraram.\n\nObs.: a DISPONIBILIDADE nunca depende desta rotina: toda oferta e toda reserva consultam o FreeBusy em tempo real.', 600, 280);
  w.schedule('A cada 30 minutos', [0, 0], { field: 'minutes', minutesInterval: 30 });
  w.subTrigger('Execução sob demanda', [0, 160]);
  w.pg('Profissionais com agenda', [220, 0], 'api_reconcile_targets', '{}');
  w.code('Expandir alvos', [440, 0], `
const res = ($json && $json.result) || {};
return (res.targets || []).map((t) => ({ json: { target: t, calendar: { op: 'list_events', provider: t.calendar_provider, calendar_id: t.calendar_id,
  external_ref: t.external_ref, time_min: t.time_min, time_max: t.time_max, settings: res.settings || {},
  clinic: { id: t.clinic_id, external_calendar_base_url: t.external_calendar_base_url } }, settings: res.settings || {} } }));`);
  w.execWf('Listar eventos (WF08)', [660, 0], WF.adaptador);
  w.ifTrue('Listagem ok?', [880, 0], '$json.calendar_result && $json.calendar_result.ok === true');
  w.pg('Reconciliar', [1100, -60], 'api_reconcile',
    '{ professional_id: $json.target.professional_id, time_min: $json.target.time_min, time_max: $json.target.time_max, events: $json.calendar_result.events }', { echo: true });
  w.code('Exclusões pendentes', [1320, -60], `
const out = [];
for (const it of $input.all()) {
  const j = it.json.input || {}; const r = it.json.result || {}; const t = j.target || {};
  const mk = (eventId, apptId) => ({ json: { appointment_id: apptId, calendar: { op: 'delete_event', provider: t.calendar_provider, calendar_id: t.calendar_id,
    event_id: eventId, settings: j.settings, clinic: { id: t.clinic_id, external_calendar_base_url: t.external_calendar_base_url } } } });
  for (const d of r.retry_deletes || []) out.push(mk(d.calendar_event_id, d.appointment_id));
  for (const o of r.orphan_events || []) out.push(mk(o.calendar_event_id, o.appointment_id));
}
return out;`);
  w.execWf('Excluir eventos (WF08)', [1540, -60], WF.adaptador);
  w.ifTrue('Excluído?', [1760, -60], '$json.calendar_result && $json.calendar_result.ok === true');
  w.pg('Marcar excluído', [1980, -120], 'api_mark_calendar_deleted', '{ appointment_id: $json.appointment_id }');
  w.chain('A cada 30 minutos', 'Profissionais com agenda', 'Expandir alvos', 'Listar eventos (WF08)', 'Listagem ok?');
  w.connect('Listagem ok?', 'Reconciliar', 0);
  w.chain('Reconciliar', 'Exclusões pendentes', 'Excluir eventos (WF08)', 'Excluído?');
  w.connect('Excluído?', 'Marcar excluído', 0);
  w.connect('Execução sob demanda', 'Profissionais com agenda');
  return w;
}
