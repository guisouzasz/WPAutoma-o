# Arquitetura

## Princípios

1. **A IA interpreta, o sistema decide.** A OpenAI só devolve um JSON (contrato estrito). O n8n valida
   contra o contrato e contra os dados reais da clínica; regras determinísticas de segurança vêm antes.
2. **Regras de negócio no banco.** Disponibilidade, reserva, cancelamento, lembretes, isolamento por
   clínica e por paciente estão em funções PostgreSQL (`ria.api_*`) — testáveis, transacionais e
   protegidas por restrições. O n8n orquestra I/O (WhatsApp, OpenAI, agenda).
3. **Nunca inventar disponibilidade.** Toda oferta e toda reserva consultam a agenda em tempo real;
   se a agenda falhar, o paciente é transferido para humano.
4. **Workflows gerados a partir de código.** `src/workflows/*.mjs` + `src/lib/*.js` → `workflows/*.json`
   (`npm run build`). As bibliotecas dos nós Code são as mesmas usadas nos testes unitários.

## Workflows

| # | Nome | Gatilho | Papel |
|---|---|---|---|
| 00 | Enviar WhatsApp | sub-workflow | Converte mensagens normalizadas em payloads oficiais (texto, botões, lista, localização, template), envia em ordem, registra resultado |
| 01 | WhatsApp Recepção | WhatsApp Trigger | Entrada: status/dedup/contexto, áudio, regras, IA, validação, roteamento, estado, resposta |
| 02 | Agendamento | sub-workflow | Oferta (2–3 horários) e escolha (revalidação, reserva protegida, evento, confirmação) |
| 03 | Remarcação e Cancelamento | sub-workflow | Lista do próprio paciente, cancelamento com confirmação, remarcação segura, confirmação de presença |
| 04 | Lembretes | a cada 15 min / sob demanda | Reivindica lembretes devidos, template ou sessão, registra resultado |
| 05 | Atendimento Humano | sub-workflow + webhook admin | Abrir transferência, repassar mensagens, comandos da equipe, API administrativa |
| 06 | Monitoramento | Error Trigger, 10 min, diário | Registro de erros, manutenção, alertas, métricas, retenção |
| 07 | Reconciliação | a cada 30 min / sob demanda | Compara agenda × banco, detecta alterações manuais, refaz exclusões pendentes |
| 08 | Adaptador de Agenda | sub-workflow | Google Calendar **ou** API externa por clínica (freebusy, create, delete, list) |

Todos (exceto o 06) usam o 06 como *Error Workflow*. No n8n 2.x os sub-workflows precisam estar
**publicados**; publique na ordem: 00, 08, 06, 05, 02, 03, 04, 07, 01.

## Fluxo de uma mensagem (WF01)

```
WhatsApp Trigger (assinatura validada)
 → Normalizar eventos (mensagens / status)
 → status "failed" ............................ ria.api_status_update (falha de entrega)
 → ria.api_inbound_begin: clínica pelo phone_number_id, DEDUP pelo ID da Meta, cadastro do paciente,
   conversa (BOT/HUMAN, estado, versão), oferta aberta, consultas do paciente, serviços, profissionais, FAQ
 → Caminho: ignorar | equipe (#comandos) | modo HUMANO (repasse) | áudio | processar
 → [áudio] Graph /{media-id} → download (binário) → OpenAI transcrição → binário descartado
 → Pré-classificar (botões, números de opção, sim/não, opt-out, emergência, pedido humano)
 → [se preciso] OpenAI chat (response_format json_schema strict)
 → Validar (contrato + dados reais) → mergeWithSafety (regras prevalecem) → decideRoute
 → reply | 02 | 03 | 05 | consentimento
 → ria.api_conversation_save (estado + versão + métricas + erros, sem conteúdo)
 → 00 Enviar WhatsApp
```

## Contrato da IA

Campos (todos obrigatórios, `null` quando ausentes): `intent` (21 valores), `confidence`,
`service_code`, `professional_id`, `date_from`, `date_to`, `period`, `time`, `option_number`,
`appointment_number`, `patient_name`, `faq_id`, `urgency` (`none|possible|emergency`), `reply`.
Definição: `src/lib/intent.js` (`INTENT_SCHEMA`); prompt: `prompts/recepcionista-system.md`.
Se a IA falhar (timeout, erro, saída inválida), um classificador determinístico assume; após
`ai_max_failures` falhas seguidas sem entendimento, o atendimento vai para humano.

