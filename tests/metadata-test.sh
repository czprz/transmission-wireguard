#!/usr/bin/env bash
# appVersion, which `helm list` shows users, must be the Transmission
# version the chart runs by default.
set -euo pipefail
cd "$(dirname "$0")/.."

failed=0
# repo:tag@digest of the chart default named $1 (wireguardImage, ...).
# shellcheck disable=SC2016 # $tag and $digest are template text
default_image() {
  local block repo tag digest
  block=$(sed -n "/define \"twg.$1\"/,/end -/p" templates/_helpers.tpl)
  tag=$(sed -nE 's/.*\$tag := default "([^"]+)".*/\1/p' <<<"$block")
  digest=$(sed -nE 's/.*\$digest := default "([^"]+)".*/\1/p' <<<"$block")
  repo=$(sed -nE 's/.*"repo" "([^"]+)".*/\1/p' <<<"$block")
  echo "$repo:$tag@$digest"
}

app=$(sed -nE 's/^appVersion: "?([^"]+)"?$/\1/p' Chart.yaml)
tx=$(default_image transmissionImage)
tag=${tx#*:}
tag=${tag%%@*}
if [[ ${tag%%-*} == "$app" ]]; then
  echo "PASS  appVersion $app is the default Transmission version"
else
  echo "FAIL  appVersion $app, but the default Transmission image is $tag"
  failed=1
fi

# Artifact Hub lists the images from Chart.yaml: they must be the defaults.
for pair in wireguard:wireguardImage transmission:transmissionImage leak-test:testImage; do
  name=${pair%%:*}
  want=$(default_image "${pair#*:}")
  got=$(awk -v n="$name" '$0 ~ "- name: "n"$" { getline; sub(/^ *image: */, ""); print }' Chart.yaml)
  if [[ $got == "$want" ]]; then
    echo "PASS  artifacthub.io/images lists the default $name image"
  else
    echo "FAIL  artifacthub.io/images lists $name as '${got}', but the default is $want"
    failed=1
  fi
done

exit "$failed"
