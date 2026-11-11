# Instalação (self-hosted com Docker Compose)

Tempo estimado: 1–2 horas (sem contar aprovações da Meta). Nenhum segredo é colocado em arquivos
versionados: senhas de infraestrutura ficam no `.env` do servidor; tokens de Meta/OpenAI/Google
ficam **somente** no cofre de credenciais criptografado do n8n.

## 1. Requisitos

- VPS Linux (Ubuntu 22.04/24.04) com **2 vCPU, 4 GB RAM, 40 GB SSD** (até ~5 clínicas pequenas).
- Docker Engine 24+ com o plugin `docker compose`.
- Domínio/subdomínio (ex.: `recepcionista.suaempresa.com.br`) com registro **A/AAAA** apontando para a VPS.
- Portas **80 e 443** abertas para a internet; **todas as demais fechadas** (o PostgreSQL e o n8n não são expostos).
- Seu IP fixo (ou VPN) para acessar o editor do n8n.

## 2. Obter os arquivos e configurar o `.env`

```bash
git clone <seu-repositorio> && cd <seu-repositorio>/recepcionista-ia
```

```bash
cp .env.example .env && chmod 600 .env
```

Gere uma senha forte para **cada** campo vazio (`N8N_ENCRYPTION_KEY`, `POSTGRES_ADMIN_PASSWORD`,
`N8N_DB_PASSWORD`, `RIA_DB_PASSWORD`) com:

```bash
openssl rand -base64 32
```

Preencha também `N8N_DOMAIN`, `ACME_EMAIL` e `ADMIN_ALLOWED_IPS` (seu IP público, ex.: `200.100.50.25/32`).

> Guarde o `N8N_ENCRYPTION_KEY` em um cofre de senhas: sem ele as credenciais salvas no n8n não podem ser recuperadas após um restore.

## 3. Subir os serviços

```bash
docker compose up -d
```

```bash
docker compose ps
```

```bash
docker compose logs -f postgres n8n caddy
```

Na primeira inicialização o PostgreSQL cria dois bancos isolados (`n8n` e `recepcionista`), dois
usuários sem privilégio de superusuário e aplica `database/schema.sql` (tabelas, funções e configurações padrão).

## 4. Cadastrar a clínica

1. Copie o exemplo e edite **todos** os campos (nome, endereço, localização, horários, feriados,
   profissionais, IDs de calendário, serviços, durações, intervalos, FAQ autorizada, equipe):

   ```bash
   cp config/clinica-exemplo.json config/minha-clinica.json
   ```

   - Gere um UUID novo para `"id"` da clínica (ou apague o campo para gerar automaticamente).
   - `whatsapp.phone_number_id` vem do painel da Meta (ver CONFIGURACAO-META.md).
   - `calendar_id` de cada profissional vem do Google (ver CONFIGURACAO-GOOGLE.md).
   - `staff[].wa_id`: celulares da equipe **com DDI e DDD, só dígitos** (ex.: `5511987654321`).
2. Gere e aplique o SQL (idempotente — pode reaplicar sempre que mudar a configuração):

   ```bash
   docker run --rm -v "$PWD":/w -w /w node:22-alpine node scripts/gerar-sql-clinica.mjs config/minha-clinica.json > database/clinica-minha.sql
   ```

   ```bash
   docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$RIA_DB_USER" -d "$RIA_DB_NAME"' < database/clinica-minha.sql
   ```

> Para testar sem dados reais, aplique `database/seed-demo.sql` (clínica fictícia) em vez do arquivo da clínica.

## 5. Criar a conta do n8n e importar os workflows

1. Acesse `https://SEU_DOMINIO` a partir de um IP autorizado e crie a conta de **proprietário**.
   Em *Settings → Personal*, ative a **autenticação em dois fatores (MFA)**.
2. Importe as credenciais-modelo (vazias) e os workflows, publicando na ordem correta:

   ```bash
   scripts/importar-no-n8n.sh --credenciais
   ```

   Nas atualizações futuras use sem `--credenciais` (para não apagar os segredos já preenchidos).

## 6. Preencher as credenciais no n8n (*Overview → Credentials*)

| Credencial | Campos | Onde obter |
|---|---|---|
| Recepcionista IA - PostgreSQL | Host `postgres`, Database `recepcionista`, User `ria_app`, Password = `RIA_DB_PASSWORD`, SSL `disable` (rede interna do Docker) | `.env` |
| Recepcionista IA - WhatsApp Cloud API | Access Token (usuário do sistema, permanente), Business Account ID (WABA) | CONFIGURACAO-META.md §3 |
| Recepcionista IA - WhatsApp Webhook (App Meta) | Client ID = **App ID**, Client Secret = **App Secret** | CONFIGURACAO-META.md §4 |
| Recepcionista IA - OpenAI | API Key (projeto dedicado, com limite de gasto) | platform.openai.com |
| Recepcionista IA - Google Calendar | Client ID, Client Secret → botão **Sign in with Google** | CONFIGURACAO-GOOGLE.md |
| Recepcionista IA - API Administrativa | Name `X-Admin-Token`, Value = `openssl rand -hex 32` | você gera |
| Recepcionista IA - API Agenda Externa | Somente se `calendar_provider = external` | fornecedor do software |

