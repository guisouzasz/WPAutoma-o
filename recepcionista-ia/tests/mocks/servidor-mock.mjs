#!/usr/bin/env node
// Servidor de SIMULAÇÃO para testes locais (NÃO é usado em produção).
// Imita os endpoints usados pelos workflows:
//   Meta Graph API:   POST /:versao/:phoneId/messages, GET /:versao/:mediaId, GET /media-download/:id
//   OpenAI:           POST /v1/chat/completions (classificador determinístico), POST /v1/audio/transcriptions
//   Google Calendar:  POST /calendar/v3/freeBusy, POST|GET /calendar/v3/calendars/:cal/events, DELETE .../events/:id
// Controle: POST /__control, POST /__reset, GET /__sent, GET /__calls, GET /__events
import http from 'node:http';
import { carregar } from '../unit/carregar-libs.mjs';

const L = carregar();
const PORT = Number(process.env.MOCK_PORT || 18080);
let state;
function reset() {
  state = {
    sent: [], calls: [], calendars: {}, seq: 0,
    fail_google: false, fail_openai: false, fail_whatsapp_to: [], transcript: 'Quero marcar uma limpeza',
    openai_override: null, saw_phone_in_ai: false,
  };
}
reset();

function send(res, status, body, type = 'application/json') {
  res.writeHead(status, { 'content-type': type });
  res.end(type === 'application/json' ? JSON.stringify(body) : body);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}

// Converte o contexto enviado à IA para o formato do classificador de reserva
function aiCtxFromRequest(body) {
  const sys = (body.messages || []).find((m) => m.role === 'system' && String(m.content).startsWith('DADOS_DA_CLINICA'));
  const d = JSON.parse(String(sys.content).split('\n').slice(1).join('\n'));
  return {
    clinic: { today_local: d.hoje, policies: { max_booking_days_ahead: 60 } },
    conversation: { state: d.estado_da_conversa },
    services: d.servicos.map((s) => ({ code: s.code, name: s.nome, synonyms: s.sinonimos })),
    professionals: d.profissionais.map((p) => ({ id: p.id, name: p.nome })),
    faqs: d.perguntas_frequentes.map((f) => ({ id: f.id, keywords: String(f.pergunta).toLowerCase().replace(/[?.,!]/g, '').split(/\s+/).filter((w) => w.length > 6) })),
    offer: { options: d.opcoes_de_horario_abertas.map((o) => ({ option_number: o.numero, label: o.horario })) },
    appointments: d.consultas_do_paciente,
  };
}

