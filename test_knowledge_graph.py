"""
Project Ubuntu - Step 1 integration smoke test.

What this script proves:
1. PostgreSQL + pgvector are reachable.
2. schema.sql can be applied idempotently.
3. Synthetic South African compliance graph data can be inserted.
4. Regulation -> Control -> Internal Policy relationships can be traversed.
5. 1536-dimensional vector chunks can be stored and queried.
6. Full-text search and JSONB metadata/RBAC filters can be combined with
   vector retrieval using Reciprocal Rank Fusion (RRF).

Dependencies:
    pip install "psycopg[binary]>=3.2,<4"

No external embedding service is required. Embeddings are deliberately synthetic
and deterministic so this file remains self-contained and reproducible.

Run:
    python test_knowledge_graph.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

import psycopg
from psycopg.rows import dict_row


SCHEMA_PATH = Path(__file__).with_name("schema.sql")
EMBEDDING_DIMENSIONS = 1536

DEFAULT_DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "127.0.0.1"),
    "port": int(os.getenv("POSTGRES_PORT", "5432")),
    "dbname": os.getenv("POSTGRES_DB", "ubuntu_compliance"),
    "user": os.getenv("POSTGRES_USER", "ubuntu"),
    "password": os.getenv("POSTGRES_PASSWORD", "ubuntu_dev_password"),
    "connect_timeout": 10,
    "application_name": "project_ubuntu_step1_smoke_test",
}


def get_connection(*, autocommit: bool = False) -> psycopg.Connection:
    """
    Connect using DATABASE_URL when supplied; otherwise use POSTGRES_* variables.

    DATABASE_URL example:
        postgresql://ubuntu:password@127.0.0.1:5432/ubuntu_compliance
    """
    database_url = os.getenv("DATABASE_URL")

    if database_url:
        return psycopg.connect(
            database_url,
            autocommit=autocommit,
            row_factory=dict_row,
        )

    return psycopg.connect(
        **DEFAULT_DB_CONFIG,
        autocommit=autocommit,
        row_factory=dict_row,
    )


def vector_literal(values: list[float]) -> str:
    """Convert a Python float list to pgvector's text representation."""
    if len(values) != EMBEDDING_DIMENSIONS:
        raise ValueError(
            f"Expected {EMBEDDING_DIMENSIONS} dimensions, got {len(values)}"
        )
    return "[" + ",".join(f"{value:.6f}" for value in values) + "]"


def make_embedding(primary: int, secondary: int | None = None) -> str:
    """
    Build a sparse-looking but valid dense 1536-dimensional demo vector.

    These vectors are NOT semantic embeddings. Their only purpose is to make the
    smoke test deterministic. In the real ingestion pipeline replace this
    function with the approved enterprise embedding provider.
    """
    values = [0.0] * EMBEDDING_DIMENSIONS
    values[primary] = 1.0

    if secondary is not None:
        values[secondary] = 0.20

    return vector_literal(values)


def apply_schema() -> None:
    """Apply schema.sql. The migration is designed to be idempotent."""
    if not SCHEMA_PATH.exists():
        raise FileNotFoundError(f"Could not find schema file: {SCHEMA_PATH}")

    schema_sql = SCHEMA_PATH.read_text(encoding="utf-8")

    # schema.sql owns its BEGIN/COMMIT so use autocommit at the connection level.
    with get_connection(autocommit=True) as conn:
        conn.execute(schema_sql, prepare=False)

    print("✓ schema.sql applied successfully")


