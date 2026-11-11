#!/usr/bin/env node
// Gera os JSONs importáveis em workflows/ a partir de src/workflows/*.mjs e src/lib/*.js.
// Uso: node scripts/build-workflows.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { ROOT } from '../src/workflows/_dsl.mjs';
import wf00 from '../src/workflows/wf00-enviar-whatsapp.mjs';
import wf01 from '../src/workflows/wf01-recepcao.mjs';
import wf02 from '../src/workflows/wf02-agendamento.mjs';
import wf03 from '../src/workflows/wf03-remarcacao-cancelamento.mjs';
import wf04 from '../src/workflows/wf04-lembretes.mjs';
import wf05 from '../src/workflows/wf05-atendimento-humano.mjs';
import wf06 from '../src/workflows/wf06-monitoramento.mjs';
import wf07 from '../src/workflows/wf07-reconciliacao.mjs';
import wf08 from '../src/workflows/wf08-adaptador-agenda.mjs';
import wf99 from '../src/workflows/wf99-gatilhos-teste.mjs';

const out = [
  ['00-enviar-whatsapp.json', wf00()],
  ['01-whatsapp-recepcao.json', wf01()],
  ['02-agendamento.json', wf02()],
  ['03-remarcacao-cancelamento.json', wf03()],
  ['04-lembretes.json', wf04()],
  ['05-atendimento-humano.json', wf05()],
  ['06-monitoramento.json', wf06()],
  ['07-reconciliacao-agenda.json', wf07()],
  ['08-adaptador-agenda.json', wf08()],
];
mkdirSync(path.join(ROOT, 'workflows'), { recursive: true });
for (const [file, wf] of out) {
  writeFileSync(path.join(ROOT, 'workflows', file), JSON.stringify(wf.toJSON(), null, 2) + '\n');
  console.log(`workflows/${file}  (${wf.nodes.length} nós)`);
}
// Variante de TESTE do 01 (Webhook no lugar do WhatsApp Trigger) — somente para tests/e2e
const testDir = path.join(ROOT, 'tests/e2e/workflows');
mkdirSync(testDir, { recursive: true });
writeFileSync(path.join(testDir, '01-whatsapp-recepcao-TESTE.json'), JSON.stringify(wf01({ trigger: 'test' }).toJSON(), null, 2) + '\n');
writeFileSync(path.join(testDir, '99-gatilhos-teste.json'), JSON.stringify(wf99().toJSON(), null, 2) + '\n');
console.log('tests/e2e/workflows/01-whatsapp-recepcao-TESTE.json, 99-gatilhos-teste.json');
