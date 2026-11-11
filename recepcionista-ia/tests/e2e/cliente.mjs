// Cliente dos testes ponta a ponta: simula a Meta enviando webhooks ao n8n e
// consulta o servidor mock e o banco de testes.
import { execFileSync } from 'node:child_process';

export const N8N = process.env.N8N_URL || 'http://127.0.0.1:5678';
export const MOCK = process.env.MOCK_URL || 'http://127.0.0.1:18080';
export const PHONE_ID = '100000000000001';
let seq = 0;

async function post(url, body) {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const t = await r.text();
  try { return { status: r.status, body: JSON.parse(t) }; } catch { return { status: r.status, body: t }; }
}

export function webhookPayload(from, message, name = 'Paciente Teste') {
  return { object: 'whatsapp_business_account', entry: [{ id: '200000000000001', changes: [{ field: 'messages', value: {
    messaging_product: 'whatsapp', metadata: { display_phone_number: '551130000000', phone_number_id: PHONE_ID },
    contacts: [{ profile: { name }, wa_id: from }], messages: [Object.assign({ from, id: `wamid.E2E${Date.now()}${++seq}`, timestamp: String(Math.floor(Date.now() / 1000)) }, message)] } }] }] };
}

export async function deliver(payload) {
  const r = await post(`${N8N}/webhook/ria-teste-whatsapp`, payload);
  if (r.status >= 400) throw new Error('n8n respondeu ' + r.status + ': ' + JSON.stringify(r.body).slice(0, 400));
  return r;
}
export const text = (from, body, name) => deliver(webhookPayload(from, { type: 'text', text: { body } }, name));
export const audio = (from, mediaId = 'MEDIA001') => deliver(webhookPayload(from, { type: 'audio', audio: { id: mediaId, mime_type: 'audio/ogg; codecs=opus', voice: true } }));
export const button = (from, id, title = 'ok') => deliver(webhookPayload(from, { type: 'interactive', interactive: { type: 'button_reply', button_reply: { id, title } } }));
export const templateButton = (from, payload, t = 'Confirmar') => deliver(webhookPayload(from, { type: 'button', button: { payload, text: t } }));
export const image = (from) => deliver(webhookPayload(from, { type: 'image', image: { id: 'IMG1', mime_type: 'image/jpeg' } }));
export const runWorkflow = (workflow) => post(`${N8N}/webhook/ria-teste-executar`, { workflow });

export async function control(obj) { return post(`${MOCK}/__control`, obj); }
export async function resetMock() { return post(`${MOCK}/__reset`, {}); }
export async function sent() { return (await fetch(`${MOCK}/__sent`)).json(); }
export async function events() { return (await fetch(`${MOCK}/__events`)).json(); }
export async function mockState() { return (await fetch(`${MOCK}/__state`)).json(); }
export async function addEvent(ev) { return post(`${MOCK}/__add_event`, ev); }

// Mensagens enviadas a um número a partir de um índice
export async function sentTo(to, since = 0) {
  return (await sent()).slice(since).filter((m) => m.to === to);
}
export function textOf(m) {
  const p = m.payload || {};
  if (p.type === 'text') return p.text.body;
  if (p.type === 'interactive') return p.interactive.body.text + ' [' + ((p.interactive.action.buttons || []).map((b) => b.reply.title).join(' | ') || (p.interactive.action.sections || []).flatMap((s) => s.rows.map((r) => r.title)).join(' | ')) + ']';
  if (p.type === 'location') return `[localização ${p.location.latitude},${p.location.longitude}]`;
  if (p.type === 'template') return `[template ${p.template.name}] ` + JSON.stringify(p.template.components);
  return JSON.stringify(p);
}

export function sql(query) {
  const db = process.env.E2E_DB || 'ria_e2e';
  return execFileSync('psql', ['-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db, '-c', query], { encoding: 'utf8' }).trim();
}
