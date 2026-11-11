# Resultado dos testes ponta a ponta (n8n real + mocks)

Execução: 2026-11-11T03:04:00.541Z

| # | Cenário | Resultado | Verificações |
|---|---|---|---|
| 1 | Paciente novo | ✅ passou | 5/5 |
| 2 | Paciente já cadastrado | ✅ passou | 3/3 |
| 3 | Mensagem de áudio | ✅ passou | 7/7 |
| 4 | Solicitação fora do expediente (domingo) | ✅ passou | 4/4 |
| 5 | Horário disponível (agendamento completo) | ✅ passou | 10/10 |
| 6 | Horário ocupado (alteração manual no Google entre oferta e escolha) | ✅ passou | 4/4 |
| 7 | Dois pacientes escolhendo o mesmo horário ao mesmo tempo | ✅ passou | 4/4 |
| 8 | Cancelamento com confirmação explícita | ✅ passou | 5/5 |
| 9 | Remarcação (mantém a original até confirmar a nova) | ✅ passou | 7/7 |
| 10 | Lembrete 24 horas antes (template, sem duplicidade) e confirmação de presença | ✅ passou | 7/7 |
| 11 | Pedido de atendimento humano (BOT → HUMANO → BOT) | ✅ passou | 9/9 |
| 12 | Possível urgência odontológica e emergência | ✅ passou | 5/5 |
| 13 | Falha de conexão com o Google Calendar | ✅ passou | 4/4 |
| 14 | Falha da API do WhatsApp | ✅ passou | 6/6 |
| 15 | Mensagem duplicada (reentrega do webhook) | ✅ passou | 2/2 |
| 16 | Clínica com dois dentistas (serviço e jornada por profissional) | ✅ passou | 4/4 |
| 17 | Tentativa de acessar dados de outro paciente | ✅ passou | 4/4 |
| 18 | Instrução maliciosa enviada na conversa | ✅ passou | 6/6 |
| 19 | Extra: reconciliação com alteração manual no Google Calendar | ✅ passou | 3/3 |
| 20 | Extra: API administrativa exige credencial | ✅ passou | 3/3 |

## Detalhes

### 1. Paciente novo
- ✅ mensagem de boas-vindas
- ✅ aviso de privacidade com opção de opt-out
- ✅ menu com botões
- ✅ paciente cadastrado automaticamente (dados mínimos)
- ✅ exibição do aviso de privacidade registrada

### 2. Paciente já cadastrado
- ✅ não repete aviso de privacidade
- ✅ não duplica cadastro
- ✅ vai direto aos horários sem pedir nome de novo

### 3. Mensagem de áudio
- ✅ consultou a mídia na Graph API
- ✅ transcreveu o áudio
- ✅ respondeu ao conteúdo do áudio (limpeza na sexta)
- ✅ nenhuma coluna armazena texto de mensagem/transcrição
- ✅ transcrição não fica no estado da conversa
- ✅ áudio grande demais é recusado educadamente
- ✅ imagem recebe orientação (não processa mídia)

### 4. Solicitação fora do expediente (domingo)
- ✅ informa que não há atendimento no dia pedido
- ✅ não oferece horário em domingo
- ✅ oferece alternativas reais próximas
- ✅ nenhuma opção fora do horário de funcionamento

### 5. Horário disponível (agendamento completo)
- ✅ pede o nome (dado mínimo)
- ✅ oferece horários
- ✅ 2 a 3 opções salvas com validade (3)
- ✅ nome normalizado e salvo
- ✅ confirma somente após gravar
- ✅ envia localização
- ✅ consulta confirmada no banco
- ✅ evento com ID determinístico (idempotente)
- ✅ evento criado no Google Calendar (mock)
- ✅ oferta marcada como usada

### 6. Horário ocupado (alteração manual no Google entre oferta e escolha)
- ✅ oferta criada
- ✅ informa que o horário foi ocupado
- ✅ apresenta novas opções
- ✅ nenhuma consulta criada no horário ocupado

