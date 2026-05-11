# Deploy RAGAS Inline Evaluation on OpenShift

Deploy a RAGAS inline evaluation environment alongside an existing RAG stack on OpenShift. Tested on RHOAI 3.3.1.

## Prerequisites

- OpenShift cluster with RHOAI installed
- `oc` CLI logged in with admin privileges
- Existing vLLM models deployed via KServe (one LLM + one embedding model)
- (Optional) Existing PGVector instance for shared PostgreSQL storage
- Existing llama-stack-rag deployment (deployed via the [RAG quickstart project](https://github.com/rh-ai-quickstart/RAG))

## Architecture

```
┌─────────────────────────┐     ┌──────────────────────────────────┐
│ ragas-eval namespace    │     │ model namespace (e.g. vszp)      │
│                         │     │                                  │
│  LlamaStackDistribution │────>│  vLLM LLM (e.g. Gemma-27B)     │
│  (rh-dev + RAGAS)       │     │  vLLM Embedding (e.g. Qwen-4B)  │
│                         │     └──────────────────────────────────┘
│  Jupyter Workbench      │
│                         │     ┌──────────────────────────────────┐
│         │               │     │ llama-stack-rag namespace        │
│         └───────────────│────>│  PGVector (shared, DB: ragas_eval│
└─────────────────────────┘     └──────────────────────────────────┘
```

## Files in This Directory

| File | Purpose |
|------|---------|
| `llama-stack-ragas-inline.yaml` | LlamaStackDistribution CR — the main deployment manifest. Edit placeholders before applying. |
| `ragas-metrics-patch-configmap.yaml` | ConfigMap that patches RAGAS metric constants (adds `answer_similarity`) |
| `apply-metrics-patch.sh` | Script to apply the metrics patch to a running pod |

## Step 1: Activate LlamaStack Operator

```bash
# Check current state
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.llamastackoperator.managementState}'
# Expected: "Removed" (if not yet activated)

# Activate
oc patch datasciencecluster default-dsc --type='merge' \
  -p '{"spec":{"components":{"llamastackoperator":{"managementState":"Managed"}}}}'

# Wait for CRD
oc get crd | grep llamastackdist
# Expected: llamastackdistributions.llamastack.io

# Verify operator pod
oc get pods -n redhat-ods-applications | grep llama-stack-k8s-operator
# Expected: 1/1 Running
```

## Step 2: Identify Model URLs and IDs

```bash
# List InferenceServices
oc get isvc -n <model-namespace>

# Get model URLs
oc get isvc <llm-isvc-name> -n <model-namespace> -o jsonpath='{.status.url}'
oc get isvc <embedding-isvc-name> -n <model-namespace> -o jsonpath='{.status.url}'

# Get model IDs from vLLM
curl -sk <model-url>/v1/models | python3 -m json.tool
# Note the "id" field — this is what vLLM reports
```

## Step 3: Create Namespace and PostgreSQL Database

```bash
oc new-project ragas-eval
```

If reusing an existing PostgreSQL (e.g., PGVector from another namespace), create the database:

```bash
oc exec <pgvector-pod> -n <pg-namespace> -- psql -U postgres -c "CREATE DATABASE ragas_eval;"
```

## Step 4: Deploy LlamaStackDistribution

Edit `llama-stack-ragas-inline.yaml` — replace all `<placeholder>` values with your environment's model URLs, model IDs, and PostgreSQL credentials. Then apply:

```bash
oc apply -f llama-stack-ragas-inline.yaml
```

Wait for Ready:

```bash
oc get llamastackdistribution -n ragas-eval -w
# Wait until PHASE = Ready
```

## Step 5: Verify Deployment

```bash
# Check pod is running
oc get pods -n ragas-eval

# Check RAGAS provider is registered
oc exec deploy/llama-stack-ragas-inline-llama-stack -n ragas-eval -- \
  curl -s http://localhost:8321/v1/providers | python3 -m json.tool | grep -A3 ragas

# Check models are registered (note the provider-prefix in IDs)
oc exec deploy/llama-stack-ragas-inline-llama-stack -n ragas-eval -- \
  curl -s http://localhost:8321/v1/models | python3 -m json.tool
```

## Step 6: Run Smoke Test (via curl)

```bash
# Port-forward (if testing from local machine)
oc port-forward svc/llama-stack-ragas-inline-service 8321:8321 -n ragas-eval &

BASE_URL="http://localhost:8321"

# Register dataset
curl -s -X POST $BASE_URL/v1beta/datasets -H 'Content-Type: application/json' -d '{
  "dataset_id": "smoke_test",
  "purpose": "eval/question-answer",
  "source": {"type": "rows", "rows": [
    {"user_input": "What is the capital of France?", "response": "The capital of France is Paris.", "retrieved_contexts": ["Paris is the capital and most populous city of France."], "reference": "Paris"}
  ]},
  "metadata": {"provider_id": "localfs"}
}'

# Register benchmark
curl -s -X POST $BASE_URL/v1alpha/eval/benchmarks -H 'Content-Type: application/json' -d '{
  "benchmark_id": "smoke_benchmark",
  "dataset_id": "smoke_test",
  "scoring_functions": ["answer_relevancy"],
  "provider_id": "trustyai_ragas_inline"
}'

# Run eval (use the fully-qualified model ID!)
curl -s -X POST $BASE_URL/v1alpha/eval/benchmarks/smoke_benchmark/jobs \
  -H 'Content-Type: application/json' -d '{
  "benchmark_config": {
    "eval_candidate": {
      "type": "model",
      "model": "vllm-inference/<your-llm-model-id>",
      "sampling_params": {"temperature": 0.1, "max_tokens": 100}
    },
    "scoring_params": {}
  }
}'

# Poll for result
curl -s $BASE_URL/v1alpha/eval/benchmarks/smoke_benchmark/jobs/0 | python3 -m json.tool

# Get results (once status=completed)
curl -s $BASE_URL/v1alpha/eval/benchmarks/smoke_benchmark/jobs/0/result | python3 -m json.tool
```

## Step 7: Set Up Jupyter Workbench

1. Create a Jupyter workbench in the `ragas-eval` namespace via OpenShift AI Dashboard
2. Install matching client version:
   ```bash
   # Check server version first
   oc exec deploy/llama-stack-ragas-inline-llama-stack -n ragas-eval -- pip show llama-stack-client | grep Version
   # Then install the same version in the workbench
   pip install llama-stack-client==<version> rich pandas
   ```
3. In notebooks, use the cluster-internal service URL:
   ```python
   LLAMA_STACK_URL = "http://llama-stack-ragas-inline-service.ragas-eval.svc.cluster.local:8321"
   ```
4. Use `client.alpha.benchmarks` (not `client.benchmarks`) for benchmark operations

## Applying the Metrics Patch

The default RAGAS provider may not include `answer_similarity`. To add it:

```bash
# Apply the ConfigMap
oc apply -f ragas-metrics-patch-configmap.yaml

# Run the patch script
bash apply-metrics-patch.sh
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod CrashLoopBackOff: "Could not connect to PostgreSQL" | Database doesn't exist or Postgres env vars wrong | Create the database manually; verify POSTGRES_* env vars |
| Eval job fails: "Model 'X' not found" | Using short model ID instead of prefixed | Call `/v1/models` to get the full ID (e.g., `vllm-embedding/qwen3-4b-embedding`) |
| HTTP 426 from client | `llama_stack_client` version mismatch | Install matching version: `pip install llama-stack-client==<server-version>` |
| Workbench can't reach LlamaStack | NetworkPolicy blocks non-llama-stack pods | Add `spec.network.allowedFrom.namespaces` in the LlamaStackDistribution CR |
| `client.benchmarks.list()` AttributeError | API path differs in client version | Use `client.alpha.benchmarks.list()` |
| Zombie predictor pods in model namespace | KServe pods not cleaned up after cluster restart | `oc get pods -n <ns> --no-headers \| grep -v Running \| awk '{print $1}' \| xargs oc delete pod -n <ns>` |

## Reference

- rh-dev config inside image: `/opt/app-root/config.yaml`
- Test notebook: `../../tests/sheryl_test_inline_ragas.ipynb`
