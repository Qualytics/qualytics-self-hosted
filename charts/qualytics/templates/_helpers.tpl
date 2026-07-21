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
