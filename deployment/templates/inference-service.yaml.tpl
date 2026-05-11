apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  annotations:
    opendatahub.io/connection-path: ${S3_MODEL_PATH}
    opendatahub.io/connections: ${S3_CONNECTION_NAME}
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
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
spec:
  predictor:
    automountServiceAccountToken: false
    deploymentStrategy:
      type: Recreate
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
      runtime: ${MODEL_NAME}
      storage:
        key: ${S3_CONNECTION_NAME}
        path: ${S3_MODEL_PATH}
    nodeSelector:
      node-role.kubernetes.io/gpu-worker: "true"
    serviceAccountName: ${SERVICE_ACCOUNT}
    tolerations:
    - effect: NoSchedule
      key: nvidia.com/gpu
      operator: Exists
