{{- if .Values.widgetImage }}
apiVersion: example.invalid/v1
kind: Widget
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
spec:
  image: {{ .Values.widgetImage }}
{{- end }}
