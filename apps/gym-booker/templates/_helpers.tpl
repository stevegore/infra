{{/*
Expand the name of the chart.
*/}}
{{- define "gym-booker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gym-booker.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "gym-booker.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "gym-booker.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "gym-booker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gym-booker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