def upsert_seed_data(conn: psycopg.Connection) -> dict[str, int]:
    """Create a small but connected synthetic compliance graph."""

    regulation = conn.execute(
        """
        INSERT INTO regulations (
            regulator,
            name,
            section,
            obligation_text,
            effective_date,
            version,
            status
        )
        VALUES (
            %(regulator)s,
            %(name)s,
            %(section)s,
            %(obligation_text)s,
            %(effective_date)s,
            %(version)s,
            'active'
        )
        ON CONFLICT (regulator, name, section, version)
        DO UPDATE SET
            obligation_text = EXCLUDED.obligation_text,
            effective_date = EXCLUDED.effective_date,
            status = EXCLUDED.status
        RETURNING id
        """,
        {
            "regulator": "FIC",
            "name": "Financial Intelligence Centre Act (FICA)",
            "section": "42",
            # Paraphrased for this synthetic demo.
            "obligation_text": (
                "Maintain, document and implement a Risk Management and "
                "Compliance Programme (RMCP) appropriate to the institution's "
                "money-laundering and terrorist-financing risks."
            ),
            "effective_date": "2026-01-01",
            "version": "demo-2026",
        },
    ).fetchone()

    policy = conn.execute(
        """
        INSERT INTO internal_policies (
            policy_name,
            owner_role,
            version,
            status,
            requires_review
        )
        VALUES (
            %(policy_name)s,
            %(owner_role)s,
            %(version)s,
            'active',
            FALSE
        )
        ON CONFLICT (policy_name, version)
        DO UPDATE SET
            owner_role = EXCLUDED.owner_role,
            status = EXCLUDED.status,
            requires_review = EXCLUDED.requires_review
        RETURNING id
        """,
        {
            "policy_name": "Ubuntu Bank AML Risk Management & Compliance Programme Policy",
            "owner_role": "Head of Financial Crime Compliance",
            "version": "1.0",
        },
    ).fetchone()

    regulation_id = int(regulation["id"])
    policy_id = int(policy["id"])

    control = conn.execute(
        """
        INSERT INTO controls (
            control_code,
            description,
            mapped_regulation_id,
            mapped_policy_id
        )
        VALUES (
            'CTRL-AML-042',
            'Maintain, approve, periodically review and retain evidence of the bank RMCP.',
            %(regulation_id)s,
            %(policy_id)s
        )
        ON CONFLICT (control_code)
        DO UPDATE SET
            description = EXCLUDED.description,
            mapped_regulation_id = EXCLUDED.mapped_regulation_id,
            mapped_policy_id = EXCLUDED.mapped_policy_id
        RETURNING id
        """,
        {
            "regulation_id": regulation_id,
            "policy_id": policy_id,
        },
    ).fetchone()

    regulation_chunk = (
        "FICA Section 42 requires an accountable institution to maintain and "
        "implement a Risk Management and Compliance Programme (RMCP). "
        "The programme should document how relevant money-laundering and "
        "terrorist-financing risks are identified, assessed, mitigated, "
        "managed and monitored."
    )

    policy_chunk = (
        "Ubuntu Bank AML Risk Management and Compliance Programme Policy 1.0 "
        "maps to FICA Section 42. The Head of Financial Crime Compliance owns "
        "the RMCP, coordinates annual review, records approval evidence, and "
        "tracks remediation where control gaps are identified."
    )

    regulation_metadata = {
        "jurisdiction": "ZA",
        "source_authority": "FIC",
        "classification": "public",
        "allowed_roles": ["compliance_officer", "auditor"],
        "pii": False,
        "version": "demo-2026",
        "status": "active",
    }

    policy_metadata = {
        "jurisdiction": "ZA",
        "source_authority": "Ubuntu Bank",
        "classification": "internal",
        "allowed_roles": ["compliance_officer", "aml_analyst"],
        "pii": False,
        "version": "1.0",
        "status": "active",
    }

    # Regulation vector is intentionally closest to the mock query vector.
    conn.execute(
        """
        INSERT INTO document_chunks (
            source_type,
            source_id,
            chunk_index,
            content,
            embedding,
            metadata
        )
        VALUES (
            'regulation',
            %(source_id)s,
            0,
            %(content)s,
            %(embedding)s::vector,
            %(metadata)s::jsonb
        )
        ON CONFLICT (source_type, source_id, chunk_index)
        DO UPDATE SET
            content = EXCLUDED.content,
            embedding = EXCLUDED.embedding,
            metadata = EXCLUDED.metadata
        """,
        {
            "source_id": regulation_id,
            "content": regulation_chunk,
            "embedding": make_embedding(0),
            "metadata": json.dumps(regulation_metadata),
        },
    )

    conn.execute(
        """
        INSERT INTO document_chunks (
            source_type,
            source_id,
            chunk_index,
            content,
            embedding,
            metadata
        )
        VALUES (
            'policy',
            %(source_id)s,
            0,
            %(content)s,
            %(embedding)s::vector,
            %(metadata)s::jsonb
        )
        ON CONFLICT (source_type, source_id, chunk_index)
        DO UPDATE SET
            content = EXCLUDED.content,
            embedding = EXCLUDED.embedding,
            metadata = EXCLUDED.metadata
        """,
        {
            "source_id": policy_id,
            "content": policy_chunk,
            "embedding": make_embedding(0, 1),
            "metadata": json.dumps(policy_metadata),
        },
    )

    return {
        "regulation_id": regulation_id,
        "policy_id": policy_id,
        "control_id": int(control["id"]),
    }


