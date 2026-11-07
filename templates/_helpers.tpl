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

{{- define "twg.rpcSecretName" -}}
{{- if .Values.transmission.rpcAuth.existingSecret -}}
{{- .Values.transmission.rpcAuth.existingSecret -}}
{{- else if and .Values.transmission.rpcAuth.username .Values.transmission.rpcAuth.password -}}
{{- printf "%s-rpc" (include "twg.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. The default tag is pinned by digest; an explicit digest
always wins, and overriding repository or tag drops the default digest.
*/}}
{{- define "twg.image" -}}
{{- $img := .img -}}
{{- $ref := printf "%s:%s" (default .repo $img.repository) (default .tag $img.tag) -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else if and (not $img.repository) (not $img.tag) -}}
{{- printf "%s@%s" $ref .digest -}}
{{- else -}}
{{- $ref -}}
{{- end -}}
{{- end -}}

{{- define "twg.wireguardImage" -}}
{{- $tag := default "1.0.20250521-r1-ls102" .Values.images.wireguard.tag -}}
{{- $digest := default "sha256:72a3c0b6eb67bcecf0138092a7a66220c081246083c7f1e0d078c186560e745b" .Values.images.wireguard.digest -}}
{{- include "twg.image" (dict "img" .Values.images.wireguard "repo" "ghcr.io/linuxserver/wireguard" "tag" $tag "digest" $digest) -}}
{{- end -}}

{{- define "twg.transmissionImage" -}}
{{- $tag := default "4.1.1-r1-ls343" .Values.images.transmission.tag -}}
{{- $digest := default "sha256:62a88fbc210fc62d867eab9c67a0f5474db7257013ce598173a9efc1043e97b8" .Values.images.transmission.digest -}}
{{- include "twg.image" (dict "img" .Values.images.transmission "repo" "lscr.io/linuxserver/transmission" "tag" $tag "digest" $digest) -}}
{{- end -}}

{{- define "twg.peerPort" -}}
{{- index .Values.transmission.settings "peer-port" | default 51413 | int -}}
{{- end -}}

{{/*
VPN endpoints as a JSON list of {ip, port}: wireguard.endpoints plus every
Endpoint line parsed from an inline wg0Conf.
*/}}
{{- define "twg.vpnEndpoints" -}}
{{- $out := list -}}
{{- range .Values.wireguard.endpoints -}}
{{- $out = append $out (dict "ip" (required "wireguard.endpoints[].ip is required" .ip) "port" (int (default 51820 .port))) -}}
{{- end -}}
{{- if .Values.wireguard.wg0Conf -}}
{{- range regexFindAll "(?mi)^[ \\t]*Endpoint[ \\t]*=[ \\t]*[^ \\t\\r\\n#]+" .Values.wireguard.wg0Conf -1 -}}
{{- $ep := regexReplaceAll "(?i)^[ \\t]*Endpoint[ \\t]*=[ \\t]*" . "" -}}
{{- $host := regexReplaceAll "^\\[?(.*?)\\]?:[0-9]+$" $ep "${1}" -}}
{{- $port := regexReplaceAll "^.*:([0-9]+)$" $ep "${1}" -}}
{{- if not (regexMatch "^([0-9]{1,3}(\\.[0-9]{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*)$" $host) -}}
{{- fail (printf "wireguard.wg0Conf Endpoint %s must be an IP address because DNS is blocked until the tunnel is up" $host) -}}
{{- end -}}
{{- $out = append $out (dict "ip" $host "port" (int $port)) -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{- define "twg.validate" -}}
{{- if not (or .Values.wireguard.existingSecret .Values.wireguard.wg0Conf) -}}
{{- fail "wireguard.wg0Conf or wireguard.existingSecret must be set" -}}
{{- end -}}
{{- with .Values.wireguard.wg0Conf -}}
{{- if and (not $.Values.firewall.allowConfFirewallHooks) (regexMatch "(?mi)^[ \\t]*(PreUp|PostUp|PreDown|PostDown)[ \\t]*=.*(iptables|ip6tables|nft)" .) -}}
{{- fail "wireguard.wg0Conf has iptables/nft commands in PreUp/PostUp/PreDown/PostDown. The chart manages the kill switch, remove them." -}}
{{- end -}}
{{- if not (regexMatch "(?mi)^[ \\t]*AllowedIPs[ \\t]*=.*(0\\.0\\.0\\.0/0|::/0)" .) -}}
{{- fail "wireguard.wg0Conf AllowedIPs must include 0.0.0.0/0 (full tunnel)" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (eq (include "twg.vpnEndpoints" . | fromJsonArray | len) 0) -}}
{{- fail "networkPolicy.enabled needs the VPN endpoint. Set wireguard.endpoints (ip and port of your Endpoint), or disable networkPolicy if your CNI does not enforce it" -}}
{{- end -}}
{{- $exposed := or .Values.ingress.enabled (ne .Values.service.type "ClusterIP") -}}
{{- if and $exposed (not (include "twg.rpcSecretName" .)) (not .Values.transmission.rpcAuth.allowAnonymous) -}}
{{- fail "The web UI is exposed (ingress or non-ClusterIP Service) without RPC auth. Set transmission.rpcAuth.existingSecret (or username/password), or rpcAuth.allowAnonymous=true" -}}
{{- end -}}
{{- end -}}
