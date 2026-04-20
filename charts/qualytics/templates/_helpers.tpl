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