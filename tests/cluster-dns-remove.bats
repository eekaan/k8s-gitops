#!/usr/bin/env bats
# Proves the scenarios of features/dns.feature that run just cluster-dns-remove, each by a test with
# its title, and, by the tests with titles of their own, how the recipe refuses and fails. The recipe
# runs from a copy of the repository with an environment of its own, so no run reads this
# checkout's .env or kubeconfig. Whatever would reach the cluster is a recording fake
# (tests/fixtures/cluster-dns-remove): kubectl answers from files and keeps what a run changes, and
# runs each Job it creates as the pinned external-dns would run with the Job's arguments, against
# the zone fixture; flux suspends and resumes there, or fails to suspend as the pinned CLI does,
# with the status 0. tofu, openstack, talosctl, talman, helm and curl fail when called. The zone's
# identifier and the provider's token are markers, which no run may print or pass as an argument.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  FIXTURES=$BATS_TEST_DIRNAME/fixtures/cluster-dns-remove
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  # The recipe's TMPDIR, which must hold nothing once it has ended.
  WORK="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$BIN" "$RECORD" "$STATE/jobs" "$WORK" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig"
  : >"$RECORD/argv"
  : >"$RECORD/events"
  : >"$RECORD/created"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  cp -R "$ROOT/scripts" "$REPO/scripts"
  # The kubeconfig the recipe points kubectl at; the fake reads none.
  : >"$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  chmod +x "$BIN/mise"
  cp "$FIXTURES/kubectl" "$FIXTURES/flux" "$BIN/"
  for tool in tofu openstack talosctl talman helm curl; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s"\necho "unexpected call: %s $*" >&2\nexit 1\n' \
      "$tool" "$RECORD/argv" "$tool" >"$BIN/$tool"
    chmod +x "$BIN/$tool"
  done
  echo "$FIXTURES" >"$STATE/fixtures"
  # The cluster: external-dns as the pinned chart renders it with the tree's values, at one replica;
  # its token in a Secret; the cluster's domain; and the zone, kept as it was for the comparisons.
  yq -o json "$FIXTURES/deployment.yaml" >"$STATE/deployment.json"
  echo 1 >"$STATE/replicas"
  ZONE_MARKER=marker-zone-identifier
  TOKEN_MARKER=marker-provider-token
  echo "$ZONE_MARKER" >"$STATE/zone-marker"
  jq -n --arg token "$(printf '%s' "$TOKEN_MARKER" | base64)" \
    '{kind: "Secret", metadata: {namespace: "external-dns", name: "external-dns-cloudflare"}, data: {"api-token": $token}}' >"$STATE/secret.json"
  jq -n '{kind: "ConfigMap", metadata: {namespace: "flux-system", name: "cluster-config"},
    data: {CLUSTER_DOMAIN: "example.com", CLUSTER_DNS_ZONE: "example.com", GATEWAY_ADDRESS: "198.51.100.1"}}' >"$STATE/cluster-config.json"
  jq . "$FIXTURES/zone.json" >"$STATE/zone.json"
  cp "$STATE/zone.json" "$STATE/zone.before.json"
  ENVIRONMENT=(TMPDIR="$WORK" DNS_REMOVE_TIMEOUT=60)
}

# remove [ARG...]: just cluster-dns-remove ARG... against the copy, with only ENVIRONMENT set and the
# fakes first on PATH, its standard input the caller's. A run that blocks fails after two minutes.
remove() {
  : >"$RECORD/argv"
  : >"$RECORD/events"
  : >"$RECORD/created"
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" cluster-dns-remove "$@"
  echo "$output"
}

# listed: the records the run listed, one "delete TYPE NAME" per line, as printed.
listed() {
  sed -n 's/^  \(delete .*\)$/\1/p' <<<"$output"
}

# lab_records: the records of lab-sto2 the zone holds under example.com, the A records of hello and
# n8n at both edges and their TXT entries, as the run lists them, sorted.
lab_records() {
  printf '%s\n' 'delete A hello' 'delete A hello' 'delete A n8n' 'delete A n8n' 'delete TXT extdns-a.hello' 'delete TXT extdns-a.n8n'
}

