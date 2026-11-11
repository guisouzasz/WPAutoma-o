# Segurança e LGPD

> Este documento descreve as medidas técnicas implementadas e os pontos que **dependem de decisão da
> clínica e de revisão jurídica**. Ele não substitui a avaliação de um profissional de privacidade/DPO.

## 1. Papéis (LGPD, arts. 5º, 37–40)

| Papel | Quem | Responsabilidades |
|---|---|---|
| **Controladora** | A clínica | Define finalidades; base legal; aviso de privacidade; atende titulares; aprova textos, regras e equipe com acesso; decide retenção |
| **Operadora** | Você (fornecedor da Recepcionista IA) | Trata dados conforme instruções da clínica; segurança; registro das operações; apoio a incidentes e pedidos de titulares; sigilo |
| Suboperadores | Meta (WhatsApp), OpenAI, Google, provedor da VPS | Processam dados por conta da operadora/controladora; transferência internacional (EUA) |

Formalize em **contrato de prestação de serviço com cláusulas de proteção de dados** (DPA): objeto,
instruções, suboperadores autorizados, transferência internacional, retenção, devolução/eliminação ao
fim do contrato, notificação de incidentes (prazo sugerido: 48h à clínica) e auditoria.

## 2. Dados tratados (minimização)

| Dado | Onde | Finalidade |
|---|---|---|
| Telefone (WhatsApp) e nome informado/perfil | `ria.patients` | Identificar o paciente e agendar |
| Consultas (data, serviço administrativo, profissional) | `ria.appointments`, Google Calendar | Agendamento |
| Estado da conversa (somente IDs e preferências de data/serviço) | `ria.conversations.context` | Continuidade do atendimento |
| Metadados de mensagens (ID da Meta, tipo, intenção, horário) — **sem conteúdo** | `ria.processed_messages`, `ria.outbound_messages` | Deduplicação, métricas, entrega |
| Consentimentos (aviso exibido, opt-in de lembretes, opt-out) | `ria.consent_events` | Prova de autorização |
| Auditoria de ações (sem conteúdo) | `ria.audit_events` | Rastreabilidade |

**Não são armazenados:** texto das mensagens, transcrições de áudio, áudios, imagens, prontuários,
diagnósticos, exames ou dados de saúde. Os áudios são baixados, transcritos e descartados na mesma
execução. Imagens/documentos enviados pelo paciente **não são baixados** — o paciente é orientado a não
enviar dados de saúde.

Pontos de atenção (decisão da clínica):

- O **conteúdo** das mensagens trafega pelo n8n e é enviado à OpenAI para classificação/transcrição.
  Mensagens com sintomas (ex.: "estou com dor") são dados de saúde (dado sensível, art. 11).
  Use projeto/organização OpenAI com retenção de dados controlada e avalie a contratação de *Zero Data Retention*.
- Execuções **com erro** do n8n guardam os dados da execução (podem conter mensagens) por
  `N8N_EXECUTIONS_MAX_AGE_HOURS` (padrão 72h) para diagnóstico. Reduza se necessário.
- Ao transferir para humano, o texto da última mensagem do paciente é repassado à equipe da clínica
  pelo WhatsApp oficial. A equipe deve usar aparelhos da clínica, com bloqueio de tela.
- O evento no Google Calendar contém nome e telefone do paciente (necessário para a recepção).

## 3. Bases legais sugeridas (validar com o jurídico da clínica)

- Agendamento e lembretes da consulta solicitada: **execução de procedimentos preliminares de contrato**
  a pedido do titular (art. 7º, V) e/ou **tutela da saúde** (art. 11, II, f) quando houver dado sensível.
- Mensagens ativas (lembretes): o paciente é informado ao agendar e pode recusar a qualquer momento (PARAR).
- Métricas agregadas: **legítimo interesse** (art. 7º, IX), sem dados individuais nos relatórios.

## 4. Direitos dos titulares

Pedidos chegam à clínica (controladora). Procedimento técnico:

- **Acesso/confirmação:** consultar `ria.patients`, `ria.appointments`, `ria.consent_events` pelo telefone.
- **Correção:** atualizar `full_name` (ou o paciente informa novamente ao agendar).
- **Oposição a mensagens:** o paciente envia PARAR (registro automático) ou a equipe registra via SQL `ria.api_consent`.
- **Eliminação/anonimização:** cancelar primeiro as consultas futuras (pelo WhatsApp ou na agenda) e então:

  ```bash
  docker compose exec -T postgres sh -c "psql -U \"\$RIA_DB_USER\" -d \"\$RIA_DB_NAME\" -c \"select ria.api_anonymize_patient('{\\\"clinic_id\\\":\\\"UUID_CLINICA\\\",\\\"patient_id\\\":\\\"UUID_PACIENTE\\\",\\\"requested_by\\\":\\\"titular\\\"}')\""
  ```

  A função substitui telefone e nome por um identificador irreversível, apaga ofertas e metadados de
  mensagens e mantém apenas o histórico mínimo de consultas exigido pela clínica. Eventos já existentes
  no Google Calendar e conversas no WhatsApp do aparelho devem ser tratados pela clínica.

