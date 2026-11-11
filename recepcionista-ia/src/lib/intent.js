// intent.js — contrato de intenções, chamada à IA, validação e classificação de reserva.
// Requer: util.js, safety.js. A constante SYSTEM_PROMPT é injetada pelo gerador
// a partir de prompts/recepcionista-system.md.

const INTENTS = [
  'greeting', 'schedule', 'choose_option', 'provide_name', 'my_appointments', 'reschedule', 'cancel',
  'confirm_attendance', 'affirm', 'deny', 'services_info', 'faq', 'location', 'hours', 'human',
  'complaint', 'urgency', 'opt_out', 'thanks', 'out_of_scope', 'other',
];
const PERIODS = ['morning', 'afternoon', 'evening'];

// Contrato JSON (Structured Outputs da OpenAI, modo strict)
const INTENT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['intent', 'confidence', 'service_code', 'professional_id', 'date_from', 'date_to', 'period', 'time',
    'option_number', 'appointment_number', 'patient_name', 'faq_id', 'urgency', 'reply'],
  properties: {
    intent: { type: 'string', enum: INTENTS },
    confidence: { type: 'number' },
    service_code: { type: ['string', 'null'] },
    professional_id: { type: ['string', 'null'] },
    date_from: { type: ['string', 'null'], description: 'AAAA-MM-DD' },
    date_to: { type: ['string', 'null'], description: 'AAAA-MM-DD' },
    period: { type: ['string', 'null'], enum: ['morning', 'afternoon', 'evening', null] },
    time: { type: ['string', 'null'], description: 'HH:MM' },
    option_number: { type: ['integer', 'null'] },
    appointment_number: { type: ['integer', 'null'] },
    patient_name: { type: ['string', 'null'] },
    faq_id: { type: ['string', 'null'] },
    urgency: { type: 'string', enum: ['none', 'possible', 'emergency'] },
    reply: { type: 'string' },
  },
};

function emptyIntent(intent) {
  return {
    intent: intent || 'other', confidence: 1, service_code: null, professional_id: null, date_from: null,
    date_to: null, period: null, time: null, option_number: null, appointment_number: null,
    patient_name: null, faq_id: null, urgency: 'none', reply: '', option_id: null, appointment_id: null,
    source: 'rule',
  };
}

// Contexto mínimo e sem dados sensíveis enviado à IA
function buildAiContext(ctx) {
  const c = ctx.clinic || {};
  return {
    clinica: { nome: c.name, endereco: c.address, horario: c.hours_summary, fuso: c.timezone },
    hoje: c.today_local, dia_da_semana: c.weekday_local, agora: c.now_local,
    estado_da_conversa: (ctx.conversation && ctx.conversation.state) || 'idle',
    paciente_tem_nome_cadastrado: !!(ctx.patient && ctx.patient.full_name),
    servicos: (ctx.services || []).map((s) => ({ code: s.code, nome: s.name, sinonimos: s.synonyms || [], descricao: s.description || '' })),
    profissionais: (ctx.professionals || []).map((p) => ({ id: p.id, nome: p.name, especialidade: p.specialty, servicos: p.service_codes })),
    perguntas_frequentes: (ctx.faqs || []).map((f) => ({ id: f.id, pergunta: f.question })),
    opcoes_de_horario_abertas: ctx.offer && ctx.offer.options ? ctx.offer.options.map((o) => ({ numero: o.option_number, horario: o.label, profissional: o.professional_name })) : [],
    consultas_do_paciente: (ctx.appointments || []).map((a, i) => ({ numero: i + 1, quando: a.label, servico: a.service_name, profissional: a.professional_name })),
  };
}

function buildAiRequest(ctx, text, model) {
  const safeText = String(text || '').replace(/<\/?mensagem_do_paciente>/gi, '').slice(0, 1500);
  return {
    model: model || 'gpt-4.1-mini',
    temperature: 0,
    max_tokens: 400,
    response_format: { type: 'json_schema', json_schema: { name: 'intencao_paciente', strict: true, schema: INTENT_SCHEMA } },
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'system', content: 'DADOS_DA_CLINICA (somente leitura):\n' + JSON.stringify(buildAiContext(ctx)) },
      { role: 'user', content: '<mensagem_do_paciente>\n' + safeText + '\n</mensagem_do_paciente>' },
    ],
  };
}

