# Adaptador de agenda (Google Calendar ⇄ software odontológico)

O workflow **08 Adaptador de Agenda** isola todas as operações de agenda. Para uma clínica que usa um
software odontológico com API, a recepcionista passa a ler e gravar **diretamente no software** — não
existe uma segunda agenda para sincronizar.

## Ativação por clínica

No JSON da clínica:

```json
"calendar_provider": "external",
"external_calendar_base_url": "https://api.software-da-clinica.com.br/v1/integracao-ria",
"professionals": [{ "key": "ana", "external_ref": "PROF-123", "calendar_id": null }]
```

Credencial no n8n: **Recepcionista IA - API Agenda Externa** (Header Auth, ex.: `Authorization: Bearer <token>`).
A URL precisa ser **HTTPS**.

## Contrato esperado (o fornecedor do software implementa, ou você cria um "conector" intermediário)

Horários em ISO 8601 com fuso (ex.: `2026-11-12T09:00:00-03:00`).

### `POST {base}/availability`

```json
{ "professional_refs": ["PROF-123", "PROF-456"], "time_min": "...", "time_max": "..." }
```

Resposta 200:

```json
{ "busy": [ { "professional_ref": "PROF-123", "start": "...", "end": "..." } ] }
```

Deve incluir **tudo** que ocupa o profissional (consultas, bloqueios, ausências). Responder 200 significa
que **todos** os profissionais pedidos foram consultados; se algum não puder ser consultado, responda
erro (5xx) — a recepcionista então não oferece horários e transfere para a equipe (nunca inventa disponibilidade).

### `POST {base}/appointments`

```json
{ "id": "3f2a...32 hex", "professional_ref": "PROF-123", "start": "...", "end": "...",
  "patient_name": "Maria Silva", "patient_phone": "+5511999990000", "service_code": "avaliacao",
  "ria_appointment_id": "uuid" }
```

Resposta 200/201 `{ "event_id": "..." }`. **Idempotência obrigatória:** se o mesmo `id` já existir,
responder **409** (tratado como sucesso). Se o horário estiver ocupado no software, responder 4xx
diferente de 409 — a reserva é liberada e o paciente é transferido para a equipe.

### `DELETE {base}/appointments/{event_id}`

200/204; 404/410 se já não existir (tratados como sucesso).

### `GET {base}/appointments?professional_ref=&time_min=&time_max=`

```json
{ "events": [ { "id": "...", "start": "...", "end": "...", "status": "confirmed|cancelled", "ria_appointment_id": "uuid|null" } ] }
```

Usado pela reconciliação (WF07).

## Respostas normalizadas devolvidas pelo WF08

| op | sucesso | falha |
|---|---|---|
| freebusy | `{ ok, busy:[{professional_id,start,end}], verified:[ids], failed:[ids] }` | `{ ok:false, error_code, error }` (registrada em `ria.integration_errors`) |
| create_event | `{ ok, event_id, already_existed? }` | idem |
| delete_event | `{ ok, already_deleted? }` | idem |
| list_events | `{ ok, events:[...] }` | idem |
