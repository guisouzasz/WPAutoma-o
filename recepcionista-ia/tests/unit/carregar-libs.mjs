// Carrega as bibliotecas de src/lib no MESMO formato usado nos nós Code do n8n
// (código concatenado em um único escopo) e devolve as funções para teste.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const LIBS = ['util', 'safety', 'webhook', 'intent', 'messages', 'router', 'whatsapp', 'calendar', 'staff'];

export function carregar() {
  const prompt = readFileSync(path.join(root, 'prompts/recepcionista-system.md'), 'utf8');
  const code = `const SYSTEM_PROMPT = ${JSON.stringify(prompt)};\n` +
    LIBS.map((l) => readFileSync(path.join(root, 'src/lib', l + '.js'), 'utf8')).join('\n') +
    `\n;globalThis.__libs = { ${[
      'normalizeText','truncate','isIsoDate','addDays','sanitizeForLog','maskPhone',
      'detectEmergency','detectUrgency','detectHumanRequest','detectInjection','isOptOut','sanitizeAiReply',
      'parseWhatsAppEvents','INTENT_SCHEMA','buildAiRequest','validateAi','fallbackClassify','preClassify','mergeWithSafety','parseDates','parseTime','parseOptionNumber',
      'decideRoute','offerMessages','bookedMessages','toGraphPayload','buildReminderTemplate','buildReminderSession','parseGraphResponse',
      'normalizeGoogleFreeBusy','googleEventBody','normalizeGoogleEvents','parseStaffCommand','SYSTEM_PROMPT'].join(',')} };`;
  const ctx = vm.createContext({});
  vm.runInContext(code, ctx, { filename: 'libs-concatenadas.js' });
  // Clona resultados para o "realm" do teste (deepEqual compara protótipos)
  const clone = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)));
  const out = {};
  for (const [k, v] of Object.entries(ctx.__libs)) out[k] = typeof v === 'function' ? (...a) => clone(v(...a)) : clone(v);
  return out;
}

// Contexto de exemplo (formato devolvido por ria.api_inbound_begin)
export function contextoDemo(over = {}) {
  return Object.assign({
    status: 'ok',
    clinic: { id: 'c1', name: 'Clínica Sorriso Demo', address: 'Av. Exemplo, 1000', maps_url: 'https://maps.google.com/?q=1,2', latitude: -23.5, longitude: -46.6,
      timezone: 'America/Sao_Paulo', hours_summary: 'segunda: 08:00–12:00 e 13:30–18:00; sábado: 08:00–12:00', is_open_now: false,
      next_opening_label: 'seg, 16/11 às 08:00', today_local: '2026-11-15', weekday_local: 'domingo', now_local: '2026-11-15T20:00',
      messages: { welcome: 'Olá! Sou a assistente.', privacy_notice: 'Aviso de privacidade.', cancel_policy: 'Cancele com 24h.' },
      policies: { max_booking_days_ahead: 30 } },
    settings: { unknown_max: 2 },
    patient: { id: 'p1', wa_id: '5511988880001', is_new: true, full_name: null, first_name: '', privacy_notice_shown: false },
    conversation: { id: 'cv1', mode: 'BOT', state: 'idle', context: {}, version: 1, unknown_count: 0 },
    offer: null,
    appointments: [],
    services: [
      { id: 's1', code: 'avaliacao', name: 'Avaliação odontológica', synonyms: ['consulta', 'primeira consulta'], bookable_by_bot: true, duration_minutes: 30, description: 'Primeira consulta.' },
      { id: 's2', code: 'limpeza', name: 'Limpeza (profilaxia)', synonyms: ['profilaxia', 'tartaro'], bookable_by_bot: true, duration_minutes: 45 },
      { id: 's3', code: 'clareamento', name: 'Clareamento dental', synonyms: ['clarear', 'branqueamento'], bookable_by_bot: true, duration_minutes: 60, description: 'Clareamento em consultório.' },
      { id: 's6', code: 'canal', name: 'Tratamento de canal', synonyms: ['endodontia'], bookable_by_bot: false, duration_minutes: 90 },
    ],
    professionals: [
      { id: '22222222-0000-4000-8000-000000000001', name: 'Dra. Ana Lima', specialty: 'Clínica geral', service_codes: ['avaliacao', 'limpeza'] },
      { id: '22222222-0000-4000-8000-000000000002', name: 'Dr. Bruno Costa', specialty: 'Estética', service_codes: ['avaliacao', 'clareamento'] },
    ],
    faqs: [{ id: 'f1', question: 'Vocês atendem convênio?', answer: 'Atendemos OdontoDemo.', keywords: ['convênio', 'convenio'] }],
  }, over);
}
