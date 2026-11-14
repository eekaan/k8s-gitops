apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
{{- if .Values.initImage }}
      initContainers:
        - name: init
          image: {{ .Values.initImage }}
{{- end }}
      containers:
        - name: hooked
          image: {{ .Values.image }}
