apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  annotations:
    opendatahub.io/apiProtocol: REST
    opendatahub.io/recommended-accelerators: '["nvidia.com/gpu"]'
    opendatahub.io/runtime-version: v0.9.1.0
    opendatahub.io/serving-runtime-scope: global
    opendatahub.io/template-display-name: vLLM NVIDIA GPU ServingRuntime for KServe
    opendatahub.io/template-name: vllm-cuda-runtime-template
    openshift.io/display-name: vLLM NVIDIA GPU ServingRuntime for KServe
  labels:
    opendatahub.io/dashboard: "true"
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
spec:
  annotations:
    opendatahub.io/kserve-runtime: vllm
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
  containers:
  - args:
    - --port=8080
    - --model=/mnt/models
    - --served-model-name={{.Name}}
    command:
    - python
    - -m
    - vllm.entrypoints.openai.api_server
    env:
    - name: HF_HOME
      value: /tmp/hf_home
    image: ${VLLM_IMAGE}
    name: kserve-container
    ports:
    - containerPort: 8080
      protocol: TCP
    volumeMounts:
    - mountPath: /dev/shm
      name: dshm
  multiModel: false
  supportedModelFormats:
  - autoSelect: true
    name: vLLM
  volumes:
  - emptyDir:
      medium: Memory
      sizeLimit: ${SHM_SIZE}
    name: dshm
