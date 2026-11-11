# Relatório final — MVP Recepcionista IA

Data: 11/11/2026 · n8n **2.47.3** · PostgreSQL **16** · Node 22 (ferramentas) / Node 24 (n8n)

## 1. Resumo

MVP completo e **executado de ponta a ponta em um n8n real**: 9 workflows importáveis, banco PostgreSQL
com as regras de negócio em funções testadas, ambiente Docker com HTTPS, documentação de implantação
e de privacidade. Os 18 cenários obrigatórios (+2 extras) passaram contra o n8n real, com PostgreSQL
real e um **servidor de simulação** no lugar da Meta, da OpenAI e do Google.

> **Não foi testado com as APIs reais** da Meta (WhatsApp), OpenAI e Google, porque não há credenciais
> neste ambiente. Esses testes estão listados na seção 5 e precisam ser feitos na implantação.

## 2. Workflows prontos para importar (`workflows/`)

| Arquivo | Nós | Função |
|---|---|---|
| 00-enviar-whatsapp.json | 7 | Envio oficial (texto, botões, lista, localização, template) + registro |
| 01-whatsapp-recepcao.json | 31 | WhatsApp Trigger → dedup → áudio → IA validada → roteamento → resposta |
| 02-agendamento.json | 36 | Oferta de 2–3 horários reais, revalidação, reserva protegida, evento, confirmação |
| 03-remarcacao-cancelamento.json | 25 | Lista do próprio paciente, cancelamento com confirmação, remarcação segura, presença |
| 04-lembretes.json | 8 | Lembrete ~24h (template/sessão), sem duplicidade, resultado registrado |
| 05-atendimento-humano.json | 31 | BOT/HUMANO, aviso à equipe, repasse, comandos `#`, API administrativa |
| 06-monitoramento.json | 19 | Error workflow, manutenção, alertas, métricas diárias, retenção |
| 07-reconciliacao-agenda.json | 12 | Detecta alterações manuais na agenda, refaz exclusões pendentes |
| 08-adaptador-agenda.json | 12 | Google Calendar ou API de software odontológico |

Somente nós nativos do n8n (Code, PostgreSQL, HTTP Request, IF, Switch, Execute Workflow, Webhook,
WhatsApp Trigger, Schedule/Error Trigger…), em versões verificadas contra as definições do n8n 2.47.3.
Credenciais referenciadas por id/nome — **nenhum segredo nos JSONs**.

## 3. Arquivos criados

```
recepcionista-ia/
  README.md  INSTALACAO.md  CONFIGURACAO-META.md  CONFIGURACAO-GOOGLE.md  SEGURANCA-LGPD.md
  docker-compose.yml  .env.example  .gitignore  package.json
  proxy/Caddyfile  docker/postgres-init/01-criar-bancos.sh
  workflows/00..08 (9 JSONs)
  database/migrations/001_estrutura.sql 002_funcoes.sql 003_configuracoes_padrao.sql  schema.sql  seed-demo.sql
  prompts/recepcionista-system.md
  config/clinica-exemplo.json
  credentials/credenciais-modelo.json          (sem segredos)
  src/lib/{util,safety,webhook,intent,messages,router,whatsapp,calendar,staff}.js
  src/workflows/_dsl.mjs  wf00..wf08 + wf99 (gatilhos de teste)
  scripts/{build-workflows,validar-workflows,gerar-sql-clinica}.mjs
  scripts/{montar-schema,importar-no-n8n,backup-loop,restaurar-backup}.sh
  tests/casos-de-teste.json
  tests/unit/{carregar-libs.mjs,libs.test.mjs}
  tests/sql/{testes-banco.sql,rodar-testes-banco.sh}
  tests/testes-de-concorrencia/corrida-mesmo-horario.sh
  tests/mocks/servidor-mock.mjs
  tests/e2e/{preparar-ambiente.sh,executar-e2e.sh,cliente.mjs,rodar-e2e.mjs,resultado-e2e.md}
  tests/e2e/workflows/{01-whatsapp-recepcao-TESTE.json,99-gatilhos-teste.json}
  docs/{ARQUITETURA,ADAPTADOR-AGENDA,MANUAL-EQUIPE,RELATORIO-FINAL}.md
```

## 4. Testes realizados e resultados

