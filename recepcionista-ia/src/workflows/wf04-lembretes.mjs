import { Workflow, WF } from './_dsl.mjs';

// 04 — Lembretes automáticos ~24h antes (Schedule Trigger).
export default function build() {
  const w = new Workflow(WF.lembretes, 'Recepcionista IA - 04 Lembretes', { settings: { errorWorkflow: WF.monitoramento, timezone: 'America/Sao_Paulo' } });
  w.note('Sobre', [-60, -300], '## 04 · Lembretes\nA cada 15 min, `ria.api_reminders_claim` reivindica de forma atômica as consultas confirmadas que entram na janela de lembrete (padrão 24h). A restrição UNIQUE(consulta, tipo) impede disparo duplicado.\n\n- Consultas canceladas ou pacientes com opt-out: não recebem (registrado como *skipped*).\n- Paciente fora da janela de 24h: usa o **template Utility aprovado** (`reminder_template`), com botões Confirmar/Remarcar.\n- Dentro da janela: mensagem interativa com botões.\n- Resultado (sent/failed) registrado; status de entrega atualizado pelo webhook.', 560, 280);
  w.schedule('A cada 15 minutos', [0, 0], { field: 'minutes', minutesInterval: 15 });
  w.subTrigger('Execução sob demanda', [0, 160]);
  w.pg('Reivindicar lembretes', [220, 0], 'api_reminders_claim', '{ limit: 50 }');
  w.code('Montar lembretes', [440, 0], `
const res = ($json && $json.result) || {};
const s = res.settings || {};
const out = [];
for (const r of res.reminders || []) {
  if (r.status !== 'sending') continue;
  const msg = r.in_session_window ? buildReminderSession(r) : buildReminderTemplate(r);
  out.push({ json: { to: r.patient_wa_id, phone_number_id: r.phone_number_id, clinic_id: r.clinic_id, patient_id: r.patient_id,
    purpose: 'reminder', message: msg, graph_base: s.graph_api_base, graph_version: s.graph_api_version,
    meta: { reminder_id: r.reminder_id, channel: r.in_session_window ? 'session' : 'template' } } });
}
return out;`, ['util', 'whatsapp']);
  w.execWf('Enviar lembretes (WF00)', [660, 0], WF.enviar, 'once');
  w.code('Resultados', [880, 0], `
const out = [];
for (const it of $input.all()) for (const r of it.json.results || []) {
  if (!r.meta || !r.meta.reminder_id) continue;
  out.push({ json: { reminder_id: r.meta.reminder_id, status: r.ok ? 'sent' : 'failed', channel: r.meta.channel, wa_message_id: r.wa_message_id || null, error_code: r.error_code || null } });
}
return out;`);
  w.pg('Registrar resultado', [1100, 0], 'api_reminder_result', '$json');
  w.chain('A cada 15 minutos', 'Reivindicar lembretes', 'Montar lembretes', 'Enviar lembretes (WF00)', 'Resultados', 'Registrar resultado');
  w.connect('Execução sob demanda', 'Reivindicar lembretes');
  return w;
}
