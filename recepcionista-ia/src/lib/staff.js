// staff.js — comandos da equipe enviados pelo WhatsApp oficial da clínica.
//   #fila                 lista atendimentos aguardando
//   #assumir ABCD         assume o atendimento ABCD (o robô para de responder)
//   #ABCD texto           envia "texto" ao paciente do atendimento ABCD
//   #devolver ABCD        devolve o atendimento ao robô
//   #atender 5511999999999  assume uma conversa que estava com o robô
//   #ajuda                mostra os comandos
// Requer: util.js

function parseStaffCommand(text) {
  const raw = String(text || '').trim();
  if (!raw.startsWith('#')) return { cmd: 'help' };
  const m = raw.match(/^#\s*([A-Za-zÀ-ú0-9]+)\s*([\s\S]*)$/);
  if (!m) return { cmd: 'help' };
  const word = normalizeText(m[1]);
  const rest = m[2].trim();
  if (word === 'fila' || word === 'lista') return { cmd: 'list' };
  if (word === 'ajuda' || word === 'help' || word === 'comandos') return { cmd: 'help' };
  if (word === 'assumir' || word === 'pegar') return { cmd: 'assign', code: rest.split(/\s+/)[0].toUpperCase() };
  if (word === 'devolver' || word === 'encerrar' || word === 'robo') return { cmd: 'release', code: rest.split(/\s+/)[0].toUpperCase() };
  if (word === 'atender') return { cmd: 'takeover', patient_wa_id: rest.replace(/\D/g, '') };
  if (/^[a-z0-9]{4}$/.test(word)) {
    if (!rest) return { cmd: 'help' };
    return { cmd: 'reply', code: word.toUpperCase(), text: rest.slice(0, 4000) };
  }
  return { cmd: 'help' };
}

const STAFF_HELP = 'Comandos da equipe:\n' +
  '#fila — atendimentos aguardando\n' +
  '#assumir CODIGO — assumir atendimento\n' +
  '#CODIGO mensagem — responder ao paciente\n' +
  '#devolver CODIGO — devolver ao robô\n' +
  '#atender 55DDDNUMERO — assumir conversa de um paciente';

// Monta mensagens para a equipe respeitando a janela de 24h do WhatsApp:
// dentro da janela => texto livre; fora => template Utility configurado (alerta_equipe).
function buildStaffOutbox(staffList, text, ctx, purpose) {
  const tpl = (ctx.clinic && ctx.clinic.staff_alert_template) || {};
  const s = ctx.settings || {};
  return (staffList || []).map((st) => ({
    to: st.wa_id,
    phone_number_id: ctx.clinic.whatsapp_phone_number_id,
    clinic_id: ctx.clinic.id,
    staff_id: st.id,
    purpose: purpose || 'handoff',
    message: st.in_window || !tpl.name ? msgText(text) : buildStaffAlertTemplate(tpl, text),
    graph_base: s.graph_api_base,
    graph_version: s.graph_api_version,
  }));
}

function patientOutbox(ctx, patientId, waId, messages, purpose) {
  const s = ctx.settings || {};
  return (messages || []).map((m) => ({
    to: waId, phone_number_id: ctx.clinic.whatsapp_phone_number_id, clinic_id: ctx.clinic.id, patient_id: patientId,
    purpose: purpose || 'reply', message: m, graph_base: s.graph_api_base, graph_version: s.graph_api_version,
  }));
}
