// Mini-DSL para gerar workflows n8n a partir de código revisável.
// Somente nós e versões nativos do n8n (n8n-nodes-base). Validação: scripts/validar-workflows.mjs
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

// IDs fixos => os nós "Execute Workflow" encontram os sub-workflows após importar via CLI
export const WF = {
  enviar: 'RiaWf00EnviarWpp',
  recepcao: 'RiaWf01Recepcao0',
  agendamento: 'RiaWf02Agendamen',
  remarcacao: 'RiaWf03Remarcaca',
  lembretes: 'RiaWf04Lembretes',
  humano: 'RiaWf05Humano000',
  monitoramento: 'RiaWf06Monitoram',
  reconciliacao: 'RiaWf07Reconcili',
  adaptador: 'RiaWf08AdaptAgen',
};

// Credenciais: somente referência (id/nome). Os segredos são preenchidos no n8n.
export const CRED = {
  postgres: { postgres: { id: 'RiaCredPostgres1', name: 'Recepcionista IA - PostgreSQL' } },
  whatsapp: { whatsAppApi: { id: 'RiaCredWhatsApp1', name: 'Recepcionista IA - WhatsApp Cloud API' } },
  whatsappTrigger: { whatsAppTriggerApi: { id: 'RiaCredWppTrigg1', name: 'Recepcionista IA - WhatsApp Webhook (App Meta)' } },
  openai: { openAiApi: { id: 'RiaCredOpenAI001', name: 'Recepcionista IA - OpenAI' } },
  google: { googleCalendarOAuth2Api: { id: 'RiaCredGoogleCal', name: 'Recepcionista IA - Google Calendar' } },
  externalCalendar: { httpHeaderAuth: { id: 'RiaCredAgendaExt', name: 'Recepcionista IA - API Agenda Externa' } },
  adminApi: { httpHeaderAuth: { id: 'RiaCredAdminApi1', name: 'Recepcionista IA - API Administrativa' } },
};

const LIB_ORDER = ['util', 'safety', 'webhook', 'intent', 'messages', 'router', 'whatsapp', 'calendar', 'staff'];

export function libsCode(libs) {
  const set = new Set(libs);
  const parts = [];
  if (set.has('intent')) {
    const prompt = readFileSync(path.join(ROOT, 'prompts/recepcionista-system.md'), 'utf8');
    parts.push(`const SYSTEM_PROMPT = ${JSON.stringify(prompt)};`);
  }
  for (const l of LIB_ORDER) if (set.has(l)) parts.push(`// ===== lib/${l}.js =====\n` + readFileSync(path.join(ROOT, 'src/lib', l + '.js'), 'utf8'));
  return parts.join('\n');
}

