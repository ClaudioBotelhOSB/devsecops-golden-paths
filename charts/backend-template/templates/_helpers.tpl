{{/*
Reusable helpers for any containerized workload.

Nothing in this file references a specific stack, language, port,
framework, or owner. Anything that would otherwise be opinionated is
sourced from .Values so a downstream chart user can override it at
install time.
*/}}

{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- if and .Values.global .Values.global.owner }}
platform.io/owner: {{ .Values.global.owner | quote }}
{{- end }}
{{- if and .Values.global .Values.global.extraLabels }}
{{ toYaml .Values.global.extraLabels }}
{{- end }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
app.image renders the image reference. If image.digest is set, the
reference is digest-pinned (required by the Kyverno admission policy);
otherwise it falls back to image.tag so `helm template` stays usable
locally. image.repository is mandatory.
*/}}
{{- define "app.image" -}}
{{- $repo   := required "image.repository is required" .Values.image.repository -}}
{{- $tag    := .Values.image.tag    | default "latest" -}}
{{- $digest := .Values.image.digest | default "" -}}
{{- if $digest -}}
{{ printf "%s@%s" $repo $digest }}
{{- else -}}
{{ printf "%s:%s" $repo $tag }}
{{- end -}}
{{- end -}}

{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "app.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
