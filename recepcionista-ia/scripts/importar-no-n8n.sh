#!/usr/bin/env bash
# Importa os workflows no n8n do docker compose e publica na ordem correta.
# Uso:
#   scripts/importar-no-n8n.sh --credenciais   # 1ª vez: cria as credenciais VAZIAS (modelo) + workflows
#   scripts/importar-no-n8n.sh                 # atualizações: somente workflows
# O 01 (WhatsApp Trigger) NÃO é publicado aqui: publique pelo editor depois de preencher
# a credencial "WhatsApp Webhook (App Meta)" — ao publicar, o n8n registra o webhook na Meta.
set -euo pipefail
cd "$(dirname "$0")/.."
DC="docker compose"
if [ "${1:-}" = "--credenciais" ]; then
  echo "ATENÇÃO: isto cria/SOBRESCREVE as 7 credenciais com valores vazios."
  read -r -p "Continuar? (s/N) " R; [ "$R" = "s" ] || exit 1
  $DC exec -T n8n n8n import:credentials --input=/import/credentials/credenciais-modelo.json
fi
$DC exec -T n8n n8n import:workflow --separate --input=/import/workflows
# Ordem: sub-workflows antes de quem os chama (exigência do n8n 2.x)
for id in RiaWf00EnviarWpp RiaWf08AdaptAgen RiaWf06Monitoram RiaWf05Humano000 RiaWf02Agendamen RiaWf03Remarcaca RiaWf04Lembretes RiaWf07Reconcili; do
  $DC exec -T n8n n8n publish:workflow --id="$id"
done
$DC restart n8n
echo "Workflows importados e publicados (exceto 01). Próximo passo: INSTALACAO.md, seção 7."
