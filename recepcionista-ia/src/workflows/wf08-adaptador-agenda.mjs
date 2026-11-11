import { Workflow, WF, CRED } from './_dsl.mjs';

// 08 — Camada adaptadora de agenda. Os demais fluxos NUNCA chamam o Google diretamente:
// pedem uma operação normalizada e este sub-workflow escolhe o provedor da clínica
// ('google' = Google Calendar; 'external' = API do software odontológico).
// Entrada: item com "calendar": { op: 'freebusy'|'create_event'|'delete_event'|'list_events', provider, ... }
// Saída:   o mesmo item + "calendar_result": { ok, ... }
export default function build() {
  const w = new Workflow(WF.adaptador, 'Recepcionista IA - 08 Adaptador de Agenda', { settings: { errorWorkflow: WF.monitoramento } });
  w.note('Sobre', [-40, -300], '## 08 · Adaptador de agenda\nOperações: **freebusy**, **create_event** (ID determinístico = idempotente), **delete_event**, **list_events**.\n\nProvedores: Google Calendar (credencial OAuth2 *Recepcionista IA - Google Calendar*) ou API externa (credencial *Recepcionista IA - API Agenda Externa*, contrato em docs/ADAPTADOR-AGENDA.md).\n\nFalhas são registradas em ria.integration_errors e devolvidas com ok=false — quem chamou decide (nunca inventa disponibilidade).', 520, 260);
  w.subTrigger('Entrada', [0, 0]);
  w.code('Preparar requisição', [220, 0], `
const j = $json;
const c = j.calendar || {};
const s = c.settings || {};
const enc = encodeURIComponent;
const qs = (o) => Object.keys(o).filter((k) => o[k] !== undefined && o[k] !== null).map((k) => enc(k) + '=' + enc(o[k])).join('&');
let req = null;
if (c.provider === 'external') {
  const base = String((c.clinic && c.clinic.external_calendar_base_url) || '').replace(/\\/$/, '');
  if (!/^https:\\/\\//.test(base) && !/^http:\\/\\/(localhost|127\\.0\\.0\\.1|mock)/.test(base)) req = { skip: true, error: 'URL da API externa não configurada (https obrigatório)' };
  else if (c.op === 'freebusy') req = { method: 'POST', url: base + '/availability', body: externalAvailabilityBody(c.professionals || [], c.time_min, c.time_max) };
  else if (c.op === 'create_event') req = { method: 'POST', url: base + '/appointments', body: externalEventBody(c.hold) };
  else if (c.op === 'delete_event') req = c.event_id ? { method: 'DELETE', url: base + '/appointments/' + enc(c.event_id) } : { skip: true, skip_ok: true };
  else if (c.op === 'list_events') req = { method: 'GET', url: base + '/appointments?' + qs({ professional_ref: c.external_ref, time_min: c.time_min, time_max: c.time_max }) };
} else {
  const base = String(s.google_calendar_base || 'https://www.googleapis.com/calendar/v3').replace(/\\/$/, '');
  if (c.op === 'freebusy') {
    const pros = (c.professionals || []).filter((p) => p.calendar_id);
    req = pros.length ? { method: 'POST', url: base + '/freeBusy', body: googleFreeBusyBody(pros, c.time_min, c.time_max, c.timezone) }
                      : { skip: true, error: 'Profissionais sem calendar_id configurado' };
  } else if (c.op === 'create_event') {
    req = c.hold && c.hold.calendar_id ? { method: 'POST', url: base + '/calendars/' + enc(c.hold.calendar_id) + '/events?sendUpdates=none', body: googleEventBody(c.hold) }
                                       : { skip: true, error: 'Profissional sem calendar_id' };
  } else if (c.op === 'delete_event') {
    req = c.event_id && c.calendar_id ? { method: 'DELETE', url: base + '/calendars/' + enc(c.calendar_id) + '/events/' + enc(c.event_id) + '?sendUpdates=none' }
                                      : { skip: true, skip_ok: true };
  } else if (c.op === 'list_events') {
    req = { method: 'GET', url: base + '/calendars/' + enc(c.calendar_id) + '/events?' + qs({ timeMin: c.time_min, timeMax: c.time_max, singleEvents: 'true', showDeleted: 'true', maxResults: '2500' }) };
  }
}
if (!req) req = { skip: true, error: 'Operação de agenda inválida: ' + c.op };
const provider = c.provider === 'external' ? 'external' : 'google';
const route = req.skip ? 'skip' : provider + (req.method === 'POST' ? '_body' : '_nobody');
return { json: Object.assign({}, j, { __req: req, __route: route }) };`, ['util', 'calendar'], { each: true });
  w.switchOn('Provedor', [440, 0], '$json.__route', ['google_body', 'google_nobody', 'external_body', 'external_nobody', 'skip']);
  w.http('Google Calendar (POST)', [700, -240], {
    method: 'POST', url: '={{ $json.__req.url }}', credType: 'googleCalendarOAuth2Api', credentials: CRED.google,
    jsonBody: '={{ JSON.stringify($json.__req.body) }}', timeout: 15000, retry: 2,
  });
  w.http('Google Calendar (GET/DELETE)', [700, -80], {
    method: '={{ $json.__req.method }}', url: '={{ $json.__req.url }}', credType: 'googleCalendarOAuth2Api', credentials: CRED.google, timeout: 15000, retry: 2,
  });
  w.http('API externa (POST)', [700, 80], {
    method: 'POST', url: '={{ $json.__req.url }}', generic: 'httpHeaderAuth', credentials: CRED.externalCalendar,
    jsonBody: '={{ JSON.stringify($json.__req.body) }}', timeout: 15000, retry: 2,
  });
  w.http('API externa (GET/DELETE)', [700, 240], {
    method: '={{ $json.__req.method }}', url: '={{ $json.__req.url }}', generic: 'httpHeaderAuth', credentials: CRED.externalCalendar, timeout: 15000, retry: 2,
  });
  w.code('Normalizar resposta', [960, 0], `
const j = $('Preparar requisição').item.json;
const c = j.calendar || {};
const r = $json || {};
const req = j.__req || {};
const status = Number(r.statusCode || 0);
const body = typeof r.body === 'string' ? (safeJsonParse(r.body) || r.body) : r.body;
const fail = (code, msg) => ({ ok: false, error_code: String(code), error: sanitizeForLog(msg || ('HTTP ' + status), 200) });
let res;
if (req.skip) res = req.skip_ok ? { ok: true, skipped: true } : fail('config', req.error);
else if (r.error && !status) res = fail('network', typeof r.error === 'string' ? r.error : (r.error.message || 'erro de rede'));
else if (c.op === 'freebusy') {
  if (status === 200) res = Object.assign({ ok: true }, c.provider === 'external' ? normalizeExternalBusy(body, c.professionals || []) : normalizeGoogleFreeBusy(body, c.professionals || []));
  else res = fail(status, body && body.error && body.error.message);
} else if (c.op === 'create_event') {
  if (status === 200 || status === 201) res = { ok: true, event_id: (body && (body.id || body.event_id)) || (c.hold && c.hold.calendar_event_id) };
  else if (status === 409) res = { ok: true, event_id: c.hold && c.hold.calendar_event_id, already_existed: true }; // repetição idempotente
  else res = fail(status, body && body.error && body.error.message);
} else if (c.op === 'delete_event') {
  res = [200, 204, 404, 410].includes(status) ? { ok: true, already_deleted: status === 404 || status === 410 } : fail(status, body && body.error && body.error.message);
} else if (c.op === 'list_events') {
  if (status === 200) res = { ok: true, events: c.provider === 'external' ? ((body && body.events) || []) : normalizeGoogleEvents(body) };
  else res = fail(status, body && body.error && body.error.message);
} else res = fail('op', 'operação desconhecida');
const out = Object.assign({}, j, { calendar_result: res });
delete out.__req; delete out.__route;
out.__log = res.ok ? null : { clinic_id: c.clinic && c.clinic.id, source: 'calendar', workflow: '08-adaptador-agenda', node: c.op + '/' + (c.provider || 'google'), error_code: res.error_code, message: res.error };
return { json: out };`, ['util', 'calendar'], { each: true });
  w.ifTrue('Falhou?', [1180, 0], '!!$json.__log');
  w.pg('Registrar falha de agenda', [1400, -100], 'api_log_error', '$json.__log', { echo: true });
  w.code('Retorno', [1620, 0], `
const j = ($json.result !== undefined && $json.input) ? $json.input : $json;
const out = Object.assign({}, j);
delete out.__log;
return { json: out };`, [], { each: true });
  w.chain('Entrada', 'Preparar requisição', 'Provedor');
  w.connect('Provedor', 'Google Calendar (POST)', 0);
  w.connect('Provedor', 'Google Calendar (GET/DELETE)', 1);
  w.connect('Provedor', 'API externa (POST)', 2);
  w.connect('Provedor', 'API externa (GET/DELETE)', 3);
  w.connect('Provedor', 'Normalizar resposta', 4);
  w.connect('Provedor', 'Normalizar resposta', 5);
  for (const n of ['Google Calendar (POST)', 'Google Calendar (GET/DELETE)', 'API externa (POST)', 'API externa (GET/DELETE)']) w.connect(n, 'Normalizar resposta');
  w.connect('Normalizar resposta', 'Falhou?');
  w.connect('Falhou?', 'Registrar falha de agenda', 0);
  w.connect('Falhou?', 'Retorno', 1);
  w.connect('Registrar falha de agenda', 'Retorno');
  return w;
}
