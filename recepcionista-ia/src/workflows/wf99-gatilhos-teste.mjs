import { Workflow, WF } from './_dsl.mjs';

// 99 — SOMENTE TESTES: dispara sob demanda os workflows agendados (lembretes, monitoramento, reconciliação).
export default function build() {
  const w = new Workflow('RiaWf99GatilhoTs', 'Recepcionista IA - 99 Gatilhos de teste (NÃO usar em produção)');
  w.add('Webhook de teste', 'n8n-nodes-base.webhook', 2, { httpMethod: 'POST', path: 'ria-teste-executar', responseMode: 'lastNode', options: {} }, [0, 0]);
  w.switchOn('Qual workflow?', [220, 0], '$json.body.workflow', ['lembretes', 'monitoramento', 'reconciliacao']);
  w.execWf('Lembretes (WF04)', [460, -120], WF.lembretes, 'once');
  w.execWf('Monitoramento (WF06)', [460, 0], WF.monitoramento, 'once');
  w.execWf('Reconciliação (WF07)', [460, 120], WF.reconciliacao, 'once');
  for (const n of w.nodes) if (n.type === 'n8n-nodes-base.executeWorkflow') n.alwaysOutputData = true;
  w.code('Fim', [700, 0], "return [{ json: { ok: true } }];");
  w.connect('Webhook de teste', 'Qual workflow?');
  w.connect('Qual workflow?', 'Lembretes (WF04)', 0);
  w.connect('Qual workflow?', 'Monitoramento (WF06)', 1);
  w.connect('Qual workflow?', 'Reconciliação (WF07)', 2);
  for (const n of ['Lembretes (WF04)', 'Monitoramento (WF06)', 'Reconciliação (WF07)']) w.connect(n, 'Fim');
  return w;
}
