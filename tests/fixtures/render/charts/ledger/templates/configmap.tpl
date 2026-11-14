apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
data:
  chart-version: {{ .Chart.Version | quote }}
  greeting: {{ .Values.greeting | quote }}
