{{/*
Expand the name of the chart.
*/}}
{{- define "markets-primer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "markets-primer.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "markets-primer.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "markets-primer.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "markets-primer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "markets-primer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
