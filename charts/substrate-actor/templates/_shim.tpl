{{- /* The Envoy config of the webhook shim. The Lua filter reads the real secret from a file on every request, so a rotated Secret takes effect at once. LuaJIT has no ~ or | operators, so the compare uses the bit library. The compare checks every byte and does not stop at the first difference. The filter removes trailing white space from the file, so a Secret that ends in a new line still matches. The retry policy retries a refused connection, a reset before the request, a 502, a 503, a 504 and a try that runs out of time. A router answers 502 or 504 while it resumes a suspended actor, so a retry is what delivers the webhook. A retry can deliver one webhook twice in a rare case. The actor tolerates that: a second review is a smaller loss than a lost one. The keep-warm check asks the actor for a 200 at a fixed interval through the router, which resumes a suspended actor. */ -}}
{{- define "substrate-actor.shimEnvoy" -}}
{{- $webhook := .actor.webhook -}}
{{- $router := .root.Values.router -}}
{{- $warm := 30 -}}
{{- if hasKey $webhook "keepWarmSeconds" -}}{{- $warm = $webhook.keepWarmSeconds -}}{{- end -}}
node: {id: webhook-shim, cluster: webhook-shim}
static_resources:
  listeners:
    - name: webhook
      address:
        socket_address: {address: 0.0.0.0, port_value: {{ $webhook.port | default 8080 }}}
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: webhook
                route_config:
                  virtual_hosts:
                    - name: webhook
                      domains: ["*"]
                      routes:
                        - match: {path: /healthz}
                          direct_response: {status: 200, body: {inline_string: ok}}
                        - match: {prefix: /}
                          route:
                            cluster: router
                            timeout: {{ $webhook.timeoutSeconds | default 75 }}s
                            retry_policy:
                              retry_on: "connect-failure,refused-stream,reset-before-request,gateway-error"
                              num_retries: {{ $webhook.retries | default 2 }}
                              per_try_timeout: {{ $webhook.perTryTimeoutSeconds | default 25 }}s
                http_filters:
                  - name: envoy.filters.http.lua
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
                      default_source_code:
                        inline_string: |
                          local function equal(a, b)
                            local diff = bit.bxor(#a, #b)
                            for i = 1, math.max(#a, #b) do
                              diff = bit.bor(diff, bit.bxor(a:byte(i) or 0, b:byte(i) or 0))
                            end
                            return diff == 0
                          end
                          function envoy_on_request(h)
                            if h:headers():get(":path") == "/healthz" then return end
                            local f = io.open("/secrets/WEBHOOK_SECRET", "rb")
                            local want = f and f:read("*a")
                            if f then f:close() end
                            if want then want = (want:gsub("%s+$", "")) end
                            local got = h:headers():get("x-gitlab-token")
                            if not want or want == "" or not got or not equal(got, want) then
                              h:respond({[":status"] = "401"}, "unauthorized\n")
                              return
                            end
                            h:headers():replace("x-gitlab-token", {{ $webhook.hopToken | default "substrate-webhook-hop" | quote }})
                            h:headers():replace("ate-target-actor", {{ printf "%s/%s" .actor.atespace .actor.name | quote }})
                          end
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
    - name: router
      {{- include "substrate-actor.shimRouterCluster" (dict "root" .root "name" "router") | nindent 6 }}
{{- if $warm }}
    - name: router_warm
      {{- include "substrate-actor.shimRouterCluster" (dict "root" .root "name" "router_warm") | nindent 6 }}
      health_checks:
        - timeout: {{ $webhook.keepWarmTimeoutSeconds | default 30 }}s
          interval: {{ $warm }}s
          no_traffic_interval: {{ $warm }}s
          unhealthy_threshold: 1
          healthy_threshold: 1
          http_health_check:
            host: {{ $router.host | quote }}
            path: {{ $webhook.keepWarmPath | default "/" | quote }}
            request_headers_to_add:
              - header: {key: ate-target-actor, value: {{ printf "%s/%s" .actor.atespace .actor.name | quote }}}
{{- end }}
{{- end -}}

{{- /* The router as an upstream: its address and the mTLS settings. The request cluster and the keep-warm cluster share it. */ -}}
{{- define "substrate-actor.shimRouterCluster" -}}
{{- $router := .root.Values.router -}}
type: STRICT_DNS
connect_timeout: 5s
load_assignment:
  cluster_name: {{ .name }}
  endpoints:
    - lb_endpoints:
        - endpoint:
            address:
              socket_address: {address: {{ $router.host | quote }}, port_value: {{ $router.port }}}
transport_socket:
  name: envoy.transport_sockets.tls
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
    sni: {{ $router.host | quote }}
    common_tls_context:
      tls_certificate_sds_secret_configs:
        - name: router-client
          sds_config:
            path_config_source: {path: /etc/envoy/sds-client.yaml}
      validation_context_sds_secret_config:
        name: router-ca
        sds_config:
          path_config_source: {path: /etc/envoy/sds-ca.yaml}
{{- end -}}

{{- /* The client certificate and key of the pod identity. watched_directory makes Envoy load the files again when the kubelet rotates them. */ -}}
{{- define "substrate-actor.shimSdsClient" -}}
resources:
  - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
    name: router-client
    tls_certificate:
      certificate_chain: {filename: /run/router-client/credential-bundle.pem}
      private_key: {filename: /run/router-client/credential-bundle.pem}
      watched_directory: {path: /run/router-client}
{{- end -}}

{{- /* The CA that signs the serving certificate of the router. The shim checks the router host name against the certificate. */ -}}
{{- define "substrate-actor.shimSdsCa" -}}
resources:
  - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
    name: router-ca
    validation_context:
      trusted_ca: {filename: /run/router-client/router-ca.pem}
      watched_directory: {path: /run/router-client}
      match_typed_subject_alt_names:
        - san_type: DNS
          matcher: {exact: {{ .root.Values.router.host | quote }}}
{{- end -}}
