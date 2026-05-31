{{/* Возвращает DNS-хост для внешнего доступа.
     Приоритет:
       1) IP из .Values.Gateway.host (если задан явно)
       2) IP из статусa LoadBalancer сервиса (если есть)
       3) ExternalIP первой попавшейся ноды
       4) InternalIP первой попавшейся ноды
     Формат: <ip>.nip.io
*/}}
{{- define "midas.detectHost" -}}
{{- $override := .Values.Gateway.host | default "" -}}
{{- if $override }}
  {{- $override -}}
{{- else -}}
  {{- $ctx := dict "ip" "" -}}

  {{/* 1) Пытаемся достать IP из LB сервиса лог-гейтвея */}}
  {{- $svcNS := .Release.Namespace -}}
  {{- $svcName := .Values.Gateway.serviceName | default .Values.Gateway.DNS -}}
  {{- $svc := (lookup "v1" "Service" $svcNS $svcName) -}}
  {{- if $svc }}
    {{- $ing := (get $svc.status "loadBalancer") | default dict -}}
    {{- $arr := (get $ing "ingress") | default list -}}
    {{- if gt (len $arr) 0 -}}
      {{- $first := index $arr 0 -}}
      {{- if hasKey $first "ip" -}}
        {{- $_ := set $ctx "ip" $first.ip -}}
      {{- end -}}
      {{- if and (eq $ctx.ip "") (hasKey $first "hostname") -}}
        {{- /* если облако вернуло hostname, не ip — ну тогда уже отдай hostname как есть */ -}}
        {{- $_ := set $ctx "ip" $first.hostname -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{/* 2) Если IP всё ещё пуст — берём ExternalIP ноды */}}
  {{- if eq $ctx.ip "" -}}
    {{- $nodes := (lookup "v1" "Node" "" "").items | default list -}}
    {{- range $n := $nodes -}}
      {{- range $a := $n.status.addresses -}}
        {{- if and (eq $a.type "ExternalIP") (eq $ctx.ip "") -}}
          {{- $_ := set $ctx "ip" $a.address -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{/* 3) Если и ExternalIP нет — берём InternalIP */}}
  {{- if eq $ctx.ip "" -}}
    {{- $nodes := (lookup "v1" "Node" "" "").items | default list -}}
    {{- range $n := $nodes -}}
      {{- range $a := $n.status.addresses -}}
        {{- if and (eq $a.type "InternalIP") (eq $ctx.ip "") -}}
          {{- $_ := set $ctx "ip" $a.address -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- if eq $ctx.ip "" -}}
    {{- fail "midas.detectHost: не удалось определить IP (ни LB, ни ExternalIP/InternalIP)" -}}
  {{- end -}}

  {{/* Если вдруг вернулся уже hostname (из LB), отдаём как есть; если это IP — делаем nip.io */}}
  {{- if (regexMatch `^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$` $ctx.ip) -}}
    {{ printf "%s.nip.io" $ctx.ip }}
  {{- else -}}
    {{ $ctx.ip }}
  {{- end -}}
{{- end -}}
{{- end -}}
