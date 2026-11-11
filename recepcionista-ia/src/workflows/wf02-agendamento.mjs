import { Workflow, WF } from './_dsl.mjs';

// 02 — Agendamento: oferta de 2-3 horários reais e reserva protegida.
// Entrada: { ev, ctx, decision: { route: 'schedule'|'book', params } }
// Saída:   o mesmo item + result: { messages, state, context }
const LIBS = ['util', 'messages', 'whatsapp', 'calendar'];

const CAL = (extra) => `Object.assign({ settings: j.ctx.settings, timezone: j.ctx.clinic.timezone, clinic: { id: j.ctx.clinic.id, external_calendar_base_url: j.ctx.clinic.external_calendar_base_url } }, ${extra})`;

export default function build() {
  const w = new Workflow(WF.agendamento, 'Recepcionista IA - 02 Agendamento', { settings: { errorWorkflow: WF.monitoramento } });
  w.note('Sobre', [-60, -520], '## 02 · Agendamento\n**Oferta:** serviço → profissionais → FreeBusy (WF08) → `ria.api_offer_create` aplica funcionamento, almoço, jornada, feriados, bloqueios, duração, intervalo, antecedência e agenda do banco → 2-3 opções com validade.\n\n**Escolha:** revalida a opção → FreeBusy de novo → `ria.api_reserve` (reserva protegida por restrição de exclusão: dois pacientes nunca ficam com o mesmo horário) → cria o evento (ID determinístico) → `ria.api_appointment_confirm` → só então confirma ao paciente e envia a localização.\n\nFalha de agenda ⇒ libera a reserva e transfere para humano. Horário tomado ⇒ nova oferta.', 640, 300);
  w.subTrigger('Entrada', [0, 0]);
  w.ifTrue('É escolha de horário?', [220, 0], "$json.decision && $json.decision.route === 'book'");

  // ------------------------------------------------------------------ OFERTA
  w.pg('Registrar nome (se informado)', [460, 200], 'api_set_patient_name',
    '{ clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id, name: ($json.decision.params && $json.decision.params.set_name) || null }', { echo: true });
  w.code('Parâmetros da busca', [680, 200], `
const j = $json.input; const nameRes = $json.result || {};
const ctx = JSON.parse(JSON.stringify(j.ctx));
const p = (j.decision && j.decision.params) || {};
if (nameRes.ok === true) { ctx.patient.full_name = nameRes.full_name; ctx.patient.first_name = nameRes.first_name; }
const search = { service_code: p.service_code || null, service_id: p.service_id || null, professional_id: p.professional_id || null,
  date_from: p.date_from || null, date_to: p.date_to || null, period: p.period || null, time: p.time || null, reschedule_of: p.reschedule_of || null };
if (nameRes.ok === false) {
  return { json: Object.assign({}, j, { ctx, next: 'done', result: { messages: [msgText('Não consegui registrar esse nome. Pode me informar seu nome completo, usando apenas letras?')], state: 'awaiting_name', context: { pending: search } } }) };
}
return { json: Object.assign({}, j, { ctx, next: 'search', search, prefix: null, prefix_messages: j.prefix_messages || [] }) };`, LIBS, { each: true });
  w.ifTrue('Buscar horários?', [900, 200], "$json.next === 'search'");
  w.pg('Preparar busca', [1120, 200], 'api_offer_prepare',
    '{ clinic_id: $json.ctx.clinic.id, service_code: $json.search.service_code, service_id: $json.search.service_id, professional_id: $json.search.professional_id, date_from: $json.search.date_from, date_to: $json.search.date_to }', { echo: true });
  w.code('Avaliar preparação', [1340, 200], `
const j = $json.input; const prep = $json.result || {};
const prefix = j.prefix_messages || [];
const done = (messages, state, context) => ({ json: Object.assign({}, j, { next: 'done', result: { messages: prefix.concat(messages), state, context } }) });
if (prep.status === 'ok') {
  if (prep.out_of_range) return done([msgText('Ainda não abrimos a agenda para essa data. Podemos agendar em até ' + (j.ctx.clinic.policies.max_booking_days_ahead || 30) + ' dias. Quer outra data?')], 'idle', { pending: Object.assign({}, j.search, { date_from: null, date_to: null, service_code: prep.service.code }) });
  return { json: Object.assign({}, j, { prep, next: 'calendar',
    calendar: ${CAL("{ op: 'freebusy', provider: prep.calendar_provider, professionals: prep.professionals, time_min: prep.window_from, time_max: prep.search_to }")} }) };
}
if (prep.status === 'service_required') return done([askServiceMessage(j.ctx)], 'awaiting_service', { pending: j.search });
if (prep.status === 'service_requires_human') return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'policy', priority: 'normal' } }) };
if (prep.status === 'no_professional') return done([msgText('No momento não há profissional com agenda online para esse atendimento. Posso chamar a nossa equipe para ajudar?')], 'idle', {});
return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'booking_problem', priority: 'normal' } }) };`, LIBS, { each: true });
  w.switchOn('Próximo passo (busca)', [1560, 200], '$json.next', ['calendar', 'handoff', 'done']);
  w.execWf('Consultar agenda (WF08)', [1800, 100], WF.adaptador);
  w.code('Avaliar agenda', [2020, 100], `
const j = $json; const cr = j.calendar_result || {};
if (!cr.ok || !Array.isArray(cr.verified) || !cr.verified.length) {
  return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'technical_failure', priority: 'normal' } }) };
}
return { json: Object.assign({}, j, { next: 'offer' }) };`, [], { each: true });
  w.ifTrue('Agenda respondeu?', [2240, 100], "$json.next === 'offer'");
  w.pg('Criar oferta', [2460, 40], 'api_offer_create', `{
    clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id, conversation_id: $json.ctx.conversation.id,
    service_id: $json.prep.service.id, professional_ids: $json.calendar_result.verified,
    window_from: $json.prep.window_from, window_to: $json.prep.window_to, search_to: $json.prep.search_to,
    busy: $json.calendar_result.busy, period: $json.search.period, time: $json.search.time, reschedule_of: $json.search.reschedule_of }`, { echo: true });
  w.code('Montar oferta', [2680, 40], `
const j = $json.input; const o = $json.result || {};
const prefix = j.prefix_messages || [];
const pending = Object.assign({}, j.search, { service_code: j.prep.service.code, service_id: null });
if (o.status === 'ok') {
  return { json: Object.assign({}, j, { result: {
    messages: prefix.concat(offerMessages(o, j.prep.service.name, { period: j.search.period, slotTaken: j.prefix === 'slot_taken' })),
    state: 'awaiting_slot_choice', context: { offer_id: o.offer_id, reschedule_of: o.reschedule_of || null, pending } } }) };
}
if (o.status === 'no_slots') {
  return { json: Object.assign({}, j, { result: { messages: prefix.concat([noSlotsMessage(j.ctx, j.prep.service.name)]), state: 'idle',
    context: { pending: Object.assign({}, pending, { date_from: null, date_to: null, period: null, time: null }) } } }) };
}
return { json: Object.assign({}, j, { result: { messages: prefix.concat([msgText('Não consegui montar as opções de horário agora. Pode tentar novamente em instantes?')]), state: 'idle', context: {} } }) };`, LIBS, { each: true });

  // ------------------------------------------------------------------ ESCOLHA
  w.pg('Resolver escolha', [460, -260], 'api_offer_choose',
    '{ conversation_id: $json.ctx.conversation.id, patient_id: $json.ctx.patient.id, option_id: $json.decision.params.option_id, option_number: $json.decision.params.option_number }', { echo: true });
  w.code('Avaliar escolha', [680, -260], `
const j = $json.input; const ch = $json.result || {};
if (ch.status === 'ok') {
  return { json: Object.assign({}, j, { choice: ch, next: 'calendar',
    calendar: ${CAL("{ op: 'freebusy', provider: ch.calendar_provider, professionals: [{ id: ch.professional_id, calendar_id: ch.calendar_id, external_ref: ch.external_ref }], time_min: ch.check_from, time_max: ch.check_to }")} }) };
}
const cx = (j.ctx.conversation && j.ctx.conversation.context) || {};
const pending = cx.pending || {};
return { json: Object.assign({}, j, { next: 'reoffer', prefix: 'expired',
  search: Object.assign({ service_code: null, service_id: null, professional_id: null, date_from: null, date_to: null, period: null, time: null }, pending, { reschedule_of: cx.reschedule_of || pending.reschedule_of || null }),
  prefix_messages: [msgText('Essas opções de horário expiraram. Buscando horários atualizados para você...')] }) };`, LIBS, { each: true });
  w.ifTrue('Opção válida?', [900, -260], "$json.next === 'calendar'");
  w.execWf('Revalidar na agenda (WF08)', [1120, -340], WF.adaptador);
  w.code('Avaliar revalidação', [1340, -340], `
const j = $json; const cr = j.calendar_result || {};
if (!cr.ok || !(cr.verified || []).includes(j.choice.professional_id)) {
  return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'technical_failure', priority: 'normal' } }) };
}
return { json: Object.assign({}, j, { next: 'reserve' }) };`, [], { each: true });
  w.ifTrue('Pode reservar?', [1560, -340], "$json.next === 'reserve'");
  w.pg('Reservar horário', [1780, -400], 'api_reserve',
    '{ option_id: $json.choice.option_id, patient_id: $json.ctx.patient.id, conversation_id: $json.ctx.conversation.id, busy: $json.calendar_result.busy }', { echo: true });
  w.code('Avaliar reserva', [2000, -400], `
const j = $json.input; const r = $json.result || {};
const tz = j.ctx.clinic.timezone;
const search = { service_code: null, service_id: j.choice.service_id, professional_id: null, date_from: localDate(j.choice.starts_at, tz), date_to: null,
  period: null, time: null, reschedule_of: j.choice.reschedule_of || null };
const done = (text, state, context) => ({ json: Object.assign({}, j, { next: 'done', result: { messages: [msgText(text)], state: state || 'idle', context: context || {} } }) });
switch (r.status) {
  case 'held':
    return { json: Object.assign({}, j, { hold: r, next: 'create', calendar: ${CAL("{ op: 'create_event', provider: r.calendar_provider, hold: r }")} }) };
  case 'slot_taken':
  case 'expired':
    return { json: Object.assign({}, j, { next: 'reoffer', prefix: r.status === 'slot_taken' ? 'slot_taken' : 'expired', search, prefix_messages: [] }) };
  case 'patient_already_booked':
    return done('Você já tem uma consulta desse tipo agendada. Se quiser trocar o horário, é só me dizer "remarcar".');
  case 'too_many_appointments':
    return done('Você já tem o número máximo de consultas futuras agendadas. Posso ajudar a remarcar uma delas ou chamar a equipe.');
  case 'patient_overlap':
    return done('Você já tem outra consulta nesse mesmo horário. Quer que eu procure outro horário?', 'idle', { pending: search });
  default:
    return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'booking_problem', priority: 'normal' } }) };
}`, LIBS, { each: true });
  w.switchOn('Após reserva', [2220, -400], '$json.next', ['create', 'reoffer', 'done', 'handoff']);
  w.execWf('Criar evento na agenda (WF08)', [2460, -560], WF.adaptador);
  w.ifTrue('Evento criado?', [2680, -560], '$json.calendar_result && $json.calendar_result.ok === true');
  w.pg('Confirmar no banco', [2900, -640], 'api_appointment_confirm',
    '{ appointment_id: $json.hold.appointment_id, calendar_event_id: $json.calendar_result.event_id || $json.hold.calendar_event_id, calendar_id: $json.hold.calendar_id }', { echo: true });
  w.code('Avaliar confirmação', [3120, -640], `
const j = $json.input; const c = $json.result || {};
const tz = j.ctx.clinic.timezone;
if (c.status === 'confirmed') {
  const msgs = bookedMessages(j.ctx, j.hold);
  if (c.old_appointment) {
    const o = c.old_appointment;
    return { json: Object.assign({}, j, { confirmed: c, next: 'delete_old',
      calendar: ${CAL("{ op: 'delete_event', provider: o.calendar_provider, calendar_id: o.calendar_id, event_id: o.calendar_event_id }")},
      result: { messages: [msgText('Remarcação concluída! O horário anterior foi liberado.')].concat(msgs), state: 'idle', context: {} } }) };
  }
  return { json: Object.assign({}, j, { confirmed: c, next: 'done', result: { messages: msgs, state: 'idle', context: {} } }) };
}
// Reserva perdida enquanto o evento era criado: desfaz o evento e oferece novos horários
return { json: Object.assign({}, j, { next: 'undo', prefix: 'slot_taken', prefix_messages: [],
  calendar: ${CAL("{ op: 'delete_event', provider: j.hold.calendar_provider, calendar_id: j.hold.calendar_id, event_id: j.calendar_result.event_id || j.hold.calendar_event_id }")},
  search: { service_code: null, service_id: j.choice.service_id, professional_id: null, date_from: localDate(j.choice.starts_at, tz), date_to: null, period: null, time: null, reschedule_of: j.choice.reschedule_of || null } }) };`, LIBS, { each: true });
  w.switchOn('Após confirmação', [3340, -640], '$json.next', ['delete_old', 'undo', 'done']);
  w.execWf('Remover evento antigo (WF08)', [3580, -760], WF.adaptador);
  w.pg('Finalizar consulta antiga', [3800, -760], 'api_cancel_finalize',
    '{ appointment_id: $json.confirmed.old_appointment.appointment_id, calendar_ok: !!($json.calendar_result && $json.calendar_result.ok) }', { echo: true });
  w.code('Resultado da remarcação', [4020, -760], 'return { json: $json.input };', [], { each: true });
  w.execWf('Desfazer evento (WF08)', [3580, -600], WF.adaptador);
  w.pg('Liberar reserva', [2900, -480], 'api_appointment_release',
    "{ appointment_id: $json.hold.appointment_id, reason: 'calendar_error' }", { echo: true });
  w.code('Falha ao criar evento', [3120, -480], `
const j = $json.input;
return { json: Object.assign({}, j, { next: 'handoff', handoff: { reason: 'booking_problem', priority: 'normal' } }) };`, [], { each: true });

  // ------------------------------------------------------------------ SAÍDAS
  w.execWf('Transferir para humano (WF05)', [2460, 420], WF.humano);
  w.code('Retorno', [4300, 0], `
const j = $json;
return { json: { ev: j.ev, ctx: j.ctx, decision: j.decision, ir: j.ir, ai_ok: j.ai_ok, errors: j.errors || [],
  result: j.result || { messages: [], state: 'idle', context: {} } } };`, [], { each: true });

  // conexões
  w.connect('Entrada', 'É escolha de horário?');
  w.connect('É escolha de horário?', 'Resolver escolha', 0);
  w.connect('É escolha de horário?', 'Registrar nome (se informado)', 1);
  w.chain('Registrar nome (se informado)', 'Parâmetros da busca', 'Buscar horários?');
  w.connect('Buscar horários?', 'Preparar busca', 0);
  w.connect('Buscar horários?', 'Retorno', 1);
  w.chain('Preparar busca', 'Avaliar preparação', 'Próximo passo (busca)');
  w.connect('Próximo passo (busca)', 'Consultar agenda (WF08)', 0);
  w.connect('Próximo passo (busca)', 'Transferir para humano (WF05)', 1);
  w.connect('Próximo passo (busca)', 'Retorno', 2);
  w.connect('Próximo passo (busca)', 'Retorno', 3);
  w.chain('Consultar agenda (WF08)', 'Avaliar agenda', 'Agenda respondeu?');
  w.connect('Agenda respondeu?', 'Criar oferta', 0);
  w.connect('Agenda respondeu?', 'Transferir para humano (WF05)', 1);
  w.chain('Criar oferta', 'Montar oferta', 'Retorno');

  w.chain('Resolver escolha', 'Avaliar escolha', 'Opção válida?');
  w.connect('Opção válida?', 'Revalidar na agenda (WF08)', 0);
  w.connect('Opção válida?', 'Preparar busca', 1);
  w.chain('Revalidar na agenda (WF08)', 'Avaliar revalidação', 'Pode reservar?');
  w.connect('Pode reservar?', 'Reservar horário', 0);
  w.connect('Pode reservar?', 'Transferir para humano (WF05)', 1);
  w.chain('Reservar horário', 'Avaliar reserva', 'Após reserva');
  w.connect('Após reserva', 'Criar evento na agenda (WF08)', 0);
  w.connect('Após reserva', 'Preparar busca', 1);
  w.connect('Após reserva', 'Retorno', 2);
  w.connect('Após reserva', 'Transferir para humano (WF05)', 3);
  w.connect('Após reserva', 'Retorno', 4);
  w.connect('Criar evento na agenda (WF08)', 'Evento criado?');
  w.connect('Evento criado?', 'Confirmar no banco', 0);
  w.connect('Evento criado?', 'Liberar reserva', 1);
  w.chain('Confirmar no banco', 'Avaliar confirmação', 'Após confirmação');
  w.connect('Após confirmação', 'Remover evento antigo (WF08)', 0);
  w.connect('Após confirmação', 'Desfazer evento (WF08)', 1);
  w.connect('Após confirmação', 'Retorno', 2);
  w.connect('Após confirmação', 'Retorno', 3);
  w.chain('Remover evento antigo (WF08)', 'Finalizar consulta antiga', 'Resultado da remarcação', 'Retorno');
  w.connect('Desfazer evento (WF08)', 'Preparar busca');
  w.chain('Liberar reserva', 'Falha ao criar evento', 'Transferir para humano (WF05)');
  w.connect('Transferir para humano (WF05)', 'Retorno');
  return w;
}
