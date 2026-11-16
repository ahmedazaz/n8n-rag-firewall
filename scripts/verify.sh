#!/usr/bin/env bash
# Reproduces the README verification log.
#   ./scripts/verify.sh            → DB checks + retrieval tests
#   ./scripts/verify.sh --ingest   → run Workflow A first (CLI), then the above
# Requires: docker compose stack up, Ollama on the host, curl, python3.
set -euo pipefail
cd "$(dirname "$0")/.."

N8N_URL="${N8N_URL:-http://localhost:5678}"
psql_rag() { docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d rag -c "$1"' _ "$1"; }

if [[ "${1:-}" == "--ingest" ]]; then
  echo "== Running Workflow A (ingestion firewall) via n8n CLI"
  # Alternate ports avoid clashing with the running n8n instance's task broker
  docker compose exec -T -e N8N_RUNNERS_BROKER_PORT=5690 -e N8N_PORT=5691 n8n \
    n8n execute --id IngestFirewallA1 >/dev/null
  echo "   done"
fi

echo
echo "== knowledge_vault (approved coaching sessions)"
psql_rag "SELECT session_id, stream_type, count(*) AS chunks,
                 min(length(content)) AS min_chars, max(length(content)) AS max_chars
          FROM knowledge_vault GROUP BY 1, 2 ORDER BY 1, 2;"

echo "== archived_sessions (rejected by the classifier, no embeddings)"
psql_rag "SELECT session_id, meeting_type, confidence_score, left(summary, 70) AS summary
          FROM archived_sessions ORDER BY 1;"

read -r -d '' FORMAT_PY <<'PY' || true
import json, sys
q = sys.argv[1]
r = json.load(sys.stdin)
route = r.get("route")
print("Q: " + q)
print("   route: " + str(route))
if route == "circuit_breaker":
    print("   best similarity  framework=%s  voice=%s  (LLM not called)"
          % (r.get("best_framework_similarity"), r.get("best_voice_similarity")))
for s in r.get("sources") or []:
    print("   source: %s %s#%s  similarity=%.3f"
          % (s["session_id"], s["stream_type"], s["chunk_index"], s["similarity"]))
print("   " + r.get("output", "").replace("\n", "\n   "))
print()
PY

ask() {
  local question="$1"
  local body
  body=$(python3 -c 'import json,sys; print(json.dumps({"question": sys.argv[1]}))' "$question")
  curl -s -m 300 -X POST "$N8N_URL/webhook/ask" -H 'Content-Type: application/json' -d "$body" |
    python3 -c "$FORMAT_PY" "$question"
}

echo "== Workflow B (gated retrieval)"
ask "Hi"
ask "How should I approach an underperforming VP?"
ask "How do I stop micromanaging my team?"
ask "How do I fix my database index?"
ask "What's a good pricing model for my SaaS?"

echo "== Proof from n8n's execution store: did the LLM node run? (last 5 Workflow B executions)"
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
  SELECT e.id AS execution_id,
         e.status,
         d.data LIKE '\''%\"Gated Vector Search\"%'\''  AS sql_ran,
         d.data LIKE '\''%\"Persona LLM (Ollama)\"%'\'' AS llm_ran
  FROM execution_entity e JOIN execution_data d ON d.\"executionId\" = e.id
  WHERE e.\"workflowId\" = '\''GatedRetrievalB1'\''
  ORDER BY e.id DESC LIMIT 5;"'
