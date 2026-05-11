# Model Deployment & Switching Guide

Deploy vLLM-served models on OpenShift (KServe) and update the Llama Stack instances to use them.

## Architecture

```
model namespace (e.g. vszp)    llama-stack-rag namespace       ragas-eval namespace
┌─────────────────┐            ┌─────────────────────────┐     ┌──────────────────────────┐
│ InferenceService │◄───────────│ llama-stack-rag          │     │ llama-stack-ragas-inline  │
│ (vLLM model)     │            │  (RAG answer generation) │◄────│  (RAGAS eval / judge LLM)│
│                  │            └─────────────────────────┘     └──────────────────────────┘
│ InferenceService │◄────────────────────────────────────────────────────────┘
│ (embedding)      │
└─────────────────┘
```

Both Llama Stack instances reference the model — when you switch models, **both** must be updated.

## Quick Start: Deploy a New Model

```bash
# 1. Deploy model (HuggingFace pull example)
bash deploy-model.sh model-configs/values-eurollm-22b.env

# 2. Update both Llama Stack instances (see "Switching Models" below)

# 3. Clean up stale model registrations (see "Cleaning Up" below)
```

## Directory Layout

```
deployment/
├── deploy-model.sh              # Main deployment script
├── experiment-guide.md          # End-to-end experiment workflow guide
├── model-configs/               # One .env per model deployment
│   ├── values-gemma-3-27b-distributed.env
│   ├── values-gemma-4-31b.env
│   ├── values-eurollm-22b.env
│   ├── values-qwen3-32b.env
│   └── values-qwen3-4b-embedding.env
├── templates/                   # K8s manifest templates (envsubst)
│   ├── inference-service-hf.yaml.tpl
│   ├── inference-service.yaml.tpl
│   ├── s3-connection.yaml.tpl
│   └── serving-runtime.yaml.tpl
├── runtimes/                    # ServingRuntime manifests
│   ├── vllm-gpu-runtime.yaml
│   └── vllm-community-runtime.yaml
└── ragas-eval/                  # RAGAS evaluation infrastructure
    ├── README.md                # Deployment guide for RAGAS eval environment
    ├── llama-stack-ragas-inline.yaml
    ├── ragas-metrics-patch-configmap.yaml
    └── apply-metrics-patch.sh
```

## Values Files

Each `.env` file defines one model deployment. Two storage modes:

| Mode | Field | Example |
|------|-------|---------|
| `hf` | `STORAGE_URI` | `hf://google/gemma-4-31B-it` |
| `s3` | `S3_MODEL_PATH`, `AWS_S3_BUCKET`, etc. | S3/MinIO bucket path |

Key variables:

```bash
STORAGE_MODE=hf              # "hf" or "s3"
MODEL_NAME=eurollm-22b       # K8s resource name
DISPLAY_NAME=EuroLLM-22B-Instruct  # Human-readable name
NAMESPACE=vszp               # Target namespace for model deployment
RUNTIME_NAME=vllm-gpu        # Shared ServingRuntime (skip creating a new one)
GPU_COUNT=4
VLLM_ARGS='["--tensor-parallel-size=4", "--dtype=bfloat16", ...]'
```

When `RUNTIME_NAME` differs from `MODEL_NAME`, the script reuses the existing ServingRuntime instead of creating a new one.

### Available Model Configs

| Values file | Model | Size | Storage |
|-------------|-------|------|---------|
| `values-gemma-3-27b-distributed.env` | Gemma 3 27B BF16 | 27B | S3 |
| `values-eurollm-22b.env` | EuroLLM-22B-Instruct | 22B | HF |
| `values-qwen3-32b.env` | Qwen3-32B | 32B | HF |
| `values-gemma-4-31b.env` | Gemma 4 31B IT | 31B | HF |
| `values-qwen3-4b-embedding.env` | Qwen3 4B Embedding | 4B | S3 |

## Switching Models

When you deploy a new inference model and want the Llama Stack instances to use it, update both systems.

### Step 1: Stop the old model (optional — saves GPU)

```bash
# Disable without deleting
oc annotate inferenceservice <old-model> -n <model-namespace> serving.kserve.io/stop=true

# Re-enable later
oc annotate inferenceservice <old-model> -n <model-namespace> serving.kserve.io/stop-
```

### Step 2: Update ragas-eval (LlamaStackDistribution CR)

