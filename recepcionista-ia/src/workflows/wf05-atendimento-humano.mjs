import { Workflow, WF, CRED } from './_dsl.mjs';

// 05 — Atendimento humano (estados BOT/HUMAN).
// Ações: open (transferir), relay (paciente fala durante modo HUMANO), staff_command (equipe
// responde pelo WhatsApp oficial com #comandos) e admin (API HTTP protegida por cabeçalho).
const LIBS = ['util', 'messages', 'whatsapp', 'staff'];

const REASON_PT = `{ patient_request: 'pediu para falar com a equipe', urgency: 'possível urgência odontológica', emergency: 'POSSÍVEL EMERGÊNCIA',
  complaint: 'reclamação', out_of_scope: 'pergunta fora da base de conhecimento', booking_problem: 'problema no agendamento',
  technical_failure: 'falha técnica', policy: 'regra da clínica exige atendimento humano', staff_takeover: 'equipe assumiu' }`;

export default function build() {
  const w = new Workflow(WF.humano, 'Recepcionista IA - 05 Atendimento Humano', { settings: { errorWorkflow: WF.monitoramento } });
  w.note('Como a equipe atende', [-80, -620], '## 05 · Atendimento humano\nQuando a conversa vai para **HUMANO**, o robô para de responder. A equipe (números cadastrados em `ria.staff_members`) recebe o aviso no próprio WhatsApp e responde **pelo número oficial da clínica**, via comandos:\n- `#fila` — atendimentos aguardando\n- `#assumir ABCD` — assumir\n- `#ABCD texto` — responder ao paciente\n- `#devolver ABCD` — devolver ao robô\n- `#atender 55DDDNUMERO` — assumir conversa\n\nTambém há a API administrativa (Webhook com cabeçalho secreto) e devolução automática por inatividade (`human_timeout_minutes`).\nFora da janela de 24h a equipe recebe o template Utility `alerta_equipe`.', 620, 360);
  w.subTrigger('Entrada', [0, 0]);
  w.add('API administrativa', 'n8n-nodes-base.webhook', 2, {
    httpMethod: 'POST', path: 'recepcionista/atendimento', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, [0, 520], { credentials: CRED.adminApi, webhookId: 'b7e4c0de-0a11-4c1a-9c55-5e7c1a0e0005' });

  w.code('Identificar ação', [220, 0], `
const j = $json;
let action = j.action || null;
if (!action) {
  if (j.handoff || (j.decision && j.decision.route === 'handoff')) action = 'open';
  else if (j.ctx && j.ctx.status === 'staff') action = 'staff_command';
  else if (j.path === 'human') action = 'relay';
}
return { json: Object.assign({}, j, { action }) };`, [], { each: true });
  w.switchOn('Ação', [440, 0], '$json.action', ['open', 'relay', 'staff_command']);

  // ------------------------------------------------------------- ABRIR
  w.pg('Abrir atendimento humano', [700, -260], 'api_handoff_open', `{
    clinic_id: $json.ctx.clinic.id, conversation_id: $json.ctx.conversation.id,
    reason: ($json.handoff && $json.handoff.reason) || ($json.decision && $json.decision.params && $json.decision.params.reason) || 'patient_request',
    priority: ($json.handoff && $json.handoff.priority) || ($json.decision && $json.decision.params && $json.decision.params.priority) || 'normal' }`, { echo: true });
  w.code('Mensagens da transferência', [920, -260], `
const j = $json.input; const h = $json.result || {}; const ctx = j.ctx; const ev = j.ev || {};
const hp = j.handoff || (j.decision && j.decision.params) || {};
const reasonPt = ${REASON_PT};
const msgs = [];
const emergency = hp.emergency || h.reason === 'emergency';
if (emergency) msgs.push(msgText('⚠️ ' + clinicMsg(ctx, 'emergency', DEFAULT_EMERGENCY)));
const intro = {
  emergency: 'Também já avisei a nossa equipe com prioridade máxima.',
  urgency: 'Sinto muito pelo desconforto. Eu não consigo avaliar sintomas por aqui, mas já avisei a nossa equipe com prioridade para te orientar e verificar um encaixe.',
  patient_request: 'Certo! Vou te transferir para a nossa equipe, que vai continuar o atendimento por aqui mesmo.',
  complaint: 'Sinto muito por isso. Encaminhei agora para a nossa equipe, que vai te responder pessoalmente.',
  out_of_scope: 'Não tenho essa informação confirmada aqui. Encaminhei sua pergunta para a nossa equipe responder por aqui.',
  booking_problem: 'Tive um problema para concluir o agendamento. Já passei para a nossa equipe finalizar com você por aqui.',
  technical_failure: 'Tive uma instabilidade técnica agora. Já avisei a nossa equipe, que vai continuar o seu atendimento por aqui.',
  policy: 'Esse pedido precisa ser tratado pela nossa equipe. Já encaminhei para alguém te responder por aqui.',
  staff_takeover: '',
}[h.reason] ?? 'Vou te transferir para a nossa equipe.';
let txt = intro;
if (h.status === 'ok' && !h.is_open_now && !emergency && txt) {
  txt += ' ' + clinicMsg(ctx, 'human_out_of_hours', 'Nossa equipe responde no horário de funcionamento.') + (h.next_opening_label ? ' Próximo atendimento: ' + h.next_opening_label + '.' : '');
}
if (h.reason === 'urgency') txt += '\\n\\nSe houver sangramento intenso, inchaço que dificulte respirar ou engolir, ou febre alta com inchaço no rosto, procure um pronto-socorro ou ligue 192.';
if (txt) msgs.push(msgText(txt));
let outbox = [];
if (h.status === 'ok') {
  const prio = { urgent: '🔴 URGENTE', high: '🟠 Prioridade alta', normal: '🟢 Normal' }[h.priority] || '';
  const last = ev.text ? truncate(ev.text, 500) : (ev.type === 'audio' ? '(áudio não transcrito)' : '');
  const staffText = '🔔 Atendimento #' + h.code + ' — ' + prio + '\\nPaciente: ' + h.patient_name + ' (' + h.patient_phone_masked + ')\\nMotivo: ' + (reasonPt[h.reason] || h.reason) +
    (last ? '\\nMensagem: "' + last + '"' : '') + '\\n\\nResponder: #' + h.code + ' sua mensagem\\nAssumir: #assumir ' + h.code + '\\nDevolver ao robô: #devolver ' + h.code;
  outbox = buildStaffOutbox(h.staff, staffText, ctx, 'handoff');
}
return { json: Object.assign({}, j, { handoff_result: { code: h.code, status: h.status }, staff_outbox: outbox,
  result: { messages: msgs, state: 'idle', context: {} } }) };`, LIBS, { each: true });
  w.code('Itens para a equipe (abertura)', [1140, -260], `
const out = [];
for (const it of $input.all()) for (const m of it.json.staff_outbox || []) out.push({ json: m });
return out.length ? out : [{ json: { __empty: true } }];`);
  w.ifTrue('Há avisos? (abertura)', [1360, -260], '!$json.__empty');
  w.execWf('Avisar equipe (WF00)', [1580, -320], WF.enviar, 'once');
  w.code('Retorno (abertura)', [1800, -260], `
return $('Mensagens da transferência').all().map((i) => {
  const j = Object.assign({}, i.json); delete j.staff_outbox; delete j.handoff; return { json: j };
});`);

  // ------------------------------------------------------------- REPASSE (modo humano)
  w.pg('Destinatários do repasse', [700, 0], 'api_handoff_relay_targets',
    '{ clinic_id: $json.ctx.clinic.id, conversation_id: $json.ctx.conversation.id }', { echo: true });
  w.code('Repassar mensagem', [920, 0], `
const j = $json.input; const t = $json.result || {}; const ev = j.ev || {}; const ctx = j.ctx;
const name = (ctx.patient && (ctx.patient.full_name || ctx.patient.profile_name)) || 'Paciente';
let body;
if (ev.type === 'text' || ev.type === 'interactive' || ev.type === 'button') body = truncate(ev.text || '', 1500);
else if (ev.type === 'audio') body = '(enviou um áudio — peça para escrever ou ligue para o paciente)';
else body = '(enviou um arquivo do tipo ' + ev.type + ', que não é repassado por segurança)';
const outbox = t.code ? buildStaffOutbox(t.staff || [], '💬 [#' + t.code + '] ' + name + ': ' + body + '\\n\\nResponder: #' + t.code + ' sua mensagem', ctx, 'staff_relay') : [];
return { json: Object.assign({}, j, { staff_outbox: outbox, result: { messages: [], state: null, context: null } }) };`, LIBS, { each: true });
  w.code('Itens para a equipe (repasse)', [1140, 0], `
const out = [];
for (const it of $input.all()) for (const m of it.json.staff_outbox || []) out.push({ json: m });
return out.length ? out : [{ json: { __empty: true } }];`);
  w.ifTrue('Há avisos? (repasse)', [1360, 0], '!$json.__empty');
  w.execWf('Repassar à equipe (WF00)', [1580, -60], WF.enviar, 'once');
  w.code('Retorno (repasse)', [1800, 0], `
return $('Repassar mensagem').all().map((i) => { const j = Object.assign({}, i.json); delete j.staff_outbox; return { json: j }; });`);

  // ------------------------------------------------------------- COMANDOS DA EQUIPE
  w.code('Interpretar comando', [700, 260], `
const j = $json; const ev = j.ev || {}; const ctx = j.ctx;
const cmd = (ev.type === 'text') ? parseStaffCommand(ev.text) : { cmd: 'help' };
const map = { list: 'list', assign: 'assign', release: 'release', reply: 'reply', takeover: 'takeover' };
return { json: Object.assign({}, j, { cmd, valid: !!map[cmd.cmd],
  args: { clinic_id: ctx.clinic.id, staff_id: ctx.staff.id, action: map[cmd.cmd] || 'list', code: cmd.code || null, patient_wa_id: cmd.patient_wa_id || null } }) };`, LIBS, { each: true });
  w.ifTrue('Comando válido?', [920, 260], '$json.valid === true');
  w.pg('Executar comando', [1140, 200], 'api_handoff_action', '$json.args', { echo: true });
  w.code('Resposta do comando', [1360, 200], `
const j = $json.input; const r = $json.result || {}; const ctx = j.ctx; const cmd = j.cmd;
const staff = [{ id: ctx.staff.id, wa_id: ctx.staff.wa_id, name: ctx.staff.name, in_window: true }];
const toStaff = (text) => buildStaffOutbox(staff, text, ctx, 'staff_relay');
let outbox = [];
if (r.status === 'forbidden') outbox = toStaff('Seu número não tem permissão para esta ação.');
else if (r.status === 'not_found') outbox = toStaff('Atendimento ' + (cmd.code ? '#' + cmd.code + ' ' : '') + 'não encontrado ou já encerrado. Envie #fila para ver os abertos.');
else if (cmd.cmd === 'list') {
  const hs = r.handoffs || [];
  outbox = toStaff(hs.length ? 'Atendimentos abertos:\\n' + hs.map((h) => '#' + h.code + ' — ' + h.patient_name + ' (' + h.priority + ', ' + h.opened_at + (h.assigned_to ? ', com ' + h.assigned_to : '') + ')').join('\\n') : 'Nenhum atendimento aguardando. 🎉');
} else if (r.status === 'ok') {
  const pOut = (texts) => r.patient_in_window ? patientOutbox(ctx, r.patient_id, r.patient_wa_id, texts.map(msgText), 'staff_relay') : [];
  const windowNote = r.patient_in_window ? '' : '\\n⚠️ O paciente está fora da janela de 24h do WhatsApp: mensagens livres não serão entregues. Ligue para o paciente ou aguarde ele escrever.';
  if (cmd.cmd === 'assign') outbox = toStaff('Você assumiu o atendimento #' + r.code + ' (' + r.patient_name + '). Responda com: #' + r.code + ' sua mensagem' + windowNote)
    .concat(pOut(['Olá! Aqui é ' + (ctx.staff.name || 'a equipe') + ', da ' + ctx.clinic.name + '. Vou continuar o seu atendimento por aqui.']));
  else if (cmd.cmd === 'reply') outbox = pOut([cmd.text]).concat(r.patient_in_window ? [] : toStaff('Mensagem NÃO enviada para #' + r.code + '.' + windowNote));
  else if (cmd.cmd === 'release') outbox = toStaff('Atendimento #' + r.code + ' devolvido ao robô.')
    .concat(pOut(['Obrigado pela conversa! Se precisar de algo mais, a assistente virtual da clínica continua à disposição por aqui.']));
  else if (cmd.cmd === 'takeover') outbox = toStaff('Você assumiu a conversa com ' + r.patient_name + ' (#' + r.code + '). Responda com: #' + r.code + ' sua mensagem' + windowNote);
}
return { json: Object.assign({}, j, { staff_outbox: outbox, action: 'staff_command' }) };`, LIBS, { each: true });
  w.code('Ajuda da equipe', [1140, 360], `
const j = $json; const ctx = j.ctx;
const staff = [{ id: ctx.staff.id, wa_id: ctx.staff.wa_id, name: ctx.staff.name, in_window: true }];
return { json: Object.assign({}, j, { staff_outbox: buildStaffOutbox(staff, STAFF_HELP, ctx, 'staff_relay'), action: 'staff_command' }) };`, LIBS, { each: true });
  w.code('Itens para envio (comando)', [1580, 260], `
const out = [];
for (const it of $input.all()) for (const m of it.json.staff_outbox || []) out.push({ json: m });
return out.length ? out : [{ json: { __empty: true } }];`);
  w.ifTrue('Há mensagens? (comando)', [1800, 260], '!$json.__empty');
  w.execWf('Enviar respostas (WF00)', [2020, 200], WF.enviar, 'once');
  w.code('Retorno (comando)', [2240, 260], `
const src = $('Interpretar comando').all();
return src.map((i) => ({ json: { ev: i.json.ev, ctx: { status: 'staff', clinic: { id: i.json.ctx.clinic.id } }, action: 'staff_command' } }));`);

  // ------------------------------------------------------------- API ADMINISTRATIVA
  w.code('Validar requisição', [220, 520], `
const b = ($json.body && typeof $json.body === 'object') ? $json.body : {};
const uuid = /^[0-9a-f-]{36}$/i;
const actions = ['list', 'assign', 'release', 'takeover'];
const ok = uuid.test(b.clinic_id || '') && actions.includes(b.action) && (b.action === 'list' || b.action === 'takeover' || /^[A-Za-z0-9]{4}$/.test(b.code || ''));
return { json: { ok, args: ok ? { clinic_id: b.clinic_id, action: b.action, code: b.code || null, staff_id: uuid.test(b.staff_id || '') ? b.staff_id : null,
  patient_wa_id: b.patient_wa_id ? String(b.patient_wa_id).replace(/\\D/g, '') : null, via: 'admin_api' } : null } };`, [], { each: true });
  w.ifTrue('Requisição válida?', [440, 520], '$json.ok === true');
  w.pg('Ação administrativa', [660, 460], 'api_handoff_action', '$json.args');
  w.add('Responder', 'n8n-nodes-base.respondToWebhook', 1.1, {
    respondWith: 'json', responseBody: '={{ JSON.stringify($json.result) }}', options: {},
  }, [880, 460]);
  w.add('Responder erro', 'n8n-nodes-base.respondToWebhook', 1.1, {
    respondWith: 'json', responseBody: '={{ JSON.stringify({ status: "invalid_request" }) }}', options: { responseCode: 400 },
  }, [660, 600]);

  // conexões
  w.chain('Entrada', 'Identificar ação', 'Ação');
  w.connect('Ação', 'Abrir atendimento humano', 0);
  w.connect('Ação', 'Destinatários do repasse', 1);
  w.connect('Ação', 'Interpretar comando', 2);
  w.chain('Abrir atendimento humano', 'Mensagens da transferência', 'Itens para a equipe (abertura)', 'Há avisos? (abertura)');
  w.connect('Há avisos? (abertura)', 'Avisar equipe (WF00)', 0);
  w.connect('Há avisos? (abertura)', 'Retorno (abertura)', 1);
  w.connect('Avisar equipe (WF00)', 'Retorno (abertura)');
  w.chain('Destinatários do repasse', 'Repassar mensagem', 'Itens para a equipe (repasse)', 'Há avisos? (repasse)');
  w.connect('Há avisos? (repasse)', 'Repassar à equipe (WF00)', 0);
  w.connect('Há avisos? (repasse)', 'Retorno (repasse)', 1);
  w.connect('Repassar à equipe (WF00)', 'Retorno (repasse)');
  w.connect('Interpretar comando', 'Comando válido?');
  w.connect('Comando válido?', 'Executar comando', 0);
  w.connect('Comando válido?', 'Ajuda da equipe', 1);
  w.chain('Executar comando', 'Resposta do comando', 'Itens para envio (comando)');
  w.connect('Ajuda da equipe', 'Itens para envio (comando)');
  w.connect('Itens para envio (comando)', 'Há mensagens? (comando)');
  w.connect('Há mensagens? (comando)', 'Enviar respostas (WF00)', 0);
  w.connect('Há mensagens? (comando)', 'Retorno (comando)', 1);
  w.connect('Enviar respostas (WF00)', 'Retorno (comando)');
  w.chain('API administrativa', 'Validar requisição', 'Requisição válida?');
  w.connect('Requisição válida?', 'Ação administrativa', 0);
  w.connect('Requisição válida?', 'Responder erro', 1);
  w.connect('Ação administrativa', 'Responder');
  return w;
}
