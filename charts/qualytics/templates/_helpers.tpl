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

{{/* Return a PostgreSQL schema name that is safe to quote in application SQL. */}}
{{- define "qualytics.postgres.schema" -}}
{{- $schema := "public" -}}
{{- if hasKey .Values.postgres "schema" -}}
{{- $schema = get .Values.postgres "schema" -}}
{{- end -}}
{{- if not (kindIs "string" $schema) -}}
{{- fail "postgres.schema must be a string" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]{0,62}$" $schema) -}}
{{- fail "postgres.schema must be a PostgreSQL identifier of 1-63 letters, numbers, or underscores" -}}
{{- end -}}
{{- $schema -}}
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

{{/*
Escape a string for use inside a double-quoted XML attribute value
(ivysettings.xml). Ampersand must be replaced first or it would re-escape
the other entities.
*/}}
{{- define "qualytics.xmlEscape" -}}
{{- . | toString | replace "&" "&amp;" | replace "<" "&lt;" | replace ">" "&gt;" | replace "\"" "&quot;" | replace "'" "&apos;" -}}
{{- end -}}

{{/*
ivysettings.xml for dataplane.ivy — redirects `spark-submit --packages` (Ivy)
resolution of dataplane.extraPackages to an internal Maven repository.
Loading a settings file replaces Spark's built-in resolver chain entirely,
so Maven Central is never contacted. The <credentials> element is emitted
only for authenticated repositories; its `host` must be the bare hostname
(no scheme, port, or path) because Ivy matches it against the JVM
Authenticator's requesting host. Rendered into the release-managed
<release>-spark-ivy-settings Secret (spark.yaml) and consumed by the driver
only — executors receive the resolved jars from the driver.
*/}}
{{- define "qualytics.ivy.settingsXml" -}}
{{- $ivy := .Values.dataplane.ivy -}}
{{- $url := required "dataplane.ivy.repositoryUrl is required when dataplane.ivy.enabled=true" $ivy.repositoryUrl -}}
<ivysettings>
  <settings defaultResolver="internal"/>
{{- if or $ivy.username $ivy.password }}
{{- $username := required "dataplane.ivy.username and dataplane.ivy.password must both be set (or both empty for anonymous access)" $ivy.username }}
{{- $password := required "dataplane.ivy.username and dataplane.ivy.password must both be set (or both empty for anonymous access)" $ivy.password }}
{{- $hostname := required "dataplane.ivy.repositoryUrl must be an absolute URL (https://host/...)" (first (splitList ":" (urlParse $url).host)) }}
  <credentials host="{{ include "qualytics.xmlEscape" $hostname }}" realm="{{ include "qualytics.xmlEscape" $ivy.realm }}" username="{{ include "qualytics.xmlEscape" $username }}" passwd="{{ include "qualytics.xmlEscape" $password }}"/>
{{- end }}
  <resolvers>
    <ibiblio name="internal" m2compatible="true" root="{{ include "qualytics.xmlEscape" $url }}"/>
  </resolvers>
</ivysettings>
{{- end -}}
