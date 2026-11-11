#!/usr/bin/env node
// Valida os JSONs de workflows contra as definições REAIS dos nós do n8n instalado:
//  - tipo de nó existe e a versão (typeVersion) é suportada
//  - parâmetros reconhecidos pela descrição do nó (nada "inventado" ou oculto)
//  - credenciais compatíveis com o nó; nenhum segredo embutido
//  - conexões apontam para nós existentes e saídas válidas
//  - código dos nós Code compila
//  - IDs de sub-workflows existem no conjunto
// Uso: N8N_NODE_MODULES=/caminho/para/node_modules node scripts/validar-workflows.mjs [arquivos...]
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { ROOT } from '../src/workflows/_dsl.mjs';

const nm = process.env.N8N_NODE_MODULES || path.join(ROOT, 'node_modules');
if (!existsSync(path.join(nm, 'n8n-nodes-base'))) {
  console.error('n8n-nodes-base não encontrado. Instale n8n (npm i n8n) e defina N8N_NODE_MODULES.');
  process.exit(2);
}
const require = createRequire(path.join(nm, 'noop.js'));
const { NodeHelpers } = require('n8n-workflow');
const pkg = require('n8n-nodes-base/package.json');
const nodeFiles = pkg.n8n.nodes;

const typeIndex = new Map();
function loadType(name) {
  if (typeIndex.has(name)) return typeIndex.get(name);
  const short = name.replace('n8n-nodes-base.', '');
  for (const f of nodeFiles) {
    const base = path.basename(f, '.node.js');
    if (base.toLowerCase() !== short.toLowerCase()) continue;
    const mod = require(path.join('n8n-nodes-base', f));
    const C = Object.entries(mod).find(([k, v]) => typeof v === 'function' && /^[A-Z]/.test(k))[1];
    const inst = new C();
    if (inst.description && inst.description.name !== short) continue;
    typeIndex.set(name, inst);
    return inst;
  }
  typeIndex.set(name, null);
  return null;
}

function descFor(inst, version) {
  if (inst.nodeVersions) {
    const v = inst.nodeVersions[version];
    return v ? v.description : null;
  }
  const vs = Array.isArray(inst.description.version) ? inst.description.version : [inst.description.version];
  return vs.includes(version) ? inst.description : null;
}

const SECRET_PATTERNS = [/sk-[A-Za-z0-9]{20,}/, /EAA[A-Za-z0-9]{30,}/, /ya29\.[A-Za-z0-9_-]{20,}/, /"password"\s*:\s*"[^"]+"/i, /Bearer [A-Za-z0-9._-]{20,}/];

const files = process.argv.slice(2).length ? process.argv.slice(2)
  : readdirSync(path.join(ROOT, 'workflows')).filter((f) => f.endsWith('.json')).map((f) => path.join(ROOT, 'workflows', f));
const all = files.map((f) => ({ file: f, wf: JSON.parse(readFileSync(f, 'utf8')) }));
const ids = new Set(all.map((x) => x.wf.id));
let errors = 0;
const err = (f, m) => { errors++; console.log(`  ✗ ${m}`); };

function flatKeys(obj, prefix = '') {
  const out = [];
  for (const [k, v] of Object.entries(obj || {})) {
    const p = prefix ? prefix + '.' + k : k;
    out.push(p);
  }
  return out;
}

