{{- /*
Names: <release>-<chart>, as since 0.x (never shortened when the release name
contains the chart name, which would rename existing releases' PVCs).
fullnameOverride replaces it; nameOverride replaces the chart part and
app.kubernetes.io/name, which is in the Deployment's immutable selector, so
set it at install only.
*/ -}}
{{- define "twg.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "twg.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "twg.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "twg.labels" -}}
{{- include "twg.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- with omit (.Values.commonLabels | default dict) "app.kubernetes.io/name" "app.kubernetes.io/instance" }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "twg.selectorLabels" -}}
app.kubernetes.io/name: {{ include "twg.name" . }}
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
{{- else if or (and .Values.transmission.rpcAuth.username .Values.transmission.rpcAuth.password) (include "twg.legacyRpcAuth" .) -}}
{{- printf "%s-rpc" (include "twg.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
"true" for RPC credentials set the old way, in transmission.settings: they
go into the chart's Secret like rpcAuth's, never into the ConfigMap or the
pod spec.
*/}}
{{- define "twg.legacyRpcAuth" -}}
{{- $s := .Values.transmission.settings -}}
{{- $a := .Values.transmission.rpcAuth -}}
{{- if and (not $a.existingSecret) (not (and $a.username $a.password)) (eq (toString (index $s "rpc-authentication-required")) "true") (index $s "rpc-username") (index $s "rpc-password") -}}
true
{{- end -}}
{{- end -}}

{{/*
Image reference. The default tag is pinned by digest; an explicit digest
always wins, and overriding repository or tag drops the default digest.
*/}}
{{- define "twg.image" -}}
{{- $img := .img -}}
{{- $tag := default .tag $img.tag -}}
{{- $ref := default .repo $img.repository -}}
{{- if $tag }}{{ $ref = printf "%s:%s" $ref $tag }}{{ end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else if and (not $img.repository) (not $img.tag) .digest -}}
{{- printf "%s@%s" $ref .digest -}}
{{- else -}}
{{- $ref -}}
{{- end -}}
{{- end -}}

{{- define "twg.wireguardImage" -}}
{{- $tag := default "1.0.20260223-20261119" .Values.images.wireguard.tag -}}
{{- $digest := default "sha256:bb36c8f42b41d7fcc2937f5ff0e6278949a7677af73b7feb8613d1cea44e1752" .Values.images.wireguard.digest -}}
{{- include "twg.image" (dict "img" .Values.images.wireguard "repo" "ghcr.io/czprz/twg-wireguard" "tag" $tag "digest" $digest) -}}
{{- end -}}

{{- define "twg.testImage" -}}
{{- $tag := default "1.34.1" .Values.tests.image.tag -}}
{{- $digest := default "sha256:8413f8890d19aa03f63851654f642957e65ba59654b0c9357ddc6ec0b05b63a6" .Values.tests.image.digest -}}
{{- include "twg.image" (dict "img" .Values.tests.image "repo" "docker.io/alpine/kubectl" "tag" $tag "digest" $digest) -}}
{{- end -}}

{{/* The Transmission image of the chosen flavor. */}}
{{- define "twg.transmissionImageRef" -}}
{{- if eq (include "twg.transmissionFlavor" .) "minimal" -}}
{{- /* The minimal image's default, on one line (Renovate's twg-transmission
manager reads it). Through $img: tests/e2e/docker/helpers.bash finds the
linuxserver default by ".Values.images.transmission "repo"". */ -}}
{{- $img := .Values.images.transmission -}}
{{- include "twg.image" (dict "img" $img "repo" "ghcr.io/czprz/twg-transmission" "tag" "4.1.2-20261119" "digest" "sha256:a45b186c448a88cdde3afd7275ec82a25c601bf5b8303d81d8512d4b9c48f87f") -}}
{{- else -}}
{{- include "twg.transmissionImage" . -}}
{{- end -}}
{{- end -}}

{{- define "twg.transmissionImage" -}}
{{- $tag := default "4.1.3-r0-ls365" .Values.images.transmission.tag -}}
{{- $digest := default "sha256:55aaeedf9fc354d34136387e15ee0ba4679096f20398dd2875867e5cd5cf8be5" .Values.images.transmission.digest -}}
{{- include "twg.image" (dict "img" .Values.images.transmission "repo" "lscr.io/linuxserver/transmission" "tag" $tag "digest" $digest) -}}
{{- end -}}

{{- define "twg.transmissionFlavor" -}}
{{- .Values.images.transmission.flavor | default "linuxserver" -}}
{{- end -}}

{{/*
The Transmission container's securityContext. The minimal image needs no
capabilities back and runs as PUID/PGID with a read-only root filesystem.
*/}}
{{- define "twg.transmissionSecurityContext" -}}
{{- $sc := deepCopy .Values.transmission.securityContext -}}
{{- if eq (include "twg.transmissionFlavor" .) "minimal" -}}
{{- $caps := omit (default dict $sc.capabilities) "add" -}}
{{- $_ := set $sc "capabilities" $caps -}}
{{- $_ := set $sc "runAsUser" (.Values.transmission.env.PUID | default "1000" | int64) -}}
{{- $_ := set $sc "runAsGroup" (.Values.transmission.env.PGID | default "1000" | int64) -}}
{{- $_ := set $sc "runAsNonRoot" true -}}
{{- $_ := set $sc "readOnlyRootFilesystem" true -}}
{{- end -}}
{{- toYaml $sc -}}
{{- end -}}

{{/* A mark in decimal or 0x hex as a decimal string, or "" if it is not one. */}}
{{- define "twg.markValue" -}}
{{- $m := ternary (int64 .) . (kindIs "float64" .) | toString | lower -}}
{{- if regexMatch "^[1-9][0-9]{0,9}$" $m -}}
{{- int64 $m -}}
{{- else if regexMatch "^0x[0-9a-f]{1,8}$" $m -}}
{{- $digits := dict "0" 0 "1" 1 "2" 2 "3" 3 "4" 4 "5" 5 "6" 6 "7" 7 "8" 8 "9" 9 "a" 10 "b" 11 "c" 12 "d" 13 "e" 14 "f" 15 -}}
{{- $v := 0 -}}
{{- range splitList "" (trimPrefix "0x" $m) }}{{ $v = add (mul $v 16) (index $digits .) }}{{ end -}}
{{- if $v }}{{ $v }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "twg.peerPort" -}}
{{- index .Values.transmission.settings "peer-port" | default 51413 | int -}}
{{- end -}}

{{- define "twg.ipPattern" -}}
^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$|^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}$
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
{{- range .Values.wireguard.failover.peers -}}
{{- $ip := .ip | toString -}}
{{- if not (regexMatch (include "twg.ipPattern" $) $ip) -}}
{{- fail (printf "wireguard.failover.peers ip %s must be an IP address because DNS is blocked until the tunnel is up" $ip) -}}
{{- end -}}
{{- $out = append $out (dict "ip" $ip "port" (int (default 51820 .port))) -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/* The failover peers as firewall.sh reads them: "publickey@endpoint" words. */}}
{{- define "twg.failoverPeers" -}}
{{- $out := list -}}
{{- range .Values.wireguard.failover.peers -}}
{{- $ip := .ip | toString -}}
{{- $host := ternary (printf "[%s]" $ip) $ip (contains ":" $ip) -}}
{{- $out = append $out (printf "%s@%s:%d" .publicKey $host (int (default 51820 .port))) -}}
{{- end -}}
{{- join " " $out -}}
{{- end -}}

{{/* RPC auth is configured through rpcAuth or, the pre-1.0 way, settings. */}}
{{- define "twg.rpcAuthConfigured" -}}
{{- $s := .Values.transmission.settings -}}
{{- /* Only a real true: Transmission reads the string "false" as false. */ -}}
{{- if or (include "twg.rpcSecretName" .) (and (eq (toString (index $s "rpc-authentication-required")) "true") (index $s "rpc-username") (index $s "rpc-password")) -}}
true
{{- end -}}
{{- end -}}

{{- define "twg.validate" -}}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) -}}
{{- fail "ingress.enabled needs ingress.hosts. An Ingress without rules routes nothing" -}}
{{- end -}}
{{- if and .Values.wireguard.portForwarding.natpmpGateway (gt (int .Values.probes.liveness.periodSeconds) 45) -}}
{{- fail (printf "probes.liveness.periodSeconds %v is too long for port forwarding. The liveness probe renews the NAT-PMP mapping, which gateways keep for 60 s, so it must run at least every 45 s" .Values.probes.liveness.periodSeconds) -}}
{{- end -}}
{{- if and .Values.issuer.enabled .Values.httpRoute.enabled (not .Values.ingress.enabled) (ne (default "Issuer" .Values.issuer.kind) "ClusterIssuer") -}}
{{- range .Values.httpRoute.parentRefs -}}
{{- if and .namespace (ne .namespace $.Release.Namespace) -}}
{{- fail (printf "issuer.kind Issuer can't issue the certificate for Gateway %s in namespace %s. cert-manager looks for a namespaced Issuer in the Gateway's own namespace, so set issuer.kind to ClusterIssuer" .name .namespace) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.issuer.enabled (not .Values.ingress.enabled) (not .Values.httpRoute.enabled) -}}
{{- fail "issuer.enabled needs ingress.enabled or httpRoute.enabled. Its HTTP-01 solver answers challenges through one of them" -}}
{{- end -}}
{{- $dataPath := include "twg.dataPath" . -}}
{{- $mounts := list $dataPath "/config" -}}
{{- range .Values.transmission.extraVolumeMounts }}{{ $mounts = append $mounts (trimSuffix "/" .mountPath) }}{{ end -}}
{{- $settings := include "twg.settings" . | fromJson -}}
{{- range $k := list "download-dir" "incomplete-dir" "watch-dir" -}}
{{- $d := index $settings $k | default "" | toString -}}
{{- if and $d (or (ne $k "incomplete-dir") (index $settings "incomplete-dir-enabled")) (or (ne $k "watch-dir") (index $settings "watch-dir-enabled")) -}}
{{- $ok := false -}}
{{- range $mounts }}{{ if or (eq $d .) (hasPrefix (printf "%s/" .) $d) }}{{ $ok = true }}{{ end }}{{ end -}}
{{- if not $ok -}}
{{- fail (printf "transmission.settings.%s %s is not on a volume (%s or a transmission.extraVolumeMounts path), so its files would go to the container's own layer and be lost on restart" $k $d $dataPath) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq (include "twg.transmissionFlavor" .) "minimal" -}}
{{- range $k := list "PUID" "PGID" -}}
{{- $v := index $.Values.transmission.env $k | default "1000" | toString -}}
{{- if not (regexMatch "^[1-9][0-9]*$" $v) -}}
{{- fail (printf "transmission.env.%s %s must be a positive number with images.transmission.flavor=minimal, which runs Transmission as that user (never root)" $k $v) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- with .Values.images.wireguard -}}
{{- if and .repository (not .tag) (not .digest) -}}
{{- fail (printf "images.wireguard.repository %s needs images.wireguard.tag or digest as well. The chart's default tag is for its own image (ghcr.io/czprz/twg-wireguard) and doesn't exist in another repository" .repository) -}}
{{- end -}}
{{- if and .tag (not .repository) (regexMatch "-ls[0-9]+$" (toString .tag)) -}}
{{- fail (printf "images.wireguard.tag %s is a linuxserver tag, but the default sidecar image is now ghcr.io/czprz/twg-wireguard. Remove the tag, or set images.wireguard.repository to ghcr.io/linuxserver/wireguard to keep that image" (toString .tag)) -}}
{{- end -}}
{{- end -}}
{{- if not (or .Values.wireguard.existingSecret .Values.wireguard.wg0Conf) -}}
{{- fail "wireguard.wg0Conf or wireguard.existingSecret must be set" -}}
{{- end -}}
{{- if and .Values.wireguard.existingSecret .Values.wireguard.wg0Conf -}}
{{- fail "set only one of wireguard.wg0Conf and wireguard.existingSecret. The pod uses the Secret, so wg0Conf would only feed the checks and the NetworkPolicy" -}}
{{- end -}}
{{- $mark := include "twg.markValue" .Values.firewall.wgFwmark -}}
{{- if or (not $mark) (gt (int64 $mark) 4294967295) -}}
{{- fail (printf "firewall.wgFwmark %v must be between 1 and 4294967295" .Values.firewall.wgFwmark) -}}
{{- end -}}
{{- if has $mark (list "253" "254" "255" "1000") -}}
{{- fail (printf "firewall.wgFwmark %v is also the routing table wg-quick uses, and 253-255 (system tables) and 1000 (the chart's saved route) are taken" .Values.firewall.wgFwmark) -}}
{{- end -}}
{{- if eq (mod (div (int64 $mark) 268435456) 2) 1 -}}
{{- fail (printf "firewall.wgFwmark %v must not set bit 0x10000000, which marks connections from the cluster" .Values.firewall.wgFwmark) -}}
{{- end -}}
{{- with .Values.wireguard.wg0Conf -}}
{{- if and (not $.Values.firewall.allowConfHooks) (regexMatch "(?mi)^[ \\t]*(PreUp|PostUp|PreDown|PostDown)[ \\t]*=" .) -}}
{{- fail "wireguard.wg0Conf has PreUp/PostUp/PreDown/PostDown hooks. They run as root and can open the kill switch, so remove them or set firewall.allowConfHooks" -}}
{{- end -}}
{{- $allowed := list -}}
{{- range regexFindAll "(?mi)^[ \\t]*AllowedIPs[ \\t]*=[^#\\r\\n]*" . -1 -}}
{{- $allowed = concat $allowed (regexSplit "[ \\t,]+" (regexReplaceAll "(?i)^[ \\t]*AllowedIPs[ \\t]*=" . "") -1) -}}
{{- end -}}
{{- if contains ":" (join "," $allowed) -}}
{{- $addrs := list -}}
{{- range regexFindAll "(?mi)^[ \\t]*Address[ \\t]*=[^#\\r\\n]*" . -1 }}{{ $addrs = append $addrs . }}{{ end -}}
{{- if not (contains ":" (regexReplaceAll "(?i)Address[ \\t]*=" (join "," $addrs) "")) -}}
{{- fail "wireguard.wg0Conf AllowedIPs has IPv6 ranges but Address has no IPv6 address. Add one, or drop the IPv6 ranges so IPv6 is blocked (otherwise the pod's own IPv6 address would reach the VPN)" -}}
{{- end -}}
{{- end -}}
{{- if not (has "0.0.0.0/0" $allowed) -}}
{{- fail "wireguard.wg0Conf AllowedIPs must include 0.0.0.0/0 (full tunnel). Halves such as 0.0.0.0/1 + 128.0.0.0/1 do not work, because wg-quick only sets up the fwmark routing the kill switch relies on for /0" -}}
{{- end -}}
{{- range regexFindAll "(?mi)^[ \\t]*Table[ \\t]*=[ \\t]*[^ \\t\\r\\n#]+" . -1 -}}
{{- if not (regexMatch "(?i)=[ \\t]*auto$" .) -}}
{{- fail "wireguard.wg0Conf sets Table, which turns off the fwmark routing the kill switch relies on. Remove it." -}}
{{- end -}}
{{- end -}}
{{- $want := include "twg.markValue" $.Values.firewall.wgFwmark -}}
{{- $fwmarks := regexFindAll "(?mi)^[ \\t]*FwMark[ \\t]*=[ \\t]*[^ \\t\\r\\n#]+" . -1 -}}
{{- if and (not $fwmarks) (ne $want "51820") -}}
{{- fail (printf "firewall.wgFwmark is %s but wireguard.wg0Conf has no FwMark line, so wg-quick would use 51820. Add FwMark = %s to [Interface]" $want $want) -}}
{{- end -}}
{{- range $fwmarks -}}
{{- $mark := regexReplaceAll "(?i)^[ \\t]*FwMark[ \\t]*=[ \\t]*" . "" -}}
{{- if ne (include "twg.markValue" $mark) $want -}}
{{- fail (printf "wireguard.wg0Conf FwMark %s differs from firewall.wgFwmark (%v). Remove it or make them equal" $mark $.Values.firewall.wgFwmark) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /* Parsed even without the NetworkPolicy: a bad Endpoint fails here, not at runtime. */ -}}
{{- $endpoints := include "twg.vpnEndpoints" . | fromJsonArray -}}
{{- with .Values.wireguard.wg0Conf -}}
{{- $addrs := list -}}
{{- range regexFindAll "(?mi)^[ \\t]*Address[ \\t]*=[^#\\r\\n]*" . -1 }}{{ $addrs = append $addrs (regexReplaceAll "(?i)^[ \\t]*Address[ \\t]*=" . "") }}{{ end -}}
{{- if not (regexMatch "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" (join "," $addrs)) -}}
{{- fail "wireguard.wg0Conf Address has no IPv4 address. Without one, traffic into the tunnel would carry the pod's own IPv4 address to the VPN" -}}
{{- end -}}
{{- end -}}
{{- with .Values.wireguard.failover -}}
{{- if .peers -}}
{{- $max := int64 $.Values.wireguard.handshakeMaxAgeSeconds -}}
{{- if and (gt $max 0) (ge (int64 .afterSeconds) $max) -}}
{{- fail (printf "wireguard.failover.afterSeconds (%d) must be less than wireguard.handshakeMaxAgeSeconds (%d), or the liveness probe restarts the sidecar before it can fail over" (int64 .afterSeconds) $max) -}}
{{- end -}}
{{- with $.Values.wireguard.wg0Conf -}}
{{- if ne (len (regexFindAll "(?mi)^[ \\t]*\\[Peer\\]" . -1)) 1 -}}
{{- fail "wireguard.failover needs exactly one [Peer] in wg0Conf, since it replaces that peer with the next one" -}}
{{- end -}}
{{- if regexMatch "(?mi)^[ \\t]*PresharedKey[ \\t]*=" . -}}
{{- fail "wireguard.failover cannot be used with a PresharedKey in wg0Conf, because the failover peers would need their own" -}}
{{- end -}}
{{- if not (regexMatch "(?mi)^[ \\t]*PersistentKeepalive[ \\t]*=[ \\t]*[1-9]" .) -}}
{{- fail "wireguard.failover needs PersistentKeepalive in wg0Conf. Without it an idle tunnel stops handshaking and would look dead" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (eq (len $endpoints) 0) -}}
{{- fail "networkPolicy.enabled needs the VPN endpoint. Set wireguard.endpoints (ip and port of your Endpoint), or disable networkPolicy if your CNI does not enforce it" -}}
{{- end -}}
{{- with .Values.transmission.rpcAuth -}}
{{- if and (not .existingSecret) (or .username .password) (not (and .username .password)) -}}
{{- fail "transmission.rpcAuth needs both username and password (or existingSecret)" -}}
{{- end -}}
{{- if and .existingSecret (or .username .password) -}}
{{- fail "transmission.rpcAuth sets existingSecret and username/password. The Secret wins, so remove username/password" -}}
{{- end -}}
{{- end -}}
{{- $s := .Values.transmission.settings -}}
{{- if and (hasKey $s "rpc-port") (ne (int (index $s "rpc-port")) (int .Values.service.webPort)) -}}
{{- fail (printf "transmission.settings rpc-port (%v) must equal service.webPort (%v), the only port the kill switch opens to the cluster" (index $s "rpc-port") .Values.service.webPort) -}}
{{- end -}}
{{- if eq (include "twg.peerPort" .) (toString (int .Values.service.webPort)) -}}
{{- fail "transmission.settings peer-port must differ from service.webPort. The kill switch opens the peer port to the VPN side" -}}
{{- end -}}
{{- if or (hasKey $s "bind-address-ipv4") (hasKey $s "bind-address-ipv6") -}}
{{- fail "transmission.settings must not set bind-address-ipv4/ipv6. The chart binds peer sockets to the tunnel address so they cannot use another interface" -}}
{{- end -}}
{{- if not .Values.transmission.bindToTunnel -}}
{{- fail "transmission.bindToTunnel must be true. Unbound peer sockets can learn and announce the pod's own IPv6 address" -}}
{{- end -}}
{{- /*
An allowlist: the sidecar runs as root with NET_ADMIN, its command and probes
are bash, and bash runs code from variables such as BASH_ENV, SHELLOPTS with
PS4, or BASH_FUNC_*, which would be the conf hooks firewall.allowConfHooks
refuses, by another name. TWG_ variables and the image's server mode
(PEERS, ...) are out too.
*/ -}}
{{- range $k, $_ := .Values.wireguard.env -}}
{{- if not (has $k (list "TZ" "PUID" "PGID")) -}}
{{- fail (printf "wireguard.env must not set %s. Only TZ, PUID and PGID are allowed, as anything else reaches the root, NET_ADMIN sidecar's shell (BASH_ENV, SHELLOPTS, ...), the kill switch's own TWG_ settings or the image's server mode" $k) -}}
{{- end -}}
{{- end -}}
{{- $txEnv := list -}}
{{- range $k, $_ := .Values.transmission.env }}{{ $txEnv = append $txEnv (list "transmission.env" $k) }}{{ end -}}
{{- range .Values.transmission.extraEnv }}{{ $txEnv = append $txEnv (list "transmission.extraEnv" (.name | toString)) }}{{ end -}}
{{- range $txEnv -}}
{{- $where := index . 0 -}}
{{- $k := index . 1 -}}
{{- if hasPrefix "TWG_" $k -}}
{{- fail (printf "%s must not set %s. The chart sets every TWG_ variable itself" $where $k) -}}
{{- end -}}
{{- if has $k (list "USER" "PASS") -}}
{{- fail (printf "%s must not set %s. The chart sets USER and PASS from transmission.rpcAuth, so the image can stop Transmission cleanly" $where $k) -}}
{{- end -}}
{{- end -}}
{{- if index $s "peer-port-random-on-start" -}}
{{- fail "transmission.settings peer-port-random-on-start must be false. The kill switch only accepts peers on the fixed peer-port" -}}
{{- end -}}
{{- if .Values.firewall.allowConfFirewallHooks -}}
{{- fail "firewall.allowConfFirewallHooks was renamed to firewall.allowConfHooks and now covers every PreUp/PostUp/PreDown/PostDown hook" -}}
{{- end -}}
{{- if or (hasKey .Values.service "peerPortTcp") (hasKey .Values.service "peerPortUdp") -}}
{{- fail "service.peerPortTcp/peerPortUdp were removed. Peers connect through the VPN to transmission.settings.peer-port (forward it at your provider)" -}}
{{- end -}}
{{- if .Values.service.exposePeerPorts -}}
{{- fail "service.exposePeerPorts was removed. Peers can only reach Transmission through the VPN, never through the Service" -}}
{{- end -}}
{{- /*
Root in the Transmission container (s6 init, kubectl exec) must not be able to
mark packets or touch the network: NET_RAW alone allows SO_MARK and raw
sockets on eth0. So the container drops every capability and adds back only
harmless ones. Without a securityContext the runtime's defaults, which include
NET_RAW, would apply.
*/ -}}
{{- $sc := .Values.transmission.securityContext -}}
{{- if not (kindIs "map" $sc) -}}
{{- fail "transmission.securityContext must be set and drop ALL capabilities. Without it the runtime's default capabilities, including NET_RAW, let root in the container bypass the kill switch" -}}
{{- end -}}
{{- $caps := default dict $sc.capabilities -}}
{{- /* Runtimes only treat a bare ALL (any case) as everything; CAP_ALL drops nothing. */ -}}
{{- $drop := list -}}
{{- range default list $caps.drop }}{{ $drop = append $drop (toString . | upper) }}{{ end -}}
{{- $added := list -}}
{{- range default list $caps.add }}{{ $added = append $added (toString . | upper | trimPrefix "CAP_") }}{{ end -}}
{{- $safe := list "CHOWN" "DAC_OVERRIDE" "FOWNER" "FSETID" "KILL" "SETGID" "SETUID" "SETPCAP" "SETFCAP" "NET_BIND_SERVICE" "SYS_CHROOT" "SYS_NICE" "MKNOD" "AUDIT_WRITE" -}}
{{- if or $sc.privileged (not (has "ALL" $drop)) -}}
{{- fail "transmission.securityContext must drop ALL capabilities (written ALL, not CAP_ALL) and not be privileged. Otherwise root in the container (NET_RAW is enough) can bypass the kill switch" -}}
{{- end -}}
{{- range $added -}}
{{- if not (has . $safe) -}}
{{- fail (printf "transmission.securityContext adds capability %s. Only %s may be added; others (NET_RAW, NET_ADMIN, SYS_ADMIN, ...) can bypass the kill switch" . (join ", " $safe)) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.wireguard.dns.override -}}
{{- fail "wireguard.dns.override=false is no longer supported. Cluster DNS is unreachable through the tunnel and its upstream would see every lookup; set wireguard.dns.nameservers to your VPN's resolvers instead" -}}
{{- end -}}
{{- if not .Values.wireguard.dns.nameservers -}}
{{- fail "wireguard.dns.override needs at least one entry in wireguard.dns.nameservers" -}}
{{- end -}}
{{- if and .Values.persistence.enabled (eq .Values.persistence.type "hostPath") (not (dig "hostPath" "path" "" .Values.persistence)) -}}
{{- fail "persistence.type=hostPath needs persistence.hostPath.path" -}}
{{- end -}}
{{- if and (not (include "twg.rpcAuthConfigured" .)) (not .Values.transmission.rpcAuth.allowAnonymous) -}}
{{- fail "The web UI needs RPC auth. Without it any pod that can reach it can add torrents (linking trackers it controls to your VPN address) and run scripts. Set transmission.rpcAuth.existingSecret (or username/password), or rpcAuth.allowAnonymous=true. Credentials in transmission.settings also work but belong in rpcAuth" -}}
{{- end -}}
{{- end -}}

