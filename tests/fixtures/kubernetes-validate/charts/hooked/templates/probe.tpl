{{- if .Values.probe }}
apiVersion: v1
kind: Pod
metadata:
  name: {{ .Release.Name }}-probe
  namespace: {{ .Release.Namespace }}
spec:
  containers:
    - name: probe
      image: {{ .Values.probeImage | toJson }}
{{- end }}
