# Manual da equipe (recepção)

A recepcionista virtual atende no WhatsApp oficial da clínica. Quando um paciente pede uma pessoa,
relata sintoma, reclama, faz pergunta que o robô não sabe responder ou algo dá errado, a conversa é
**transferida para vocês** e o robô **para de responder** àquele paciente.

## Como vocês recebem

O celular de cada pessoa da equipe cadastrada recebe, no WhatsApp, uma mensagem do **número da clínica**:

```
🔔 Atendimento #K7QM — 🔴 URGENTE
Paciente: Maria Silva (****4321)
Motivo: possível urgência odontológica
Mensagem: "Estou com muita dor de dente desde ontem"

Responder: #K7QM sua mensagem
Assumir: #assumir K7QM
Devolver ao robô: #devolver K7QM
```

Tudo o que o paciente escrever depois chega para vocês como `💬 [#K7QM] Maria Silva: ...`.

## Comandos (enviados para o número da clínica)

| Comando | O que faz |
|---|---|
| `#fila` | Lista os atendimentos aguardando |
| `#assumir K7QM` | Você assume (o paciente recebe "Olá! Aqui é <seu nome>...") |
| `#K7QM Bom dia, Maria! Podemos te encaixar hoje às 14h?` | Envia a mensagem ao paciente **pelo número da clínica** |
| `#devolver K7QM` | Encerra e devolve a conversa ao robô |
| `#atender 5511999990000` | Assume a conversa de um paciente que está com o robô |
| `#ajuda` | Mostra os comandos |

## Regras importantes

- **Mande um "oi" para o número da clínica ao começar o expediente.** O WhatsApp só permite mensagens
  livres dentro de 24h da última mensagem de vocês; fora disso os avisos chegam como modelo resumido.
- Se o paciente ficou mais de 24h sem escrever, o WhatsApp **não entrega** mensagens livres — o sistema
  avisa. Nesse caso, ligue para o paciente.
- Atendimentos marcados como **URGENTE** precisam de resposta rápida. Se ficarem 15 min sem ninguém
  assumir, a administração recebe alerta.
- Se ninguém devolver, a conversa volta sozinha para o robô após o tempo configurado (padrão 4 horas sem atividade).
- Agendamentos feitos por vocês direto no Google Agenda bloqueiam o horário para o robô imediatamente.
  Não apague nem mova eventos criados pelo robô sem avisar o paciente: o sistema detecta e alerta a administração.
- Não peçam nem recebam fotos, exames ou dados de saúde pelo WhatsApp sem orientação da clínica.