{{/*
The sidecar's securityContext: wireguard.securityContext, or with
wireguard.unprivileged.enabled, the same without privileged and with
NET_ADMIN + NET_RAW (what the README documents and the Docker suite runs).
*/}}
{{- define "twg.wireguardSecurityContext" -}}
{{- $sc := deepCopy (.Values.wireguard.securityContext | default dict) -}}
{{- if .Values.wireguard.unprivileged.enabled -}}
{{- /* Only what wg-quick and the kill switch need: none of the runtime's
default capabilities (CHOWN, DAC_OVERRIDE, SETUID, ...), no privilege
escalation, the runtime's seccomp profile. */ -}}
{{- $_ := set $sc "privileged" false -}}
{{- $_ := set $sc "allowPrivilegeEscalation" false -}}
{{- $caps := deepCopy ($sc.capabilities | default dict) -}}
{{- $_ := set $caps "drop" (concat (list "ALL") ($caps.drop | default list) | uniq) -}}
{{- $_ := set $caps "add" (concat ($caps.add | default list) (list "NET_ADMIN" "NET_RAW") | uniq) -}}
{{- $_ := set $sc "capabilities" $caps -}}
{{- if not $sc.seccompProfile -}}
{{- $_ := set $sc "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- end -}}
{{- end -}}
{{- toYaml $sc -}}
{{- end -}}

{{/*
The pod's securityContext: podSecurityContext, plus with
wireguard.unprivileged.enabled the sysctls wg-quick (src_valid_mark) and
the kill switch (accept_ra_*) would otherwise write themselves. Sysctls
already in podSecurityContext win.
*/}}
{{- define "twg.podSecurityContext" -}}
{{- $psc := deepCopy (.Values.podSecurityContext | default dict) -}}
{{- if and .Values.wireguard.unprivileged.enabled (eq (include "twg.sysctlsFrom" .) "pod") -}}
{{- $want := list (dict "name" "net.ipv4.conf.all.src_valid_mark" "value" "1") -}}
{{- if .Values.wireguard.unprivileged.blockRouterAdvertisements -}}
{{- $want = concat $want (list (dict "name" "net.ipv6.conf.eth0.accept_ra_pinfo" "value" "0") (dict "name" "net.ipv6.conf.eth0.accept_ra_rt_info_max_plen" "value" "0")) -}}
{{- end -}}
{{- $sysctls := $psc.sysctls | default list -}}
{{- $have := list -}}
{{- range $sysctls }}{{ $have = append $have .name }}{{ end -}}
{{- range $want -}}
{{- if not (has .name $have) }}{{ $sysctls = append $sysctls . }}{{ end -}}
{{- end -}}
{{- $_ := set $psc "sysctls" $sysctls -}}
{{- end -}}
{{- with $psc }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/* Transmission's /config mount. */}}
{{- define "twg.storageMounts" -}}
{{- if .Values.persistence.enabled -}}
- name: transmission-storage
  mountPath: /config
  subPath: config
{{- else -}}
- name: transmission-config
  mountPath: /config
{{- end -}}
{{- end -}}

{{- define "twg.dataPath" -}}
{{- (.Values.persistence.mounts | default dict).data | default dict | dig "mountPath" "" | default "/data" | trimSuffix "/" | default "/data" -}}
{{- end -}}

{{/* Transmission's downloads mount, if any. */}}
{{- define "twg.dataMount" -}}
{{- if include "twg.dataPathTaken" . -}}
{{- else if .Values.persistence.downloads.enabled -}}
- name: transmission-downloads
  mountPath: {{ include "twg.dataPath" . }}
{{- else if .Values.persistence.enabled -}}
- name: transmission-storage
  mountPath: {{ include "twg.dataPath" . }}
  {{- with (.Values.persistence.mounts | default dict).data | default dict | dig "subPath" "" }}
  subPath: {{ . }}
  {{- end }}
{{- else if include "twg.dataEmptyDir" . -}}
- name: transmission-data
  mountPath: {{ include "twg.dataPath" . }}
{{- end -}}
{{- end -}}

{{/*
"true" when nothing else is mounted at the data path: without persistence
it is an emptyDir, so downloads survive container restarts (not the pod)
and never land in the container's own layer (read-only with the minimal
image).
*/}}
{{- define "twg.dataEmptyDir" -}}
{{- if and (not .Values.persistence.enabled) (not .Values.persistence.downloads.enabled) (not (include "twg.dataPathTaken" .)) -}}
true
{{- end -}}
{{- end -}}

{{/* Where an unprivileged sidecar's sysctls are set: "pod" or "initContainer". */}}
{{- define "twg.sysctlsFrom" -}}
{{- .Values.wireguard.unprivileged.sysctls | default "pod" -}}
{{- end -}}

{{/*
transmission.settings as rendered into settings.json, as JSON: the RPC
credentials left out (they come from the Secret), the hosts the web UI is
reached under added to rpc-host-whitelist, and download, incomplete and
watch dirs that still point under /data moved to the data mount when
persistence.mounts.data.mountPath puts it elsewhere.
*/}}
{{- define "twg.settings" -}}
{{- $settings := omit (deepCopy .Values.transmission.settings) "rpc-username" "rpc-password" -}}
{{- $dataPath := include "twg.dataPath" . -}}
{{- if ne $dataPath "/data" -}}
{{- range $k := list "download-dir" "incomplete-dir" "watch-dir" -}}
{{- $d := index $settings $k | default "" | toString -}}
{{- if or (eq $d "/data") (hasPrefix "/data/" $d) -}}
{{- $_ := set $settings $k (printf "%s%s" $dataPath (trimPrefix "/data" $d)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if index $settings "rpc-host-whitelist-enabled" -}}
{{- $fullname := include "twg.fullname" . -}}
{{- $hosts := splitList "," (index $settings "rpc-host-whitelist" | default "" | toString) -}}
{{- $hosts = concat $hosts (list $fullname (printf "%s.%s" $fullname .Release.Namespace) (printf "%s.%s.svc" $fullname .Release.Namespace) (printf "%s.%s.svc.cluster.local" $fullname .Release.Namespace)) -}}
{{- if .Values.ingress.enabled -}}
{{- range .Values.ingress.hosts -}}
{{- $hosts = append $hosts .host -}}
{{- end -}}
{{- end -}}
{{- if .Values.httpRoute.enabled -}}
{{- $hosts = concat $hosts (.Values.httpRoute.hostnames | default list) -}}
{{- end -}}
{{- $_ := set $settings "rpc-host-whitelist" (without ($hosts | uniq) "" | join ",") -}}
{{- end -}}
{{- toJson $settings -}}
{{- end -}}

{{/* The claims this release's pods mount, for the PrometheusRule. */}}
{{- define "twg.claimNames" -}}
{{- $names := list -}}
{{- if and .Values.persistence.enabled (ne .Values.persistence.type "hostPath") -}}
{{- $names = append $names (default (include "twg.fullname" .) .Values.persistence.existingClaim) -}}
{{- end -}}
{{- if .Values.persistence.downloads.enabled -}}
{{- $names = append $names (.Values.persistence.downloads.existingClaim | default (printf "%s-downloads" (include "twg.fullname" .))) -}}
{{- end -}}
{{- toJson $names -}}
{{- end -}}

{{/* "true" when a transmission.extraVolumeMount takes the data path. */}}
{{- define "twg.dataPathTaken" -}}
{{- $path := include "twg.dataPath" . -}}
{{- range .Values.transmission.extraVolumeMounts }}{{ if eq (trimSuffix "/" .mountPath) $path }}true{{ end }}{{ end -}}
{{- end -}}

{{/*
The issuer's name: issuer.name, or <fullname>-issuer. A ClusterIssuer is
cluster-wide, so its default name has the namespace in it too: two
namespaces with the same release name would otherwise fight over one.
*/}}
{{- define "twg.issuerName" -}}
{{- if .Values.issuer.name -}}
{{- .Values.issuer.name -}}
{{- else if eq (default "Issuer" .Values.issuer.kind) "ClusterIssuer" -}}
{{- printf "%s-%s-issuer" .Release.Namespace (include "twg.fullname" .) | trunc 253 -}}
{{- else -}}
{{- printf "%s-issuer" (include "twg.fullname" .) -}}
{{- end -}}
{{- end -}}
