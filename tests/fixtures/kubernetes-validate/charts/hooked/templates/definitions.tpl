{{- if .Values.definitionGroup }}
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: escapes.example.invalid
spec:
  group: {{ .Values.definitionGroup | toJson }}
  names:
    kind: {{ .Values.definitionKind | default "Escape" | toJson }}
    listKind: EscapeList
    plural: escapes
    singular: escape
  scope: Namespaced
  versions:
    - name: {{ .Values.definitionVersion | default "v1" | toJson }}
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
{{- end }}
{{- if .Values.brokenDefinition }}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: brokens.example.invalid
spec:
  group: example.invalid
  names:
    kind: Broken
    listKind: BrokenList
    plural: brokens
    singular: broken
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: string
              pattern: "[unclosed"
{{- end }}
