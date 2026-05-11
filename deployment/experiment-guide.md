# Experiment Guide: RAGAS Evaluation for Health Wallet RAG System

End-to-end evaluation of a RAG system using RAGAS inline provider on OpenShift. Uses a FAQ PDF as ground truth to measure RAG retrieval and generation quality.

## Prerequisites

- RAGAS inline evaluation environment deployed (see [`ragas-eval/README.md`](ragas-eval/README.md))
- RAG system running in `llama-stack-rag` namespace with ingested vector store
- Test PDF (FAQ format with numbered Q&A pairs) uploaded to MinIO
- Jupyter workbench in `ragas-eval` namespace
- Existing llama-stack-rag deployment (deployed via the RAG quickstart project)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Jupyter Workbench (ragas-eval)                    │
│                  ragas_health_wallet_eval.ipynb                      │
│                                                                     │
│  Step 1: Download PDF ──┐                                           │
│  Step 2: Query RAG ─────┼──────────────────────────┐                │
│  Step 3-5: Run RAGAS ───┼───────────┐              │                │
└─────────────────────────┼───────────┼──────────────┼────────────────┘
                          │           │              │
                          ▼           ▼              ▼
                   ┌──────────┐ ┌──────────┐ ┌──────────────────┐
                   │  MinIO   │ │ RAGAS    │ │  RAG LlamaStack  │
                   │  (S3)   │ │ LlamaStack│ │  (llama-stack-rag)│
                   │eval-data│ │(ragas-eval)│ │  + PGVector      │
                   └──────────┘ └──────────┘ └──────────────────┘
                                      │              │
                                      ▼              ▼
                               ┌──────────────────────────┐
                               │  vLLM Models (vszp)      │
                               │  Gemma-3-27B + qwen3-4b  │
                               └──────────────────────────┘
```

## Evaluation Workflow

### Step 1: Prepare Test Data

Upload the FAQ PDF to MinIO:

```bash
# The test PDF (najcastejsie-otazky-penazenka-zdravia.pdf) is a 33-page FAQ
# with numbered Q&A pairs in Slovak. It was intentionally excluded from the
# vector store to serve as independent ground truth.

# Upload to MinIO eval-data bucket (via MinIO Console or mc CLI)
```

**Important**: The test PDF must NOT be in the vector store being evaluated — otherwise you're testing memorization, not retrieval quality.

### Step 2: Run the Evaluation Notebook

Upload `ragas_health_wallet_eval.ipynb` to the Jupyter workbench in `ragas-eval` namespace.

Install dependencies:

```bash
pip install llama-stack-client==0.4.2 boto3 pdfplumber rich pandas
```

#### Key Configuration (cell-config)

```python
# RAG system
RAG_URL = "http://llamastack.llama-stack-rag.svc.cluster.local:8321"
VECTOR_STORE_NAME = "vszp-health-wallet-vector-store-v2"

# RAGAS evaluation system
RAGAS_URL = "http://llama-stack-ragas-inline-service.ragas-eval.svc.cluster.local:8321"

