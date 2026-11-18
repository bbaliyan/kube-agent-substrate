{{- define "substrate-idle-suspend.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "substrate-idle-suspend.serviceAccountName" -}}
{{- default (include "substrate-idle-suspend.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "substrate-idle-suspend.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: substrate-idle-suspend
{{- end -}}

{{- define "substrate-idle-suspend.image" -}}
{{ .Values.image.repository }}:{{ .Values.substrate.version }}@{{ .Values.image.digest }}
{{- end -}}

{{- /* One line for each actor: atespace/name. */ -}}
{{- define "substrate-idle-suspend.actors" -}}
{{- range $actor := .Values.actors -}}
{{ $actor.atespace }}/{{ $actor.name }}
{{ end -}}
{{- end -}}

{{- /* The URL is required. A render without it fails, so a missing value never gives a CronJob that cannot work. */ -}}
{{- define "substrate-idle-suspend.prometheusUrl" -}}
{{- required "prometheus.url is required" .Values.prometheus.url | trimSuffix "/" -}}
{{- end -}}

{{- /* Names the ConfigMap. Anything that the script reads gives a new name, so a run never mixes two versions. */ -}}
{{- define "substrate-idle-suspend.hash" -}}
{{- $inputs := dict "script" (.Files.Get "files/idle-suspend.sh") "actors" (include "substrate-idle-suspend.actors" .) "queries" .Values.queries "idleMinutes" .Values.idleMinutes "idleCpuCores" .Values.idleCpuCores "suspendMode" .Values.suspendMode "url" (include "substrate-idle-suspend.prometheusUrl" .) "timeout" .Values.prometheus.timeoutSeconds -}}
{{- toJson $inputs | sha256sum | trunc 10 -}}
{{- end -}}

{{- define "substrate-idle-suspend.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