# order: what the run did to the cluster, in order: each Job by its kind, a deleting one with the
# fake's note when a pod of external-dns still ran, each suspension and scale, and the wait for the
# pod, once however many reads it took.
order() {
  sed -E 's/^job plan [^ ]+.*/plan Job/; s/^job delete [^ ]+/delete Job/; s/^pods [01]$/wait/; /^deleted job /d' "$RECORD/events" | uniq
}

# job_args KIND: the arguments of the container of the last Job of KIND, plan or delete, the run
# created, one per line.
job_args() {
  local dry=true
  [[ $1 == plan ]] || dry=false
  jq -s -r --argjson dry "$dry" '[.[] | select((.spec.template.spec.containers[0].args | index("--dry-run") != null) == $dry)]
    | last | .spec.template.spec.containers[0].args[]' "$RECORD/created"
}

# nothing_secret: the output holds neither marker, no address, no name under the cluster's domain
# and no line of external-dns' log.
nothing_secret() {
  if grep -nE "$ZONE_MARKER|$TOKEN_MARKER|[0-9]{1,3}(\.[0-9]{1,3}){3}|example\.(com|net)|Changing record|level=|\"msg\"" <<<"$output"; then
    echo "a marker, an address, a name under the domain or a line of the log is printed" >&2
    return 1
  fi
}

# absent GREP_ARG...: fails, showing what it found, when grep finds what GREP_ARG... asks for; the last
# command of a function, as bats ignores a failing ! anywhere else.
absent() {
  ! grep "$@"
}

@test "The removal's check lists the records it would delete and changes nothing in the zone or in what Flux owns" {
  remove --check

  [ "$status" -eq 0 ]
  [[ $output == *"cluster-dns-remove: external-dns of lab-sto2 owns its records as lab-sto2"* ]]
  [ "$(listed)" = "$(lab_records)" ]
  [[ $output == *"--check deletes none of them"* ]]
  # One Job, in dry-run, deleted once it was read; nothing suspended, scaled or deleted in the zone.
  [ "$(order)" = "plan Job" ]
  [ "$(jq -s length "$RECORD/created")" -eq 1 ]
  [ "$(job_args plan | grep -cx -- --dry-run)" -eq 1 ]
  grep -q '^deleted job external-dns-remove-[0-9]*-plan$' "$RECORD/events"
  [ -z "$(find "$STATE/jobs" -mindepth 1)" ]
  absent -E '^flux |^kubectl scale ' "$RECORD/argv"
  cmp "$STATE/zone.json" "$STATE/zone.before.json"
  absent -E '^kubectl get .* secrets?( |$)' "$RECORD/argv"
  absent -F "$TOKEN_MARKER" "$RECORD/argv" "$RECORD/created"
  nothing_secret
  [ -z "$(find "$WORK" -mindepth 1)" ]
}

