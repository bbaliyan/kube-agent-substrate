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

{{- /* The snapshot location. A value in config.storage must stay inside the bucket of the profile. */ -}}
{{- define "substrate-install.snapshotLocation" -}}
{{- $prefix := printf "s3://%s/" .Values.storage.bucket -}}
{{- $set := dig "storage" "snapshotLocation" "" .Values.config -}}
{{- if and $set (ne $set (trimSuffix "/" $prefix)) (not (hasPrefix $prefix $set)) -}}
{{- fail (printf "config.storage.snapshotLocation %q is outside the bucket: it must be s3://%s or start with %s" $set .Values.storage.bucket $prefix) -}}
{{- end -}}
{{- default $prefix $set -}}
{{- end -}}

{{- /* The Secret that holds the S3 keys: the name you set, or the default when an ExternalSecret creates it. */ -}}
{{- define "substrate-install.s3SecretName" -}}
{{- $creds := .Values.storage.s3Compatible.credentials -}}
{{- if $creds.secretName -}}
{{- $creds.secretName -}}
{{- else if $creds.externalSecret.enabled -}}
substrate-s3-credentials
{{- else -}}
{{- fail "storage.profile s3-compatible needs credentials.secretName or credentials.externalSecret.enabled" -}}
{{- end -}}
{{- end -}}

{{- /* The install document. The chart sets the image source and the sandbox class, so a value cannot change them. */ -}}
{{- define "substrate-install.document" -}}
{{- $doc := deepCopy .Values.config -}}
{{- $_ := set $doc "context" (include "substrate-install.contextName" .) -}}
{{- /* ate-setup models a cluster that is not kind as GCS and needs these two. S3 uses neither, so a value cannot change them. */ -}}
{{- $gcp := default (dict) $doc.gcp -}}
{{- $_ = set $gcp "projectID" "unused-placeholder" -}}
{{- $_ = set $doc "gcp" $gcp -}}
{{- $storage := default (dict) $doc.storage -}}
{{- $_ = set $storage "snapshotLocation" (include "substrate-install.snapshotLocation" .) -}}
{{- $_ = set $storage "transferGSAName" "unused-placeholder" -}}
{{- $_ = set $storage "bucketName" .Values.storage.bucket -}}
{{- $_ = set $doc "storage" $storage -}}
{{- $_ = set $doc "apiVersion" "install.ate.dev/v1alpha1" -}}
{{- $_ = set $doc "kind" "SubstrateInstall" -}}
{{- $_ = set $doc "images" (dict "repo" .Values.substrate.imageRepository "tag" .Values.substrate.version) -}}
{{- $_ = set $doc "sandboxClasses" "gvisor" -}}
{{- toYaml $doc -}}
{{- end -}}

{{- /* The context name that the kubeconfig defines and the install document selects. */ -}}
{{- define "substrate-install.contextName" -}}in-cluster{{- end -}}

{{- /* ate-setup reads this file through KUBECONFIG. It names the service account of the Job pod. */ -}}
{{- define "substrate-install.kubeconfig" -}}
apiVersion: v1
kind: Config
clusters:
  - name: {{ include "substrate-install.contextName" . }}
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
users:
  - name: installer
    user:
      tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
contexts:
  - name: {{ include "substrate-install.contextName" . }}
    context:
      cluster: {{ include "substrate-install.contextName" . }}
      user: installer
current-context: {{ include "substrate-install.contextName" . }}
{{- end -}}

