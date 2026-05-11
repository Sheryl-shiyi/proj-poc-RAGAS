#!/bin/bash
# Deploy a model to OpenShift using a values file.
#
# Supports two storage modes:
#   STORAGE_MODE=hf  — Pull model from HuggingFace Hub (storageUri: hf://)
#   STORAGE_MODE=s3  — Load model from S3/MinIO (storage.key + storage.path)
#
# Usage:
#   bash deploy-model.sh model-configs/values-qwen3-32b.env          # HF mode
#   bash deploy-model.sh model-configs/values-gemma-3-27b-distributed.env  # S3 mode
#
# To create a new model deployment, copy an existing values file,
# edit the variables, and run this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <values-file.env>"
    echo ""
    echo "Available values files:"
    ls "$SCRIPT_DIR"/model-configs/values-*.env 2>/dev/null | xargs -I{} basename {}
    exit 1
fi

VALUES_FILE="$1"
if [ ! -f "$VALUES_FILE" ]; then
    VALUES_FILE="$SCRIPT_DIR/$VALUES_FILE"
fi

if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: values file not found: $1"
    exit 1
fi

echo "=== Loading values from: $(basename "$VALUES_FILE") ==="
set -a
source "$VALUES_FILE"
set +a

STORAGE_MODE="${STORAGE_MODE:-s3}"
RUNTIME_NAME="${RUNTIME_NAME:-$MODEL_NAME}"

echo "  Model:     $MODEL_NAME"
echo "  Namespace: $NAMESPACE"
echo "  GPUs:      $GPU_COUNT"
echo "  Mode:      $STORAGE_MODE"
if [ "$STORAGE_MODE" = "hf" ]; then
    echo "  HF model:  $STORAGE_URI"
    echo "  Runtime:   $RUNTIME_NAME"
else
    echo "  S3 path:   $S3_MODEL_PATH"
    echo "  S3 bucket: $AWS_S3_BUCKET @ $AWS_S3_ENDPOINT"
fi
echo ""

# --- Render templates ---
RENDERED_DIR=$(mktemp -d)
trap "rm -rf $RENDERED_DIR" EXIT

if [ "$STORAGE_MODE" = "hf" ]; then
    # HF mode: use hf template, no S3 secret needed
    envsubst < "$SCRIPT_DIR/templates/inference-service-hf.yaml.tpl" > "$RENDERED_DIR/inference-service-raw.yaml"
else
    # S3 mode: render S3 connection + S3 inference service template
    envsubst < "$SCRIPT_DIR/templates/s3-connection.yaml.tpl" > "$RENDERED_DIR/s3-connection.yaml"
    envsubst < "$SCRIPT_DIR/templates/inference-service.yaml.tpl" > "$RENDERED_DIR/inference-service-raw.yaml"
fi

# Convert VLLM_ARGS JSON array to YAML list
python3 - "$RENDERED_DIR/inference-service-raw.yaml" "$RENDERED_DIR/inference-service.yaml" <<'PYEOF'
import json, sys, re

infile, outfile = sys.argv[1], sys.argv[2]
with open(infile) as f:
    content = f.read()

match = re.search(r'( +)(args: )(\[.*\])', content)
if match:
    indent = match.group(1)
    args = json.loads(match.group(3))
    yaml_args = '\n'.join(f'{indent}- {a}' for a in args)
    content = content.replace(match.group(0), f'{indent}args:\n{yaml_args}')

with open(outfile, 'w') as f:
    f.write(content)
PYEOF

# --- Preview ---
echo "=== Rendered manifests ==="

if [ "$STORAGE_MODE" = "s3" ]; then
    echo "--- S3 Connection (Secret + ServiceAccount) ---"
    cat "$RENDERED_DIR/s3-connection.yaml" | grep -v 'AWS_SECRET_ACCESS_KEY\|AWS_ACCESS_KEY_ID'
    echo "  (credentials hidden)"
    echo ""
fi

echo "--- InferenceService ---"
cat "$RENDERED_DIR/inference-service.yaml"
echo ""

if [ "$RUNTIME_NAME" = "$MODEL_NAME" ]; then
    # New runtime needed — render and show
    envsubst < "$SCRIPT_DIR/templates/serving-runtime.yaml.tpl" > "$RENDERED_DIR/serving-runtime.yaml"
    echo "--- ServingRuntime (new) ---"
    cat "$RENDERED_DIR/serving-runtime.yaml"
    echo ""
else
    echo "--- ServingRuntime: reusing '$RUNTIME_NAME' ---"
    echo ""
fi

# --- Confirm ---
read -p "Apply to cluster? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Apply ---
echo "=== Ensuring namespace $NAMESPACE exists ==="
oc get namespace "$NAMESPACE" &>/dev/null || oc create namespace "$NAMESPACE"

if [ "$STORAGE_MODE" = "s3" ]; then
    echo "=== Applying S3 Connection (Secret + ServiceAccount) ==="
    oc apply -f "$RENDERED_DIR/s3-connection.yaml"
fi

if [ "$RUNTIME_NAME" = "$MODEL_NAME" ]; then
    echo "=== Applying ServingRuntime ==="
    oc apply -f "$RENDERED_DIR/serving-runtime.yaml"
else
    # Ensure the shared runtime exists
    if ! oc get servingruntime "$RUNTIME_NAME" -n "$NAMESPACE" &>/dev/null; then
        echo "=== Shared runtime '$RUNTIME_NAME' not found — creating from vllm-gpu-runtime.yaml ==="
        RUNTIME_FILE="$SCRIPT_DIR/runtimes/vllm-gpu-runtime.yaml"
        if [ -f "$RUNTIME_FILE" ]; then
            oc apply -f "$RUNTIME_FILE"
        else
            echo "ERROR: $RUNTIME_FILE not found and runtime '$RUNTIME_NAME' doesn't exist on cluster"
            exit 1
        fi
    else
        echo "=== ServingRuntime '$RUNTIME_NAME' already exists ==="
    fi
fi

echo "=== Applying InferenceService ==="
oc apply -f "$RENDERED_DIR/inference-service.yaml"

echo ""
echo "=== Waiting for deployment ==="
oc rollout status deployment/"${MODEL_NAME}-predictor" -n "$NAMESPACE" --timeout=600s 2>/dev/null || \
    echo "Note: rollout status check timed out or deployment name differs. Check with: oc get pods -n $NAMESPACE"

echo ""
echo "=== Status ==="
oc get inferenceservice "$MODEL_NAME" -n "$NAMESPACE" -o wide
echo ""
echo "Done. Model '$MODEL_NAME' deployed to namespace '$NAMESPACE'."