@test "The removal stops external-dns, deletes only the records of this cluster's owner, and finds none left" {
  local manifest
  remove <<<"lab-sto2"

  [ "$status" -eq 0 ]
  [[ $output == *"Type lab-sto2 to stop external-dns and delete the records above for it: "* ]]
  [ "$(order)" = "$(printf '%s\n' 'plan Job' 'suspended kustomization flux-system/external-dns' \
    'suspended helmrelease external-dns/external-dns' 'scaled external-dns/external-dns to 0' 'wait' 'delete Job' 'plan Job')" ]
  # Three Jobs of names of their own, each deleted once read.
  [ "$(sed -nE 's/^job (plan|delete) external-dns-remove-[0-9]+-([a-z]+)( .*)?$/\2/p' "$RECORD/events" | paste -sd' ' -)" = "plan delete verify" ]
  [ "$(grep -c '^deleted job ' "$RECORD/events")" -eq 3 ]
  # What was deleted, the records of lab-sto2 and their entries and nothing else: another owner's, the
  # default owner's, the one made by hand and lab-sto2's outside the domain filter stay.
  [ "$(jq -c 'sort' "$STATE/zone.json")" = "$(jq -c '[.[] | select((.name | test("^(extdns-a\\.)?(hello|n8n)\\.example\\.com$")) | not)] | sort' "$STATE/zone.before.json")" ]
  [ "$(jq length "$STATE/zone.json")" -eq 8 ]
  [ "$(sed -n '/external-dns deleted these/,/^cluster-dns-remove: /p' <<<"$output" | sed -n 's/^  \(delete .*\)$/\1/p')" = "$(lab_records)" ]
  [[ $output == *"a second plan finds no record of lab-sto2 left"* ]]
  [[ $output == *"external-dns stays stopped"*"flux resume kustomization external-dns"*"then flux resume helmrelease external-dns --namespace external-dns"* ]]
  # The way back holds while the edges it published at stand; once the edge stack is destroyed, only
  # once the edges are built again, their addresses are in the cluster's configuration and the
  # Gateway, whose annotation external-dns reads them from, has been applied again with them.
  [[ $output == *"To start it again, before the edge stack's destroy, or after it only once the edges are built again, just cluster-config has written their addresses to the cluster and flux reconcile kustomization gateway-public has applied them to the Gateway and ended Ready: flux resume kustomization external-dns"* ]]
  [[ $output != *"until the cluster is destroyed"* ]]
  # The deleting Job: external-dns once, against no source, with the template's owner, prefix,
  # registry, policy, filter, record types and provider, and none of its sources or the Gateway's.
  job_args delete >"$BATS_TEST_TMPDIR/args"
  for arg in --source=empty --once --log-format=json --txt-owner-id=lab-sto2 '--txt-prefix=extdns-%{record_type}.' \
    --registry=txt --policy=sync '--regex-domain-filter=\A(example\.com|(.+\.)?example\.com)\z' --managed-record-types=A \
    --provider=cloudflare --min-ttl=300s --log-level=info; do
    [ "$(grep -cxF -- "$arg" "$BATS_TEST_TMPDIR/args")" -eq 1 ] || { echo "not once: $arg"; return 1; }
  done
  [ "$(wc -l <"$BATS_TEST_TMPDIR/args")" -eq 12 ]
  absent -E -- '^--(source=gateway|gateway-|events|interval=|min-event|log-format=text|dry-run)' "$BATS_TEST_TMPDIR/args"
  # Its pod: the template's image, account, security contexts, resources and environment, the token
  # by reference; its own label, no probes and no ports; it runs once and is bounded in time.
  manifest=$(jq -s -c 'map(select(.spec.template.spec.containers[0].args | index("--dry-run") | not)) | last' "$RECORD/created")
  [ "$(jq -c '.spec | {backoffLimit, activeDeadlineSeconds, restartPolicy: .template.spec.restartPolicy, labels: .template.metadata.labels,
    automount: .template.spec.automountServiceAccountToken, containers: (.template.spec.containers | length),
    probes: [.template.spec.containers[0] | .livenessProbe, .readinessProbe, .ports]}' <<<"$manifest")" \
    = '{"backoffLimit":0,"activeDeadlineSeconds":60,"restartPolicy":"Never","labels":{"app.kubernetes.io/name":"external-dns-remove"},"automount":false,"containers":1,"probes":[null,null,null]}' ]
  [ "$(jq -c '.spec.template.spec | {serviceAccountName, securityContext, c: (.containers[0] | {name, image, securityContext, resources, env})}' <<<"$manifest")" \
    = "$(jq -c '.spec.template.spec | {serviceAccountName, securityContext, c: (.containers[0] | {name, image, securityContext, resources, env})}' "$STATE/deployment.json")" ]
  absent -F "$TOKEN_MARKER" "$RECORD/argv" "$RECORD/created"
  absent -E '^kubectl get .* secrets?( |$)' "$RECORD/argv"
  [ -z "$(find "$STATE/jobs" -mindepth 1)" ]
  nothing_secret

  # A second run finds nothing to delete, and neither asks nor changes anything.
  remove </dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"would delete nothing"* ]]
  [[ $output != *"Type lab-sto2"* ]]
  [ "$(order)" = "plan Job" ]
  nothing_secret
}

