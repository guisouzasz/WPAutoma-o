import { Workflow, WF } from './_dsl.mjs';

// 03 — Consultas do paciente, remarcação, cancelamento e confirmação de presença.
// Sempre parte da lista de consultas DO PRÓPRIO paciente (ria.api_patient_appointments);
// IDs vindos de botões são conferidos contra essa lista e novamente no banco.
const LIBS = ['util', 'messages', 'whatsapp'];
const CAL = (extra) => `Object.assign({ settings: j.ctx.settings, timezone: j.ctx.clinic.timezone, clinic: { id: j.ctx.clinic.id, external_calendar_base_url: j.ctx.clinic.external_calendar_base_url } }, ${extra})`;

export default function build() {
  const w = new Workflow(WF.remarcacao, 'Recepcionista IA - 03 Remarcação e Cancelamento', { settings: { errorWorkflow: WF.monitoramento } });
  w.note('Sobre', [-60, -460], '## 03 · Remarcação e cancelamento\n- Lista somente consultas do próprio paciente.\n- **Cancelar:** verifica política → pede confirmação explícita (Sim/Não) → `cancel_requested` → remove da agenda → `cancelled`. Falha na agenda ⇒ reverte e transfere para humano.\n- **Remarcar:** verifica política → oferece horários (WF02) mantendo a consulta original até a nova estar confirmada.\n- **Confirmar presença:** botão do lembrete.', 600, 260);
  w.subTrigger('Entrada', [0, 0]);
  w.pg('Consultas do paciente', [220, 0], 'api_patient_appointments', '{ clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id }', { echo: true });
  w.code('Decidir ação', [440, 0], `
const j = $json.input; const appts = ($json.result && $json.result.appointments) || [];
const p = (j.decision && j.decision.params) || {};
const done = (messages, state, context) => ({ json: Object.assign({}, j, { appts, next: 'done', result: { messages, state: state || 'idle', context: context || {} } }) });
const go = (next, extra) => ({ json: Object.assign({}, j, { appts, next }, extra) });
const own = (id) => appts.find((a) => a.id === id);
const notFound = () => done([msgText('Não encontrei essa consulta entre as suas consultas futuras. Posso ajudar com outra coisa?')]);
const none = () => done([msgButtons('Não encontrei consultas futuras no seu cadastro. Quer agendar uma?', [{ id: 'MENU:SCHEDULE', title: 'Agendar consulta' }])]);
switch (p.action) {
  case 'list': {
    if (!appts.length) return none();
    const btns = [{ id: 'MENU:SCHEDULE', title: 'Agendar outra' }];
    if (appts.length === 1) btns.push({ id: 'RESCHEDULE:' + appts[0].id, title: 'Remarcar' }, { id: 'CANCEL:' + appts[0].id, title: 'Cancelar' });
    return done([msgButtons('Suas próximas consultas:\\n\\n' + appointmentsListText(appts), btns)]);
  }
  case 'cancel_start':
  case 'reschedule_start': {
    const purpose = p.action === 'cancel_start' ? 'cancel' : 'reschedule';
    if (!appts.length) return none();
    if (p.appointment_id && !own(p.appointment_id)) return notFound();
    const target = p.appointment_id ? own(p.appointment_id) : (appts.length === 1 ? appts[0] : null);
    if (!target) return done([chooseAppointmentMessage(appts, purpose)], 'awaiting_appointment_choice', { purpose, appointment_ids: appts.map((a) => a.id), prefs: p.prefs || {} });
    return purpose === 'cancel' ? go('cancel_check', { appointment: target }) : go('reschedule_check', { appointment: target, prefs: p.prefs || {} });
  }
  case 'cancel_prompt': {
    const t = own(p.appointment_id); if (!t) return notFound();
    return go('cancel_check', { appointment: t });
  }
  case 'cancel_execute': {
    const t = own(p.appointment_id); if (!t) return notFound();
    return go('cancel_exec', { appointment: t });
  }
  case 'confirm_attendance': {
    const t = p.appointment_id ? own(p.appointment_id) : appts[0];
    if (!t) return p.appointment_id ? notFound() : none();
    return go('attend', { appointment: t });
  }
  default:
    return done([menuMessage('Como posso ajudar?')]);
}`, LIBS, { each: true });
  w.switchOn('Próximo passo', [660, 0], '$json.next', ['cancel_check', 'cancel_exec', 'reschedule_check', 'attend', 'done']);

  // --- cancelamento: confirmação explícita ---
  w.pg('Verificar cancelamento', [920, -360], 'api_cancel_check',
    '{ clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id, appointment_id: $json.appointment.id }', { echo: true });
  w.code('Pedir confirmação', [1140, -360], `
const j = $json.input; const r = $json.result || {};
if (r.status === 'ok') return { json: Object.assign({}, j, { next: 'done', result: { messages: [cancelConfirmMessage(r.label, r.late, j.ctx)], state: 'awaiting_cancel_confirmation', context: { appointment_id: r.appointment_id } } }) };
if (r.status === 'policy_handoff') return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'policy', priority: 'normal' } }) };
return { json: Object.assign({}, j, { next: 'done', result: { messages: [msgText('Essa consulta não pode mais ser cancelada por aqui. Posso chamar a equipe?')], state: 'idle', context: {} } }) };`, LIBS, { each: true });

  // --- cancelamento: execução ---
  w.pg('Solicitar cancelamento', [920, -180], 'api_cancel_request',
    "{ clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id, appointment_id: $json.appointment.id, actor: 'patient', reason: 'patient_request' }", { echo: true });
  w.code('Avaliar pedido', [1140, -180], `
const j = $json.input; const r = $json.result || {};
if (r.status === 'ok') return { json: Object.assign({}, j, { cancel: r, next: 'calendar',
  calendar: ${CAL("{ op: 'delete_event', provider: r.calendar_provider, calendar_id: r.calendar_id, event_id: r.calendar_event_id }")} }) };
if (r.status === 'policy_handoff') return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'policy', priority: 'normal' } }) };
return { json: Object.assign({}, j, { next: 'done', result: { messages: [msgText('Não encontrei essa consulta ativa para cancelar. Posso ajudar com outra coisa?')], state: 'idle', context: {} } }) };`, LIBS, { each: true });
  w.ifTrue('Cancelamento aceito?', [1360, -180], "$json.next === 'calendar'");
  w.execWf('Remover da agenda (WF08)', [1580, -260], WF.adaptador);
  w.ifTrue('Removido da agenda?', [1800, -260], '$json.calendar_result && $json.calendar_result.ok === true');
  w.pg('Concluir cancelamento', [2020, -340], 'api_cancel_finalize', '{ appointment_id: $json.cancel.appointment_id, calendar_ok: true }', { echo: true });
  w.code('Cancelamento concluído', [2240, -340], `
const j = $json.input;
return { json: Object.assign({}, j, { next: 'done', result: { state: 'idle', context: {}, messages: [msgButtons(
  'Pronto, sua consulta de ' + j.cancel.label + ' foi cancelada. Quer agendar um novo horário?',
  [{ id: 'MENU:SCHEDULE', title: 'Agendar novo horário' }, { id: 'NO', title: 'Agora não' }])] } }) };`, LIBS, { each: true });
  w.pg('Reverter cancelamento', [2020, -180], 'api_cancel_revert', '{ appointment_id: $json.cancel.appointment_id }', { echo: true });
  w.code('Falha no cancelamento', [2240, -180], `
const j = $json.input;
return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'technical_failure', priority: 'normal' } }) };`, [], { each: true });

  // --- remarcação ---
  w.pg('Verificar remarcação', [920, 40], 'api_reschedule_check',
    '{ clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id, appointment_id: $json.appointment.id }', { echo: true });
  w.code('Preparar remarcação', [1140, 40], `
const j = $json.input; const r = $json.result || {};
if (r.status === 'ok') {
  const prefs = j.prefs || {};
  return { json: Object.assign({}, j, { next: 'schedule',
    prefix_messages: [msgText('Vamos remarcar sua consulta de ' + r.label + '. Ela continua garantida até você confirmar o novo horário.')],
    decision: Object.assign({}, j.decision, { route: 'schedule', params: { action: 'offer', service_code: r.service_code, reschedule_of: r.appointment_id,
      professional_id: prefs.professional_id || null, date_from: prefs.date_from || null, date_to: prefs.date_to || null, period: prefs.period || null, time: prefs.time || null } }) }) };
}
if (r.status === 'policy_handoff') return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'policy', priority: 'normal' } }) };
return { json: Object.assign({}, j, { next: 'done', result: { messages: [msgText('Não encontrei essa consulta ativa para remarcar.')], state: 'idle', context: {} } }) };`, LIBS, { each: true });
  w.ifTrue('Oferecer horários?', [1360, 40], "$json.next === 'schedule'");
  w.execWf('Oferecer novos horários (WF02)', [1580, -20], WF.agendamento);

  // --- confirmação de presença ---
  w.pg('Confirmar presença', [920, 220], 'api_attendance_confirm',
    '{ clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id, appointment_id: $json.appointment.id }', { echo: true });
  w.code('Presença confirmada', [1140, 220], `
const j = $json.input; const r = $json.result || {};
const text = r.status === 'ok' ? 'Presença confirmada para ' + r.label + '. Obrigado e até lá! 😊' : 'Não encontrei essa consulta para confirmar. Posso ajudar com outra coisa?';
return { json: Object.assign({}, j, { next: 'done', result: { messages: [msgText(text)], state: 'idle', context: {} } }) };`, LIBS, { each: true });

  // --- saída ---
  w.switchOn('Encaminhar', [2500, 0], '$json.next', ['handoff', 'done']);
  w.execWf('Transferir para humano (WF05)', [2740, -80], WF.humano);
  w.code('Retorno', [2980, 0], `
const j = $json;
return { json: { ev: j.ev, ctx: j.ctx, decision: j.decision, ir: j.ir, ai_ok: j.ai_ok, errors: j.errors || [],
  result: j.result || { messages: [], state: 'idle', context: {} } } };`, [], { each: true });

  w.chain('Entrada', 'Consultas do paciente', 'Decidir ação', 'Próximo passo');
  w.connect('Próximo passo', 'Verificar cancelamento', 0);
  w.connect('Próximo passo', 'Solicitar cancelamento', 1);
  w.connect('Próximo passo', 'Verificar remarcação', 2);
  w.connect('Próximo passo', 'Confirmar presença', 3);
  w.connect('Próximo passo', 'Retorno', 4);
  w.connect('Próximo passo', 'Retorno', 5);
  w.connect('Verificar cancelamento', 'Pedir confirmação');
  w.connect('Pedir confirmação', 'Encaminhar');
  w.chain('Solicitar cancelamento', 'Avaliar pedido', 'Cancelamento aceito?');
  w.connect('Cancelamento aceito?', 'Remover da agenda (WF08)', 0);
  w.connect('Cancelamento aceito?', 'Encaminhar', 1);
  w.connect('Remover da agenda (WF08)', 'Removido da agenda?');
  w.connect('Removido da agenda?', 'Concluir cancelamento', 0);
  w.connect('Removido da agenda?', 'Reverter cancelamento', 1);
  w.chain('Concluir cancelamento', 'Cancelamento concluído', 'Encaminhar');
  w.chain('Reverter cancelamento', 'Falha no cancelamento', 'Encaminhar');
  w.chain('Verificar remarcação', 'Preparar remarcação', 'Oferecer horários?');
  w.connect('Oferecer horários?', 'Oferecer novos horários (WF02)', 0);
  w.connect('Oferecer horários?', 'Encaminhar', 1);
  w.connect('Oferecer novos horários (WF02)', 'Retorno');
  w.chain('Confirmar presença', 'Presença confirmada', 'Encaminhar');
  w.connect('Encaminhar', 'Transferir para humano (WF05)', 0);
  w.connect('Encaminhar', 'Retorno', 1);
  w.connect('Encaminhar', 'Retorno', 2);
  w.connect('Transferir para humano (WF05)', 'Retorno');
  return w;
}
