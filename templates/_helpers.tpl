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

{{- define "twg.testImage" -}}
{{- $tag := default "1.34.1" .Values.tests.image.tag -}}
{{- $digest := default "sha256:8413f8890d19aa03f63851654f642957e65ba59654b0c9357ddc6ec0b05b63a6" .Values.tests.image.digest -}}
{{- include "twg.image" (dict "img" .Values.tests.image "repo" "docker.io/alpine/kubectl" "tag" $tag "digest" $digest) -}}
{{- end -}}

{{- define "twg.transmissionImage" -}}
{{- $tag := default "4.1.1-r1-ls343" .Values.images.transmission.tag -}}
{{- $digest := default "sha256:62a88fbc210fc62d867eab9c67a0f5474db7257013ce598173a9efc1043e97b8" .Values.images.transmission.digest -}}
{{- include "twg.image" (dict "img" .Values.images.transmission "repo" "lscr.io/linuxserver/transmission" "tag" $tag "digest" $digest) -}}
{{- end -}}

{{- define "twg.peerPort" -}}
{{- index .Values.transmission.settings "peer-port" | default 51413 | int -}}
{{- end -}}

{{- define "twg.ipPattern" -}}
^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$|^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*$
{{- end -}}

{{/*
VPN endpoints as a JSON list of {ip, port}: wireguard.endpoints plus every
Endpoint line parsed from an inline wg0Conf.
*/}}
{{- define "twg.vpnEndpoints" -}}
{{- $out := list -}}
{{- range .Values.wireguard.endpoints -}}
{{- $ip := required "wireguard.endpoints[].ip is required" .ip | toString -}}
{{- $port := int (default 51820 .port) -}}
{{- if not (regexMatch (include "twg.ipPattern" $) $ip) -}}
{{- fail (printf "wireguard.endpoints ip %s must be an IP address" $ip) -}}
{{- end -}}
{{- if or (lt $port 1) (gt $port 65535) -}}
{{- fail (printf "wireguard.endpoints port %d must be between 1 and 65535" $port) -}}
{{- end -}}
{{- $out = append $out (dict "ip" $ip "port" $port) -}}
{{- end -}}
{{- if .Values.wireguard.wg0Conf -}}
{{- range regexFindAll "(?mi)^[ \\t]*Endpoint[ \\t]*=[ \\t]*[^ \\t\\r\\n#]+" .Values.wireguard.wg0Conf -1 -}}
{{- $ep := regexReplaceAll "(?i)^[ \\t]*Endpoint[ \\t]*=[ \\t]*" . "" -}}
{{- if not (regexMatch ":[0-9]{1,5}$" $ep) -}}
{{- fail (printf "wireguard.wg0Conf Endpoint %s needs a port (ip and port, e.g. 203.0.113.10 then 51820)" $ep) -}}
{{- end -}}
{{- $host := regexReplaceAll "^\\[?(.*?)\\]?:[0-9]+$" $ep "${1}" -}}
{{- $port := regexReplaceAll "^.*:([0-9]+)$" $ep "${1}" | int -}}
{{- if not (regexMatch (include "twg.ipPattern" $) $host) -}}
{{- fail (printf "wireguard.wg0Conf Endpoint %s must be an IP address because DNS is blocked until the tunnel is up" $host) -}}
{{- end -}}
{{- if or (lt $port 1) (gt $port 65535) -}}
{{- fail (printf "wireguard.wg0Conf Endpoint port %d must be between 1 and 65535" $port) -}}
{{- end -}}
{{- $out = append $out (dict "ip" $host "port" $port) -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/* RPC auth is configured through rpcAuth or, the pre-1.0 way, settings. */}}
{{- define "twg.rpcAuthConfigured" -}}
{{- $s := .Values.transmission.settings -}}
{{- if or (include "twg.rpcSecretName" .) (and (index $s "rpc-authentication-required") (index $s "rpc-username") (index $s "rpc-password")) -}}
true
{{- end -}}
{{- end -}}

