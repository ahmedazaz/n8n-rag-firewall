#!/bin/sh
# One-shot n8n bootstrap (runs in the n8n-import service before n8n starts).
#  1. Creates the "Postgres (rag)" credential from environment variables.
#  2. Imports both workflows with their stable IDs.
#  3. Publishes Workflow B so POST /webhook/ask is live.
set -eu

MARKER=/home/node/.n8n/.bootstrap-done
if [ -f "$MARKER" ] && [ "${FORCE_IMPORT:-false}" != "true" ]; then
  echo "[bootstrap] already done, skipping (set FORCE_IMPORT=true to re-import)"
  exit 0
fi

CREDS=/tmp/credentials.json
# node builds the JSON so passwords with quotes/special characters stay valid
node -e '
const e = process.env;
console.log(JSON.stringify([{
  id: "pgvectorRagCred1",
  name: "Postgres (rag)",
  type: "postgres",
  data: {
    host: "postgres", port: 5432, database: e.RAG_DB_NAME,
    user: e.RAG_DB_USER, password: e.RAG_DB_PASSWORD, ssl: "disable"
  }
}]));' > "$CREDS"

echo "[bootstrap] importing credentials"
n8n import:credentials --input="$CREDS"
rm -f "$CREDS"

echo "[bootstrap] importing workflows"
n8n import:workflow --separate --input=/workflows

echo "[bootstrap] publishing Workflow B (webhook /ask)"
n8n publish:workflow --id=GatedRetrievalB1

touch "$MARKER"
echo "[bootstrap] done"
