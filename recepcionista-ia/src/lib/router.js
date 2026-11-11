// router.js — decide o próximo passo a partir da intenção VALIDADA e do estado da conversa.
// Nenhuma ação crítica acontece aqui: o roteador só escolhe o workflow e os parâmetros,
// que serão revalidados no banco (PostgreSQL) antes de qualquer alteração.
// Requer: util.js, messages.js, intent.js

const SCHEDULE_KEYS = ['service_code', 'professional_id', 'date_from', 'date_to', 'period', 'time'];

function pickSchedule(src) {
  const o = {};
  for (const k of SCHEDULE_KEYS) if (src && src[k] !== null && src[k] !== undefined && src[k] !== '') o[k] = src[k];
  return o;
}

function serviceById(ctx, id) {
  return (ctx.services || []).find((s) => s.id === id) || null;
}

function handoffRoute(base, reason, priority, extra) {
  return Object.assign({}, base, { route: 'handoff', params: Object.assign({ reason, priority }, extra || {}) });
}

function decideRoute(ctx, ir, ev) {
  const conv = ctx.conversation || {};
  const st = conv.state || 'idle';
  const cx = conv.context || {};
  const settings = ctx.settings || {};
  const i = ir.intent;
  const text = (ev && ev.text) || '';
  const base = { intent: i, understood: true, unknown: false, messages: [], state: 'idle', context: {}, params: {} };

  // 1) Consentimento
  if (i === 'opt_out') {
    return Object.assign(base, { route: 'consent', params: { kind: 'opt_out' },
      messages: [msgText('Pronto, você não receberá mais mensagens automáticas (lembretes). Se quiser voltar a receber, envie VOLTAR. Você continua podendo falar conosco por aqui quando quiser.')] });
  }
  if (i === 'opt_in') {
    return Object.assign(base, { route: 'consent', params: { kind: 'opt_in_again' },
      messages: [msgText('Combinado! Você voltará a receber lembretes das suas consultas.')] });
  }

  // 2) Segurança e atendimento humano (prevalecem sobre qualquer fluxo)
  if (ir.urgency === 'emergency') return handoffRoute(base, 'emergency', 'urgent', { emergency: true });
  if (i === 'human') return handoffRoute(base, 'patient_request', 'normal');
  if (i === 'complaint') return handoffRoute(base, 'complaint', 'high');
  if (ir.urgency === 'possible' || i === 'urgency') return handoffRoute(base, 'urgency', 'urgent');

  // 3) Respostas dependentes do estado
  const offerOpen = !!(ctx.offer && ctx.offer.options && ctx.offer.options.length);
  if (i === 'choose_option' && (ir.option_id || (ir.option_number && offerOpen))) {
    return Object.assign(base, { route: 'book', params: { option_id: ir.option_id || null, option_number: ir.option_number || null } });
  }
  if (i === 'choose_option' && !offerOpen) {
    return Object.assign(base, { route: 'reply', state: 'idle', context: { pending: cx.pending || {} },
      messages: [msgText('Essas opções de horário expiraram. Quer que eu procure novos horários? Me diga o dia ou período de preferência.')] });
  }

  if (st === 'awaiting_slot_choice' && i === 'deny') {
    const svc = ctx.offer ? serviceById(ctx, ctx.offer.service_id) : null;
    return Object.assign(base, { route: 'reply', state: 'idle',
      context: { pending: Object.assign({}, cx.pending || {}, svc ? { service_code: svc.code } : {}, cx.reschedule_of ? { reschedule_of: cx.reschedule_of } : {}) },
      messages: [msgText('Sem problemas! Me diga outro dia ou período que prefere (por exemplo: "sexta à tarde") que eu procuro novos horários.')] });
  }

  if (st === 'awaiting_appointment_choice' && (ir.appointment_id || ir.appointment_number)) {
    const appts = ctx.appointments || [];
    const allowed = Array.isArray(cx.appointment_ids) ? cx.appointment_ids : appts.map((a) => a.id);
    const id = ir.appointment_id || (appts[ir.appointment_number - 1] && appts[ir.appointment_number - 1].id);
    if (id && allowed.includes(id)) {
      return Object.assign(base, { route: 'manage',
        params: { action: cx.purpose === 'cancel' ? 'cancel_prompt' : 'reschedule_start', appointment_id: id, prefs: cx.prefs || {} } });
    }
  }

  if (st === 'awaiting_cancel_confirmation' && cx.appointment_id) {
    if (i === 'affirm') return Object.assign(base, { route: 'manage', params: { action: 'cancel_execute', appointment_id: cx.appointment_id } });
    if (i === 'deny') return Object.assign(base, { route: 'reply', messages: [msgText('Tudo certo, sua consulta continua mantida. Posso ajudar em algo mais?')] });
  }

  if (st === 'awaiting_name') {
    const name = ir.patient_name || (['provide_name', 'other', 'greeting'].includes(i) ? validName(text) : null);
    if (name && (i === 'provide_name' || normalizeText(text).split(' ').length <= 6)) {
      return Object.assign(base, { route: 'schedule', params: Object.assign({ action: 'offer', set_name: name }, cx.pending || {}) });
    }
  }

  // 4) Intenções gerais
  const pendingCtx = ['awaiting_service', 'awaiting_name', 'awaiting_slot_choice'].includes(st) || (cx.pending && st === 'idle') ? (cx.pending || {}) : {};
  switch (i) {
    case 'greeting': {
      const msgs = greetingMessages(ctx, ir.reply);
      return Object.assign(base, { route: 'reply', messages: msgs, privacy_notice: !!(ctx.patient && (ctx.patient.is_new || !ctx.patient.privacy_notice_shown)) });
    }
    case 'thanks':
      return Object.assign(base, { route: 'reply', messages: [msgText(ir.reply && ir.reply.length > 3 ? ir.reply : 'Por nada! Se precisar, é só chamar por aqui. 😊')] });
    case 'location':
      return Object.assign(base, { route: 'reply', messages: locationMessages(ctx) });
    case 'hours':
      return Object.assign(base, { route: 'reply', messages: [hoursMessage(ctx)] });
    case 'faq': {
      const f = (ctx.faqs || []).find((x) => x.id === ir.faq_id);
      if (f) return Object.assign(base, { route: 'reply', messages: [msgText(f.answer), menuMessage('Posso ajudar com mais alguma coisa?')] });
      return handoffRoute(base, 'out_of_scope', 'normal');
    }
    case 'services_info': {
      const svc = ir.service_code ? (ctx.services || []).find((s) => s.code === ir.service_code) : null;
      if (svc) return Object.assign(base, { route: 'reply', messages: serviceInfoMessages(ctx, svc), context: { pending: { service_code: svc.code } } });
      return handoffRoute(base, 'out_of_scope', 'normal');
    }
    case 'out_of_scope':
      return handoffRoute(base, 'out_of_scope', 'normal');
    case 'my_appointments':
      return Object.assign(base, { route: 'manage', params: { action: 'list' } });
    case 'cancel':
      return Object.assign(base, { route: 'manage', params: { action: 'cancel_start', appointment_id: ir.appointment_id || null } });
    case 'reschedule':
      return Object.assign(base, { route: 'manage', params: { action: 'reschedule_start', appointment_id: ir.appointment_id || null, prefs: pickSchedule(ir) } });
    case 'confirm_attendance':
      return Object.assign(base, { route: 'manage', params: { action: 'confirm_attendance', appointment_id: ir.appointment_id || null } });
    case 'schedule':
    case 'provide_name': {
      let params = Object.assign({}, pendingCtx, pickSchedule(ir));
      if (st === 'awaiting_slot_choice' && ctx.offer) {
        const svc = serviceById(ctx, ctx.offer.service_id);
        if (svc && !params.service_code) params.service_code = svc.code;
        if (ctx.offer.reschedule_of) params.reschedule_of = ctx.offer.reschedule_of;
      }
      if (ir.more && ctx.offer && ctx.offer.options && ctx.offer.options.length) {
        const last = ctx.offer.options[ctx.offer.options.length - 1];
        params.after = last.starts_at;
      }
      if (cx.reschedule_of && !params.reschedule_of) params.reschedule_of = cx.reschedule_of;
      const setName = ir.patient_name && !(ctx.patient && ctx.patient.full_name) ? ir.patient_name : null;
      if (!params.service_code) {
        return Object.assign(base, { route: 'reply', state: 'awaiting_service', context: { pending: params },
          messages: [askServiceMessage(ctx, params.date_from ? 'Claro, vou verificar a agenda!' : 'Claro, vamos agendar!')] });
      }
      if (!(ctx.patient && ctx.patient.full_name) && !setName && !params.reschedule_of) {
        return Object.assign(base, { route: 'reply', state: 'awaiting_name', context: { pending: params }, messages: [askNameMessage()] });
      }
      return Object.assign(base, { route: 'schedule', params: Object.assign({ action: 'offer' }, params, setName ? { set_name: setName } : {}) });
    }
    case 'affirm':
      if (cx.pending && cx.pending.service_code) {
        return decideRoute(ctx, Object.assign({}, ir, { intent: 'schedule' }), ev);
      }
      return Object.assign(base, { route: 'reply', messages: [menuMessage('Certo! Como posso ajudar?')] });
    case 'deny':
      return Object.assign(base, { route: 'reply', messages: [msgText('Tudo bem! Se precisar de algo, é só me chamar por aqui.')] });
    case 'unsupported_media':
      return Object.assign(base, { route: 'reply', state: st, context: cx, messages: [unsupportedMediaMessage()] });
    case 'audio_failed':
      return Object.assign(base, { route: 'reply', state: st, context: cx, understood: false,
        messages: [msgText('Não consegui entender o seu áudio. Pode escrever a mensagem ou gravar novamente?')] });
    case 'audio_too_long':
      return Object.assign(base, { route: 'reply', state: st, context: cx,
        messages: [msgText('Seu áudio ficou um pouco longo para mim. Pode enviar um áudio mais curto ou escrever a mensagem?')] });
    default: {
      const unknownMax = Number(settings.unknown_max || 2);
      if ((conv.unknown_count || 0) + 1 >= unknownMax + 1) {
        return handoffRoute(Object.assign(base, { unknown: true }), 'out_of_scope', 'normal');
      }
      return Object.assign(base, { route: 'reply', understood: false, unknown: true, state: st === 'idle' ? 'idle' : st, context: cx,
        messages: [notUnderstoodMessage(ctx, ir.injection_suspected ? ir.reply : ir.reply)] });
    }
  }
}