{{- define "twg.validate" -}}
{{- if not (or .Values.wireguard.existingSecret .Values.wireguard.wg0Conf) -}}
{{- fail "wireguard.wg0Conf or wireguard.existingSecret must be set" -}}
{{- end -}}
{{- with .Values.wireguard.wg0Conf -}}
{{- if and (not $.Values.firewall.allowConfHooks) (regexMatch "(?mi)^[ \\t]*(PreUp|PostUp|PreDown|PostDown)[ \\t]*=" .) -}}
{{- fail "wireguard.wg0Conf has PreUp/PostUp/PreDown/PostDown hooks. They run as root and can open the kill switch, so remove them or set firewall.allowConfHooks" -}}
{{- end -}}
{{- $allowed := list -}}
{{- range regexFindAll "(?mi)^[ \\t]*AllowedIPs[ \\t]*=[^#\\r\\n]*" . -1 -}}
{{- $allowed = concat $allowed (regexSplit "[ \\t,]+" (regexReplaceAll "(?i)^[ \\t]*AllowedIPs[ \\t]*=" . "") -1) -}}
{{- end -}}
{{- if not (has "0.0.0.0/0" $allowed) -}}
{{- fail "wireguard.wg0Conf AllowedIPs must include 0.0.0.0/0 (full tunnel)" -}}
{{- end -}}
{{- range regexFindAll "(?mi)^[ \\t]*Table[ \\t]*=[ \\t]*[^ \\t\\r\\n#]+" . -1 -}}
{{- if not (regexMatch "(?i)=[ \\t]*auto$" .) -}}
{{- fail "wireguard.wg0Conf sets Table, which turns off the fwmark routing the kill switch relies on. Remove it." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (eq (include "twg.vpnEndpoints" . | fromJsonArray | len) 0) -}}
{{- fail "networkPolicy.enabled needs the VPN endpoint. Set wireguard.endpoints (ip and port of your Endpoint), or disable networkPolicy if your CNI does not enforce it" -}}
{{- end -}}
{{- with .Values.transmission.rpcAuth -}}
{{- if and (not .existingSecret) (or .username .password) (not (and .username .password)) -}}
{{- fail "transmission.rpcAuth needs both username and password (or existingSecret)" -}}
{{- end -}}
{{- end -}}
{{- $exposed := or .Values.ingress.enabled (ne .Values.service.type "ClusterIP") -}}
{{- if and $exposed (not (include "twg.rpcAuthConfigured" .)) (not .Values.transmission.rpcAuth.allowAnonymous) -}}
{{- fail "The web UI is exposed (ingress or non-ClusterIP Service) without RPC auth. Set transmission.rpcAuth.existingSecret (or username/password), or rpcAuth.allowAnonymous=true. Credentials in transmission.settings also work but belong in rpcAuth" -}}
{{- end -}}
{{- $s := .Values.transmission.settings -}}
{{- if and (hasKey $s "rpc-port") (ne (int (index $s "rpc-port")) (int .Values.service.webPort)) -}}
{{- fail (printf "transmission.settings rpc-port (%v) must equal service.webPort (%v), the only port the kill switch opens to the cluster" (index $s "rpc-port") .Values.service.webPort) -}}
{{- end -}}
{{- if index $s "peer-port-random-on-start" -}}
{{- fail "transmission.settings peer-port-random-on-start must be false. The kill switch only accepts peers on the fixed peer-port" -}}
{{- end -}}
{{- if .Values.firewall.allowConfFirewallHooks -}}
{{- fail "firewall.allowConfFirewallHooks was renamed to firewall.allowConfHooks and now covers every PreUp/PostUp/PreDown/PostDown hook" -}}
{{- end -}}
{{- if .Values.service.exposePeerPorts -}}
{{- fail "service.exposePeerPorts was removed. Peers can only reach Transmission through the VPN, never through the Service" -}}
{{- end -}}
{{- with .Values.transmission.securityContext -}}
{{- $caps := list -}}
{{- with .capabilities }}{{ $caps = default list .add }}{{ end -}}
{{- if or .privileged (has "NET_ADMIN" $caps) (has "NET_RAW" $caps) (has "SYS_ADMIN" $caps) (has "ALL" $caps) -}}
{{- fail "transmission.securityContext must not be privileged or add NET_ADMIN, NET_RAW, SYS_ADMIN or ALL. These would let Transmission bypass the kill switch" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.wireguard.dns.override (not .Values.wireguard.dns.nameservers) -}}
{{- fail "wireguard.dns.override needs at least one entry in wireguard.dns.nameservers" -}}
{{- end -}}
{{- end -}}
