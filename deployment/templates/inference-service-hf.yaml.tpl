apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  annotations:
    opendatahub.io/hardware-profile-name: ${HARDWARE_PROFILE}
    opendatahub.io/hardware-profile-namespace: redhat-ods-applications
    opendatahub.io/model-type: ${MODEL_TYPE}
    openshift.io/display-name: ${DISPLAY_NAME}
    security.opendatahub.io/enable-auth: "false"
    serving.kserve.io/deploymentMode: RawDeployment
    serving.kserve.io/stop: "false"
  labels:
    networking.kserve.io/visibility: exposed
    opendatahub.io/dashboard: "true"
    opendatahub.io/genai-asset: "true"
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
spec:
  predictor:
    maxReplicas: 1
    minReplicas: 1
    model:
      args: ${VLLM_ARGS}
      modelFormat:
        name: vLLM
      name: ""
      resources:
        limits:
          cpu: "${CPU_LIMIT}"
          memory: ${MEMORY_LIMIT}
          nvidia.com/gpu: "${GPU_COUNT}"
        requests:
          cpu: "${CPU_REQUEST}"
          memory: ${MEMORY_REQUEST}
          nvidia.com/gpu: "${GPU_COUNT}"
      runtime: ${RUNTIME_NAME}
      storageUri: ${STORAGE_URI}
    nodeSelector:
      node-role.kubernetes.io/gpu-worker: "true"
    tolerations:
    - effect: NoSchedule
      key: nvidia.com/gpu
      operator: Exists