The ragas-eval instance uses a `LlamaStackDistribution` CR with inline env vars.

```bash
# Use internal Service URL (see "Important: Internal URLs" below)
NEW_URL="http://<new-model>-predictor.<model-namespace>.svc.cluster.local:8080/v1"
NEW_DISPLAY_NAME="<DisplayName>"  # Must match --served-model-name in VLLM_ARGS

oc patch llamastackdistribution llama-stack-ragas-inline -n ragas-eval --type=json -p "[
  {\"op\": \"replace\", \"path\": \"/spec/server/containerSpec/env/0/value\", \"value\": \"$NEW_DISPLAY_NAME\"},
  {\"op\": \"replace\", \"path\": \"/spec/server/containerSpec/env/1/value\", \"value\": \"$NEW_URL\"}
]"
```

> The env array indices: `0` = `INFERENCE_MODEL`, `1` = `VLLM_URL`. Verify with:
> `oc get llamastackdistribution llama-stack-ragas-inline -n ragas-eval -o jsonpath='{.spec.server.containerSpec.env[0..1]}'`

### Step 3: Update llama-stack-rag (ConfigMap + Deployment)

The llama-stack-rag instance uses a ConfigMap (`run-config`) containing a full `config.yaml`. It also has a hardcoded init container health check URL.

```bash
NEW_URL="http://<new-model>-predictor.<model-namespace>.svc.cluster.local:8080/v1"
NEW_DISPLAY_NAME="<DisplayName>"    # Must match --served-model-name in VLLM_ARGS
NEW_PROVIDER_ID="<new-model>"       # K8s resource name of the InferenceService

# Edit ConfigMap — replace provider_id, url, and model_id in config.yaml
oc edit configmap run-config -n llama-stack-rag
# In the editor, update these three fields under providers.inference[0] and models[0]:
#   provider_id: <NEW_PROVIDER_ID>
#   url: <NEW_URL>
#   model_id: <NEW_DISPLAY_NAME>

# Patch init container (health check URL is hardcoded in Deployment spec)
oc patch deployment llamastack -n llama-stack-rag --type=json -p "[
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/initContainers/0/command\",
   \"value\": [\"sh\", \"-c\",
     \"until curl -sk '$NEW_URL/models' | grep -q '\\\"id\\\"'; do echo waiting; sleep 5; done\"]}
]"
```

> The Deployment patch triggers a pod rollout. The new pod loads the updated config and
> automatically drops model registrations from providers that no longer exist in the config.

### Step 4: Wait for rollout

```bash
oc rollout status deployment/llama-stack-ragas-inline-llama-stack -n ragas-eval --timeout=120s
oc rollout status deployment/llamastack -n llama-stack-rag --timeout=120s
```

### Important: Use Internal Service URLs

KServe creates both a ClusterIP Service (`<model>-predictor.<namespace>.svc.cluster.local:8080`) and an external Route (`https://<model>-<namespace>.apps.<cluster-domain>`).

**Always use the internal Service URL** for Llama Stack instances running in the same cluster. The external Route goes through HAProxy which has a 30s default timeout — long LLM generations (e.g. `answer_correctness` with `max_tokens=1500`) will hit 504 Gateway Timeout errors and trigger expensive retries. Internal URLs have no timeout limit and skip TLS overhead.

## Cleaning Up Stale Model Registrations

**This is required every time you switch models.** Llama Stack persists model registrations in SQLite/PostgreSQL. Even after updating env vars, old model entries remain and can confuse notebooks.

> **Tip:** If switching models also triggers a pod rollout (e.g. ConfigMap change + init container patch), the new pod only loads providers defined in the current config — stale registrations from removed providers are automatically cleaned up. Manual deletion is only needed when the pod was NOT restarted after a config change.

### Check registered models

```bash
# ragas-eval
oc exec deploy/llama-stack-ragas-inline-llama-stack -n ragas-eval -- \
  curl -s http://localhost:8321/v1/models | python3 -m json.tool

# llama-stack-rag
oc exec deploy/llamastack -n llama-stack-rag -- \
  curl -s http://localhost:8321/v1/models | python3 -m json.tool
```

### Delete stale registrations

The simplest way is to ensure the old provider is removed from the config and then trigger a pod rollout — Llama Stack only loads providers defined in the current config on startup.