{{- /* The storage patch: a Component that sets the object store backend on the two containers that read it, the plugin sidecar of ate-api-server and the plugin sidecar of atelet. The atelet container is left alone: in v1.0.0 it exits if ATE_STORAGE_BACKEND is set on it. The test operations stop the install if upstream moves the sidecar. */ -}}
{{- define "substrate-install.storagePatch" -}}
{{- $s := .Values.storage -}}
{{- if not (has $s.profile (list "aws" "s3-compatible")) -}}
{{- fail (printf "storage.profile %q is unknown: use aws or s3-compatible" $s.profile) -}}
{{- end -}}
{{- $env := list (dict "name" "ATE_STORAGE_BACKEND" "value" "s3") (dict "name" "AWS_REGION" "value" $s.region) -}}
{{- if eq $s.profile "s3-compatible" -}}
{{- $s3 := $s.s3Compatible -}}
{{- if not $s3.endpoint -}}
{{- fail "storage.profile s3-compatible needs storage.s3Compatible.endpoint" -}}
{{- end -}}
{{- $secret := include "substrate-install.s3SecretName" . -}}
{{- $env = concat $env (list
    (dict "name" "AWS_ENDPOINT_URL" "value" $s3.endpoint)
    (dict "name" "AWS_S3_USE_PATH_STYLE" "value" (toString $s3.pathStyle))
    (dict "name" "AWS_ACCESS_KEY_ID" "valueFrom" (dict "secretKeyRef" (dict "name" $secret "key" $s3.credentials.accessKeyKey)))
    (dict "name" "AWS_SECRET_ACCESS_KEY" "valueFrom" (dict "secretKeyRef" (dict "name" $secret "key" $s3.credentials.secretKeyKey)))) -}}
{{- end -}}
{{- $patches := list -}}
{{- range $w := list (dict "kind" "Deployment" "name" "ate-api-server") (dict "kind" "DaemonSet" "name" "atelet") -}}
{{- $guard := list
    (dict "op" "test" "path" "/spec/template/spec/initContainers/0/name" "value" "objectstore-plugin")
    (dict "op" "test" "path" "/spec/template/spec/initContainers/0/env/0/name" "value" "ATE_STORAGE_BACKEND") -}}
{{- $merge := dict "apiVersion" "apps/v1" "kind" $w.kind "metadata" (dict "name" $w.name) "spec" (dict "template" (dict "spec" (dict "initContainers" (list (dict "name" "objectstore-plugin" "env" $env))))) -}}
{{- $target := dict "kind" $w.kind "name" $w.name -}}
{{- $patches = concat $patches (list (dict "target" $target "patch" (toYaml $guard)) (dict "target" $target "patch" (toYaml $merge))) -}}
{{- end -}}
# Generated from the storage values. Do not edit.
# Workaround: the object store backend must be explicit on each container that
# reads it. Upstream issues: agent-substrate/substrate#3668 and #2378.
{{ toYaml (dict "apiVersion" "kustomize.config.k8s.io/v1alpha1" "kind" "Component" "patches" $patches) }}
{{- end -}}

{{- /* The Postgres sizing patch: a Component for the StatefulSet of the bundled Postgres. It is not part of the base kustomization: ate-setup applies postgres/postgres.yaml on its own, so the Job renders this Component over that file (see the job). The merge patch has no target, so kustomize fails the build if no StatefulSet named postgres exists. The test operations stop the install if upstream moves the container or the volume claim. */ -}}
{{- define "substrate-install.postgresPatch" -}}
{{- $pg := .Values.postgres -}}
{{- $target := dict "kind" "StatefulSet" "name" "postgres" -}}
{{- $guard := list
    (dict "op" "test" "path" "/spec/template/spec/containers/0/name" "value" "postgres")
    (dict "op" "test" "path" "/spec/volumeClaimTemplates/0/metadata/name" "value" "data")
    (dict "op" "replace" "path" "/spec/volumeClaimTemplates/0/spec/resources/requests/storage" "value" $pg.storage) -}}
{{- $merge := dict "apiVersion" "apps/v1" "kind" "StatefulSet" "metadata" (dict "name" "postgres" "namespace" "ate-system") "spec" (dict "template" (dict "spec" (dict "containers" (list (dict "name" "postgres" "resources" (deepCopy $pg.resources)))))) -}}
# Generated from the postgres values. Do not edit.
# Workaround: upstream hardcodes the sizing of the bundled Postgres.
# Upstream issues: agent-substrate/substrate#3167 and #3168.
{{ toYaml (dict "apiVersion" "kustomize.config.k8s.io/v1alpha1" "kind" "Component" "patches" (list (dict "patch" (toYaml $merge)) (dict "target" $target "patch" (toYaml $guard)))) }}
{{- end -}}