| Bateria | O que exercita | Resultado |
|---|---|---|
| Validação estrutural (`npm run validar`) | Tipos de nó, versões, parâmetros reconhecidos, credenciais, conexões, sintaxe do código, IDs de sub-workflows, ausência de segredos — contra o n8n 2.47.3 instalado (o validador também foi testado com erros injetados) | ✅ 11 workflows válidos |
| Importação real | `n8n import:credentials` + `import:workflow` dos 9 workflows de produção; publicação de todos (exceto o 01, que exige a Meta) | ✅ |
| Unitários (`npm run test:unit`) | Webhook, segurança, datas, classificador de reserva, validação da IA, roteador, payloads do WhatsApp, agenda, comandos, logs | ✅ 16/16 |
| Banco (`npm run test:db`) | Disponibilidade (funcionamento, almoço, jornada, feriado, bloqueio, ocupação, antecedência, limite), dedup, isolamento por clínica, oferta/validade, reserva, overbooking, duplicidade, remarcação, cancelamento, lembretes, opt-out, BOT/HUMANO, reconciliação, alertas, métricas, retenção, anonimização | ✅ 87 verificações |
| Concorrência | 25 conexões simultâneas reservando o mesmo horário | ✅ 1 reserva, 24 recusas |
| Ponta a ponta (n8n real + mocks) | 18 cenários obrigatórios + 2 extras, 102 verificações; 224 execuções do n8n, **0 com erro** | ✅ 20/20 — ver [tests/e2e/resultado-e2e.md](../tests/e2e/resultado-e2e.md) |
| Docker | `docker compose config` válido; script de inicialização do PostgreSQL executado localmente nas mesmas condições (socket local) | ✅ (stack completa não executada: sem daemon Docker no ambiente) |

## 5. Pendente / não verificado neste ambiente

**Requer credenciais e ambiente real (não afirmo que funcionam até serem testados):**

- Webhook real da Meta (registro automático pelo WhatsApp Trigger, assinatura) e envio real de mensagens/templates.
- Qualidade da classificação com o modelo OpenAI real (os testes usaram um classificador determinístico
  no lugar da IA). Recomenda-se rodar as frases dos testes com a IA real e ajustar o prompt.
- Transcrição de áudio real (OGG/Opus do WhatsApp).
- Google Calendar real (FreeBusy, criação/remoção, renovação do token OAuth).
- Subida completa do `docker compose` com certificado HTTPS (precisa de domínio e servidor).

**Melhorias recomendadas para versões seguintes:**

- Painel web para a clínica (agenda, fila humana, métricas) e caixa de entrada compartilhada (ex.: Chatwoot) ou coexistência com o app WhatsApp Business.
- Row Level Security por clínica no PostgreSQL; papéis de banco separados por função.
- Mais de 3 opções via lista, preferência por profissional na diversidade das opções e "ver mais horários".
- Fila de mensagens para picos (modo *queue* do n8n com Redis) e limite de taxa por paciente.
- Lembrete adicional (ex.: 2h antes) e confirmação/no-show automáticos.
- Paginação de eventos na reconciliação (>2500 eventos por profissional na janela).
- Template `alerta_equipe` configurável no monitoramento (hoje o nome é fixo no WF06).

## 6. Credenciais necessárias (preenchidas no n8n, nunca em arquivos)

| Credencial n8n | Tipo | Conteúdo |
|---|---|---|
| Recepcionista IA - PostgreSQL | Postgres | host `postgres`, banco `recepcionista`, usuário `ria_app`, senha do `.env` |
| Recepcionista IA - WhatsApp Cloud API | WhatsApp API | token permanente do usuário do sistema + WABA ID |
| Recepcionista IA - WhatsApp Webhook (App Meta) | WhatsApp OAuth (trigger) | App ID + App Secret |
| Recepcionista IA - OpenAI | OpenAI | API key |
| Recepcionista IA - Google Calendar | Google Calendar OAuth2 | Client ID/Secret + login Google |
| Recepcionista IA - API Administrativa | Header Auth | `X-Admin-Token` aleatório |
| Recepcionista IA - API Agenda Externa | Header Auth | somente para software odontológico |

Infraestrutura (`.env`): `N8N_ENCRYPTION_KEY`, senhas do PostgreSQL, domínio, e-mail ACME, IPs administrativos.

## 7. Passo a passo para a primeira clínica

1. Contrato com cláusulas LGPD e aprovação dos textos/políticas pela clínica (SEGURANCA-LGPD.md §8).
2. Meta: app Business, WABA, número verificado, nome aprovado, usuário do sistema e token permanente;
   templates `lembrete_consulta` e `alerta_equipe` enviados para aprovação (CONFIGURACAO-META.md).
3. Google: projeto, Calendar API, OAuth publicado, uma agenda por profissional, IDs anotados (CONFIGURACAO-GOOGLE.md).
4. VPS + DNS → `.env` → `docker compose up -d` (INSTALACAO.md §1–3).
5. Preencher `config/<clinica>.json` e aplicar o SQL gerado (INSTALACAO.md §4).
6. Criar a conta do n8n com MFA → `scripts/importar-no-n8n.sh --credenciais` → preencher as 7 credenciais.
7. Publicar o WF01 → assinar a WABA no app (`subscribed_apps`).
8. Cadastrar a equipe (`staff`) e treinar com docs/MANUAL-EQUIPE.md.
9. Executar o teste de aceitação (INSTALACAO.md §9) com números internos.
10. Operação assistida na primeira semana: acompanhar `ria.integration_errors`, alertas e métricas diárias.
