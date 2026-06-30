{{/*
Generate postgres connection URL
*/}}
{{- define "qualytics.postgres.connection_url" -}}
{{- $host := "" -}}
{{- $port := "" -}}
{{- $sslMode := "prefer" -}}
{{- if .Values.postgres.enabled -}}
{{- $host = printf "%s-postgres.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- $port = toString 5432 -}}
{{- else -}}
{{- $host = .Values.secrets.postgres.host -}}
{{- $port = toString .Values.secrets.postgres.port -}}
{{- end -}}
{{- if .Values.postgres.tls.enabled -}}
{{- $sslMode = "require" -}}
{{- end -}}
{{- printf "%s:%s@%s:%s/%s?sslmode=%s" .Values.secrets.postgres.username .Values.secrets.postgres.password $host $port .Values.secrets.postgres.database $sslMode -}}
{{- end -}}

{{/*
Determine deployment size based on dataplane.driver.cores
*/}}
{{- define "qualytics.global.size" -}}
  {{- $cores := .Values.dataplane.driver.cores | int -}}
  {{- if and (ge $cores 1) (le $cores 4) -}}
    small
  {{- else if and (gt $cores 4) (le $cores 8) -}}
    medium
  {{- else if and (gt $cores 8) (le $cores 16) -}}
    large
  {{- else if and (gt $cores 16) (le $cores 32) -}}
    xlarge
  {{- else -}}
    unspecified
  {{- end -}}
{{- end }}

{{/*
Driver pod memory in MiB. Mirrors Spark's KubernetesUtils overhead computation:
  overhead = max(memoryOverheadFactor * heap, 384)
The 384 MiB floor matters for small drivers; for production-sized 55 GiB drivers
the factor (e.g. 5500 MiB at 0.1) dominates. Without the floor, small driver
pods would have less non-heap headroom than spark-operator-managed ones and
risk OOMKill — the side-by-side smoke against the SparkApplication shape
showed exactly this: operator pod = 1408Mi (1024 + 384), this without floor
= 1126 (1024 + 102).
Input shape: dataplane.driver.memory expressed in Spark units like "55000m" (= MiB).
*/}}
{{- define "qualytics.spark.driver.podMemoryMb" -}}
{{- $heapMb := .Values.dataplane.driver.memory | trimSuffix "m" | int -}}
{{- $factorPct := mulf .Values.dataplane.memoryOverheadFactor 100 | int -}}
{{- /* Sprig pipes pass the value as the trailing arg, so `mul A B | div 100`
       means div(100, A*B). Use explicit parens to compute (A*B)/100. */ -}}
{{- $factorOverhead := div (mul $heapMb $factorPct) 100 -}}
{{- $overhead := max $factorOverhead 384 -}}
{{- add $heapMb $overhead -}}
{{- end -}}

{{/*
ModSecurity / Coraza SecLang snippet shared by the nginx ingress
(templates/ingress.yaml) and the Envoy Gateway WAF (templates/gateway.yaml).
MUST stay apostrophe-free: ingress-nginx wraps it in `modsecurity_rules '...'`, so
any `'` (even in a comment) breaks the nginx reload. See tests/ingress_test.yaml.
*/}}
{{- define "common.modsecurity.snippet" -}}
# Enable prevention mode. Can be any of: DetectionOnly,On,Off (default is DetectionOnly)
SecRuleEngine On
SecRequestBodyAccess On
# Update config to include PUT/PATCH/DELETE in the allowed HTTP methods
SecAction "id:900200,phase:1,nolog,pass,t:none,\
  setvar:tx.allowed_methods=GET HEAD POST OPTIONS PUT PATCH DELETE"
# Send ModSecurity audit logs to the stdout (only for rejected requests)
SecAuditLog /dev/stdout
SecAuditLogParts ABCIJDEFHZ
SecAuditLogFormat JSON
SecAuditEngine RelevantOnly # could be On/Off/RelevantOnly
# addresses SC-14854 expanded (phase:1 to reject before body processing)
SecRule REQUEST_URI_RAW "@rx (?:/\?){3,}" "id:14854,phase:1,deny,status:403"
# Block absurdly long URIs used in DDoS path-traversal floods (>4KB).
# t:length must run before @gt so the numeric comparison is against the URI
# character count, otherwise @gt coerces the raw string to int (=0) and never fires.
SecRule REQUEST_URI_RAW "@gt 4096" "id:14855,phase:1,deny,status:414,t:length"
# addresses SC-15205
SecRuleRemoveById 949110
{{- end -}}

{{/*
Per-rule HTTPRoute filters applied to every Envoy Gateway route: the 7 security
response headers (ResponseHeaderModifier) + the X-Original-URI request header
(RequestHeaderModifier). Gateway API has no route-wide filter, so this block is
included on each rule. Always emitted (the nginx path bakes the equivalents into
its annotations). Header values are byte-identical to the nginx path.
*/}}
{{- define "qualytics.gateway.routeFilters" -}}
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: X-Frame-Options
        value: "SAMEORIGIN"
      - name: X-Content-Type-Options
        value: "nosniff"
      - name: Referrer-Policy
        value: "same-origin"
      - name: Strict-Transport-Security
        value: "max-age=31536000; includeSubDomains; preload"
      - name: Content-Security-Policy
        value: "default-src https: blob: data: 'unsafe-eval' 'unsafe-inline'; worker-src https: blob:"
      - name: Permissions-Policy
        value: "autoplay=(self),cross-origin-isolated=(self),display-capture=(self),encrypted-media=(self),fullscreen=(self),keyboard-map=(self),picture-in-picture=(self),publickey-credentials-get=(self),screen-wake-lock=(self),sync-xhr=(self)"
      - name: X-Xss-Protection
        value: "1; mode=block"
- type: RequestHeaderModifier
  requestHeaderModifier:
    set:
      # nginx: proxy_set_header X-Original-URI $request_uri. %REQ(...)% is an Envoy
      # Gateway command-operator extension; on HTTP/1 this is the full request-target
      # (path+query), matching $request_uri.
      - name: X-Original-URI
        value: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
{{- end -}}

{{/*
Comma-separated spark.local.dir paths, one per dataplane.numVolumes.
Renders empty when numVolumes <= 0.
*/}}
{{- define "qualytics.spark.localDirs" -}}
{{- $dirs := list -}}
{{- if gt (.Values.dataplane.numVolumes | int) 0 -}}
{{- range $i := until (int .Values.dataplane.numVolumes) -}}
{{- $dirs = append $dirs (printf "/tmp/spark-local-dir-%d" (add1 $i)) -}}
{{- end -}}
{{- end -}}
{{- join "," $dirs -}}
{{- end -}}