import { Workflow, WF } from './_dsl.mjs';

// 06 — Monitoramento: erros (Error Trigger), manutenção, alertas, métricas diárias e retenção.
export default function build() {
  const w = new Workflow(WF.monitoramento, 'Recepcionista IA - 06 Monitoramento', { settings: { timezone: 'America/Sao_Paulo' } });
  w.note('Sobre', [-60, -360], '## 06 · Monitoramento\n- **Erro em qualquer workflow** (configurado como *Error Workflow*): registra em `ria.integration_errors`, sem dados pessoais.\n- **A cada 10 min:** expira ofertas/reservas, devolve conversas humanas inativas ao robô, coleta alertas (erros/hora, falhas de entrega, divergência de agenda, urgência sem resposta) e avisa administradores (`receives_alerts`).\n- **Diário 07:40:** métricas do dia anterior (mensagens, pacientes, confirmadas, canceladas, remarcadas, transferências, lembretes, erros).\n- **Diário 03:20:** política de retenção (LGPD).\nAlertas nunca contêm dados clínicos nem telefone completo.', 600, 300);

  // Erros
  w.add('Erro em workflow', 'n8n-nodes-base.errorTrigger', 1, {}, [0, 0]);
  w.code('Resumo do erro', [220, 0], `
const j = $json || {};
const exec = j.execution || {}; const wf = j.workflow || {}; const err = exec.error || j.trigger && j.trigger.error || {};
const node = exec.lastNodeExecuted || (err.node && err.node.name) || '';
const n = (node + ' ' + (err.message || '')).toLowerCase();
const source = /openai|ia\\b|transcrev/.test(n) ? 'openai' : /agenda|calendar|google/.test(n) ? 'calendar' : /whatsapp|graph|mídia|enviar/.test(n) ? 'whatsapp' : /postgres|banco|database|sql/.test(n) ? 'database' : 'n8n';
return [{ json: { source, workflow: wf.name || '', node, error_code: String(err.httpCode || err.name || 'erro'), message: sanitizeForLog(err.message || err.description || 'erro', 400), execution_id: String(exec.id || '') } }];`, ['util']);
  w.pg('Registrar erro', [440, 0], 'api_log_error', '$json');

  // Manutenção + alertas
  w.schedule('A cada 10 minutos', [0, 260], { field: 'minutes', minutesInterval: 10 });
  w.subTrigger('Execução sob demanda', [0, 380]);
  w.pg('Manutenção', [220, 260], 'api_janitor', '{}');
  w.pg('Coletar alertas', [440, 260], 'api_alerts_collect', '{}');
  w.code('Montar alertas', [660, 260], `
const res = ($json && $json.result) || {};
const s = res.settings || {};
const out = [];
for (const a of res.alerts || []) {
  const admins = a.admins || [];
  if (!admins.length || !a.phone_number_id) { out.push({ json: { __mark_only: true, alert_id: a.alert_id } }); continue; }
  for (const ad of admins) {
    out.push({ json: { to: ad.wa_id, phone_number_id: a.phone_number_id, clinic_id: a.clinic_id, staff_id: ad.id, purpose: 'alert',
      message: ad.in_window ? { type: 'text', text: '⚙️ Recepcionista IA — ' + a.message } : { type: 'template', name: 'alerta_equipe', language: 'pt_BR',
        components: [{ type: 'body', parameters: [{ type: 'text', text: truncate(a.message, 900) }] }] },
      graph_base: s.graph_api_base, graph_version: s.graph_api_version, meta: { alert_id: a.alert_id } } });
  }
}
return out;`, ['util']);
  w.ifTrue('Enviar alerta?', [880, 260], '!$json.__mark_only');
  w.execWf('Enviar alertas (WF00)', [1100, 200], WF.enviar, 'once');
  w.code('Alertas processados', [1320, 260], `
const ids = new Set();
for (const it of $input.all()) {
  if (it.json.alert_id) ids.add(it.json.alert_id);
  for (const r of it.json.results || []) if (r.meta && r.meta.alert_id) ids.add(r.meta.alert_id);
}
return [...ids].map((id) => ({ json: { alert_id: id } }));`);
  w.pg('Marcar alerta enviado', [1540, 260], 'api_alert_sent', '{ alert_id: $json.alert_id }');

  // Métricas diárias
  w.schedule('Diariamente 07:40', [0, 520], { field: 'days', daysInterval: 1, triggerAtHour: 7, triggerAtMinute: 40 });
  w.pg('Métricas do dia anterior', [220, 520], 'api_daily_metrics', '{}');
  w.code('Resumo diário', [440, 520], `
const res = ($json && $json.result) || {};
const s = res.settings || {};
const out = [];
for (const m of res.metrics || []) {
  const text = '📊 ' + m.clinic_name + ' — resumo de ' + String(m.day).split('-').reverse().join('/') + '\\n' +
    'Mensagens recebidas: ' + m.messages_in + ' (áudios: ' + m.audio_messages + ')\\n' +
    'Pacientes atendidos: ' + m.patients_served + ' (novos: ' + m.new_patients + ')\\n' +
    'Consultas confirmadas: ' + m.appointments_confirmed + '\\nCanceladas: ' + m.appointments_cancelled + ' | Remarcadas: ' + m.appointments_rescheduled + '\\n' +
    'Transferências humanas: ' + m.handoffs + '\\nLembretes enviados: ' + m.reminders_sent + '\\n' +
    'Erros de integração: ' + m.integration_errors + ' | Falhas de entrega: ' + m.delivery_failures;
  for (const ad of m.admins || []) {
    out.push({ json: { to: ad.wa_id, phone_number_id: m.phone_number_id, clinic_id: m.clinic_id, staff_id: ad.id, purpose: 'alert',
      message: ad.in_window ? { type: 'text', text } : { type: 'template', name: 'alerta_equipe', language: 'pt_BR', components: [{ type: 'body', parameters: [{ type: 'text', text: truncate(text.replace(/\\n/g, ' | '), 900) }] }] },
      graph_base: s.graph_api_base, graph_version: s.graph_api_version } });
  }
}
return out;`, ['util']);
  w.execWf('Enviar resumo (WF00)', [660, 520], WF.enviar, 'once');

  // Retenção
  w.schedule('Diariamente 03:20', [0, 720], { field: 'days', daysInterval: 1, triggerAtHour: 3, triggerAtMinute: 20 });
  w.pg('Retenção de dados (LGPD)', [220, 720], 'api_retention', '{}');

  w.chain('Erro em workflow', 'Resumo do erro', 'Registrar erro');
  w.chain('A cada 10 minutos', 'Manutenção', 'Coletar alertas', 'Montar alertas', 'Enviar alerta?');
  w.connect('Enviar alerta?', 'Enviar alertas (WF00)', 0);
  w.connect('Enviar alerta?', 'Alertas processados', 1);
  w.connect('Enviar alertas (WF00)', 'Alertas processados');
  w.connect('Alertas processados', 'Marcar alerta enviado');
  w.chain('Diariamente 07:40', 'Métricas do dia anterior', 'Resumo diário', 'Enviar resumo (WF00)');
  w.connect('Diariamente 03:20', 'Retenção de dados (LGPD)');
  w.connect('Execução sob demanda', 'Manutenção');
  return w;
}
