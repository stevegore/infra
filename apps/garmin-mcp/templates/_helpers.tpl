{{/*
Expand the name of the chart.
*/}}
{{- define "garmin-mcp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "garmin-mcp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "garmin-mcp.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "garmin-mcp.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "garmin-mcp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "garmin-mcp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
