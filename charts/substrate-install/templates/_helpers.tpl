{{- define "substrate-install.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "substrate-install.serviceAccountName" -}}
{{- default (include "substrate-install.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "substrate-install.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: substrate-install
{{- end -}}

{{- define "substrate-install.image" -}}
{{ .Values.image.repository }}:{{ .Values.substrate.version }}@{{ .Values.image.digest }}
{{- end -}}

{{- /* The install document. The chart sets the image source and the sandbox class, so a value cannot change them. */ -}}
{{- define "substrate-install.document" -}}
{{- $doc := deepCopy .Values.config -}}
{{- $_ := set $doc "apiVersion" "install.ate.dev/v1alpha1" -}}
{{- $_ = set $doc "kind" "SubstrateInstall" -}}
{{- $_ = set $doc "images" (dict "repo" .Values.substrate.imageRepository "tag" .Values.substrate.version) -}}
{{- $_ = set $doc "sandboxClasses" "gvisor" -}}
{{- toYaml $doc -}}
{{- end -}}

{{- /* ate-setup reads this file through KUBECONFIG. It names the service account of the Job pod. */ -}}
{{- define "substrate-install.kubeconfig" -}}
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
users:
  - name: installer
    user:
      tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
contexts:
  - name: in-cluster
    context:
      cluster: in-cluster
      user: installer
current-context: in-cluster
{{- end -}}

{{- /* The patch directories in the order of their names. Each holds one kustomize Component. */ -}}
{{- define "substrate-install.patchNames" -}}
{{- $names := list -}}
{{- range $path, $_ := .Files.Glob "patches/*/kustomization.yaml" -}}
{{- $names = append $names (base (dir $path)) -}}
{{- end -}}
{{- toJson (sortAlpha $names) -}}
{{- end -}}

{{- /* Everything the Job reads from the config map, as JSON. */ -}}
{{- define "substrate-install.configData" -}}
{{- $data := dict "substrate-install.yaml" (include "substrate-install.document" .) "kubeconfig" (include "substrate-install.kubeconfig" .) -}}
{{- range $name := include "substrate-install.patchNames" . | fromJsonArray -}}
{{- $_ := set $data (printf "patch-%s" $name) ($.Files.Get (printf "patches/%s/kustomization.yaml" $name)) -}}
{{- end -}}
{{- toJson $data -}}
{{- end -}}

{{- /* Names the Job and its config map. A change to the version, image, patches or config gives a new name. The same inputs find the Job already there. */ -}}
{{- define "substrate-install.hash" -}}
{{- $inputs := dict "image" (include "substrate-install.image" .) "data" (include "substrate-install.configData" . | fromJson) "env" .Values.env "resources" .Values.resources -}}
{{- toJson $inputs | sha256sum | trunc 10 -}}
{{- end -}}

{{- define "substrate-install.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