@test "a removal answered with another name than the cluster's suspends, scales and deletes nothing" {
  remove <<<"wrong"

  [ "$status" -eq 1 ]
  [[ $output == *"lab-sto2 was not confirmed"* ]]
  [ "$(order)" = "plan Job" ]
  absent -E '^flux |^kubectl scale ' "$RECORD/argv"
  cmp "$STATE/zone.json" "$STATE/zone.before.json"
  nothing_secret
}

@test "a removal whose Kustomization the flux CLI does not suspend stops before the scale and makes no deleting Job" {
  : >"$STATE/suspend-fails.kustomization"
  remove --yes

  [ "$status" -eq 1 ]
  [[ $output == *"flux: "*" failed suspending Kustomization external-dns in "* ]]
  [[ $output == *"the Kustomization flux-system/external-dns is not suspended after flux suspend"* ]]
  [ "$(order)" = "plan Job" ]
  absent -E '^flux suspend helmrelease |^kubectl scale ' "$RECORD/argv"
  [[ $output != *"is left suspended"* && $output != *"left at 0 replicas"* ]]
  cmp "$STATE/zone.json" "$STATE/zone.before.json"
  nothing_secret
}

@test "a removal whose HelmRelease the flux CLI does not suspend stops before the scale and makes no deleting Job" {
  : >"$STATE/suspend-fails.helmrelease"
  remove --yes

  [ "$status" -eq 1 ]
  [[ $output == *"flux: "*" failed suspending HelmRelease external-dns in "* ]]
  [[ $output == *"the HelmRelease external-dns/external-dns is not suspended after flux suspend"* ]]
  [ "$(order)" = "$(printf '%s\n' 'plan Job' 'suspended kustomization flux-system/external-dns')" ]
  absent -E '^kubectl scale ' "$RECORD/argv"
  # Last, before just's own line, the Kustomization it did suspend, and nothing else.
  [ "$(grep -v '^error: recipe ' <<<"$output" | tail -n 1)" = "cluster-dns-remove: the Kustomization flux-system/external-dns is left suspended; resume it with: flux resume kustomization external-dns" ]
  [[ $output != *"HelmRelease external-dns/external-dns is left suspended"* && $output != *"left at 0 replicas"* ]]
  cmp "$STATE/zone.json" "$STATE/zone.before.json"
  nothing_secret
}