def show_graph_mapping(conn: psycopg.Connection) -> None:
    """Demonstrate Regulation -> Control -> Policy graph traversal."""
    row = conn.execute(
        """
        SELECT
            r.regulator,
            r.name AS regulation_name,
            r.section,
            c.control_code,
            c.description AS control_description,
            p.policy_name,
            p.owner_role,
            p.requires_review
        FROM controls AS c
        LEFT JOIN regulations AS r
            ON r.id = c.mapped_regulation_id
        LEFT JOIN internal_policies AS p
            ON p.id = c.mapped_policy_id
        WHERE c.control_code = 'CTRL-AML-042'
        """
    ).fetchone()

    if row is None:
        raise RuntimeError("Expected seeded graph relationship was not found")

    print("\nCompliance graph proof")
    print("----------------------")
    print(f"Regulation : {row['regulator']} | {row['regulation_name']} §{row['section']}")
    print(f"Control    : {row['control_code']} | {row['control_description']}")
    print(f"Policy     : {row['policy_name']}")
    print(f"Owner      : {row['owner_role']}")
    print(f"Review?    : {row['requires_review']}")


def run_hybrid_search(conn: psycopg.Connection) -> list[dict[str, Any]]:
    """
    Execute hybrid retrieval with:
      - cosine-distance vector candidates,
      - PostgreSQL FTS candidates,
      - JSONB jurisdiction/PII/RBAC filtering,
      - Reciprocal Rank Fusion (RRF).

    The query embedding is synthetic but intentionally aligned with the seeded
    FICA/RMCP chunks so the smoke test is deterministic.
    """

    query_text = "FICA Section 42 RMCP"
    query_embedding = make_embedding(0)

    # JSONB containment implements retrieval-time metadata constraints.
    # In production, build this object from authenticated user claims and policy.
    metadata_filter = {
        "jurisdiction": "ZA",
        "pii": False,
        "allowed_roles": ["compliance_officer"],
    }

    rows = conn.execute(
        """
        WITH params AS (
            SELECT
                %(query_embedding)s::vector AS qvec,
                websearch_to_tsquery('english', %(query_text)s) AS qtext,
                %(metadata_filter)s::jsonb AS meta_filter
        ),
        vector_candidates AS (
            SELECT
                ranked.id,
                ROW_NUMBER() OVER (ORDER BY ranked.distance ASC) AS vector_rank
            FROM (
                SELECT
                    dc.id,
                    dc.embedding <=> p.qvec AS distance
                FROM document_chunks AS dc
                CROSS JOIN params AS p
                WHERE dc.metadata @> p.meta_filter
                ORDER BY dc.embedding <=> p.qvec
                LIMIT 20
            ) AS ranked
        ),
        text_candidates AS (
            SELECT
                ranked.id,
                ROW_NUMBER() OVER (ORDER BY ranked.text_rank DESC) AS text_rank_position
            FROM (
                SELECT
                    dc.id,
                    ts_rank_cd(dc.fts, p.qtext) AS text_rank
                FROM document_chunks AS dc
                CROSS JOIN params AS p
                WHERE dc.metadata @> p.meta_filter
                  AND dc.fts @@ p.qtext
                ORDER BY text_rank DESC
                LIMIT 20
            ) AS ranked
        ),
        fused AS (
            SELECT
                id,
                SUM(rrf_score) AS hybrid_score
            FROM (
                SELECT
                    id,
                    1.0 / (60.0 + vector_rank) AS rrf_score
                FROM vector_candidates

                UNION ALL

                SELECT
                    id,
                    1.0 / (60.0 + text_rank_position) AS rrf_score
                FROM text_candidates
            ) AS scores
            GROUP BY id
        )
        SELECT
            dc.id,
            dc.source_type,
            dc.source_id,
            dc.chunk_index,
            dc.content,
            dc.metadata,
            ROUND(f.hybrid_score::numeric, 8) AS hybrid_score,
            ROUND((1.0 - (dc.embedding <=> p.qvec))::numeric, 6)
                AS cosine_similarity,
            ROUND(ts_rank_cd(dc.fts, p.qtext)::numeric, 6)
                AS lexical_rank
        FROM fused AS f
        JOIN document_chunks AS dc
          ON dc.id = f.id
        CROSS JOIN params AS p
        ORDER BY f.hybrid_score DESC, cosine_similarity DESC
        LIMIT 10
        """,
        {
            "query_embedding": query_embedding,
            "query_text": query_text,
            "metadata_filter": json.dumps(metadata_filter),
        },
    ).fetchall()

    return list(rows)


