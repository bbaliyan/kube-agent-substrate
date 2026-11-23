{{- define "substrate-actor.labels" -}}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: substrate-actor
substrate.actor: {{ .actor.name }}
{{- end -}}

{{- /* An ActorTemplate is immutable, so its name carries a hash of what it holds: the actor values without the egress rules, and the snapshot location. The substrate-registration chart builds the same name from the same values. */ -}}
{{- define "substrate-actor.templateName" -}}
{{- $actor := pick .actor "name" "atespace" "image" "command" "args" "env" "workerSelector" "resources" "wakeupProbe" "egressTrustBundle" -}}
{{- if not .actor.egressTrustBundle }}{{- $actor = omit $actor "egressTrustBundle" -}}{{- end -}}
{{- $inputs := dict "actor" $actor "snapshotStorageLocation" .root.Values.snapshotStorageLocation -}}
{{- printf "%s-%s" (.actor.name | trunc 52 | trimSuffix "-") (toJson $inputs | sha256sum | trunc 10) -}}
{{- end -}}

{{- /* The ActorTemplate is a protojson object for kubectl-ate, not a Kubernetes resource. */ -}}
{{- define "substrate-actor.template" -}}
metadata:
  atespace: {{ .actor.atespace }}
  name: {{ include "substrate-actor.templateName" . }}
{{- with .actor.workerSelector }}
workerSelector:
  matchLabels: {{ toJson . }}
{{- end }}
containers:
- name: {{ .actor.name }}
  image: {{ .actor.image }}
{{- with .actor.command }}
  command: {{ toJson . }}
{{- end }}
{{- with .actor.args }}
  args: {{ toJson . }}
{{- end }}
{{- if .actor.env }}
  env:
{{- range $name, $value := .actor.env }}
  - name: {{ $name }}
    value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- with .actor.wakeupProbe }}
  wakeupProbe:
    httpGet:
      path: {{ .path }}
      port: {{ .port }}
    timeoutSeconds: {{ .timeoutSeconds | default 30 }}
{{- end }}
{{- if .actor.egressTrustBundle }}
  volumeMounts:
  - name: egress-trust-bundle
    mountPath: /run/ate/egress-trust-bundle
{{- end }}
snapshotConfig:
  storageLocation: {{ .root.Values.snapshotStorageLocation }}
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
{{- with .actor.resources }}
resources:
  limits:
{{- with .cpuMillicores }}
    cpuMillicores: {{ . }}
{{- end }}
{{- with .memoryBytes }}
    memoryBytes: {{ . | int64 }}
{{- end }}
{{- end }}
{{- if .actor.egressTrustBundle }}
volumes:
- name: egress-trust-bundle
  systemInfo:
    dataSources:
    - trustBundle:
        names:
        - egress-mitm.ate.dev
        - system-roots.ate.dev
        path: trust-bundle.pem
{{- end }}
{{- end -}}

{{- /* The ports of an egress rule, as a JSON list. The server fills in the port of an http rule (80) and of an https rule (443). The policy that the chart renders must hold the same list, or the registration Job finds a difference and updates the policy on every run. A tlsPassthrough rule has no default. */ -}}
{{- define "substrate-actor.ports" -}}
{{- if .ports -}}
{{- toJson .ports -}}
{{- else if eq .protocol "http" -}}
[80]
{{- else if eq .protocol "https" -}}
[443]
{{- else -}}
[]
{{- end -}}
{{- end -}}

{{- define "substrate-actor.egress" -}}
metadata:
  atespace: {{ .actor.atespace }}
  name: default
rules:
{{- range .actor.egress }}
- {{ .protocol }}:
    hostnames: {{ toJson .hostnames }}
{{- with include "substrate-actor.ports" . | fromJsonArray }}
    ports:
      numbers: {{ toJson . }}
{{- end }}
{{- with .credential }}
    effects:
      replaceHeaders:
      - header: {{ .header }}
{{- with .prefix }}
        prefix: {{ . | quote }}
{{- end }}
        credentialUri: {{ .credentialUri }}
{{- end }}
{{- end }}
{{- end -}}

{{- /* The egress policy changes in place, so it has its own hash. The substrate-registration chart builds the same hash. */ -}}
{{- define "substrate-actor.egressHash" -}}
{{- toJson (default (list) .actor.egress) | sha256sum | trunc 10 -}}
{{- end -}}

{{- /* The same policy as "substrate-actor.egress", as JSON, so a client can compare it with the live policy. */ -}}
{{- define "substrate-actor.egressJson" -}}
{{- $rules := list -}}
{{- range .actor.egress -}}
{{- $protocol := .protocol -}}
{{- $rule := dict "hostnames" .hostnames -}}
{{- with include "substrate-actor.ports" . | fromJsonArray }}{{- $_ := set $rule "ports" (dict "numbers" .) -}}{{- end -}}
{{- with .credential -}}
{{- $header := dict "header" .header "credentialUri" .credentialUri -}}
{{- with .prefix }}{{- $_ := set $header "prefix" . -}}{{- end -}}
{{- $_ := set $rule "effects" (dict "replaceHeaders" (list $header)) -}}
{{- end -}}
{{- $rules = append $rules (dict $protocol $rule) -}}
{{- end -}}
{{- toJson (dict "metadata" (dict "atespace" $.actor.atespace "name" "default") "rules" $rules) -}}
{{- end -}}
