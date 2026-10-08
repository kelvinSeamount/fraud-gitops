{{/* ==========================================================================
     Shared definitions. No Kubernetes objects here.

     The most important job: decide WHAT THIS THING IS CALLED, once, so that
     every file agrees. If the Deployment and the Service disagree about the
     name by even one character, the Service points at nothing — and the only
     symptom is "connection refused" with everything appearing healthy.
     ========================================================================== */}}

{{/* The short name. Overridable, defaults to the chart name. */}}
{{- define "fraud-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* The full name — what objects are actually called.

     Three cases:
       1. fullnameOverride set   -> use it exactly. Every service here does
                                    this, because dashboards and other services
                                    refer to these names.
       2. release contains name  -> do not repeat it ("scoring-scoring")
       3. otherwise              -> release-name

     trunc 63 is not cosmetic: Kubernetes rejects names over 63 characters,
     and the error appears at install time, not while writing the file.        */}}
{{- define "fraud-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Chart name and version, for the labels below. */}}
{{- define "fraud-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* ── LABELS ────────────────────────────────────────────────────────────────
     Two sets, and the difference is critical.

     SELECTOR labels are how a Service finds its pods. They are written into
     the Deployment's matching rule, which Kubernetes treats as PERMANENT —
     changing one later is rejected outright and the app must be deleted and
     recreated. So they contain only things that never change: name and release.

     COMMON labels include the version, which changes on every release. They
     are informational — safe to change, useful for filtering.

     Putting the version in the selector is a classic mistake: the first
     upgrade fails with "field is immutable" and the only way out is deleting
     the application.                                                          */}}

{{- define "fraud-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fraud-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "fraud-service.labels" -}}
helm.sh/chart: {{ include "fraud-service.chart" . }}
{{ include "fraud-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fraud-platform
{{- end }}

{{/* Which identity the pod runs as. */}}
{{- define "fraud-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fraud-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Names for the two config holders. Kept apart because the mechanism that
     loads environment variables requires every key to be a valid variable
     name — and a filename like "index.html" is not one. One mixed holder
     breaks the entire set, silently. */}}
{{- define "fraud-service.envConfigName" -}}
{{- printf "%s-env" (include "fraud-service.fullname" .) }}
{{- end }}

{{- define "fraud-service.filesConfigName" -}}
{{- printf "%s-files" (include "fraud-service.fullname" .) }}
{{- end }}