// Extrai o JSON da resposta da API de chat completions
function extractAiJson(resp) {
  try {
    const choice = resp && resp.choices && resp.choices[0];
    if (!choice || !choice.message) return null;
    if (choice.message.refusal) return null;
    return safeJsonParse(choice.message.content);
  } catch (e) {
    return null;
  }
}

function findService(ctx, codeOrText) {
  if (!codeOrText) return null;
  const services = ctx.services || [];
  const exact = services.find((s) => s.code === codeOrText);
  if (exact) return exact;
  const t = normalizeText(codeOrText);
  return services.find((s) => {
    const names = [s.code.replace(/_/g, ' '), s.name].concat(s.synonyms || []).map(normalizeText);
    return names.some((n) => n && (t === n || (n.length >= 4 && new RegExp('\\b' + n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b').test(t))));
  }) || null;
}

function findProfessional(ctx, idOrText) {
  if (!idOrText) return null;
  const pros = ctx.professionals || [];
  const byId = pros.find((p) => p.id === idOrText);
  if (byId) return byId;
  const t = normalizeText(idOrText);
  return pros.find((p) => normalizeText(p.name).replace(/\b(dra?|doutora?)\.?\s/g, '').split(' ')
    .some((w) => w.length >= 3 && new RegExp('\\b' + w + '\\b').test(t))) || null;
}

function validName(s) {
  const t = String(s || '').replace(/\s+/g, ' ').trim();
  return /^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ .'-]{1,79}$/.test(t) && t.split(' ').length <= 8 ? t : null;
}

// Valida a saída da IA contra o contrato e contra os dados reais da clínica
function validateAi(raw, ctx) {
  const errors = [];
  const r = safeJsonParse(raw);
  if (!r || typeof r !== 'object') return { ok: false, errors: ['json_invalido'], result: null };
  const out = emptyIntent('other');
  out.source = 'ai';
  if (!INTENTS.includes(r.intent)) { errors.push('intent_invalida'); return { ok: false, errors, result: null }; }
  out.intent = r.intent;
  out.confidence = typeof r.confidence === 'number' ? Math.max(0, Math.min(1, r.confidence)) : 0.5;

  const svc = r.service_code ? findService(ctx, r.service_code) : null;
  if (r.service_code && !svc) errors.push('servico_desconhecido');
  out.service_code = svc ? svc.code : null;

  const pro = r.professional_id ? findProfessional(ctx, r.professional_id) : null;
  if (r.professional_id && !pro) errors.push('profissional_desconhecido');
  out.professional_id = pro ? pro.id : null;

  const today = (ctx.clinic && ctx.clinic.today_local) || new Date().toISOString().slice(0, 10);
  const maxDays = (ctx.clinic && ctx.clinic.policies && ctx.clinic.policies.max_booking_days_ahead) || 60;
  const okDate = (d) => isIsoDate(d) && d >= today && d <= addDays(today, maxDays + 31);
  out.date_from = okDate(r.date_from) ? r.date_from : null;
  if (r.date_from && !out.date_from) errors.push('data_invalida');
  out.date_to = okDate(r.date_to) && out.date_from && r.date_to >= out.date_from ? r.date_to : null;
  out.period = PERIODS.includes(r.period) ? r.period : null;
  out.time = typeof r.time === 'string' && /^([01]?\d|2[0-3]):[0-5]\d$/.test(r.time) ? r.time.padStart(5, '0') : null;

  const nOpts = ctx.offer && ctx.offer.options ? ctx.offer.options.length : 0;
  out.option_number = Number.isInteger(r.option_number) && r.option_number >= 1 && r.option_number <= nOpts ? r.option_number : null;
  const nAppts = (ctx.appointments || []).length;
  out.appointment_number = Number.isInteger(r.appointment_number) && r.appointment_number >= 1 && r.appointment_number <= nAppts ? r.appointment_number : null;
  out.patient_name = validName(r.patient_name);
  out.faq_id = (ctx.faqs || []).some((f) => f.id === r.faq_id) ? r.faq_id : null;
  out.urgency = ['none', 'possible', 'emergency'].includes(r.urgency) ? r.urgency : 'none';
  out.reply = sanitizeAiReply(r.reply, { max: 400, fallback: '' });

  if (out.intent === 'choose_option' && !out.option_number && out.time && ctx.offer && ctx.offer.options) {
    // "pode ser às 14h" => procura a opção com esse horário
    const m = ctx.offer.options.find((o) => String(o.label || '').endsWith(out.time));
    if (m) out.option_number = m.option_number;
  }
  if (out.intent === 'faq' && !out.faq_id) out.intent = 'out_of_scope';
  return { ok: true, errors, result: out };
}

// ---------------------------------------------------------------------------
// Datas em linguagem natural (usado no classificador de reserva)
// ---------------------------------------------------------------------------
const WEEKDAYS = { domingo: 0, segunda: 1, terca: 2, quarta: 3, quinta: 4, sexta: 5, sabado: 6 };

function parseDates(text, today) {
  const t = normalizeText(text);
  let m;
  if (/\bdepois de amanha\b/.test(t)) return { date_from: addDays(today, 2), date_to: null };
  if (/\bamanha\b/.test(t)) return { date_from: addDays(today, 1), date_to: null };
  if (/\bhoje\b/.test(t)) return { date_from: today, date_to: null };
  if (/\b(semana que vem|proxima semana)\b/.test(t)) {
    const wd = weekdayOf(today);
    const nextMonday = addDays(today, ((8 - wd) % 7) || 7);
    return { date_from: nextMonday, date_to: addDays(nextMonday, 5) };
  }
  if ((m = t.match(/\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/))) {
    const year0 = Number(today.slice(0, 4));
    let y = m[3] ? Number(m[3].length === 2 ? '20' + m[3] : m[3]) : year0;
    const mm = String(m[2]).padStart(2, '0');
    const dd = String(m[1]).padStart(2, '0');
    let iso = `${y}-${mm}-${dd}`;
    if (isIsoDate(iso) && !m[3] && iso < today) iso = `${y + 1}-${mm}-${dd}`;
    if (isIsoDate(iso)) return { date_from: iso, date_to: null };
  }
  for (const [name, wd] of Object.entries(WEEKDAYS)) {
    if (new RegExp('\\b' + name + '(-feira| feira)?\\b').test(t)) {
      const diff = (wd - weekdayOf(today) + 7) % 7 || 7;
      return { date_from: addDays(today, diff), date_to: null };
    }
  }
  return { date_from: null, date_to: null };
}

function parsePeriod(text) {
  const t = normalizeText(text);
  if (/\b(de manha|pela manha|manha|cedo)\b/.test(t)) return 'morning';
  if (/\b(a tarde|de tarde|pela tarde|tarde)\b/.test(t)) return 'afternoon';
  if (/\b(a noite|de noite|noite)\b/.test(t)) return 'evening';
  return null;
}

function parseTime(text) {
  const t = normalizeText(text);
  const m = t.match(/\b(?:as|a partir das|depois das|umas)?\s*([01]?\d|2[0-3])\s*(?:h|:|hs|horas)\s*([0-5]\d)?\b/);
  if (!m) return null;
  return String(m[1]).padStart(2, '0') + ':' + (m[2] || '00');
}

function parseOptionNumber(text) {
  const t = normalizeText(text).replace(/[.!]+$/, '');
  let m = t.match(/^(?:a |o )?(?:opcao |numero |n )?([1-9])$/);
  if (m) return Number(m[1]);
  m = t.match(/\b(?:opcao|numero)\s*([1-9])\b/);
  if (m) return Number(m[1]);
  const ord = { primeir: 1, segund: 2, terceir: 3 };
  for (const [k, v] of Object.entries(ord)) if (new RegExp('^(a |o )?' + k + '[oa]?( opcao| horario)?$').test(t)) return v;
  return null;
}

// Classificador determinístico usado quando a IA está indisponível
function fallbackClassify(text, ctx) {
  const t = normalizeText(text);
  const today = (ctx.clinic && ctx.clinic.today_local) || new Date().toISOString().slice(0, 10);
  const r = emptyIntent('other');
  r.source = 'fallback';
  r.confidence = 0.6;
  const svc = findService(ctx, text);
  const pro = findProfessional(ctx, text);
  const dates = parseDates(text, today);
  r.service_code = svc ? svc.code : null;
  r.professional_id = pro ? pro.id : null;
  r.date_from = dates.date_from;
  r.date_to = dates.date_to;
  r.period = parsePeriod(text);
  r.time = parseTime(text);
  const state = (ctx.conversation && ctx.conversation.state) || 'idle';
  const optionNumber = parseOptionNumber(text);
  if (detectEmergency(text)) { r.intent = 'urgency'; r.urgency = 'emergency'; return r; }
  if (detectUrgency(text)) r.urgency = 'possible';
  if (isOptOut(text)) { r.intent = 'opt_out'; return r; }
  if (detectHumanRequest(text)) { r.intent = 'human'; return r; }
  if (detectComplaint(text)) { r.intent = 'complaint'; return r; }
  if (optionNumber && ctx.offer && ctx.offer.options && optionNumber <= ctx.offer.options.length) { r.intent = 'choose_option'; r.option_number = optionNumber; return r; }
  if (state === 'awaiting_appointment_choice' && optionNumber && optionNumber <= (ctx.appointments || []).length) {
    r.intent = 'affirm'; r.appointment_number = optionNumber; return r;
  }
  if (/^(sim|s|isso|pode|pode ser|ok|claro|quero|confirmo|certo|beleza)\b/.test(t) && t.length < 25) { r.intent = 'affirm'; return r; }
  if (/^(nao|n|nenhum|nenhuma|deixa|deixa pra la|negativo)\b/.test(t) && t.length < 25) { r.intent = 'deny'; return r; }
  if (state === 'awaiting_name' && validName(text) && !svc && t.split(' ').length <= 6 && !/\d/.test(t)) {
    r.intent = 'provide_name'; r.patient_name = validName(text); return r;
  }
  if (/\b(cancel\w*|desmarc\w*)\b/.test(t)) { r.intent = 'cancel'; return r; }
  if (/\b(remarc\w*|reagend\w*|adiar|trocar|mudar|alterar)\b/.test(t) && /\b(horario|consulta|data|dia|hora)\b/.test(t)) { r.intent = 'reschedule'; return r; }
  if (/\b(minha consulta|minhas consultas|quando e minha|tenho consulta|tenho horario)\b/.test(t)) { r.intent = 'my_appointments'; return r; }
  if (/^(confirmo|confirmado|confirmada|vou sim|estarei la|confirmar presenca)\b/.test(t)) { r.intent = 'confirm_attendance'; return r; }
  if (/\b(endereco|localizacao|onde fica|como chego|como chegar|mapa|localiza)\b/.test(t)) { r.intent = 'location'; return r; }
  if (/\b(que horas (abre|fecha)|horario de (funcionamento|atendimento)|funcionam|abrem|fecham|aberto)\b/.test(t) && !dates.date_from) { r.intent = 'hours'; return r; }
  const faq = (ctx.faqs || []).find((f) => (f.keywords || []).some((k) => new RegExp('\\b' + normalizeText(k) + '\\b').test(t)));
  if (/\b(marcar|agendar|agenda|horario|vaga|tem dentista|disponivel|disponibilidade|consulta)\b/.test(t) ||
      (svc && /\b(quero|queria|gostaria|preciso|fazer|marcar)\b/.test(t))) { r.intent = 'schedule'; return r; }
  if (svc && /\b(voces fazem|faz|fazem|tem|quanto|valor|preco|custa|como funciona)\b/.test(t)) { r.intent = 'services_info'; return r; }
  if (faq) { r.intent = 'faq'; r.faq_id = faq.id; return r; }
  if (r.urgency === 'possible') { r.intent = 'urgency'; return r; }
  if (/\b(obrigad\w*|valeu|agradec\w*|ate mais|tchau)\b/.test(t)) { r.intent = 'thanks'; return r; }
  if (/^(oi+|ola|bom dia|boa tarde|boa noite|e ai|opa|hello|alo)\b/.test(t) && t.length < 40) { r.intent = 'greeting'; return r; }
  if (/\?\s*$/.test(String(text || '').trim())) { r.intent = 'out_of_scope'; return r; }
  return r;
}

// Regras determinísticas que vêm ANTES da IA (botões, estados, segurança)
function preClassify(ev, ctx) {
  const id = ev.reply_id || '';
  const state = (ctx.conversation && ctx.conversation.state) || 'idle';
  const text = ev.text || '';
  let m;
  if ((m = id.match(/^OPT:([0-9a-f-]{36})$/i))) { const r = emptyIntent('choose_option'); r.option_id = m[1]; return r; }
  if ((m = id.match(/^APPT:([0-9a-f-]{36})$/i))) { const r = emptyIntent('affirm'); r.appointment_id = m[1]; return r; }
  if ((m = id.match(/^CONFIRM:([0-9a-f-]{36})$/i))) { const r = emptyIntent('confirm_attendance'); r.appointment_id = m[1]; return r; }
  if ((m = id.match(/^RESCHEDULE:([0-9a-f-]{36})$/i))) { const r = emptyIntent('reschedule'); r.appointment_id = m[1]; return r; }
  if ((m = id.match(/^CANCEL:([0-9a-f-]{36})$/i))) { const r = emptyIntent('cancel'); r.appointment_id = m[1]; return r; }
  if ((m = id.match(/^SVC:([a-z0-9_]{2,40})$/))) { const r = emptyIntent('schedule'); r.service_code = findService(ctx, m[1]) ? m[1] : null; return r; }
  if (id === 'YES') return emptyIntent('affirm');
  if (id === 'NO') return emptyIntent('deny');
  if (id === 'MENU:SCHEDULE') return emptyIntent('schedule');
  if (id === 'MENU:APPTS') return emptyIntent('my_appointments');
  if (id === 'MENU:HUMAN') return emptyIntent('human');
  if (id === 'MORE_SLOTS') { const r = emptyIntent('schedule'); r.more = true; return r; }

  if (!text) return null;
  if (isOptOut(text)) return emptyIntent('opt_out');
  if (isOptIn(text)) { const r = emptyIntent('other'); r.intent = 'opt_in'; return r; }
  if (detectEmergency(text)) { const r = emptyIntent('urgency'); r.urgency = 'emergency'; return r; }
  if (detectHumanRequest(text)) return emptyIntent('human');

  const opt = parseOptionNumber(text);
  if (opt && ctx.offer && ctx.offer.options && opt <= ctx.offer.options.length) {
    const r = emptyIntent('choose_option'); r.option_number = opt; return r;
  }
  if (state === 'awaiting_appointment_choice' && opt && opt <= (ctx.appointments || []).length) {
    const r = emptyIntent('affirm'); r.appointment_number = opt; return r;
  }
  if (state === 'awaiting_cancel_confirmation') {
    const t = normalizeText(text);
    if (/^(sim|s|pode|pode cancelar|confirmo|isso|quero cancelar|cancela|cancelar)\b/.test(t) && t.length < 30) return emptyIntent('affirm');
    if (/^(nao|n|deixa|mantem|manter|nao quero)\b/.test(t) && t.length < 30) return emptyIntent('deny');
  }
  if (state === 'awaiting_service') {
    const svc = findService(ctx, text);
    if (svc && normalizeText(text).split(' ').length <= 4) { const r = emptyIntent('schedule'); r.service_code = svc.code; return r; }
  }
  return null;
}

// Combina IA + regras: as regras de segurança sempre prevalecem
function mergeWithSafety(result, text, ctx) {
  const r = Object.assign(emptyIntent('other'), result || {});
  if (!text) return r;
  if (detectEmergency(text)) { r.urgency = 'emergency'; r.intent = 'urgency'; }
  else if (detectUrgency(text) && r.urgency === 'none') r.urgency = 'possible';
  if (detectComplaint(text) && !['urgency'].includes(r.intent)) r.intent = 'complaint';
  r.injection_suspected = detectInjection(text);
  if (r.injection_suspected && !['schedule', 'cancel', 'reschedule', 'my_appointments', 'urgency', 'human'].includes(r.intent)) {
    r.intent = 'other';
    r.reply = 'Posso ajudar apenas com o seu atendimento: agendamentos, remarcações, cancelamentos e informações da clínica.';
  }
  return r;
}
