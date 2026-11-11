// messages.js — textos oficiais (pt-BR) e formato normalizado de mensagens de saída.
// Formatos: {type:'text', text} | {type:'buttons', text, buttons:[{id,title}]} |
//           {type:'list', text, button, rows:[{id,title,description}]} |
//           {type:'location', latitude, longitude, name, address} | {type:'template', ...}
// Requer: util.js

function msgText(text) { return { type: 'text', text: truncate(text, 4000) }; }
function msgButtons(text, buttons) {
  return { type: 'buttons', text: truncate(text, 1024), buttons: (buttons || []).slice(0, 3).map((b) => ({ id: String(b.id).slice(0, 256), title: truncate(b.title, 20) })) };
}
function msgList(text, button, rows) {
  return { type: 'list', text: truncate(text, 1024), button: truncate(button, 20),
    rows: (rows || []).slice(0, 10).map((r) => ({ id: String(r.id).slice(0, 200), title: truncate(r.title, 24), description: r.description ? truncate(r.description, 72) : undefined })) };
}

const DEFAULT_EMERGENCY = 'Se houver sangramento intenso que não para, inchaço que dificulta respirar ou engolir, febre alta com inchaço no rosto ou trauma forte na boca ou rosto, procure agora um pronto-socorro ou ligue 192 (SAMU).';

function clinicMsg(ctx, key, fallback) {
  const m = (ctx.clinic && ctx.clinic.messages) || {};
  return m[key] || fallback || '';
}

function menuMessage(text) {
  return msgButtons(text || 'Como posso ajudar?', [
    { id: 'MENU:SCHEDULE', title: 'Agendar consulta' },
    { id: 'MENU:APPTS', title: 'Minhas consultas' },
    { id: 'MENU:HUMAN', title: 'Falar com a equipe' },
  ]);
}

function greetingMessages(ctx, aiReply) {
  const p = ctx.patient || {};
  const out = [];
  const name = p.first_name ? `, ${p.first_name}` : '';
  if (p.is_new || !p.privacy_notice_shown) {
    out.push(msgText(clinicMsg(ctx, 'welcome', `Olá! Sou a assistente virtual da ${ctx.clinic.name}.`)));
    const notice = clinicMsg(ctx, 'privacy_notice', '');
    if (notice) out.push(msgText(notice));
  } else {
    out.push(msgText(aiReply && aiReply.length > 3 ? aiReply : `Olá${name}! Que bom falar com você novamente.`));
  }
  out.push(menuMessage('Como posso ajudar?'));
  return out;
}

function askServiceMessage(ctx, prefix) {
  const rows = (ctx.services || []).filter((s) => s.bookable_by_bot).map((s) => ({
    id: 'SVC:' + s.code, title: s.name, description: s.duration_minutes ? `Cerca de ${s.duration_minutes} min` : undefined,
  }));
  return msgList((prefix ? prefix + '\n\n' : '') + 'Para qual atendimento você gostaria de agendar?', 'Ver serviços', rows);
}

function askNameMessage() {
  return msgText('Para fazer o seu cadastro, qual é o seu nome completo?');
}

function periodLabel(p) {
  return { morning: 'pela manhã', afternoon: 'à tarde', evening: 'à noite' }[p] || '';
}

function offerMessages(offer, serviceName, opts) {
  const o = opts || {};
  const lines = offer.options.map((x) => `${x.option_number}) ${x.label} com ${x.professional_name}`);
  let head = o.slotTaken ? 'Que pena, esse horário acabou de ser ocupado. ' : '';
  if (offer.alternative_dates) head += 'Não encontrei horários na data pedida, mas tenho estas opções próximas';
  else head += 'Tenho estes horários disponíveis';
  head += serviceName ? ` para ${serviceName}:` : ':';
  if (offer.period_relaxed && o.period) head = `Não há horários ${periodLabel(o.period)} nesse período. ` + head;
  const body = `${head}\n\n${lines.join('\n')}\n\nToque no horário desejado ou responda com o número. Assim que você escolher, eu confirmo na agenda.`;
  return [msgButtons(body, offer.options.map((x) => ({ id: 'OPT:' + x.option_id, title: x.short_label || x.label })))];
}

function noSlotsMessage(ctx, serviceName) {
  return msgText(`Não encontrei horários livres para ${serviceName || 'esse atendimento'} nos próximos dias. ` +
    `Nosso horário de funcionamento é: ${ctx.clinic.hours_summary}. Quer que eu tente outra data ou período, ou prefere falar com a equipe?`);
}