# MinIO
MINIO_ENDPOINT = "http://minio.llama-stack-rag.svc.cluster.local:9000"
EVAL_BUCKET = "eval-data"
```

#### Pipeline Steps in the Notebook

| Step | What it does | Time estimate |
|------|-------------|---------------|
| **Step 0** | Install deps, verify connectivity to both LlamaStack instances and MinIO | ~30s |
| **Step 1** | Download FAQ PDF from MinIO → parse with pdfplumber → extract Q&A pairs via regex | ~10s |
| **Step 2** | For each Q: (1) retrieve contexts via `vector-io/query` (2) generate response via `chat/completions` | ~15-30 min for 182 questions |
| **Save** | Save eval_data to `eval_data_health_wallet.json` (checkpoint) | instant |
| **Step 3** | Register eval dataset with RAGAS LlamaStack | ~1s |
| **Step 4** | Register benchmark + submit eval job, poll for completion | ~10-25 min |
| **Step 5** | Display aggregated scores, per-question breakdown, diagnostics | instant |

### Step 3: Interpret Results

RAGAS metrics:

| Metric | What it measures | Good score |
|--------|-----------------|------------|
| `answer_relevancy` | Is the RAG response relevant to the question? | > 0.8 |
| `faithfulness` | Is the response faithful to the retrieved contexts? | > 0.8 |
| `context_precision` | Are the retrieved contexts relevant to the question? | > 0.7 |
| `context_recall` | Do the contexts cover the ground truth answer? | > 0.7 |

Diagnostics help identify:
- **Low context_precision** → retrieval problem (vector store or embedding quality)
- **Low faithfulness** → generation problem (LLM hallucinating beyond context)
- **Low answer_relevancy** → response doesn't address the question
- **Low context_recall** → missing relevant documents in the vector store

## Known Issues and Workarounds

### 1. LlamaStack Version Mismatch Between Namespaces

**Problem**: `llama-stack-rag` runs server v0.3.5 (community image), `ragas-eval` runs v0.4.2 (rh-dev image). `llama_stack_client==0.4.2` is incompatible with the RAG server (HTTP 426).

**Workaround**: Use `requests` for RAG system API calls, `LlamaStackClient` only for RAGAS system. The notebook already implements this.

### 2. faithfulness Metric Parsing Failure with Gemma-3

**Problem**: RAGAS faithfulness metric requires the LLM to output structured statements. Gemma-3 returns JSON format that RAGAS's StringIO parser can't handle, causing `OUTPUT_PARSING_FAILURE`. With `raise_exceptions: True` (default), one failure kills the entire job.

**Workaround**: Start with `answer_relevancy` only (confirmed working). To try other metrics later, either:
- Set `raise_exceptions: False` in RAGAS config to skip failures
- Use a different LLM that better follows RAGAS's expected output format

### 3. Vector Store ID Format

**Problem**: The `vector-io/query` API requires the UUID (`vs_d7b17dd5-...`), not the human-readable name. Using the name returns "not served by provider" error.

**Workaround**: The notebook auto-resolves the name to UUID via `/v1/vector_stores` API.

### 4. eval_data Checkpoint

**Problem**: Step 2 (querying RAG for 182 questions) takes 15-30 minutes. If Step 4 fails, you lose all that work.

**Workaround**: eval_data is saved to `eval_data_health_wallet.json` after Step 2. On re-runs, uncomment the reload cell to skip Steps 1-2.

## Re-running the Evaluation

To re-run without re-querying RAG (e.g., to try different metrics):

1. Open the notebook
2. Run Step 0 (imports + config + connectivity)
3. Uncomment and run the reload cell:
   ```python
   import json
   with open("eval_data_health_wallet.json", "r", encoding="utf-8") as f:
       eval_data = json.load(f)
   ```
4. Run Steps 3-5

## Key Files

- Evaluation notebooks: `../experiment*/ragas_eval_answer_metrics.ipynb`
- Cached eval data: `../experiment*/eval_data_health_wallet.json`
- RAGAS deployment guide: [`ragas-eval/README.md`](ragas-eval/README.md)
- LlamaStackDistribution CR: [`ragas-eval/llama-stack-ragas-inline.yaml`](ragas-eval/llama-stack-ragas-inline.yaml)

## Vector Store Maintenance

Before running evaluation, verify the vector store is clean:

```bash
# List vector stores
oc exec deploy/llamastack -n llama-stack-rag -- \
  curl -s http://localhost:8321/v1/vector_stores | python3 -m json.tool

# Check files in a vector store
oc exec pgvector-0 -n llama-stack-rag -- psql -U postgres -d rag_blueprint -c \
  "SELECT document->'metadata'->>'filename' as filename, count(*) as chunks
   FROM vs_vs_<uuid_underscored> GROUP BY 1 ORDER BY 1;"

# Rebuild a vector store (via ingestion pipeline)
curl -X POST http://localhost:8000/add \
  -H "Content-Type: application/json" \
  -d '{
    "name": "vszp-health-wallet",
    "version": "2.0",
    "source": "S3",
    "embedding_model": "qwen-3-4b-embedding/qwen3-4b-embedding",
    "vector_store_name": "vszp-health-wallet-vector-store-v2",
    "access_key_id": "minio_rag_user",
    "secret_access_key": "minio_rag_password",
    "endpoint_url": "http://minio:9000",
    "bucket_name": "vszp-health-wallet",
    "region": "us-east-1"
  }'
```

Note: When deleting files from a vector store, the LlamaStack `DELETE /v1/vector_stores/{id}/files/{file_id}` API has a bug (500 error). Use direct SQL deletion as a workaround, then rebuild the vector store for a clean state.
