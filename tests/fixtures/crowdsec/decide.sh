#!/bin/sh
# Runs inside the CrowdSec image with no network, as tests/crowdsec.bats starts it, with the
# release's parser and scenarios and the sample access log in /t: starts a local API alone with the
# image's own entrypoint, to hold what is decided, reads the log the way the agent reads the
# proxies' lines, and prints the decisions the local API holds, the post-overflow items still loaded
# and the number of reverse DNS lookups the agent made, as one JSON object. DISABLE_POSTOVERFLOWS, as
# the agent's pod has it, names the items to remove, as the image's entrypoint removes them before it
# starts the agent. The release's own local API is started by the chart's script, which the test
# runs in a step of its own.
set -eu
DISABLE_AGENT=true DISABLE_ONLINE_API=true CROWDSEC_BYPASS_DB_VOLUME_CHECK=true /docker_start.sh >/tmp/lapi.log 2>&1 &
i=0
until nc -z 127.0.0.1 8080 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    cat /tmp/lapi.log >&2
    exit 1
  fi
  sleep 1
done
cp /t/parser.yaml /etc/crowdsec/parsers/s01-parse/envoy-gateway-json.yaml
for file in /t/scenario-*.yaml; do
  cp "$file" "/etc/crowdsec/scenarios/${file#/t/scenario-}"
done
if [ -n "${DISABLE_POSTOVERFLOWS:-}" ]; then
  # shellcheck disable=SC2086 # a space-separated list of items, as the entrypoint reads it.
  cscli postoverflows remove $DISABLE_POSTOVERFLOWS --force >/dev/null
fi
if ! crowdsec -debug -c /etc/crowdsec/config.yaml -type envoy-gateway-json -dsn file:///t/access.log -no-api >/tmp/agent.log 2>&1; then
  cat /tmp/agent.log >&2
  exit 1
fi
# The alerts reach the local API before the process ends, and its database a moment after.
sleep 2
lookups=$(grep -c 'method=reverse_dns' /tmp/agent.log || true)
loaded=$(cscli postoverflows list -o raw | tail -n +2 | cut -d, -f1 | paste -sd, -)
printf '{"decisions":%s,"postoverflows":"%s","reverse_dns":%s}\n' "$(cscli decisions list -o json)" "$loaded" "$lookups"
