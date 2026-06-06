{{/*
Expand the name of the chart.
*/}}
{{- define "strava-keeper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "strava-keeper.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "strava-keeper.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "strava-keeper.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "strava-keeper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "strava-keeper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
