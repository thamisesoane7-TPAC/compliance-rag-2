-- =============================================================================
-- Project Ubuntu
-- Enterprise Compliance Intelligence & Evidence Engine
-- Step 1: Compliance Knowledge Graph + Hybrid Retrieval + Audit Schema
--
-- PostgreSQL: 16
-- pgvector:   0.8.x
--
-- Design principles:
--   1. Regulations, policies, and controls form the relational compliance graph.
--   2. document_chunks supports semantic retrieval + PostgreSQL full-text search.
--   3. JSONB metadata carries RBAC, PII, versioning, classification, and lineage.
--   4. Audit logs retain generated answers, cited evidence, and human decisions.
--   5. Polymorphic chunk references are enforced in the database with triggers.
--
-- This migration is intentionally idempotent for an enterprise MVP/bootstrap.
-- =============================================================================

BEGIN;

-- Embeddings / ANN search.
CREATE EXTENSION IF NOT EXISTS vector;

-- Useful for fuzzy lookup of regulation and policy names.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- -----------------------------------------------------------------------------
-- 1. Regulations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS regulations (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    regulator       VARCHAR(100) NOT NULL,
    name            TEXT NOT NULL,
    section         VARCHAR(120) NOT NULL,
    obligation_text TEXT NOT NULL,
    effective_date  DATE NOT NULL,
    version         VARCHAR(80) NOT NULL,
    status          VARCHAR(24) NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT regulations_status_chk
        CHECK (status IN ('draft', 'active', 'superseded', 'withdrawn')),

    CONSTRAINT regulations_obligation_not_blank_chk
        CHECK (btrim(obligation_text) <> ''),

    CONSTRAINT regulations_business_key_uk
        UNIQUE (regulator, name, section, version)
);

COMMENT ON TABLE regulations IS
    'Authoritative regulatory obligations tracked by regulator, section, version, and effective date.';

COMMENT ON COLUMN regulations.status IS
    'Lifecycle state used to prevent superseded or withdrawn requirements from silently appearing current.';


-- -----------------------------------------------------------------------------
-- 2. Internal bank policies
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS internal_policies (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_name      TEXT NOT NULL,
    owner_role       VARCHAR(160) NOT NULL,
    version          VARCHAR(80) NOT NULL,
    status           VARCHAR(24) NOT NULL DEFAULT 'draft',
    requires_review  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT internal_policies_status_chk
        CHECK (status IN ('draft', 'active', 'superseded', 'retired')),

    CONSTRAINT internal_policies_name_not_blank_chk
        CHECK (btrim(policy_name) <> ''),

    CONSTRAINT internal_policies_business_key_uk
        UNIQUE (policy_name, version)
);

COMMENT ON TABLE internal_policies IS
    'Versioned internal-bank policies that can be mapped to regulatory obligations and controls.';

COMMENT ON COLUMN internal_policies.requires_review IS
    'Human-in-the-loop flag signalling that policy content or mappings require compliance review.';