## Máquina de estados da conversa

`mode`: **BOT** ↔ **HUMAN** (`api_handoff_open` / `api_handoff_action release` / timeout `human_timeout_minutes`).

`state` (somente em BOT): `idle` → `awaiting_service` → `awaiting_name` → `awaiting_slot_choice` → `idle`;
`idle` → `awaiting_appointment_choice` → `awaiting_cancel_confirmation` → `idle`.
O `context` guarda apenas IDs e preferências (serviço, datas, período, `offer_id`, `reschedule_of`).

## Agendamento e concorrência

```
oferta:  api_offer_prepare → FreeBusy (WF08) → api_offer_create (fn_available_slots + seleção variada) → botões
escolha: api_offer_choose → FreeBusy do horário → api_reserve → evento (ID = UUID sem hífens) → api_appointment_confirm
```

- `fn_available_slots` aplica: funcionamento (várias faixas/dia ⇒ almoço), interseção com a jornada do
  profissional, feriados, bloqueios, duração + intervalo, antecedência mínima, limite de dias, consultas
  do banco (inclusive reservas temporárias) e ocupação do Google.
- `api_reserve` trava a oferta e o paciente, revalida tudo e insere `status='held'`. A restrição
  `appointments_no_overlap` (GiST, `EXCLUDE ... tstzrange(starts_at, block_until) WITH &&`) garante que
  duas reservas ativas do mesmo profissional nunca se sobreponham, mesmo com execuções paralelas.
- Evento criado com ID determinístico: repetir a criação devolve 409 e é tratado como sucesso (idempotente).
- Reserva expira em `hold_ttl_minutes`; se expirar durante a criação do evento, a confirmação tenta
  reativar (ainda protegida pela restrição) ou desfaz o evento e oferece novos horários.
- Remarcação: a nova consulta é confirmada **antes** de a antiga entrar em `cancel_requested` e ser removida da agenda.
- Cancelamento: `cancel_requested` (ainda bloqueia) → remoção na agenda → `cancelled`; falha ⇒ reverte e transfere.

## Estados da consulta

`held` → `confirmed` → (`cancel_requested` → `cancelled`) | `completed` | `no_show`; `held` → `expired`.
`sync_status`: `pending`, `synced`, `missing_in_calendar`, `time_mismatch`, `conflict`, `delete_pending`, `deleted`.

## API do banco (`ria.api_*`, sempre `SELECT ria.api_x($1::jsonb)`)

| Função | Uso |
|---|---|
| `api_inbound_begin` | dedup + contexto completo da mensagem |
| `api_conversation_save` | estado, versão, métricas, aviso de privacidade, erros |
| `api_set_patient_name`, `api_consent` | cadastro mínimo e consentimentos |
| `api_offer_prepare`, `api_offer_create`, `api_offer_choose` | oferta de horários |
| `api_reserve`, `api_appointment_confirm`, `api_appointment_release` | reserva protegida |
| `api_patient_appointments`, `api_cancel_check`, `api_cancel_request`, `api_cancel_finalize`, `api_cancel_revert`, `api_reschedule_check`, `api_attendance_confirm` | consultas do próprio paciente |
| `api_handoff_open`, `api_handoff_action`, `api_handoff_relay_targets` | atendimento humano |
| `api_reminders_claim`, `api_reminder_result` | lembretes |
| `api_outbound_record`, `api_status_update`, `api_log_error`, `api_message_finish` | rastreabilidade sem conteúdo |
| `api_janitor`, `api_alerts_collect`, `api_alert_sent`, `api_daily_metrics`, `api_retention`, `api_anonymize_patient` | operação e LGPD |
| `api_reconcile_targets`, `api_reconcile`, `api_mark_calendar_deleted` | reconciliação |

## Multiclínica

- A clínica é identificada pelo `metadata.phone_number_id` do webhook.
- Todas as tabelas de negócio têm `clinic_id`; FKs compostas `(id, clinic_id)` impedem relacionar
  registros de clínicas diferentes; funções sempre filtram por clínica.
- Configuração por clínica: fuso horário, horários, feriados, bloqueios, serviços, profissionais,
  regras, textos, templates, retenção, provedor de agenda.
- Evolução sugerida: *Row Level Security* por clínica com papéis distintos e um painel web.
