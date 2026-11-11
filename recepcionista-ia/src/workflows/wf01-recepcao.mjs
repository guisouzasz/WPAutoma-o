import { Workflow, WF, CRED } from './_dsl.mjs';

// 01 — Recebimento de mensagens (porta de entrada do WhatsApp).
// trigger: 'whatsapp' (produção, nó oficial WhatsApp Trigger) ou 'test' (Webhook p/ testes locais)
export default function build({ trigger = 'whatsapp' } = {}) {
  const isTest = trigger === 'test';
  const w = new Workflow(isTest ? 'RiaWf01RecepTest' : WF.recepcao,
    isTest ? 'Recepcionista IA - 01 Recepção (TESTE com webhook)' : 'Recepcionista IA - 01 WhatsApp Recepção',
    { settings: { errorWorkflow: WF.monitoramento } });

  w.note('Sobre', [-60, -420], '## 01 · Recepção de mensagens\n1. Recebe o webhook oficial (assinatura validada pelo nó WhatsApp Trigger).\n2. Ignora status (exceto falhas, que são registradas).\n3. Deduplica pelo ID da Meta, identifica clínica, paciente e conversa (PostgreSQL).\n4. Modo HUMANO → repassa para a equipe (WF05). Número da equipe → comandos (WF05).\n5. Áudio → baixa pela Graph API, transcreve (OpenAI) e descarta o arquivo.\n6. Regras determinísticas → IA (saída JSON estrita) → validação → roteador.\n7. Executa WF02/WF03/WF05, salva o estado e responde via WF00.', 620, 300);

  if (isTest) {
    w.add('Webhook de teste', 'n8n-nodes-base.webhook', 2, { httpMethod: 'POST', path: 'ria-teste-whatsapp', responseMode: 'lastNode', options: {} }, [-300, 0]);
    // Reproduz exatamente a saída do nó WhatsApp Trigger: um item por change => { ...change.value, field }
    w.code('WhatsApp Trigger', [-80, 0], `
const out = [];
for (const it of $input.all()) {
  const body = it.json.body || {};
  for (const entry of body.entry || []) for (const ch of entry.changes || []) out.push({ json: Object.assign({}, ch.value, { field: ch.field }) });
}
return out;`);
    w.connect('Webhook de teste', 'WhatsApp Trigger');
  } else {
    w.add('WhatsApp Trigger', 'n8n-nodes-base.whatsAppTrigger', 1, {
      updates: ['messages'],
      options: { messageStatusUpdates: ['failed'] },
    }, [-80, 0], { credentials: CRED.whatsappTrigger, webhookId: 'b7e4c0de-0a11-4c1a-9c55-5e7c1a0e0001' });
  }

  w.code('Normalizar eventos', [140, 0], `
const events = parseWhatsAppEvents($input.all().map((i) => i.json));
return events.map((e) => ({ json: e }));`, ['util', 'webhook']);
  w.ifTrue('É status de entrega?', [360, 0], "$json.kind === 'status'");
  w.pg('Registrar status', [580, -180], 'api_status_update',
    '{ wa_message_id: $json.wa_message_id, status: $json.status, error_code: $json.error_code, error_title: $json.error_title }');
  w.pg('Iniciar atendimento', [580, 40], 'api_inbound_begin',
    '{ phone_number_id: $json.phone_number_id, wa_message_id: $json.wa_message_id, from: $json.from, profile_name: $json.profile_name, msg_type: $json.type, wa_timestamp: $json.timestamp }');
  w.code('Mesclar contexto', [800, 40], `
const ev = $('Normalizar eventos').item.json;
const ctx = $json.result || { status: 'invalid' };
let path = 'process';
if (ctx.status === 'staff') path = 'staff';
else if (ctx.status !== 'ok') path = 'ignore';
else if (ctx.conversation && ctx.conversation.mode === 'HUMAN') path = 'human';
else if (ev.type === 'audio' && ev.audio && ev.audio.id) path = 'audio';
return { json: { ev, ctx, path } };`, [], { each: true });
  w.switchOn('Caminho', [1020, 40], '$json.path', ['process', 'audio', 'human', 'staff', 'ignore']);

  // ---- áudio ----
  w.http('Consultar mídia (Graph)', [1260, -260], {
    method: 'GET', url: "={{ $json.ctx.settings.graph_api_base + '/' + $json.ctx.settings.graph_api_version + '/' + $json.ev.audio.id }}",
    credType: 'whatsAppApi', credentials: CRED.whatsapp, timeout: 15000, retry: 2,
  });
  w.ifTrue('Áudio válido?', [1480, -260],
    "$json.statusCode === 200 && !!($json.body && $json.body.url) && Number(($json.body && $json.body.file_size) || 0) <= Number($('Mesclar contexto').item.json.ctx.settings.audio_max_bytes || 2000000)");
  w.http('Baixar áudio', [1700, -340], {
    method: 'GET', url: '={{ $json.body.url }}', credType: 'whatsAppApi', credentials: CRED.whatsapp, timeout: 30000, file: true, retry: 2,
  });
  w.http('Transcrever áudio (OpenAI)', [1920, -340], {
    method: 'POST', url: "={{ $('Mesclar contexto').item.json.ctx.settings.openai_base + '/audio/transcriptions' }}",
    credType: 'openAiApi', credentials: CRED.openai, timeout: 60000,
    multipart: [
      { parameterType: 'formBinaryData', name: 'file', inputDataFieldName: 'data' },
      { name: 'model', value: "={{ $('Mesclar contexto').item.json.ctx.settings.openai_transcribe_model || 'gpt-4o-mini-transcribe' }}" },
      { name: 'language', value: 'pt' },
      { name: 'response_format', value: 'json' },
    ],
  });
  w.code('Texto do áudio', [2140, -340], `
// Mantém apenas o texto em memória: o arquivo (binário) é descartado aqui e
// a transcrição NÃO é gravada no banco.
const base = $('Mesclar contexto').item.json;
const ev = Object.assign({}, base.ev);
const errors = [];
const text = $json && $json.statusCode === 200 && $json.body && typeof $json.body.text === 'string' ? $json.body.text.trim() : '';
if (text) { ev.text = text.slice(0, 2000); ev.audio_status = 'ok'; }
else {
  ev.audio_status = 'failed';
  errors.push({ source: 'openai', workflow: '01-whatsapp-recepcao', node: 'Transcrever áudio', error_code: String(($json && $json.statusCode) || 'erro'), message: 'Falha ao baixar ou transcrever áudio' });
}
return { json: { ev, ctx: base.ctx, path: base.path, errors } };`, [], { each: true });
  w.code('Áudio recusado', [1700, -160], `
const base = $('Mesclar contexto').item.json;
const ev = Object.assign({}, base.ev);
const tooLong = $json && $json.statusCode === 200 && $json.body && $json.body.url;
ev.audio_status = tooLong ? 'too_long' : 'failed';
const errors = tooLong ? [] : [{ source: 'whatsapp', workflow: '01-whatsapp-recepcao', node: 'Consultar mídia', error_code: String(($json && $json.statusCode) || 'erro'), message: 'Falha ao consultar mídia' }];
return { json: { ev, ctx: base.ctx, path: base.path, errors } };`, [], { each: true });

  // ---- compreensão ----
  w.code('Pré-classificar', [1260, 60], `
const j = $json;
const ev = j.ev; const ctx = j.ctx;
const settings = ctx.settings || {};
let pre = null;
if (!ev.supported) pre = emptyIntent('unsupported_media');
else if (ev.type === 'audio' && ev.audio_status === 'too_long') pre = emptyIntent('audio_too_long');
else if (ev.type === 'audio' && ev.audio_status !== 'ok') pre = emptyIntent('audio_failed');
else pre = preClassify(ev, ctx);
const needAi = !pre && !!(ev.text && String(ev.text).trim());
if (!pre && !needAi) pre = emptyIntent('other');
return { json: { ev, ctx, errors: j.errors || [], pre, needAi,
  aiRequest: needAi ? buildAiRequest(ctx, ev.text, settings.openai_model) : null } };`, ['util', 'safety', 'intent'], { each: true });
  w.ifTrue('Precisa de IA?', [1480, 60], '$json.needAi === true');
  w.http('Classificar intenção (OpenAI)', [1700, 0], {
    method: 'POST', url: "={{ $json.ctx.settings.openai_base + '/chat/completions' }}", credType: 'openAiApi', credentials: CRED.openai,
    jsonBody: '={{ JSON.stringify($json.aiRequest) }}', timeout: 20000, retry: 2,
  });
  w.code('Validar e rotear', [1920, 80], `
// A IA nunca executa ações: sua saída é validada contra o contrato e contra os
// dados reais da clínica; regras de segurança prevalecem; o roteador escolhe o fluxo.
const base = $('Pré-classificar').item.json;
const ev = base.ev; const ctx = base.ctx;
const errors = (base.errors || []).slice();
let ir = base.pre; let aiOk = null;
if (!ir) {
  const r = $json || {};
  if (r.statusCode === 200) {
    const v = validateAi(extractAiJson(r.body), ctx);
    if (v.ok) { ir = v.result; aiOk = true; }
    else errors.push({ source: 'openai', workflow: '01-whatsapp-recepcao', node: 'Validar e rotear', error_code: 'saida_invalida', message: v.errors.join(',') });
  } else {
    errors.push({ source: 'openai', workflow: '01-whatsapp-recepcao', node: 'Classificar intenção', error_code: String(r.statusCode || 'timeout'), message: 'Falha na chamada à IA; usando classificador de reserva' });
  }
  if (!ir) { ir = fallbackClassify(ev.text, ctx); aiOk = false; }
}
ir = mergeWithSafety(ir, ev.text, ctx);
let decision = decideRoute(ctx, ir, ev);
const maxFail = Number((ctx.settings || {}).ai_max_failures || 2);
if (aiOk === false && ((ctx.conversation.ai_failures || 0) + 1) >= maxFail && decision.route === 'reply' && decision.unknown) {
  decision = { intent: ir.intent, route: 'handoff', params: { reason: 'technical_failure', priority: 'normal' }, messages: [], state: 'idle', context: {} };
}
return { json: { ev, ctx, ir: { intent: ir.intent, urgency: ir.urgency, source: ir.source, injection_suspected: !!ir.injection_suspected }, decision, ai_ok: aiOk, errors } };`,
  ['util', 'safety', 'intent', 'messages', 'router'], { each: true });
  w.switchOn('Rotear', [2140, 80], '$json.decision.route', ['reply', 'schedule', 'book', 'manage', 'handoff', 'consent']);
  w.execWf('Agendamento (WF02)', [2400, -120], WF.agendamento);
  w.execWf('Remarcação e cancelamento (WF03)', [2400, 40], WF.remarcacao);
  w.execWf('Atendimento humano (WF05)', [2400, 200], WF.humano);
  w.pg('Registrar consentimento', [2400, 360], 'api_consent',
    "{ clinic_id: $json.ctx.clinic.id, patient_id: $json.ctx.patient.id, kind: $json.decision.params.kind, source: 'whatsapp_inbound', evidence: $json.ev.wa_message_id }", { echo: true });
  w.code('Após consentimento', [2620, 360], 'return { json: $json.input };', [], { each: true });
  w.code('Consolidar resultado', [2860, 80], `
const j = $json;
const d = j.decision || {};
const res = j.result || { messages: d.messages || [], state: d.state, context: d.context };
const ctx = j.ctx; const ev = j.ev;
const messages = res.messages || [];
const save = {
  conversation_id: ctx.conversation.id, clinic_id: ctx.clinic.id, patient_id: ctx.patient.id,
  expected_version: ctx.conversation.version,
  wa_message_id: ev.wa_message_id, intent: (j.ir && j.ir.intent) || d.intent, route: d.route,
  state: res.state || 'idle', context: res.context || {},
  ai_ok: j.ai_ok === true, ai_failed: j.ai_ok === false,
  unknown: !!d.unknown, understood: !d.unknown,
  replied: messages.length > 0, privacy_notice: !!d.privacy_notice,
  injection_suspected: !!(j.ir && j.ir.injection_suspected),
  errors: (j.errors || []).concat(res.errors || []),
  message_status: 'processed',
};
return { json: { save, outbox: patientOutbox(ctx, ctx.patient.id, ev.from, messages, 'reply') } };`, ['util', 'messages', 'whatsapp', 'staff'], { each: true });
  w.pg('Salvar estado', [3080, 80], 'api_conversation_save', '$json.save');
  w.code('Preparar envio', [3300, 80], `
const out = [];
for (const it of $('Consolidar resultado').all()) for (const m of it.json.outbox || []) out.push({ json: m });
return out;`);
  w.execWf('Enviar WhatsApp (WF00)', [3520, 80], WF.enviar, 'once');

  // ---- equipe / modo humano ----
  w.execWf('Equipe ou modo humano (WF05)', [1260, 300], WF.humano);
  w.pg('Finalizar mensagem', [1480, 300], 'api_message_finish',
    "{ wa_message_id: $json.ev && $json.ev.wa_message_id, status: 'processed', route: $json.action || 'human' }");
  w.noop('Ignorar (duplicada ou sem clínica)', [1260, 480]);

  // ---- conexões ----
  w.chain('WhatsApp Trigger', 'Normalizar eventos', 'É status de entrega?');
  w.connect('É status de entrega?', 'Registrar status', 0);
  w.connect('É status de entrega?', 'Iniciar atendimento', 1);
  w.chain('Iniciar atendimento', 'Mesclar contexto', 'Caminho');
  w.connect('Caminho', 'Pré-classificar', 0);
  w.connect('Caminho', 'Consultar mídia (Graph)', 1);
  w.connect('Caminho', 'Equipe ou modo humano (WF05)', 2);
  w.connect('Caminho', 'Equipe ou modo humano (WF05)', 3);
  w.connect('Caminho', 'Ignorar (duplicada ou sem clínica)', 4);
  w.connect('Caminho', 'Ignorar (duplicada ou sem clínica)', 5);
  w.connect('Consultar mídia (Graph)', 'Áudio válido?');
  w.connect('Áudio válido?', 'Baixar áudio', 0);
  w.connect('Áudio válido?', 'Áudio recusado', 1);
  w.chain('Baixar áudio', 'Transcrever áudio (OpenAI)', 'Texto do áudio', 'Pré-classificar');
  w.connect('Áudio recusado', 'Pré-classificar');
  w.connect('Pré-classificar', 'Precisa de IA?');
  w.connect('Precisa de IA?', 'Classificar intenção (OpenAI)', 0);
  w.connect('Precisa de IA?', 'Validar e rotear', 1);
  w.connect('Classificar intenção (OpenAI)', 'Validar e rotear');
  w.connect('Validar e rotear', 'Rotear');
  w.connect('Rotear', 'Consolidar resultado', 0);
  w.connect('Rotear', 'Agendamento (WF02)', 1);
  w.connect('Rotear', 'Agendamento (WF02)', 2);
  w.connect('Rotear', 'Remarcação e cancelamento (WF03)', 3);
  w.connect('Rotear', 'Atendimento humano (WF05)', 4);
  w.connect('Rotear', 'Registrar consentimento', 5);
  w.connect('Rotear', 'Consolidar resultado', 6);
  for (const n of ['Agendamento (WF02)', 'Remarcação e cancelamento (WF03)', 'Atendimento humano (WF05)']) w.connect(n, 'Consolidar resultado');
  w.connect('Registrar consentimento', 'Após consentimento');
  w.connect('Após consentimento', 'Consolidar resultado');
  w.chain('Consolidar resultado', 'Salvar estado', 'Preparar envio', 'Enviar WhatsApp (WF00)');
  w.connect('Equipe ou modo humano (WF05)', 'Finalizar mensagem');
  return w;
}
