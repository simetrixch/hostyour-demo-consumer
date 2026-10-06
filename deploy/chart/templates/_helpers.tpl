{{/* Common labels emitted on every resource. */}}
{{- define "demo.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
The registry host the build pipeline pushed this consumer's image to: the platform's registry
endpoint, else zot.<global.domain>, the rule every consumer chart of the platform follows.
*/}}
{{- define "demo.registryHost" -}}
{{- .Values.global.endpoints.registry.host | default (printf "zot.%s" .Values.global.domain) -}}
{{- end }}

{{/*
The app's image from this stage's builds[] pin. The release bump finds the pin by the build's name
and writes its tag; a missing pin fails the render rather than rendering an empty image.
*/}}
{{- define "demo.image" -}}
{{- $pin := dict -}}
{{- range (.Values.builds | default list) -}}
{{- if eq .name "hostyour-demo-consumer" }}{{- $pin = . -}}{{- end -}}
{{- end -}}
{{- $image := $pin.image | required "builds[] in values-<stage>.yaml carries no entry named \"hostyour-demo-consumer\" — the image pin is missing" -}}
{{- $tag := $pin.tag | required "builds[] entry \"hostyour-demo-consumer\" has no tag — the image pin is incomplete" -}}
{{- printf "%s/%s:%s" (include "demo.registryHost" .) $image $tag -}}
{{- end }}

{{/* The unit's public host, delivered by the platform; never composed here. */}}
{{- define "demo.host" -}}
{{- required "unitHost is delivered by the platform's consumers ApplicationSet; for a local render pass --set unitHost=demo.<stage apex>" .Values.unitHost -}}
{{- end }}
