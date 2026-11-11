# Configuração da Meta — WhatsApp Business Cloud API (oficial)

A solução usa **somente a API oficial** (Cloud API hospedada pela Meta). Não há uso de WhatsApp Web,
QR Code ou bibliotecas não oficiais. Os nomes de menus podem mudar; consulte sempre a documentação
oficial em developers.facebook.com/docs/whatsapp.

## 1. Pré-requisitos da clínica

- Portfólio empresarial (Meta Business Manager) da **clínica** — a clínica é a dona da conta e do número.
  Você (fornecedor) recebe acesso como parceiro.
- Verificação da empresa no Business Manager (necessária para aumentar limites e para o nome de exibição).
- Um número de telefone que **não** esteja ativo no aplicativo WhatsApp comum (ou que será migrado).
  Para usar o mesmo número no app WhatsApp Business **e** na API ao mesmo tempo, a Meta oferece a
  "coexistência", disponível via cadastro incorporado (Embedded Signup) de Provedores de Tecnologia — fora do escopo do MVP.

## 2. Criar o aplicativo e a conta do WhatsApp

1. developers.facebook.com → **Meus apps → Criar app** → tipo **Empresa (Business)** → vincule ao portfólio da clínica.
2. No app, adicione o produto **WhatsApp**. Será criada (ou vinculada) uma **WhatsApp Business Account (WABA)**.
3. Em **WhatsApp → Configuração da API**: adicione o número da clínica, verifique por SMS/ligação,
   defina o **nome de exibição** (passa por aprovação) e o **PIN de 2 etapas**.
4. Anote:
   - **Phone number ID** → `config/<clinica>.json` → `whatsapp.phone_number_id` (é assim que o sistema identifica a clínica).
   - **WhatsApp Business Account ID** → `whatsapp.waba_id` e credencial do n8n.

## 3. Token permanente (usuário do sistema)

O token temporário do painel expira em 24h — **não use em produção**.

1. Business Manager → **Configurações do negócio → Usuários → Usuários do sistema → Adicionar** (função *Admin*).
2. **Adicionar ativos**: o **app** (controle total) e a **conta do WhatsApp** (controle total).
3. **Gerar token** → selecione o app → validade **Nunca** → permissões:
   `whatsapp_business_messaging` e `whatsapp_business_management`.
4. Cole o token **somente** na credencial do n8n *Recepcionista IA - WhatsApp Cloud API* (campo *Access Token*),
   junto com o *Business Account ID*. Não envie o token por chat ou e-mail.

> Multiclínica: um usuário do sistema do **seu** portfólio (parceiro) com acesso às WABAs das clínicas
> permite usar um único token para várias clínicas — cada uma é identificada pelo `phone_number_id`.

## 4. Webhook (recebimento de mensagens)

O nó oficial **WhatsApp Trigger** do n8n cria e valida a assinatura do webhook automaticamente:

1. App → **Configurações do app → Básico**: copie **ID do app** e **Chave secreta do app**.
2. No n8n, preencha a credencial *Recepcionista IA - WhatsApp Webhook (App Meta)*: Client ID = ID do app, Client Secret = chave secreta.
3. Publique o workflow **01 WhatsApp Recepção**. O n8n registra a assinatura `whatsapp_business_account`
   com o campo **messages**, URL `https://SEU_DOMINIO/webhook/<id>/webhook` e token de verificação gerado.
   Cada requisição recebida tem a assinatura `X-Hub-Signature-256` conferida com a chave secreta.
4. Em **WhatsApp → Configuração**, confirme que o webhook aparece e que o campo **messages** está assinado.

Limitação conhecida do n8n: **um WhatsApp Trigger por aplicativo da Meta**. Ambientes de teste e
produção devem usar apps diferentes.

## 5. Assinar a WABA no aplicativo (obrigatório)

Sem este passo o webhook não recebe as mensagens do número. Execute uma vez por WABA (no terminal do
seu computador; o token é o do usuário do sistema — não o salve em arquivos):

```bash
curl -X POST "https://graph.facebook.com/v23.0/WABA_ID/subscribed_apps" -H "Authorization: Bearer TOKEN_DO_USUARIO_DO_SISTEMA"
```

Verificação:

```bash
curl "https://graph.facebook.com/v23.0/WABA_ID/subscribed_apps" -H "Authorization: Bearer TOKEN_DO_USUARIO_DO_SISTEMA"
```

## 6. Templates (mensagens iniciadas pela clínica)

Fora da **janela de 24h** (contada a partir da última mensagem do paciente), a Meta só permite
**templates aprovados**. Crie em **WhatsApp Manager → Modelos de mensagem**:

### 6.1 `lembrete_consulta` — categoria **Utilidade**, idioma **Português (BR)**

Corpo (5 variáveis, na ordem exata configurada em `reminder_template.body_params`):

```
Olá, {{1}}! Lembrete da sua consulta na {{2}}: dia {{3}} às {{4}} com {{5}}. Você confirma sua presença?
```

Exemplos para aprovação: `Maria`, `Clínica Sorriso`, `12/11/2026`, `09:00`, `Dra. Ana Lima`.
Botões do tipo **Resposta rápida** (nesta ordem): `Confirmar presença`, `Remarcar`.
O sistema envia em cada botão a carga `CONFIRM:<id>` / `RESCHEDULE:<id>` e trata a resposta automaticamente.

### 6.2 `alerta_equipe` — categoria **Utilidade**

```
Aviso da recepção virtual: {{1}}
```

Usado para avisar a equipe/administração quando o número dela está fora da janela de 24h
(transferências, alertas e resumo diário). Recomenda-se que cada membro da equipe envie "oi" para o
número da clínica no início do expediente — dentro da janela as mensagens chegam sem template.

Se usar outros nomes/idiomas, ajuste `reminder_template` e `staff_alert_template` no JSON da clínica.
Mudou a ordem das variáveis? Ajuste `body_params`.

## 7. Políticas que o sistema já respeita

- **Opt-in:** o paciente inicia a conversa; ao agendar, recebe o aviso de que receberá lembretes
  (registro em `ria.consent_events`). Pacientes que respondem **PARAR** não recebem mensagens ativas
  (opt-out registrado); **VOLTAR** reativa.
- **Janela de 24h:** respostas livres apenas dentro da janela; fora dela, templates Utility.
- **Qualidade do número:** sem disparos em massa/marketing; somente mensagens transacionais.
- **Preços:** a Meta cobra por mensagem de template entregue (tabela por país/categoria). Templates
  Utility enviados dentro da janela de atendimento não são cobrados. Consulte a tabela vigente antes de precificar o serviço.

## 8. Checklist final

- [ ] Número verificado, nome de exibição aprovado, PIN configurado.
- [ ] Token permanente do usuário do sistema salvo na credencial do n8n.
- [ ] App ID/Secret na credencial do trigger; WF01 publicado sem erro.
- [ ] `subscribed_apps` retorna o app.
- [ ] Templates `lembrete_consulta` e `alerta_equipe` **aprovados**.
- [ ] Mensagem de teste respondida pelo robô.
