{{- if .Values.testImage }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-test-connection
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: {{ .Values.testImage | toJson }}
{{- end }}
{{- if .Values.upgradeImage }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": pre-upgrade
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: {{ .Values.upgradeImage }}
{{- end }}
{{- if .Values.podTestImage }}
---
apiVersion: v1
kind: Pod
metadata:
  name: {{ .Release.Name }}-test-pod
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: {{ .Values.podTestImage }}
{{- end }}
