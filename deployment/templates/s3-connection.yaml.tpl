apiVersion: v1
kind: Secret
metadata:
  annotations:
    opendatahub.io/connection-type: s3
    opendatahub.io/connection-type-protocol: s3
    opendatahub.io/connection-type-ref: s3
    openshift.io/display-name: ${S3_DISPLAY_NAME}
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/managed: "true"
  name: ${S3_CONNECTION_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
  AWS_S3_BUCKET: ${AWS_S3_BUCKET}
  AWS_S3_ENDPOINT: ${AWS_S3_ENDPOINT}
  AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${NAMESPACE}
secrets:
- name: ${S3_CONNECTION_NAME}