```bash
# For llama-stack-rag: edit the ConfigMap to remove the old provider, then restart
oc rollout restart deployment/llamastack -n llama-stack-rag

# For ragas-eval: patch the CR (this triggers a rollout automatically)
# See Step 2 above

# Verify
oc exec deploy/llamastack -n llama-stack-rag -- \
  curl -s http://localhost:8321/v1/models | python3 -m json.tool
```

> After cleanup, only the new inference model and embedding model should remain.

## VRAM Budget Reference (4x A10G / g5.12xlarge)

Each A10G has 22.5 GB VRAM (not 24 GB). With `--gpu-memory-utilization=0.8`:

| Model | Weights/GPU | Available/GPU | KV Cache Headroom |
|-------|-------------|---------------|-------------------|
| EuroLLM-22B (BF16, tp=4) | ~11 GB | 18 GB | ~7 GB |
| Gemma-3-27B (BF16, tp=4) | ~13.5 GB | 18 GB | ~4.5 GB |
| Gemma-4-31B (BF16, tp=4) | ~15.5 GB | 18 GB | ~2.5 GB |
| Qwen3-32B (BF16, tp=4) | ~16 GB | 18 GB | ~2 GB (tight) |

Models >22 GB in BF16 require `--tensor-parallel-size=4` — a single A10G cannot fit them.

## Community vLLM on OpenShift: Known Issues

When using the community vLLM image (`docker.io/vllm/vllm-openai`) instead of the Red Hat image (`registry.redhat.io/rhaiis/vllm-cuda-rhel9`), you will hit several issues due to OpenShift's restricted security context. These are documented here to avoid repeated debugging.

### 1. `python` not found in PATH

The community image has `python3` in PATH, not `python`. The ServingRuntime command must use `python3`:

```yaml
command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
```

### 2. `PermissionError: [Errno 13] Permission denied: '/.cache'`

OpenShift runs containers as a non-root arbitrary UID that cannot write to `/.cache`. Add these env vars to the ServingRuntime:

```yaml
env:
- name: HOME
  value: /tmp
- name: XDG_CACHE_HOME
  value: /tmp/.cache
- name: VLLM_CACHE_ROOT
  value: /tmp/.cache/vllm
```

See `runtimes/vllm-community-runtime.yaml` for the full example.

### 3. Multimodal models (Gemma 4) — compilation timeout

Gemma 4 is a multimodal model. Even for text-only inference, vLLM profiles the vision encoder and compiles CUDA graphs for it, which can exceed the shared memory broadcast timeout (60s) and crash the engine.

**Fix:** Disable multimodal profiling entirely with:

```
--limit-mm-per-prompt '{"image": 0, "audio": 0}'
```

Also set `--max-num-batched-tokens=4096` to avoid the related error:
`"Chunked MM input disabled but max_tokens_per_mm_item (2496) is larger than max_num_batched_tokens (2048)"`

### 4. Alternative: Red Hat preview image for Gemma 4

Red Hat provides a preview image with all the above issues pre-fixed:

```
registry.redhat.io/rhaii-preview/vllm-cuda-rhel9:gemma4
```

This is the simpler option if you don't need a specific community vLLM version.

### 5. HuggingFace storage mode — model re-downloaded on every pod rebuild

`hf://` mode stores the model in the pod's ephemeral storage. Every time the pod is recreated (ServingRuntime change, InferenceService arg change, pod deletion), the full model is re-downloaded from HuggingFace (~15 min for 60 GB). Plan your changes carefully to minimize pod rebuilds, or use S3/MinIO storage for frequently-debugged models.

## Key Lessons Learned

### Internal vs External URLs

KServe creates both an internal ClusterIP Service and an external HAProxy Route for each model. **Always use internal Service URLs** (`http://<model>-predictor.<ns>.svc.cluster.local:8080/v1`) for in-cluster communication. The external Route has a 30s HAProxy timeout that causes 504 Gateway Timeout errors during long LLM generations, triggering expensive retries.

### HF Storage vs S3 Storage

`hf://` mode re-downloads the full model (~15 min for 60 GB) on every pod rebuild. Use S3/MinIO storage for models you're actively debugging to avoid repeated downloads.

### Stale Model Registrations

Llama Stack persists model registrations in its database. After switching models, old entries remain unless the pod is rolled out with the old provider removed from config. A pod rollout (triggered by ConfigMap or Deployment changes) automatically cleans up registrations for removed providers.
