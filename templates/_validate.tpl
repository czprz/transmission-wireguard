{{- if not (or .Values.wireguard.existingSecret .Values.wireguard.wg0Conf) -}}
{{- fail "wireguard.wg0Conf or wireguard.existingSecret must be set" -}}
{{- end -}}