Clique em **Save** em cada uma; o n8n testa a conexão quando possível.

## 7. Publicar o workflow 01 (entrada do WhatsApp)

1. Abra **Recepcionista IA - 01 WhatsApp Recepção**, confira o nó *WhatsApp Trigger* (credencial
   preenchida) e clique em **Publish**. Ao publicar, o n8n registra automaticamente o webhook no
   aplicativo da Meta (campo `messages`), usando o App ID/Secret.
2. Faça a assinatura da WABA no aplicativo (passo obrigatório, CONFIGURACAO-META.md §5).
3. Em *Settings → Workflows*, confirme que os workflows 00, 02–08 aparecem como **publicados**.

## 8. Ajustes globais (opcional)

Configurações não secretas ficam na tabela `ria.app_settings` (modelo da IA, versão da Graph API, limites):

```bash
docker compose exec -T postgres sh -c 'psql -U "$RIA_DB_USER" -d "$RIA_DB_NAME" -c "select key, value from ria.app_settings order by key"'
```

Exemplo — trocar o modelo de classificação (use um modelo com suporte a *Structured Outputs*):

```bash
docker compose exec -T postgres sh -c "psql -U \"\$RIA_DB_USER\" -d \"\$RIA_DB_NAME\" -c \"update ria.app_settings set value='\\\"gpt-4.1-mini\\\"' where key='openai_model'\""
```

## 9. Teste de aceitação (com o número real)

- [ ] De um celular de teste: "Oi" → boas-vindas, aviso de privacidade e menu.
- [ ] "Quero marcar uma avaliação amanhã" → pede nome → 2–3 horários reais → escolher → confirmação + localização; evento criado no calendário certo.
- [ ] Criar manualmente um evento no Google no horário oferecido e escolher esse horário → o robô avisa que foi ocupado.
- [ ] Áudio "quero marcar uma limpeza" → entendido.
- [ ] "Quero cancelar minha consulta" → pede confirmação → cancelado no calendário.
- [ ] "Quero falar com uma pessoa" → a recepção recebe o aviso; `#CODIGO texto` chega ao paciente; `#devolver CODIGO` devolve ao robô.
- [ ] Rodar o lembrete (abrir WF04 → *Execute workflow*) para uma consulta em ~24h → template recebido.
- [ ] Ver erros e métricas: tabela `ria.integration_errors` e `ria.daily_metrics`.

## 10. Operação

- **Backups:** o serviço `backup` gera `pg_dump` diário em `./backups` (retenção `BACKUP_RETENTION_DAYS`).
  Copie diariamente para fora do servidor, criptografado (ex.: `restic` ou `rclone` com criptografia).
  Restauração: `scripts/restaurar-backup.sh backups/<arquivo>.dump <banco>`. Teste a restauração mensalmente.
- **Atualizar os workflows:** `git pull` → `scripts/importar-no-n8n.sh` → republicar o 01 pelo editor.
- **Atualizar o banco:** novas migrações em `database/migrations/` são idempotentes; aplique com
  `docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$RIA_DB_USER" -d "$RIA_DB_NAME"' < database/migrations/00X_*.sql`.
- **Atualizar o n8n:** altere a tag da imagem em `docker-compose.yml` após testar em homologação
  (rode a bateria de testes de `tests/e2e`). Faça backup antes.
- **Logs:** `docker compose logs n8n`. Execuções com erro ficam no n8n por `N8N_EXECUTIONS_MAX_AGE_HOURS` (padrão 72h) e podem conter mensagens de pacientes — acesso restrito ao administrador.

## 11. Problemas comuns

| Sintoma | Verificação |
|---|---|
| Robô não responde | WF01 publicado? WABA assinada no app (§5 Meta)? `docker compose logs n8n`; execuções com erro no n8n |
| "Workflow is not active" ao chamar sub-workflow | Publique os sub-workflows (ordem do script) |
| Sem horários | `calendar_id` corretos? Calendários compartilhados com a conta conectada? `ria.business_hours` preenchido? |
| Lembretes não saem | Template `lembrete_consulta` aprovado e com os mesmos parâmetros; paciente com opt-in; ver `ria.reminders` |
| Google pede login de novo a cada 7 dias | App OAuth em modo *Testing* — publique (CONFIGURACAO-GOOGLE.md §2) |
| Erro 131047 no envio | Fora da janela de 24h: só templates aprovados podem ser enviados |
