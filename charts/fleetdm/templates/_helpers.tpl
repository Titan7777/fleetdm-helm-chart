{{- define "fleetdm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fleetdm.fullname" -}}
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

{{- define "fleetdm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "fleetdm.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "fleetdm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fleetdm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "fleetdm.mysql.fullname" -}}
{{- printf "%s-mysql" (include "fleetdm.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fleetdm.redis.fullname" -}}
{{- printf "%s-redis" (include "fleetdm.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fleetdm.mysql.address" -}}
{{- if .Values.mysql.enabled }}
{{- printf "%s:3306" (include "fleetdm.mysql.fullname" .) }}
{{- else }}
{{- required "mysql.external.address is required when mysql.enabled=false" .Values.mysql.external.address }}
{{- end }}
{{- end }}

{{- define "fleetdm.redis.address" -}}
{{- if .Values.redis.enabled }}
{{- printf "%s:6379" (include "fleetdm.redis.fullname" .) }}
{{- else }}
{{- required "redis.external.address is required when redis.enabled=false" .Values.redis.external.address }}
{{- end }}
{{- end }}

{{- define "fleetdm.secretName" -}}
{{- default (include "fleetdm.fullname" .) .Values.fleet.existingSecret }}
{{- end }}

{{- define "fleetdm.mysql.secretName" -}}
{{- default (include "fleetdm.mysql.fullname" .) .Values.mysql.auth.existingSecret }}
{{- end }}

{{- define "fleetdm.tls.secretName" -}}
{{- default (printf "%s-tls" (include "fleetdm.fullname" .)) .Values.fleet.tls.existingSecret }}
{{- end }}

{{/*
Base64 value for a generated secret key: the explicit value if given, else
whatever is already stored in the cluster, else a fresh random string. The
lookup keeps credentials stable across `helm upgrade`.
Usage: include "fleetdm.secretValue" (dict "ctx" $ "secret" name "key" key "value" .Values.x "length" 32)
*/}}
{{- define "fleetdm.secretValue" -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .secret }}
{{- if .value }}
{{- .value | b64enc }}
{{- else if and $existing $existing.data (hasKey $existing.data .key) }}
{{- index $existing.data .key }}
{{- else }}
{{- randAlphaNum .length | b64enc }}
{{- end }}
{{- end }}

{{/* Fleet configuration shared by the server and the migration initContainer. */}}
{{- define "fleetdm.env" -}}
- name: FLEET_MYSQL_ADDRESS
  value: {{ include "fleetdm.mysql.address" . | quote }}
- name: FLEET_MYSQL_DATABASE
  value: {{ .Values.mysql.auth.database | quote }}
- name: FLEET_MYSQL_USERNAME
  value: {{ .Values.mysql.auth.username | quote }}
- name: FLEET_MYSQL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "fleetdm.mysql.secretName" . }}
      key: mysql-password
- name: FLEET_REDIS_ADDRESS
  value: {{ include "fleetdm.redis.address" . | quote }}
- name: FLEET_SERVER_ADDRESS
  value: "0.0.0.0:8080"
- name: FLEET_SERVER_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "fleetdm.secretName" . }}
      key: server-private-key
- name: FLEET_SERVER_TLS
  value: {{ .Values.fleet.tls.enabled | quote }}
{{- if .Values.fleet.tls.enabled }}
- name: FLEET_SERVER_CERT
  value: /etc/fleet/tls/tls.crt
- name: FLEET_SERVER_KEY
  value: /etc/fleet/tls/tls.key
{{- end }}
- name: FLEET_LOGGING_JSON
  value: "true"
{{- with .Values.fleet.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "fleetdm.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end }}