function overlaps(aStart, aEnd, bStart, bEnd) { return new Date(aStart) < new Date(bEnd) && new Date(bStart) < new Date(aEnd); }

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  const raw = await readBody(req);
  const isJson = (req.headers['content-type'] || '').includes('application/json');
  const body = isJson && raw.length ? JSON.parse(raw.toString()) : null;
  if (!p.startsWith('/__')) state.calls.push({ method: req.method, path: p, auth: !!req.headers.authorization });

  // ---------------- controle ----------------
  if (p === '/__reset') { reset(); return send(res, 200, { ok: true }); }
  if (p === '/__control') { Object.assign(state, body || {}); return send(res, 200, { ok: true }); }
  if (p === '/__sent') return send(res, 200, state.sent);
  if (p === '/__calls') return send(res, 200, state.calls);
  if (p === '/__events') return send(res, 200, state.calendars);
  if (p === '/__state') return send(res, 200, { saw_phone_in_ai: state.saw_phone_in_ai });
  if (p === '/__add_event' && body) {
    const cal = (state.calendars[body.calendar_id] = state.calendars[body.calendar_id] || {});
    cal[body.id] = { id: body.id, status: 'confirmed', start: { dateTime: body.start }, end: { dateTime: body.end }, summary: 'Evento manual' };
    return send(res, 200, { ok: true });
  }

  if (!req.headers.authorization) return send(res, 401, { error: { message: 'sem credencial' } });

  // ---------------- WhatsApp / Graph ----------------
  let m;
  if (req.method === 'POST' && (m = p.match(/^\/v[\d.]+\/(\d+)\/messages$/))) {
    const to = body && body.to;
    if (state.fail_whatsapp_to.includes(to) || state.fail_whatsapp_to.includes('*')) {
      state.sent.push({ to, payload: body, failed: true });
      return send(res, 400, { error: { message: `(#131026) Message undeliverable to ${to}`, code: 131026 } });
    }
    const id = 'wamid.MOCK' + ++state.seq;
    state.sent.push({ to, phone_number_id: m[1], payload: body, id });
    return send(res, 200, { messaging_product: 'whatsapp', contacts: [{ input: to, wa_id: to }], messages: [{ id }] });
  }
  if (req.method === 'GET' && (m = p.match(/^\/v[\d.]+\/(MEDIA[\w-]*)$/))) {
    return send(res, 200, { id: m[1], url: `http://127.0.0.1:${PORT}/media-download/${m[1]}`, mime_type: 'audio/ogg', file_size: m[1].includes('BIG') ? 99999999 : 2048 });
  }
  if (req.method === 'GET' && p.startsWith('/media-download/')) {
    return send(res, 200, Buffer.from('OggS-fake-audio-data'), 'audio/ogg');
  }

  // ---------------- OpenAI ----------------
  if (req.method === 'POST' && p === '/v1/audio/transcriptions') {
    if (state.fail_openai) return send(res, 503, { error: { message: 'indisponível' } });
    if (!raw.includes(Buffer.from('OggS'))) return send(res, 400, { error: { message: 'arquivo ausente' } });
    return send(res, 200, { text: state.transcript });
  }
  if (req.method === 'POST' && p === '/v1/chat/completions') {
    if (state.fail_openai) return send(res, 503, { error: { message: 'indisponível' } });
    if (JSON.stringify(body).match(/55119\d{8}/)) state.saw_phone_in_ai = true;
    const ok = body.response_format && body.response_format.json_schema && body.response_format.json_schema.strict === true;
    if (!ok) return send(res, 400, { error: { message: 'schema estrito ausente' } });
    let out;
    if (state.openai_override) { out = state.openai_override; state.openai_override = null; }
    else {
      const userMsg = body.messages.find((x) => x.role === 'user').content.replace(/<\/?mensagem_do_paciente>/g, '').trim();
      const r = L.fallbackClassify(userMsg, aiCtxFromRequest(body));
      out = { intent: r.intent, confidence: 0.9, service_code: r.service_code, professional_id: r.professional_id, date_from: r.date_from, date_to: r.date_to,
        period: r.period, time: r.time, option_number: r.option_number, appointment_number: r.appointment_number, patient_name: r.patient_name,
        faq_id: r.faq_id, urgency: r.urgency, reply: r.intent === 'greeting' ? 'Olá! Como posso ajudar?' : '' };
    }
    return send(res, 200, { id: 'chatcmpl-mock', object: 'chat.completion', choices: [{ index: 0, message: { role: 'assistant', content: JSON.stringify(out) }, finish_reason: 'stop' }] });
  }

  // ---------------- Google Calendar ----------------
  if (p.startsWith('/calendar/v3/')) {
    if (state.fail_google) return send(res, 503, { error: { code: 503, message: 'Backend Error' } });
    if (req.method === 'POST' && p === '/calendar/v3/freeBusy') {
      const calendars = {};
      for (const it of body.items || []) {
        const evs = Object.values(state.calendars[it.id] || {}).filter((e) => e.status !== 'cancelled' && overlaps(e.start.dateTime, e.end.dateTime, body.timeMin, body.timeMax));
        calendars[it.id] = { busy: evs.map((e) => ({ start: e.start.dateTime, end: e.end.dateTime })) };
      }
      return send(res, 200, { kind: 'calendar#freeBusy', timeMin: body.timeMin, timeMax: body.timeMax, calendars });
    }
    if ((m = p.match(/^\/calendar\/v3\/calendars\/([^/]+)\/events(?:\/([^/]+))?$/))) {
      const calId = decodeURIComponent(m[1]);
      const cal = (state.calendars[calId] = state.calendars[calId] || {});
      if (req.method === 'POST' && !m[2]) {
        if (cal[body.id]) return send(res, 409, { error: { code: 409, message: 'The requested identifier already exists.' } });
        cal[body.id] = Object.assign({ status: 'confirmed' }, body);
        return send(res, 200, cal[body.id]);
      }
      if (req.method === 'DELETE' && m[2]) {
        const id = decodeURIComponent(m[2]);
        if (!cal[id] || cal[id].status === 'cancelled') return send(res, 410, { error: { code: 410, message: 'Resource has been deleted' } });
        cal[id].status = 'cancelled';
        return send(res, 204, '', 'text/plain');
      }
      if (req.method === 'GET' && !m[2]) {
        return send(res, 200, { kind: 'calendar#events', items: Object.values(cal) });
      }
    }
  }
  return send(res, 404, { error: { message: 'rota não simulada: ' + req.method + ' ' + p } });
});

server.listen(PORT, '127.0.0.1', () => console.log(`mock ouvindo em http://127.0.0.1:${PORT}`));