-- -----------------------------------------------------------------------------
-- 3. Controls: relational edges in the MVP compliance graph
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS controls (
    id                     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    control_code           VARCHAR(80) NOT NULL UNIQUE,
    description            TEXT NOT NULL,
    mapped_regulation_id   BIGINT,
    mapped_policy_id       BIGINT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT controls_regulation_fk
        FOREIGN KEY (mapped_regulation_id)
        REFERENCES regulations(id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,

    CONSTRAINT controls_policy_fk
        FOREIGN KEY (mapped_policy_id)
        REFERENCES internal_policies(id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,

    -- A control must participate in the graph. It may initially map only to a
    -- regulation or only to a policy while remediation is still in progress.
    CONSTRAINT controls_has_graph_edge_chk
        CHECK (mapped_regulation_id IS NOT NULL OR mapped_policy_id IS NOT NULL),

    CONSTRAINT controls_description_not_blank_chk
        CHECK (btrim(description) <> '')
);

COMMENT ON TABLE controls IS
    'Compliance controls connecting regulatory obligations to internal-bank policy implementation.';


-- -----------------------------------------------------------------------------
-- 4. Document chunks: semantic + lexical retrieval layer
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS document_chunks (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Polymorphic source:
    --   regulation -> regulations.id
    --   policy     -> internal_policies.id
    source_type  VARCHAR(24) NOT NULL,
    source_id    BIGINT NOT NULL,

    chunk_index  INTEGER NOT NULL,
    content      TEXT NOT NULL,

    -- 1536 dimensions supports common enterprise embedding models while staying
    -- below pgvector's vector HNSW dimension ceiling.
    embedding    vector(1536) NOT NULL,

    -- Example metadata:
    -- {
    --   "jurisdiction": "ZA",
    --   "allowed_roles": ["compliance_officer", "auditor"],
    --   "pii": false,
    --   "classification": "internal",
    --   "version": "1.0",
    --   "effective_date": "2026-01-01"
    -- }
    metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- Stored generated column keeps lexical search synchronized automatically
    -- whenever content changes.
    fts          TSVECTOR
                 GENERATED ALWAYS AS (
                     to_tsvector('english'::regconfig, coalesce(content, ''))
                 ) STORED,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT document_chunks_source_type_chk
        CHECK (source_type IN ('regulation', 'policy')),

    CONSTRAINT document_chunks_chunk_index_chk
        CHECK (chunk_index >= 0),

    CONSTRAINT document_chunks_content_not_blank_chk
        CHECK (btrim(content) <> ''),

    CONSTRAINT document_chunks_metadata_object_chk
        CHECK (jsonb_typeof(metadata) = 'object'),

    CONSTRAINT document_chunks_source_chunk_uk
        UNIQUE (source_type, source_id, chunk_index)
);

COMMENT ON TABLE document_chunks IS
    'Chunked regulatory and policy content used for hybrid full-text + vector retrieval.';

COMMENT ON COLUMN document_chunks.metadata IS
    'POPIA-by-design retrieval metadata: RBAC tags, PII flags, versioning, classification, lineage, and jurisdiction.';


-- -----------------------------------------------------------------------------
-- 5. Human-in-the-loop audit trail
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    query_text          TEXT NOT NULL,
    generated_response  TEXT NOT NULL,

    -- JSON array is deliberately structured rather than plain text so each
    -- citation can carry source_type, source_id, chunk_id, section, score, etc.
    sources_cited       JSONB NOT NULL DEFAULT '[]'::jsonb,

    -- Kept as text because the enterprise IdP/user directory is not part of
    -- Step 1. Later this can reference an application_users table or IdP subject.
    reviewer_id         TEXT,

    -- NULL means "awaiting human review".
    human_decision      VARCHAR(16),

    -- TIMESTAMPTZ preserves the actual instant even when reviewers operate in
    -- different time zones.
    timestamp           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT audit_logs_sources_array_chk
        CHECK (jsonb_typeof(sources_cited) = 'array'),

    CONSTRAINT audit_logs_decision_chk
        CHECK (human_decision IS NULL OR human_decision IN ('approved', 'rejected')),

    CONSTRAINT audit_logs_reviewer_required_chk
        CHECK (human_decision IS NULL OR reviewer_id IS NOT NULL),

    CONSTRAINT audit_logs_query_not_blank_chk
        CHECK (btrim(query_text) <> '')
);

COMMENT ON TABLE audit_logs IS
    'Auditable record of compliance questions, generated answers, cited evidence, and human approval/rejection decisions.';


-- =============================================================================
-- POLYMORPHIC REFERENTIAL-INTEGRITY TRIGGERS
-- PostgreSQL cannot declare one normal FK from source_id to two parent tables.
-- Enforce the relationship centrally in the database instead of trusting every
-- application client to do it correctly.
-- =============================================================================

CREATE OR REPLACE FUNCTION validate_document_chunk_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.source_type = 'regulation' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM regulations
            WHERE id = NEW.source_id
        ) THEN
            RAISE EXCEPTION
                'document_chunks source_id % does not reference an existing regulation',
                NEW.source_id
                USING ERRCODE = '23503';
        END IF;

    ELSIF NEW.source_type = 'policy' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM internal_policies
            WHERE id = NEW.source_id
        ) THEN
            RAISE EXCEPTION
                'document_chunks source_id % does not reference an existing internal policy',
                NEW.source_id
                USING ERRCODE = '23503';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_document_chunk_source ON document_chunks;

