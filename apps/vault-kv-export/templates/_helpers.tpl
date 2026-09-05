{{/*
Expand the name of the chart.
*/}}
{{- define "vault-kv-export.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vault-kv-export.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "vault-kv-export.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "vault-kv-export.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "vault-kv-export.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vault-kv-export.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
