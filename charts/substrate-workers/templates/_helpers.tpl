{{- define "substrate-workers.poolName" -}}
{{- default .Release.Name .Values.pool.name -}}
{{- end -}}

{{- define "substrate-workers.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: substrate-workers
{{- end -}}
