apiVersion: v1
kind: Secret
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
type: Opaque
data:
  # Derived, so that this value is in no file of the tree, as a decrypted one would not be.
  password: {{ printf "%s-for-%s" .Values.password .Release.Name | b64enc }}
  generated: {{ randAlphaNum 24 | b64enc }}
