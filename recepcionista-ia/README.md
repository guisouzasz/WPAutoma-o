# Recepcionista IA — clínicas odontológicas (n8n + WhatsApp oficial)

Recepcionista virtual que atende 24h no WhatsApp da clínica: entende texto e áudio, agenda com
disponibilidade **real** de cada dentista, confirma, lembra, remarca, cancela e transfere para a
equipe humana quando necessário. Construída sobre **n8n**, **WhatsApp Business Cloud API (Meta)**,
**OpenAI**, **Google Calendar** e **PostgreSQL**, com implantação via **Docker Compose** e HTTPS.

> Status: **MVP funcional e testado localmente** (n8n 2.47.3 real + PostgreSQL 16 real + simulação
> das APIs externas). Ainda **não** foi testado com credenciais reais da Meta, OpenAI e Google —
> ver [docs/RELATORIO-FINAL.md](docs/RELATORIO-FINAL.md).

## O que faz

| Capacidade | Como |
|---|---|
| Atendimento 24h em pt-BR | Workflow 01 + IA com saída JSON estrita, validada antes de qualquer ação |
| Áudio | Download pela Graph API oficial → transcrição OpenAI → arquivo descartado; transcrição não é gravada |
| Agendamento real | FreeBusy do Google + regras da clínica no PostgreSQL (funcionamento, almoço, jornada, feriados, bloqueios, duração, intervalo, antecedência) |
| 2–3 opções com validade | `slot_offers` com expiração; botões interativos |
| Sem overbooking | Revalidação na agenda + reserva com **restrição de exclusão GiST** no banco (testado com 25 conexões simultâneas) |
| Confirmação + localização | Somente depois de gravar no banco e no calendário |
| Lembretes 24h | Template Utility aprovado fora da janela de 24h; sem duplicidade; opt-out respeitado |
| Remarcação / cancelamento | Confirmação explícita; a consulta original só é liberada após a nova ser confirmada |
| Atendimento humano | Estados BOT/HUMANO; equipe responde pelo **número oficial** com comandos `#CODIGO mensagem` |
| Urgências | Sem diagnóstico/medicação; prioridade urgente para a equipe; orientação de emergência (192) |
| Monitoramento | Erros, falhas de entrega, divergências de agenda, métricas diárias, alertas sem dados clínicos |
| Multiclínica | Cada clínica identificada pelo `phone_number_id`; dados isolados por `clinic_id` com FKs compostas |
| Software odontológico | Camada adaptadora (WF08) troca o Google Calendar por API própria sem duplicar agenda |

## Arquitetura

```
 WhatsApp (paciente/equipe)
        │  webhook assinado (X-Hub-Signature-256)
        ▼
 Caddy (HTTPS) ──► n8n
                    ├─ 01 Recepção ──► dedup/contexto (PostgreSQL) ─► regras ─► OpenAI (JSON estrito) ─► validação ─► roteador
                    │      ├─ 02 Agendamento ──────┐
                    │      ├─ 03 Remarcação/Cancel.├─► 08 Adaptador de agenda ─► Google Calendar | API do software
                    │      ├─ 05 Atendimento humano│
                    │      └─ 00 Enviar WhatsApp ◄─┘ (Graph API oficial)
                    ├─ 04 Lembretes (a cada 15 min)
                    ├─ 06 Monitoramento (erros, alertas, métricas, retenção)
                    └─ 07 Reconciliação de agenda (a cada 30 min)
 PostgreSQL: schema "ria" — regras de negócio em funções SQL testadas (ria.api_*)
```

Detalhes: [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

## Estrutura

```
recepcionista-ia/
├── workflows/                 # JSONs importáveis no n8n (GERADOS — não edite à mão)
│   ├── 00-enviar-whatsapp.json        05-atendimento-humano.json
│   ├── 01-whatsapp-recepcao.json      06-monitoramento.json
│   ├── 02-agendamento.json            07-reconciliacao-agenda.json
│   ├── 03-remarcacao-cancelamento.json 08-adaptador-agenda.json
│   └── 04-lembretes.json
├── database/
│   ├── migrations/            # 001 estrutura, 002 funções, 003 configurações (fonte)
│   ├── schema.sql             # todas as migrações (gerado)
│   └── seed-demo.sql          # clínica fictícia (gerado de config/clinica-exemplo.json)
├── prompts/recepcionista-system.md
├── config/clinica-exemplo.json
├── credentials/credenciais-modelo.json   # modelo SEM segredos (ids/nomes das credenciais)
├── src/lib/*.js               # lógica dos nós Code (testada em tests/unit)
├── src/workflows/*.mjs        # definição dos workflows (fonte dos JSONs)
├── scripts/                   # build, validação, SQL de clínica, importação, backup
├── tests/
│   ├── casos-de-teste.json    # os 18 casos obrigatórios + extras
│   ├── unit/  sql/  testes-de-concorrencia/  e2e/  mocks/
├── docker-compose.yml  .env.example  proxy/Caddyfile  docker/postgres-init/
├── INSTALACAO.md  CONFIGURACAO-META.md  CONFIGURACAO-GOOGLE.md  SEGURANCA-LGPD.md
└── docs/ (ARQUITETURA, ADAPTADOR-AGENDA, MANUAL-EQUIPE, RELATORIO-FINAL)
```

## Início rápido

1. Servidor com Docker, domínio apontando para ele: siga [INSTALACAO.md](INSTALACAO.md).
2. Meta (WhatsApp oficial): [CONFIGURACAO-META.md](CONFIGURACAO-META.md).
3. Google Calendar: [CONFIGURACAO-GOOGLE.md](CONFIGURACAO-GOOGLE.md).
4. Antes de usar dados reais: [SEGURANCA-LGPD.md](SEGURANCA-LGPD.md).

## Desenvolvimento e testes

Os JSONs de `workflows/` são **gerados** a partir de `src/` (para que a lógica seja revisável e testável):

```bash
npm run build
```

```bash
N8N_NODE_MODULES=/caminho/para/node_modules npm run validar
```

```bash
npm run test:unit
```

```bash
PGHOST=localhost PGUSER=postgres npm run test:db
```

```bash
PGHOST=localhost PGUSER=postgres npm run test:concorrencia
```

```bash
PGHOST=localhost PGUSER=postgres N8N_BIN=$(which n8n) tests/e2e/executar-e2e.sh
```

Último resultado: [tests/e2e/resultado-e2e.md](tests/e2e/resultado-e2e.md).

## Licença

Uso comercial restrito ao titular do projeto.
