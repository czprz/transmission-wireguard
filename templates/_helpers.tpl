{{- define "twg.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "twg.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "twg.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "twg.wgSecretName" -}}
{{- if .Values.wireguard.existingSecret -}}
{{- .Values.wireguard.existingSecret -}}
{{- else -}}
{{- printf "%s-wg" (include "twg.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "twg.wireguardImage" -}}
{{- $repo := default "ghcr.io/linuxserver/wireguard" .Values.images.wireguard.repository -}}
{{- $tag := default "1.0.20250521-r1-ls102" .Values.images.wireguard.tag -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}

{{- define "twg.transmissionImage" -}}
{{- $repo := default "lscr.io/linuxserver/transmission" .Values.images.transmission.repository -}}
{{- $tag := default "4.1.0-r0-ls329" .Values.images.transmission.tag -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