### 7. Dois pacientes escolhendo o mesmo horário ao mesmo tempo
- ✅ os dois receberam o mesmo horário como opção 1 (2026-11-12 11:00:00+00)
- ✅ apenas UMA consulta no horário disputado
- ✅ exatamente um paciente recebeu confirmação
- ✅ o outro foi avisado e recebeu novas opções

### 8. Cancelamento com confirmação explícita
- ✅ pede confirmação explícita
- ✅ nada alterado antes da confirmação
- ✅ confirma cancelamento
- ✅ cancelada no banco e removida da agenda
- ✅ evento cancelado no Google (mock)

### 9. Remarcação (mantém a original até confirmar a nova)
- ✅ consulta original confirmada
- ✅ informa que a original continua garantida
- ✅ original segue confirmada durante a escolha
- ✅ confirma remarcação
- ✅ original cancelada como remarcada
- ✅ nova consulta vinculada à original
- ✅ evento antigo removido da agenda

### 10. Lembrete 24 horas antes (template, sem duplicidade) e confirmação de presença
- ✅ template Utility aprovado usado fora da janela de 24h
- ✅ botão de confirmação vinculado à consulta
- ✅ resultado do envio registrado
- ✅ não envia lembrete duplicado
- ✅ paciente confirma presença pelo botão
- ✅ presença registrada
- ✅ opt-out respeitado

### 11. Pedido de atendimento humano (BOT → HUMANO → BOT)
- ✅ paciente informado da transferência
- ✅ equipe notificada com código (YNGD)
- ✅ conversa em modo HUMANO
- ✅ robô NÃO responde em modo humano
- ✅ mensagem repassada à equipe
- ✅ resposta da recepcionista chega ao paciente pelo número oficial
- ✅ devolvido ao robô
- ✅ robô volta a responder
- ✅ número fora da equipe não executa comandos

### 12. Possível urgência odontológica e emergência
- ✅ não avalia nem diagnostica
- ✅ não indica medicamento
- ✅ equipe avisada com prioridade
- ✅ atendimento prioritário registrado
- ✅ orienta procurar emergência em sinais de perigo

### 13. Falha de conexão com o Google Calendar
- ✅ avisa o paciente sem inventar horários
- ✅ nenhum horário oferecido sem consultar a agenda
- ✅ transferido para humano
- ✅ erro de integração registrado

### 14. Falha da API do WhatsApp
- ✅ execução não quebra
- ✅ falha de envio registrada
- ✅ erro de integração do WhatsApp registrado
- ✅ log sem telefone do paciente
- ✅ administrador recebe alerta
- ✅ alerta sem telefone/dados sensíveis

### 15. Mensagem duplicada (reentrega do webhook)
- ✅ mesma mensagem processada uma única vez (3 → 3)
- ✅ ID da Meta registrado uma vez

### 16. Clínica com dois dentistas (serviço e jornada por profissional)
- ✅ responde com a informação autorizada do serviço
- ✅ clareamento só com o dentista habilitado
- ✅ respeita a jornada do Dr. Bruno (ter/qui/sáb)
- ✅ respeita o profissional pedido pelo paciente

### 17. Tentativa de acessar dados de outro paciente
- ✅ consulta da vítima existe
- ✅ nenhum dado da consulta de terceiro foi exposto
- ✅ consulta de terceiro intacta
- ✅ IA não revela dados de outro paciente

### 18. Instrução maliciosa enviada na conversa
- ✅ nenhum dado interno exposto
- ✅ tentativa registrada na auditoria (sem conteúdo)
- ✅ saída inválida da IA descartada: sistema pergunta o serviço
- ✅ texto da IA que "confirma" ação é bloqueado
- ✅ tabelas intactas
- ✅ telefones nunca foram enviados à IA

### 19. Extra: reconciliação com alteração manual no Google Calendar
- ✅ evento existe antes
- ✅ divergência detectada (horário alterado)
- ✅ alerta administrativo gerado

### 20. Extra: API administrativa exige credencial
- ✅ sem cabeçalho: acesso negado (403)
- ✅ com cabeçalho: lista atendimentos humanos abertos
- ✅ devolve atendimento ao robô pela API