CREATE TRIGGER trg_validate_document_chunk_source
BEFORE INSERT OR UPDATE OF source_type, source_id
ON document_chunks
FOR EACH ROW
EXECUTE FUNCTION validate_document_chunk_source();


-- Clean up chunks when an unreferenced regulation/policy is deleted.
-- Controls use ON DELETE RESTRICT, so a parent still used by the graph cannot be
-- removed accidentally.
CREATE OR REPLACE FUNCTION cleanup_regulation_chunks()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM document_chunks
    WHERE source_type = 'regulation'
      AND source_id = OLD.id;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_cleanup_regulation_chunks ON regulations;

CREATE TRIGGER trg_cleanup_regulation_chunks
AFTER DELETE ON regulations
FOR EACH ROW
EXECUTE FUNCTION cleanup_regulation_chunks();


CREATE OR REPLACE FUNCTION cleanup_policy_chunks()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM document_chunks
    WHERE source_type = 'policy'
      AND source_id = OLD.id;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_cleanup_policy_chunks ON internal_policies;

CREATE TRIGGER trg_cleanup_policy_chunks
AFTER DELETE ON internal_policies
FOR EACH ROW
EXECUTE FUNCTION cleanup_policy_chunks();


-- =============================================================================
-- UPDATED_AT MAINTENANCE
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_regulations_updated_at ON regulations;
CREATE TRIGGER trg_regulations_updated_at
BEFORE UPDATE ON regulations
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_internal_policies_updated_at ON internal_policies;
CREATE TRIGGER trg_internal_policies_updated_at
BEFORE UPDATE ON internal_policies
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_controls_updated_at ON controls;
CREATE TRIGGER trg_controls_updated_at
BEFORE UPDATE ON controls
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_document_chunks_updated_at ON document_chunks;
CREATE TRIGGER trg_document_chunks_updated_at
BEFORE UPDATE ON document_chunks
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- INDEXES
-- =============================================================================

-- Vector ANN search using cosine distance (<=>).
-- HNSW provides strong speed/recall trade-offs for low-latency retrieval.
CREATE INDEX IF NOT EXISTS idx_document_chunks_embedding_hnsw
    ON document_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- PostgreSQL full-text search.
CREATE INDEX IF NOT EXISTS idx_document_chunks_fts_gin
    ON document_chunks
    USING GIN (fts);

-- Flexible JSONB filtering for jurisdiction, PII flags, RBAC arrays, source
-- versions, classifications, and other retrieval-time constraints.
CREATE INDEX IF NOT EXISTS idx_document_chunks_metadata_gin
    ON document_chunks
    USING GIN (metadata);

-- Fast source lookup / chunk reconstruction.
CREATE INDEX IF NOT EXISTS idx_document_chunks_source
    ON document_chunks (source_type, source_id, chunk_index);

-- Fast graph traversal.
CREATE INDEX IF NOT EXISTS idx_controls_regulation
    ON controls (mapped_regulation_id)
    WHERE mapped_regulation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_controls_policy
    ON controls (mapped_policy_id)
    WHERE mapped_policy_id IS NOT NULL;

-- Useful operational filters.
CREATE INDEX IF NOT EXISTS idx_regulations_status_effective_date
    ON regulations (status, effective_date DESC);

CREATE INDEX IF NOT EXISTS idx_internal_policies_status_review
    ON internal_policies (status, requires_review);

CREATE INDEX IF NOT EXISTS idx_audit_logs_timestamp
    ON audit_logs (timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_decision
    ON audit_logs (human_decision)
    WHERE human_decision IS NOT NULL;

-- Fuzzy name lookup for human-entered searches / document reconciliation.
CREATE INDEX IF NOT EXISTS idx_regulations_name_trgm
    ON regulations
    USING GIN (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_internal_policies_name_trgm
    ON internal_policies
    USING GIN (policy_name gin_trgm_ops);

COMMIT;