function stableId(wfId, name) {
  const h = createHash('sha1').update(wfId + '::' + name).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export class Workflow {
  constructor(id, name, opts = {}) {
    this.id = id;
    this.name = name;
    this.nodes = [];
    this.connections = {};
    this.settings = Object.assign({ executionOrder: 'v1', saveManualExecutions: false, callerPolicy: 'workflowsFromSameOwner' }, opts.settings || {});
    this.tags = opts.tags || [];
    this.description = opts.description || '';
  }

  add(name, type, typeVersion, parameters, position, extra = {}) {
    if (this.nodes.some((n) => n.name === name)) throw new Error(`Nó duplicado: ${name} em ${this.name}`);
    const node = Object.assign({ parameters, id: stableId(this.id, name), name, type, typeVersion, position }, extra);
    // Nós de webhook precisam de webhookId fixo para que o caminho seja exatamente o "path" configurado
    if (/\.webhook$|whatsAppTrigger$/.test(type) && !node.webhookId) node.webhookId = stableId(this.id, name + ':webhook');
    this.nodes.push(node);
    return name;
  }

  connect(from, to, output = 0, input = 0) {
    this.connections[from] = this.connections[from] || { main: [] };
    const main = this.connections[from].main;
    while (main.length <= output) main.push([]);
    main[output].push({ node: to, type: 'main', index: input });
  }

  chain(...names) {
    for (let i = 0; i < names.length - 1; i++) this.connect(names[i], names[i + 1]);
  }

  // ---------- fábricas de nós ----------
  code(name, pos, body, libs = [], opts = {}) {
    const jsCode = `// Gerado por scripts/build-workflows.mjs — edite src/workflows/ e src/lib/.\n` +
      (libs.length ? libsCode(libs) + '\n\n// ===== lógica do nó =====\n' : '') + body.trim() + '\n';
    return this.add(name, 'n8n-nodes-base.code', 2, { mode: opts.each ? 'runOnceForEachItem' : 'runOnceForAllItems', jsCode }, pos,
      opts.onError ? { onError: opts.onError } : {});
  }

  // Chama uma função ria.api_*(jsonb) com parâmetro posicional ($1) — SQL parametrizado
  // opts.echo: devolve também o item de entrada em "input" (o nó Postgres não preserva campos)
  pg(name, pos, apiFn, argExpr, opts = {}) {
    const query = opts.echo
      ? `SELECT ria.${apiFn}($1::jsonb) AS result, $2::jsonb AS input;`
      : `SELECT ria.${apiFn}($1::jsonb) AS result;`;
    const repl = opts.echo
      ? `={{ [ JSON.stringify(${argExpr}), JSON.stringify($json) ] }}`
      : `={{ [ JSON.stringify(${argExpr}) ] }}`;
    return this.add(name, 'n8n-nodes-base.postgres', 2.6, {
      operation: 'executeQuery',
      query,
      options: { queryReplacement: repl },
    }, pos, Object.assign({ credentials: CRED.postgres }, opts.alwaysOutput ? { alwaysOutputData: true } : {}, opts.onError ? { onError: opts.onError } : {}));
  }

  http(name, pos, p) {
    const parameters = {
      method: p.method || 'GET',
      url: p.url,
    };
    if (p.cred === 'none') {
      parameters.authentication = 'none';
    } else if (p.generic) {
      parameters.authentication = 'genericCredentialType';
      parameters.genericAuthType = p.generic;
    } else {
      parameters.authentication = 'predefinedCredentialType';
      parameters.nodeCredentialType = p.credType;
    }
    if (p.query) {
      parameters.sendQuery = true;
      parameters.queryParameters = { parameters: p.query };
    }
    if (p.jsonBody) {
      parameters.sendBody = p.sendBody !== undefined ? p.sendBody : true;
      parameters.specifyBody = 'json';
      parameters.jsonBody = p.jsonBody;
    }
    if (p.multipart) {
      parameters.sendBody = true;
      parameters.contentType = 'multipart-form-data';
      parameters.bodyParameters = { parameters: p.multipart };
    }
    const options = { timeout: p.timeout || 15000 };
    if (p.file) options.response = { response: { responseFormat: 'file', outputPropertyName: 'data' } };
    else if (p.full !== false) options.response = { response: { fullResponse: true, neverError: true } };
    if (p.batch) options.batching = { batch: { batchSize: 1, batchInterval: p.batch } };
    parameters.options = options;
    const credentials = p.cred === 'none' ? undefined : p.credentials;
    const extra = { onError: 'continueRegularOutput' };
    if (credentials) extra.credentials = credentials;
    if (p.retry) Object.assign(extra, { retryOnFail: true, maxTries: p.retry, waitBetweenTries: 1500 });
    return this.add(name, 'n8n-nodes-base.httpRequest', 4.2, parameters, pos, extra);
  }

  ifTrue(name, pos, boolExpr) {
    return this.add(name, 'n8n-nodes-base.if', 2.2, {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{ id: stableId(this.id, name + ':c'), leftValue: `={{ ${boolExpr} }}`, rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and',
      },
      options: {},
    }, pos);
  }

  // Switch por valor textual: uma saída por valor, na ordem dada (+ saída extra "fallback")
  switchOn(name, pos, valueExpr, values) {
    return this.add(name, 'n8n-nodes-base.switch', 3.2, {
      rules: {
        values: values.map((v) => ({
          conditions: {
            options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
            conditions: [{ id: stableId(this.id, name + ':' + v), leftValue: `={{ ${valueExpr} }}`, rightValue: v, operator: { type: 'string', operation: 'equals' } }],
            combinator: 'and',
          },
          renameOutput: true,
          outputKey: v,
        })),
      },
      options: { fallbackOutput: 'extra', renameFallbackOutput: 'outro' },
    }, pos);
  }

  execWf(name, pos, wfId, mode = 'each') {
    return this.add(name, 'n8n-nodes-base.executeWorkflow', 1.2, {
      source: 'database',
      workflowId: { __rl: true, value: wfId, mode: 'id' },
      mode,
      options: { waitForSubWorkflow: true },
    }, pos);
  }

  subTrigger(name, pos) {
    return this.add(name, 'n8n-nodes-base.executeWorkflowTrigger', 1.1, { inputSource: 'passthrough' }, pos);
  }

  schedule(name, pos, rule) {
    return this.add(name, 'n8n-nodes-base.scheduleTrigger', 1.2, { rule: { interval: [rule] } }, pos);
  }

  noop(name, pos) {
    return this.add(name, 'n8n-nodes-base.noOp', 1, {}, pos);
  }

  note(name, pos, content, w = 420, h = 260, color = 7) {
    return this.add(name, 'n8n-nodes-base.stickyNote', 1, { content, height: h, width: w, color }, pos);
  }

  toJSON() {
    return {
      id: this.id,
      name: this.name,
      nodes: this.nodes,
      connections: this.connections,
      active: false,
      settings: this.settings,
      pinData: {},
      meta: { templateCredsSetupCompleted: false, generatedBy: 'recepcionista-ia/scripts/build-workflows.mjs' },
      tags: [],
    };
  }
}

// Expressão comum: settings do banco com padrão
export const S = (key, def) => `($json.ctx && $json.ctx.settings && $json.ctx.settings.${key} !== undefined ? $json.ctx.settings.${key} : ${JSON.stringify(def)})`;
