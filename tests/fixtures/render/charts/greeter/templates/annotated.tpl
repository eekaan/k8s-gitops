{{- if .Values.repeatKey }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-annotated
  namespace: {{ .Release.Namespace }}
  annotations:
    fixture/policy: keep
    {{- if eq .Values.repeatKey "annotation" }}
    fixture/policy: keep
    {{- end }}
    {{- if eq .Values.repeatKey "quoted-annotation" }}
    80: one
    "80": two
    {{- end }}
data:
  nested:
    key: one
    {{- if eq .Values.repeatKey "nested" }}
    key: two
    {{- end }}
    {{- if and (eq .Values.repeatKey "served") (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor") }}
    key: two
    {{- end }}
    {{- if and (eq .Values.repeatKey "unserved") (not (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor")) }}
    key: two
    {{- end }}
    {{- if eq .Values.repeatKey "integer" }}
    80: one
    80: two
    {{- end }}
    {{- if eq .Values.repeatKey "quoted" }}
    80: one
    "80": two
    {{- end }}
    {{- if eq .Values.repeatKey "boolean" }}
    true: one
    "true": two
    {{- end }}
{{- end }}
{{- if eq .Values.repeatKey "unnamed" }}
---
fixture: unnamed
repeated: one
repeated: two
{{- end }}