for (const { file, wf } of all) {
  console.log(`\n${path.relative(ROOT, file)} — ${wf.name}`);
  const raw = readFileSync(file, 'utf8');
  for (const re of SECRET_PATTERNS) if (re.test(raw)) err(file, `possível segredo embutido (${re})`);
  const names = new Set(wf.nodes.map((n) => n.name));
  if (names.size !== wf.nodes.length) err(file, 'nomes de nós duplicados');
  const outputsCount = {};
  for (const n of wf.nodes) {
    const inst = loadType(n.type);
    if (!inst) { err(file, `${n.name}: tipo de nó inexistente ${n.type}`); continue; }
    const d = descFor(inst, n.typeVersion);
    if (!d) { err(file, `${n.name}: versão ${n.typeVersion} não suportada por ${n.type}`); continue; }
    // parâmetros
    const resolved = NodeHelpers.getNodeParameters(d.properties, n.parameters, true, false, n, d);
    for (const k of flatKeys(n.parameters)) {
      if (!(k in (resolved || {}))) err(file, `${n.name}: parâmetro desconhecido ou oculto "${k}"`);
    }
    // parâmetros aninhados (options/collections) — checa nomes de opções
    for (const [k, v] of Object.entries(n.parameters || {})) {
      const prop = d.properties.find((p) => p.name === k && (p.type === 'collection'));
      if (prop && v && typeof v === 'object') {
        for (const sub of Object.keys(v)) if (!prop.options.some((o) => o.name === sub)) err(file, `${n.name}: opção desconhecida "${k}.${sub}"`);
      }
    }
    // credenciais
    for (const ctype of Object.keys(n.credentials || {})) {
      const allowed = (d.credentials || []).map((c) => c.name);
      const generic = n.type === 'n8n-nodes-base.httpRequest' && (n.parameters.nodeCredentialType === ctype || n.parameters.genericAuthType === ctype);
      if (!allowed.includes(ctype) && !generic) err(file, `${n.name}: credencial ${ctype} não aceita pelo nó`);
      const c = n.credentials[ctype];
      if (!c.id || !c.name || Object.keys(c).some((k) => !['id', 'name'].includes(k))) err(file, `${n.name}: referência de credencial inválida`);
    }
    // código
    if (n.type === 'n8n-nodes-base.code') {
      try { new Function('$input', '$json', '$', '$node', `return (async () => { ${n.parameters.jsCode}\n })`); }
      catch (e) { err(file, `${n.name}: erro de sintaxe no código: ${e.message}`); }
    }
    // sub-workflows
    if (n.type === 'n8n-nodes-base.executeWorkflow') {
      const id = n.parameters.workflowId && n.parameters.workflowId.value;
      if (!ids.has(id) && !all.some((x) => x.wf.id === id)) err(file, `${n.name}: sub-workflow ${id} não existe no conjunto`);
    }
    if (n.type === 'n8n-nodes-base.switch') outputsCount[n.name] = n.parameters.rules.values.length + (n.parameters.options && n.parameters.options.fallbackOutput === 'extra' ? 1 : 0);
    else if (n.type === 'n8n-nodes-base.if') outputsCount[n.name] = 2;
    else outputsCount[n.name] = 1;
  }
  for (const [from, c] of Object.entries(wf.connections)) {
    if (!names.has(from)) err(file, `conexão de nó inexistente: ${from}`);
    (c.main || []).forEach((targets, idx) => {
      if (idx >= (outputsCount[from] || 1) && targets.length) err(file, `${from}: saída ${idx} não existe`);
      for (const t of targets) if (!names.has(t.node)) err(file, `${from} → nó inexistente ${t.node}`);
    });
  }
  // nós sem entrada (exceto gatilhos e notas)
  const hasInput = new Set();
  for (const c of Object.values(wf.connections)) for (const ts of c.main || []) for (const t of ts) hasInput.add(t.node);
  for (const n of wf.nodes) {
    const isTrigger = /trigger|webhook/i.test(n.type) || n.type === 'n8n-nodes-base.stickyNote' || n.name === 'WhatsApp Trigger';
    if (!isTrigger && !hasInput.has(n.name)) err(file, `${n.name}: nó desconectado`);
  }
  if (wf.settings && wf.settings.errorWorkflow && !ids.has(wf.settings.errorWorkflow)) err(file, 'errorWorkflow inexistente');
  console.log(`  ${wf.nodes.length} nós verificados`);
}
console.log(errors ? `\n${errors} problema(s) encontrado(s)` : '\nTODOS OS WORKFLOWS VÁLIDOS');
process.exit(errors ? 1 : 0);
