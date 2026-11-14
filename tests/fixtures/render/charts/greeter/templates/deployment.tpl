{{- if .Values.broken }}
{{- fail "the greeter chart refuses broken: true" }}
{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
      annotations:
        # Made up anew on every render, as charts do for generated passwords and certificates.
        checksum/random: {{ randAlphaNum 16 | sha256sum }}
    spec:
      containers:
        - name: greeter
          image: registry.example.invalid/greeter:1.0.0
          env:
            - name: DOMAIN
              value: {{ .Values.domain | quote }}
