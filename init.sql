-- =====================================================================
-- init.sql — runs once on a fresh Postgres volume (docker-entrypoint-initdb.d)
-- n8n keeps its own internal tables in POSTGRES_DB; all RAG data lives in
-- a separate "rag" database so the project schema stays clean.
-- =====================================================================

CREATE DATABASE rag;
\c rag

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------
-- knowledge_vault: approved coaching sessions only (dual-stream chunks)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS knowledge_vault (
    id           BIGSERIAL PRIMARY KEY,
    session_id   TEXT        NOT NULL,
    stream_type  TEXT        NOT NULL CHECK (stream_type IN ('framework', 'voice_sample')),
    chunk_index  INTEGER     NOT NULL,
    content      TEXT        NOT NULL,
    metadata     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    embedding    vector(1024) NOT NULL,          -- bge-m3 output dimension
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Idempotent re-runs: Workflow A upserts on this key instead of duplicating rows
    CONSTRAINT knowledge_vault_chunk_uniq UNIQUE (session_id, stream_type, chunk_index)
);

-- HNSW index with cosine operators, matching the <=> operator used in Workflow B
CREATE INDEX IF NOT EXISTS knowledge_vault_embedding_hnsw
    ON knowledge_vault
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Supports the per-stream filter applied before similarity ranking
CREATE INDEX IF NOT EXISTS knowledge_vault_stream_type_idx
    ON knowledge_vault (stream_type);

-- ---------------------------------------------------------------------
-- archived_sessions: rejected sessions (internal ops, sales, low confidence)
-- Flat relational table — intentionally NO embedding column.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS archived_sessions (
    id                BIGSERIAL PRIMARY KEY,
    session_id        TEXT        NOT NULL UNIQUE,
    title             TEXT,
    meeting_type      TEXT        NOT NULL,
    confidence_score  NUMERIC(3,2),
    summary           TEXT,
    participants      JSONB       NOT NULL DEFAULT '[]'::jsonb,
    session_created_at TIMESTAMPTZ,
    archived_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