def print_hybrid_results(rows: list[dict[str, Any]]) -> None:
    if not rows:
        raise RuntimeError("Hybrid search returned no results")

    print("\nHybrid search proof")
    print("-------------------")

    for index, row in enumerate(rows, start=1):
        metadata = row["metadata"]
        print(
            f"{index}. {row['source_type']}:{row['source_id']} "
            f"| hybrid={row['hybrid_score']} "
            f"| cosine={row['cosine_similarity']} "
            f"| lexical={row['lexical_rank']}"
        )
        print(
            "   metadata="
            f"jurisdiction={metadata.get('jurisdiction')}, "
            f"pii={metadata.get('pii')}, "
            f"allowed_roles={metadata.get('allowed_roles')}"
        )
        print(f"   {row['content'][:180]}...")


def verify_extensions(conn: psycopg.Connection) -> None:
    """Fail loudly if the required extensions are not active."""
    rows = conn.execute(
        """
        SELECT extname, extversion
        FROM pg_extension
        WHERE extname IN ('vector', 'pg_trgm')
        ORDER BY extname
        """
    ).fetchall()

    installed = {row["extname"]: row["extversion"] for row in rows}
    missing = {"vector", "pg_trgm"} - set(installed)

    if missing:
        raise RuntimeError(f"Required extensions are missing: {sorted(missing)}")

    print(
        "✓ extensions active: "
        + ", ".join(f"{name}={version}" for name, version in installed.items())
    )


def main() -> int:
    try:
        apply_schema()

        with get_connection() as conn:
            with conn.transaction():
                verify_extensions(conn)
                ids = upsert_seed_data(conn)
                print(
                    "✓ seed data upserted: "
                    f"regulation_id={ids['regulation_id']}, "
                    f"policy_id={ids['policy_id']}, "
                    f"control_id={ids['control_id']}"
                )

                show_graph_mapping(conn)

                rows = run_hybrid_search(conn)
                print_hybrid_results(rows)

        print("\n✓ Project Ubuntu Step 1 passed.")
        return 0

    except psycopg.OperationalError as exc:
        print("\n✗ Could not connect to PostgreSQL.", file=sys.stderr)
        print("  Is `docker compose up -d` running and healthy?", file=sys.stderr)
        print(f"  Details: {exc}", file=sys.stderr)
        return 2

    except Exception as exc:
        print(f"\n✗ Step 1 failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
