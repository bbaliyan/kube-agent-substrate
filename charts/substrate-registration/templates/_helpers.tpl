{{- define "substrate-registration.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "substrate-registration.serviceAccountName" -}}
{{- default (include "substrate-registration.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "substrate-registration.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: substrate-registration
{{- end -}}

{{- define "substrate-registration.image" -}}
{{ .Values.image.repository }}:{{ .Values.substrate.version }}@{{ .Values.image.digest }}
{{- end -}}

{{- /* The contract with the substrate-actor chart: the template name that chart renders for the same values. The Job refuses to run on a ConfigMap that holds another name, so it never registers stale data. Keep this equal to "substrate-actor.templateName"; make test-contract fails if it drifts. */ -}}
{{- define "substrate-registration.templateName" -}}
{{- $inputs := dict "actor" (omit .actor "webhook") "snapshotStorageLocation" .root.Values.snapshotStorageLocation -}}
{{- printf "%s-%s" (.actor.name | trunc 52 | trimSuffix "-") (toJson $inputs | sha256sum | trunc 10) -}}
{{- end -}}

{{- /* One line for each actor: name, atespace and the template name to register. */ -}}
{{- define "substrate-registration.plan" -}}
{{- range $actor := .Values.actors -}}
{{ $actor.name }} {{ $actor.atespace }} {{ include "substrate-registration.templateName" (dict "root" $ "actor" $actor) }}
{{ end -}}
{{- end -}}

{{- /* Names the Job and its ConfigMap. A change to anything in the pod spec or the inputs gives a new name. The same inputs find the Job already there. */ -}}
{{- define "substrate-registration.hash" -}}
{{- $inputs := dict "image" (include "substrate-registration.image" .) "script" (.Files.Get "files/register.sh") "plan" (include "substrate-registration.plan" .) "namespace" .Values.substrate.namespace "waitSeconds" .Values.waitSeconds "resources" .Values.resources "nodeSelector" .Values.nodeSelector "tolerations" .Values.tolerations "serviceAccount" (include "substrate-registration.serviceAccountName" .) "backoffLimit" .Values.backoffLimit "activeDeadlineSeconds" .Values.activeDeadlineSeconds -}}
{{- toJson $inputs | sha256sum | trunc 10 -}}
{{- end -}}

{{- define "substrate-registration.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
