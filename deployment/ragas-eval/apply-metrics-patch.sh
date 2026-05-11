#!/bin/bash
# Adds answer_similarity + answer_correctness metrics to the RAGAS inline provider.
# The deployed image only ships 4 metrics; this overlays an updated constants.py via ConfigMap.
#
# Run after the LlamaStackDistribution CR is applied and the pod is running:
#   cd demos/llama-stack-openshift/deployment
#   bash apply-metrics-patch.sh

set -euo pipefail

NAMESPACE="ragas-eval"
DEPLOYMENT="llama-stack-ragas-inline"
CONFIGMAP="ragas-metrics-patch"
MOUNT_PATH="/opt/app-root/lib64/python3.12/site-packages/llama_stack_provider_ragas/constants.py"

echo "=== Step 1: Apply ConfigMap ==="
oc apply -f ragas-metrics-patch-configmap.yaml
echo ""

echo "=== Step 2: Check if volume already mounted ==="
EXISTING=$(oc get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="ragas-metrics-patch")].name}' 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
    echo "Volume 'ragas-metrics-patch' already mounted — skipping patch."
    echo "To force update, delete the ConfigMap and re-run: oc delete configmap $CONFIGMAP -n $NAMESPACE"
else
    echo "Patching deployment to mount ConfigMap..."
    oc patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type=json -p "[
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/volumes/-\",
        \"value\": {
          \"name\": \"ragas-metrics-patch\",
          \"configMap\": { \"name\": \"$CONFIGMAP\" }
        }
      },
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/containers/0/volumeMounts/-\",
        \"value\": {
          \"name\": \"ragas-metrics-patch\",
          \"mountPath\": \"$MOUNT_PATH\",
          \"subPath\": \"constants.py\"
        }
      }
    ]"
fi
echo ""

echo "=== Step 3: Wait for rollout ==="
oc rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s
echo ""

echo "=== Step 4: Verify ==="
POD=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD"
oc exec "$POD" -n "$NAMESPACE" -- python3 -c "
from llama_stack_provider_ragas.constants import AVAILABLE_METRICS
print('Available metrics:', AVAILABLE_METRICS)
"
echo ""
echo "Done. Metrics 'answer_similarity' and 'answer_correctness' are now available."