@test "a removal that cannot read back what the flux CLI suspended stops before the scale, naming it as maybe suspended" {
  : >"$STATE/readback-fails.kustomization"
  remove --yes

  [ "$status" -eq 1 ]
  [[ $output == *"kubectl: Unable to connect to the server"* ]]
  [[ $output == *"the Kustomization flux-system/external-dns cannot be read, so whether flux suspended it is not known"* ]]
  [ "$(order)" = "$(printf '%s\n' 'plan Job' 'suspended kustomization flux-system/external-dns')" ]
  absent -E '^flux suspend helmrelease |^kubectl scale ' "$RECORD/argv"
  # Last, before just's own line, the Kustomization as maybe suspended, and the command that resumes it.
  [ "$(grep -v '^error: recipe ' <<<"$output" | tail -n 1)" = "cluster-dns-remove: the Kustomization flux-system/external-dns may be left suspended, as it could not be read back; resume it with: flux resume kustomization external-dns" ]
  cmp "$STATE/zone.json" "$STATE/zone.before.json"
  nothing_secret

  rm "$STATE/readback-fails.kustomization" "$STATE/suspended.kustomization.flux-system.external-dns"
  : >"$STATE/readback-fails.helmrelease"
  remove --yes

  [ "$status" -eq 1 ]
  [[ $output == *"the HelmRelease external-dns/external-dns cannot be read, so whether flux suspended it is not known"* ]]
  [ "$(order)" = "$(printf '%s\n' 'plan Job' 'suspended kustomization flux-system/external-dns' 'suspended helmrelease external-dns/external-dns')" ]
  absent -E '^kubectl scale ' "$RECORD/argv"
  [ "$(grep -v '^error: recipe ' <<<"$output" | tail -n 2)" = "cluster-dns-remove: the Kustomization flux-system/external-dns is left suspended; resume it with: flux resume kustomization external-dns
cluster-dns-remove: the HelmRelease external-dns/external-dns may be left suspended, as it could not be read back; resume it, after the Kustomization, with: flux resume helmrelease external-dns --namespace external-dns" ]
  cmp "$STATE/zone.json" "$STATE/zone.before.json"
  nothing_secret
}

@test "a removal whose plan changes a record otherwise than by deleting it is refused, and suspends nothing" {
  local action
  for action in CREATE UPDATE; do
    echo "$action" >"$STATE/job-action.plan"
    remove --yes

    [ "$status" -eq 1 ]
    [[ $output == *"is not read as external-dns' plan: it changes a record otherwise than by deleting it"* ]]
    [ "$(order)" = "plan Job" ]
    absent -E '^flux |^kubectl scale ' "$RECORD/argv"
    cmp "$STATE/zone.json" "$STATE/zone.before.json"
    nothing_secret
    rm -f "$STATE"/jobs/*
  done
}

@test "a removal refuses an external-dns that does not delete by this cluster's owner, before any Job" {
  local case filter why
  local -a cases=(
    'del(.spec.template.spec.containers[0].args[] | select(. == "--registry=txt"))|--registry=txt'
    '(.spec.template.spec.containers[0].args[] | select(. == "--policy=sync")) = "--policy=upsert-only"|--policy=sync'
    '(.spec.template.spec.containers[0].args[] | select(startswith("--txt-owner-id="))) = "--txt-owner-id=set-by-the-overlay"|--txt-owner-id'
    'del(.spec.template.spec.containers[0].args[] | select(startswith("--txt-owner-id=")))|--txt-owner-id'
    '.spec.template.spec.containers[0].args += ["--policy=upsert-only"]|--policy=sync'
    '(.spec.template.spec.containers[0].args[] | select(. == "--provider=cloudflare")) = "--provider=aws"|--provider=cloudflare'
    '.spec.template.spec.containers[0].name = "dns"|one container named external-dns'
  )
  for case in "${cases[@]}"; do
    filter=${case%|*} why=${case##*|}
    echo "the Deployment: $filter"
    yq -o json "$FIXTURES/deployment.yaml" | jq "$filter" >"$STATE/deployment.json"
    remove --yes

    [ "$status" -eq 1 ]
    [[ $output == *"the Deployment external-dns/external-dns"*"$why"* ]]
    absent -E '^kubectl create |^flux |^kubectl scale ' "$RECORD/argv"
    cmp "$STATE/zone.json" "$STATE/zone.before.json"
    nothing_secret
  done
}

@test "a removal whose deleting Job fails keeps the Job, names it and what is left suspended, and prints none of its log" {
  : >"$STATE/job-fails.delete"
  remove --yes

  [ "$status" -eq 1 ]
  job=$(sed -nE 's/^job delete ([^ ]+)$/\1/p' "$RECORD/events")
  [ -n "$job" ]
  [ -f "$STATE/jobs/$job.json" ]
  [[ $output == *"the Job external-dns/$job failed"*"kubectl --namespace external-dns logs job/$job"* ]]
  # Last, before just's own line, what it left suspended and scaled, and the commands that undo it.
  [ "$(grep -v '^error: recipe ' <<<"$output" | tail -n 3)" = "cluster-dns-remove: the Kustomization flux-system/external-dns is left suspended; resume it with: flux resume kustomization external-dns
cluster-dns-remove: the HelmRelease external-dns/external-dns is left suspended; resume it, after the Kustomization, with: flux resume helmrelease external-dns --namespace external-dns
cluster-dns-remove: the Deployment external-dns/external-dns is left at 0 replicas, which helm-controller's drift detection undoes once the HelmRelease is resumed" ]
  nothing_secret
}

@test "a removal whose second plan still finds a record fails, naming it" {
  : >"$STATE/comes-back"
  remove --yes

  [ "$status" -eq 1 ]
  [[ $output == *"the plan after the deletion still finds records of lab-sto2"* ]]
  [ "$(sed -n '/still finds records/,$p' <<<"$output" | sed -n 's/^  \(delete .*\)$/\1/p')" = "$(printf '%s\n' 'delete A hello' 'delete A hello' 'delete TXT extdns-a.hello')" ]
  [[ $output == *"flux resume kustomization external-dns"* ]]
  nothing_secret
}

@test "a removal whose deleting Job its own deadline stops keeps the Job, names it and what is left suspended, and names no log to read" {
  : >"$STATE/job-expires.delete"
  remove --yes

  [ "$status" -eq 1 ]
  job=$(sed -nE 's/^job delete ([^ ]+)$/\1/p' "$RECORD/events")
  [ -n "$job" ]
  [ -f "$STATE/jobs/$job.json" ]
  [[ $output == *"the Job external-dns/$job did not end within 60 seconds; its own deadline stops it, and just cluster-dns-remove --check, run after that, lists what is left in the zone"* ]]
  [[ $output == *"the Job external-dns/$job is kept; its own deadline of 60 seconds stops its pod, which goes with its log"* ]]
  [[ $output != *"logs job/"* ]]
  [ "$(grep -v '^error: recipe ' <<<"$output" | tail -n 3)" = "cluster-dns-remove: the Kustomization flux-system/external-dns is left suspended; resume it with: flux resume kustomization external-dns
cluster-dns-remove: the HelmRelease external-dns/external-dns is left suspended; resume it, after the Kustomization, with: flux resume helmrelease external-dns --namespace external-dns
cluster-dns-remove: the Deployment external-dns/external-dns is left at 0 replicas, which helm-controller's drift detection undoes once the HelmRelease is resumed" ]
  nothing_secret
}

@test "a removal's waits and Jobs are bounded by DNS_REMOVE_TIMEOUT, and a value that is not one is refused" {
  for value in 0 -1 1m 1234567890; do
    ENVIRONMENT=(TMPDIR="$WORK" "DNS_REMOVE_TIMEOUT=$value")
    remove --check

    [ "$status" -eq 1 ]
    [[ $output == *DNS_REMOVE_TIMEOUT* ]]
    absent -E '^kubectl ' "$RECORD/argv"
  done

  # A deleting Job that does not end within the wait is kept and named, as is what is left suspended;
  # its own deadline stops its pod, which goes with its log, so no command to read that log is named.
  ENVIRONMENT=(TMPDIR="$WORK" DNS_REMOVE_TIMEOUT=3)
  : >"$STATE/job-stuck.delete"
  remove --yes

  [ "$status" -eq 1 ]
  job=$(sed -nE 's/^job delete ([^ ]+)$/\1/p' "$RECORD/events")
  [[ $output == *"the Job external-dns/$job did not end within 3 seconds; its own deadline stops it, and just cluster-dns-remove --check, run after that, lists what is left in the zone"* ]]
  [[ $output == *"the Job external-dns/$job is kept; its own deadline of 3 seconds stops its pod, which goes with its log"* ]]
  [[ $output != *"logs job/"* ]]
  [ "$(jq '.spec.activeDeadlineSeconds' "$STATE/jobs/$job.json")" -eq 3 ]
  [[ $output == *"flux resume helmrelease external-dns --namespace external-dns"* ]]
  nothing_secret
}

@test "a cluster without external-dns has no records to remove, and kubectl's errors are shown without an address" {
  : >"$STATE/no-dns-app"
  remove --yes

  [ "$status" -eq 0 ]
  [[ $output == *"lab-sto2 does not select external-dns"* ]]
  absent -E '^kubectl (create |get .* deployment )|^flux ' "$RECORD/argv"

  rm "$STATE/no-dns-app"
  : >"$STATE/noisy"
  remove --check

  [ "$status" -eq 1 ]
  [[ $output == *"kubectl: Unable to connect to the server"* ]]
  [[ $output == *"the Deployment external-dns/external-dns cannot be read"* ]]
  nothing_secret
}
