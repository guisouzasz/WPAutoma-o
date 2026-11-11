# Configuração do Google Calendar

Na primeira versão, a disponibilidade real vem do Google Calendar (**uma agenda por profissional**) e
das regras cadastradas no banco. Eventos criados manualmente pela recepção bloqueiam horários
automaticamente (o sistema consulta o FreeBusy na oferta **e** novamente antes de reservar).

## 1. Projeto no Google Cloud

1. console.cloud.google.com → crie um projeto (ex.: `recepcionista-ia`).
2. **APIs e serviços → Biblioteca** → ative **Google Calendar API**.

## 2. Tela de consentimento OAuth

1. **APIs e serviços → Tela de consentimento OAuth** (Google Auth Platform).
2. Tipo de usuário:
   - **Interno**, se a conta que vai conectar for de um Google Workspace (recomendado: não exige verificação e o token não expira em 7 dias);
   - **Externo**, para contas @gmail.com.
3. Escopos: `.../auth/calendar` e `.../auth/calendar.events` (os que o n8n solicita).
4. **Importante:** se o app ficar no status *Teste* (Externo), o Google invalida o *refresh token* a cada
   **7 dias** e a agenda para de funcionar. Clique em **Publicar app** (status *Em produção*). Escopos
   sensíveis podem exigir verificação do Google; até lá, o aviso de "app não verificado" aparece apenas para quem conecta.

## 3. Cliente OAuth

1. **Credenciais → Criar credenciais → ID do cliente OAuth** → tipo **Aplicativo da Web**.
2. Em **URIs de redirecionamento autorizados**, cole a URL exibida na credencial do n8n
   (*OAuth Redirect URL*), normalmente: `https://SEU_DOMINIO/rest/oauth2-credential/callback`.
3. Copie **ID do cliente** e **Chave secreta** para a credencial *Recepcionista IA - Google Calendar*
   no n8n e clique em **Sign in with Google** com a conta que administra as agendas.

## 4. Agendas dos profissionais

Recomendado: uma conta operacional da clínica (ex.: `agenda@clinica.com.br`) conectada ao n8n.

- **Opção A — agendas criadas nessa conta:** Google Agenda → *Outras agendas → + → Criar nova agenda*
  (ex.: "Dra. Ana Lima — Consultas"). Compartilhe com o profissional para ele acompanhar.
- **Opção B — agenda do próprio profissional:** o profissional compartilha a agenda dele com a conta
  operacional com a permissão **"Fazer alterações nos eventos"**.

Para cada agenda: *Configurações da agenda → Integrar agenda → ID da agenda* (ex.:
`c_abc123@group.calendar.google.com`) → `professionals[].calendar_id` no JSON da clínica.

## 5. Boas práticas para a recepção

- Bloqueios (almoço especial, curso, folga) podem ser criados como eventos comuns no Google — eles
  passam a bloquear horários imediatamente. Mantenha-os como **Ocupado** (eventos "Disponível" não bloqueiam).
- Feriados, horário de funcionamento, jornada por profissional, duração de cada serviço e intervalo
  entre pacientes ficam no JSON da clínica (banco), não no Google.
- Eventos criados pelo robô têm o título `Serviço — Nome do paciente`, a descrição com telefone e uma
  referência interna. **Não altere a referência**. Se mover/apagar um evento do robô manualmente, o
  workflow 07 detecta a divergência e avisa a administração (o robô não cancela nada sozinho).

## 6. Multiclínica

Uma única conta operacional (do fornecedor) pode receber o compartilhamento das agendas de várias
clínicas; cada profissional tem seu `calendar_id`. Para clínicas que exigem isolamento total, use
uma instância (VPS) por clínica.

## 7. Software odontológico próprio

Se a clínica usa um sistema com API de agenda, defina `"calendar_provider": "external"` e
`"external_calendar_base_url"` no JSON da clínica, preencha `external_ref` de cada profissional e a
credencial *Recepcionista IA - API Agenda Externa*. O contrato está em
[docs/ADAPTADOR-AGENDA.md](docs/ADAPTADOR-AGENDA.md). Assim o software continua sendo a **única**
agenda (sem duplicidade).

## 8. Checklist

- [ ] Calendar API ativa; app OAuth **publicado** (ou Interno).
- [ ] Credencial do n8n conectada ("Account connected").
- [ ] Um `calendar_id` por profissional no JSON da clínica, todos acessíveis pela conta conectada.
- [ ] Teste: oferta de horários respeita um evento manual criado na agenda.
