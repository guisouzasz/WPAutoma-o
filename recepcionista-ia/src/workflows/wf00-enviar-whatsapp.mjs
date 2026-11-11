import { Workflow, WF, CRED } from './_dsl.mjs';

// 00 — Sub-workflow de envio pela WhatsApp Cloud API (reutilizado por todos os fluxos).
// Entrada (um item por mensagem): { to, phone_number_id, clinic_id, patient_id?, staff_id?, purpose,
//   message: {type:'text'|'buttons'|'list'|'location'|'template', ...}, graph_base, graph_version, meta? }
// Saída: { sent, failed, results: [{ ok, wa_message_id, error_code, meta }] }
export default function build() {
  const w = new Workflow(WF.enviar, 'Recepcionista IA - 00 Enviar WhatsApp', { settings: { errorWorkflow: WF.monitoramento } });
  w.note('Sobre', [-40, -260], '## 00 · Enviar WhatsApp\nRecebe mensagens no formato normalizado, monta o payload oficial da Graph API, envia em sequência (ordem preservada), registra o resultado (sem conteúdo) e devolve um resumo.\n\nCredencial: **Recepcionista IA - WhatsApp Cloud API** (token de usuário do sistema).', 460, 220);
  w.subTrigger('Entrada', [0, 0]);
  w.code('Montar payload', [220, 0], `
const out = [];
for (const it of $input.all()) {
  const j = it.json || {};
  try {
    const payload = toGraphPayload(j.to, j.message);
    const base = j.graph_base || 'https://graph.facebook.com';
    const version = j.graph_version || 'v23.0';
    out.push({ json: Object.assign({}, j, { url: base + '/' + version + '/' + j.phone_number_id + '/messages', payload, kind: graphKind(j.message), build_error: null }) });
  } catch (e) {
    out.push({ json: Object.assign({}, j, { url: 'http://invalid.invalid/', payload: {}, kind: 'text', build_error: String(e.message || e) }) });
  }
}
return out;`, ['util', 'whatsapp']);
  w.http('Enviar mensagem', [440, 0], {
    method: 'POST', url: '={{ $json.url }}', credType: 'whatsAppApi', credentials: CRED.whatsapp,
    jsonBody: '={{ JSON.stringify($json.payload) }}', timeout: 15000, batch: 250, retry: 3,
  });
  w.code('Interpretar respostas', [660, 0], `
const inputs = $('Montar payload').all();
return $input.all().map((it, i) => {
  const src = (inputs[i] && inputs[i].json) || {};
  const j = it.json || {};
  let r;
  if (src.build_error) r = { ok: false, error_code: 'build', error_title: sanitizeForLog(src.build_error, 200) };
  else if (j.error && !j.statusCode) r = { ok: false, error_code: 'network', error_title: sanitizeForLog(typeof j.error === 'string' ? j.error : (j.error.message || 'erro de rede'), 200) };
  else r = parseGraphResponse(j);
  return { json: Object.assign({
    clinic_id: src.clinic_id || null, patient_id: src.patient_id || null, staff_id: src.staff_id || null,
    purpose: src.purpose || 'reply', kind: src.kind || 'text', meta: src.meta || null, to_masked: maskPhone(src.to),
  }, r) };
});`, ['util', 'whatsapp']);
  w.pg('Registrar envio', [880, 0], 'api_outbound_record',
    `{ clinic_id: $json.clinic_id, patient_id: $json.patient_id, staff_id: $json.staff_id, wa_message_id: $json.wa_message_id || null, kind: $json.kind, purpose: $json.purpose, status: $json.ok ? 'accepted' : 'error', error_code: $json.error_code || null, error_title: $json.error_title || null }`);
  w.code('Resultado', [1100, 0], `
const res = $('Interpretar respostas').all().map((i) => i.json);
return [{ json: { sent: res.filter((r) => r.ok).length, failed: res.filter((r) => !r.ok).length, results: res } }];`);
  w.chain('Entrada', 'Montar payload', 'Enviar mensagem', 'Interpretar respostas', 'Registrar envio', 'Resultado');
  return w;
}