## 5. Retenção (configurável por clínica)

| Item | Padrão | Campo |
|---|---|---|
| Metadados de mensagens recebidas/enviadas | 90 dias | `retention_message_log_days` |
| Auditoria | 365 dias | `retention_audit_days` |
| Anonimização de pacientes inativos sem consultas | desativado | `retention_inactive_patient_days` |
| Erros de integração e alertas | 180 dias | fixo |
| Execuções do n8n com erro | 72 horas | `N8N_EXECUTIONS_MAX_AGE_HOURS` |
| Backups | 14 dias | `BACKUP_RETENTION_DAYS` |

A rotina diária do WF06 aplica a retenção. Consultas (agendamentos) seguem a política da clínica.

## 6. Medidas de segurança implementadas

- **Segredos:** nenhum token nos JSONs exportados (o validador `scripts/validar-workflows.mjs` falha se
  encontrar padrões de segredo). Tokens só no cofre criptografado do n8n (`N8N_ENCRYPTION_KEY`).
  Senhas de infraestrutura no `.env` (permissão 600, fora do Git).
- **Rede:** apenas 80/443 expostos; PostgreSQL e n8n só na rede interna do Docker; editor do n8n restrito
  por IP no proxy; HSTS e cabeçalhos de segurança; acesso administrativo com MFA no n8n.
- **Webhook autêntico:** assinatura `X-Hub-Signature-256` validada pelo nó oficial WhatsApp Trigger.
- **API administrativa:** exige cabeçalho secreto (credencial *Header Auth*).
- **Banco:** usuários separados para n8n e aplicação, sem superusuário; SQL sempre parametrizado
  (`$1::jsonb`); FKs compostas impedem misturar dados de clínicas; toda função de paciente filtra por
  `clinic_id` + `patient_id` (testes de acesso a terceiros automatizados).
- **IA confinada:** a IA não executa ações; sua saída passa por esquema estrito + validação contra os
  dados reais; regras determinísticas de segurança prevalecem; texto livre da IA é filtrado (sem
  medicamentos, sem links, sem "confirmações" falsas); telefone do paciente não é enviado à IA;
  tentativas de manipulação são auditadas sem conteúdo.
- **Logs higienizados:** números longos, e-mails e tokens são mascarados (`ria.sanitize_log`).
- **Alertas** administrativos sem dados clínicos e sem telefone completo.
- **Integridade de agenda:** restrição de exclusão no banco impede dupla reserva; reconciliação detecta alterações manuais.
- **Backups** diários com retenção; recomenda-se cópia externa criptografada.

## 7. Incidentes

1. Conter (revogar token do usuário do sistema da Meta, chave OpenAI, desconectar Google; bloquear IP).
2. Preservar evidências (logs do Caddy/n8n, `ria.audit_events`).
3. Avisar a clínica no prazo contratual; a clínica avalia a comunicação à ANPD e aos titulares (art. 48).
4. Corrigir, trocar segredos (`N8N_ENCRYPTION_KEY` exige recadastrar credenciais) e registrar lições aprendidas.

## 8. Checklist de aprovação ANTES de usar dados reais

- [ ] Contrato com cláusulas de proteção de dados assinado (controladora × operadora).
- [ ] Clínica aprovou: textos de boas-vindas, aviso de privacidade, políticas de cancelamento/retorno, FAQ e respostas autorizadas.
- [ ] Clínica aprovou a lista de suboperadores (Meta, OpenAI, Google, hospedagem) e a transferência internacional.
- [ ] Aviso de privacidade completo da clínica publicado (link no perfil do WhatsApp ou site).
- [ ] Lista de membros da equipe com acesso (números em `staff_members`) aprovada e mantida atualizada.
- [ ] Prazos de retenção definidos pela clínica.
- [ ] Procedimento de urgência validado por um cirurgião-dentista responsável (textos de orientação e 192).
- [ ] Teste de restauração de backup realizado.
- [ ] Revisão das configurações da conta OpenAI (retenção, organização dedicada, limite de gasto).

## 9. Limites da IA (comunicar à clínica e ao paciente)

A assistente **não** faz diagnóstico, **não** indica medicamentos ou cuidados e **não** avalia a
gravidade de sintomas. Relatos de sintomas são encaminhados com prioridade à equipe; sinais claros de
perigo recebem orientação imediata para procurar pronto-socorro/192. A clínica deve garantir que a
equipe acompanhe a fila de atendimentos prioritários durante o expediente.