{{- /* The SELinux patch: a Component that sets the type spc_t on the atelet pods. On nodes that enforce SELinux, atelet runs as container_t and cannot write /var/lib/ate on the host, so it exits at start. The test operation stops the install if upstream moves the container. */ -}}
{{- define "substrate-install.seLinuxPatch" -}}
{{- $target := dict "kind" "DaemonSet" "name" "atelet" -}}
{{- $guard := list (dict "op" "test" "path" "/spec/template/spec/containers/0/name" "value" "atelet") -}}
{{- $merge := dict "apiVersion" "apps/v1" "kind" "DaemonSet" "metadata" (dict "name" "atelet") "spec" (dict "template" (dict "spec" (dict "securityContext" (dict "seLinuxOptions" (dict "type" "spc_t"))))) -}}
# Generated from the selinux values. Do not edit.
# Workaround: atelet pods run as container_t on SELinux nodes and cannot write /var/lib/ate.
# Upstream issue: agent-substrate/substrate#3597.
{{ toYaml (dict "apiVersion" "kustomize.config.k8s.io/v1alpha1" "kind" "Component" "patches" (list (dict "target" $target "patch" (toYaml $guard)) (dict "target" $target "patch" (toYaml $merge)))) }}
{{- end -}}

{{- /* Every patch Component by directory name: the files in patches/ and the generated ones. */ -}}
{{- define "substrate-install.patchFiles" -}}
{{- $files := dict -}}
{{- range $path, $_ := .Files.Glob "patches/*/kustomization.yaml" -}}
{{- $_ := set $files (base (dir $path)) ($.Files.Get $path) -}}
{{- end -}}
{{- $_ := set $files "20-storage-profile" (include "substrate-install.storagePatch" .) -}}
{{- $_ = set $files "30-postgres-sizing" (include "substrate-install.postgresPatch" .) -}}
{{- if .Values.selinux.enabled -}}
{{- $_ = set $files "25-atelet-selinux" (include "substrate-install.seLinuxPatch" .) -}}
{{- end -}}
{{- toJson $files -}}
{{- end -}}

{{- /* The patch directories in the order of their names. Each holds one kustomize Component. */ -}}
{{- define "substrate-install.patchNames" -}}
{{- toJson (keys (include "substrate-install.patchFiles" . | fromJson) | sortAlpha) -}}
{{- end -}}

{{- /* The kustomization that applies the Postgres patch to the Postgres manifest. The Job builds it over that manifest. */ -}}
{{- define "substrate-install.postgresBuild" -}}
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../postgres/postgres.yaml
components:
  - ../patches/30-postgres-sizing
{{- end -}}

{{- /* The patches for the base kustomization. The Postgres patch is not one of them: base holds no Postgres. */ -}}
{{- define "substrate-install.basePatchNames" -}}
{{- toJson (without (include "substrate-install.patchNames" . | fromJsonArray) "30-postgres-sizing") -}}
{{- end -}}

{{- /* Everything the Job reads from the config map, as JSON. */ -}}
{{- define "substrate-install.configData" -}}
{{- $data := dict "substrate-install.yaml" (include "substrate-install.document" .) "kubeconfig" (include "substrate-install.kubeconfig" .) "pg-build" (include "substrate-install.postgresBuild" .) -}}
{{- range $name, $content := include "substrate-install.patchFiles" . | fromJson -}}
{{- $_ := set $data (printf "patch-%s" $name) $content -}}
{{- end -}}
{{- toJson $data -}}
{{- end -}}

{{- /* Names the Job and its config map. A change to anything in the pod spec gives a new name. The same inputs find the Job already there. */ -}}
{{- define "substrate-install.hash" -}}
{{- $inputs := dict "image" (include "substrate-install.image" .) "data" (include "substrate-install.configData" . | fromJson) "env" .Values.env "resources" .Values.resources "nodeSelector" .Values.nodeSelector "tolerations" .Values.tolerations "serviceAccount" (include "substrate-install.serviceAccountName" .) "backoffLimit" .Values.backoffLimit "activeDeadlineSeconds" .Values.activeDeadlineSeconds -}}
{{- toJson $inputs | sha256sum | trunc 10 -}}
{{- end -}}

{{- define "substrate-install.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