function bookedMessages(ctx, b) {
  const c = ctx.clinic;
  const out = [msgText(
    `Pronto${ctx.patient && ctx.patient.first_name ? ', ' + ctx.patient.first_name : ''}! Sua consulta está agendada ✅\n\n` +
    `📅 ${b.label}\n🦷 ${b.service_name}\n👩‍⚕️ ${b.professional_name}\n📍 ${c.name} — ${c.address}` +
    (c.maps_url ? `\n🗺️ ${c.maps_url}` : '') +
    `\n\nVocê receberá um lembrete um dia antes. Para remarcar ou cancelar, é só me escrever por aqui.` +
    (clinicMsg(ctx, 'cancel_policy') ? `\n\n${clinicMsg(ctx, 'cancel_policy')}` : ''))];
  const loc = locationMessage(ctx);
  if (loc) out.push(loc);
  return out;
}

function locationMessage(ctx) {
  const c = ctx.clinic || {};
  if (c.latitude === null || c.latitude === undefined || c.longitude === null || c.longitude === undefined) return null;
  return { type: 'location', latitude: Number(c.latitude), longitude: Number(c.longitude), name: c.name, address: c.address };
}

function locationMessages(ctx) {
  const c = ctx.clinic;
  const out = [msgText(`📍 ${c.name}\n${c.address}` + (c.maps_url ? `\n\nComo chegar: ${c.maps_url}` : ''))];
  const loc = locationMessage(ctx);
  if (loc) out.push(loc);
  return out;
}

function hoursMessage(ctx) {
  const c = ctx.clinic;
  return msgText(`Nosso horário de funcionamento é:\n${c.hours_summary.split('; ').join('\n')}` +
    (c.is_open_now ? '\n\nEstamos abertos agora.' : (c.next_opening_label ? `\n\nAbrimos novamente ${c.next_opening_label}.` : '')));
}

function appointmentsListText(appts) {
  return appts.map((a, i) => `${i + 1}) ${a.label} — ${a.service_name} com ${a.professional_name}`).join('\n');
}

function chooseAppointmentMessage(appts, purpose) {
  const verb = purpose === 'cancel' ? 'cancelar' : 'remarcar';
  const text = `Você tem estas consultas:\n\n${appointmentsListText(appts)}\n\nQual delas deseja ${verb}?`;
  if (appts.length <= 3) return msgButtons(text, appts.map((a, i) => ({ id: 'APPT:' + a.id, title: `${i + 1}) ${a.short_label}` })));
  return msgList(text, 'Escolher', appts.map((a, i) => ({ id: 'APPT:' + a.id, title: a.short_label, description: `${a.service_name} – ${a.professional_name}` })));
}

function cancelConfirmMessage(label, late, ctx) {
  const policy = late ? `\n\nAtenção: ${clinicMsg(ctx, 'cancel_policy', 'o cancelamento está sendo feito com pouca antecedência.')}` : '';
  return msgButtons(`Confirma o cancelamento da consulta de ${label}?${policy}`, [
    { id: 'YES', title: 'Sim, cancelar' },
    { id: 'NO', title: 'Não, manter' },
  ]);
}

function serviceInfoMessages(ctx, svc) {
  const parts = [`Sim! Fazemos ${svc.name.toLowerCase()}.`];
  if (svc.description) parts.push(svc.description);
  if (svc.price_info) parts.push(svc.price_info);
  const out = [msgText(parts.join(' '))];
  if (svc.bookable_by_bot) out.push(msgButtons('Quer que eu veja os horários disponíveis?', [{ id: 'SVC:' + svc.code, title: 'Ver horários' }, { id: 'MENU:HUMAN', title: 'Falar com a equipe' }]));
  else out.push(msgButtons('Esse agendamento é feito pela nossa equipe. Posso chamar alguém para você?', [{ id: 'MENU:HUMAN', title: 'Sim, por favor' }]));
  return out;
}

function notUnderstoodMessage(ctx, aiReply) {
  return menuMessage((aiReply && aiReply.length > 3 ? aiReply + '\n\n' : 'Desculpe, não entendi muito bem. ') +
    'Posso ajudar com agendamentos, remarcações, cancelamentos e informações da clínica.');
}

function technicalErrorMessage() {
  return msgText('Desculpe, tive uma instabilidade técnica agora. Já avisei a nossa equipe, que vai continuar o seu atendimento por aqui.');
}

function unsupportedMediaMessage() {
  return msgText('Por aqui eu consigo entender mensagens de texto e áudio. Por segurança, não envie fotos, exames ou documentos. Como posso ajudar?');
}
