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
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end -}}

{{- /* The contract with the substrate-actor chart: the template name that chart renders for the same values. The Job refuses to run on a ConfigMap that holds another name, so it never registers stale data. Keep this equal to "substrate-actor.templateName"; make test-contract fails if it drifts. */ -}}
{{- define "substrate-registration.templateName" -}}
{{- $actor := pick .actor "name" "atespace" "image" "command" "args" "env" "workerSelector" "resources" "wakeupProbe" "egressTrustBundle" -}}
{{- if not .actor.egressTrustBundle }}{{- $actor = omit $actor "egressTrustBundle" -}}{{- end -}}
{{- $inputs := dict "actor" $actor "snapshotStorageLocation" .root.Values.snapshotStorageLocation -}}
{{- printf "%s-%s" (.actor.name | trunc 52 | trimSuffix "-") (toJson $inputs | sha256sum | trunc 10) -}}
{{- end -}}

{{- /* Equal to "substrate-actor.egressHash". */ -}}
{{- define "substrate-registration.egressHash" -}}
{{- toJson (default (list) .actor.egress) | sha256sum | trunc 10 -}}
{{- end -}}

{{- /* One line for each actor: name, atespace, the template name, the egress hash to register, and warm or cold. */ -}}
{{- define "substrate-registration.plan" -}}
{{- range $actor := .Values.actors -}}
{{ $actor.name }} {{ $actor.atespace }} {{ include "substrate-registration.templateName" (dict "root" $ "actor" $actor) }} {{ include "substrate-registration.egressHash" (dict "actor" $actor) }} {{ ternary "warm" "cold" (default false $actor.warm) }}
{{ end -}}
{{- end -}}

{{- /* One line for each member of each binding: atespace, role and member. */ -}}
{{- define "substrate-registration.bindings" -}}
{{- range $binding := .Values.accessBindings -}}
{{- range $member := $binding.members -}}
{{ $binding.atespace }} {{ $binding.role }} {{ $member }}
{{ end -}}
{{- end -}}
{{- /* With unregister.enabled the Job owns each atespace of its actors. The hook must delete an atespace, which needs the owner role, and it must not depend on the bootstrapOwners list: that list changes when an agent leaves. The Job holds the role as a binding in the atespace, so it stays as long as the atespace does. */ -}}
{{- if .Values.unregister.enabled -}}
{{- $seen := dict -}}
{{- range $actor := .Values.actors -}}
{{- if not (hasKey $seen $actor.atespace) -}}
{{- $_ := set $seen $actor.atespace true -}}
{{ $actor.atespace }} owner user:system:serviceaccount:{{ $.Release.Namespace }}:{{ include "substrate-registration.serviceAccountName" $ }}
{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Names the Job and its ConfigMap. A change to anything in the pod spec or the inputs gives a new name. The same inputs find the Job already there. */ -}}
{{- define "substrate-registration.hash" -}}
{{- $inputs := dict "image" (include "substrate-registration.image" .) "script" (.Files.Get "files/register.sh") "plan" (include "substrate-registration.plan" .) "bindings" (include "substrate-registration.bindings" .) "namespace" .Values.substrate.namespace "waitSeconds" .Values.waitSeconds "resources" .Values.resources "nodeSelector" .Values.nodeSelector "tolerations" .Values.tolerations "serviceAccount" (include "substrate-registration.serviceAccountName" .) "backoffLimit" .Values.backoffLimit "activeDeadlineSeconds" .Values.activeDeadlineSeconds -}}
{{- toJson $inputs | sha256sum | trunc 10 -}}
{{- end -}}

{{- define "substrate-registration.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
