#!/usr/bin/env bats

# just ci-host-setup and just ci-host-remove against a fake CI host. Nothing here reaches a host or
# GitHub: ssh, ssh-keyscan, ssh-keygen and gh are fakes, and the fake ssh runs the remote command
# with bash on this machine, under a directory that stands for the host's file system, with fakes of
# the host's sudo, docker, systemctl and curl first on its PATH. The remote side of the recipes runs
# for real against that directory.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/ci-host"
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  HOST_BIN="$BATS_TEST_TMPDIR/host-bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  # The recipes' temporary files, here and on the host, go where the tests can read them.
  TEMP_DIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$BIN" "$HOST_BIN" "$RECORD" "$HOME_DIR" "$TEMP_DIR" "$BATS_TEST_TMPDIR/host" \
    "$BATS_TEST_TMPDIR/repo/infra/openstack/stacks/sto2/ci"
  HOST=$(cd "$BATS_TEST_TMPDIR/host" && pwd)
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  # A copy of the scripts, the backend file and the ci stack's configuration, so no run touches
  # this checkout; versions.yaml is the fixture's, pinning the fixture's runner package.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  cp "$ROOT"/infra/openstack/stacks/sto2/ci/*.tf "$REPO/infra/openstack/stacks/sto2/ci/"
  : > "$RECORD/argv"
  : > "$RECORD/host"

  KNOWN_HOSTS="$HOME_DIR/.local/state/k8s-gitops/ci-host.known_hosts"
  ADDRESS=$(jq -r .address.value "$FIXTURES/outputs.json")
  INSTANCE=$(jq -r .instance.value.id "$FIXTURES/outputs.json")
  HOST_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOfTheCiHostFixtureFixture'
  TOKEN=MARKERREGISTRATIONTOKEN0123456789
  REMOVE_TOKEN=MARKERREMOVETOKEN0123456789
  ENGINE="registry.dagger.io/engine:v0.0.0-fixture@sha256:$(printf '0%.0s' {1..64})"

  # The host as cloud-init leaves it: the runner's user with its home, and the cache volume mounted.
  mkdir -p "$HOST/home/ci-runner" "$HOST/var/lib/dagger" "$HOST/.fake"
  echo "$HOST/var/lib/dagger" > "$HOST/.fake/mounts"

  runner_package
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  # The tools the recipes hand values to, recorded on their way to the real binaries.
  for tool in jq yq grep flock cat; do
    record "$tool"
  done
  fake tofu <<EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
if [[ \${2-} == output ]]; then
  cat "$FIXTURES/outputs.json"
fi
EOF
  fake gh <<EOF
printf '%s\n' "gh \$*" >> "$RECORD/argv"
env | cut -d= -f1 >> "$RECORD/names.gh"
case "\$*" in
  'repo view --json url --jq .url') echo https://github.com/fixture-owner/fixture-repo ;;
  'api --method POST repos/fixture-owner/fixture-repo/actions/runners/registration-token --jq .token') echo $TOKEN ;;
  'api --method POST repos/fixture-owner/fixture-repo/actions/runners/remove-token --jq .token') echo $REMOVE_TOKEN ;;
  *) echo "unexpected call: gh \$*" >&2; exit 1 ;;
esac
EOF
  fake_ssh
  fake ssh-keyscan <<EOF
printf '%s\n' "ssh-keyscan \$*" >> "$RECORD/argv"
[[ \${*: -1} == "$ADDRESS" ]] || exit 1
printf '%s\n' "|1|fixturesalt=|fixturehash= $HOST_KEY"
EOF
  # ssh-keygen -F finds whatever the file records, as there is one host; -l prints a fingerprint
  # per key it reads.
  fake ssh-keygen <<EOF
printf '%s\n' "ssh-keygen \$*" >> "$RECORD/argv"
case \$1 in
  -F) [[ -s \$4 ]] ;;
  -l) while read -r line; do [[ -z \$line ]] || echo "256 SHA256:FixtureFingerprintOfTheCiHost0123456789abcd \${line%% *} (ED25519)"; done < "\$3" ;;
  *) echo "unexpected call: ssh-keygen \$*" >&2; exit 1 ;;
esac
EOF
  # Nothing else may reach a host, a cloud or a container runtime from this machine.
  for tool in scp sftp curl docker; do
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
echo "unexpected call: $tool \$*" >&2
exit 1
EOF
  done
  # The OpenStack client: its version, and an instance's console log, from the file console-ID in
  # the record's directory; an instance without a file is not found, as the client says it.
  fake openstack <<EOF
printf '%s\n' "openstack \$*" >> "$RECORD/argv"
if [[ \$* == --version ]]; then echo "openstack 7.1.0"; exit 0; fi
if [[ "\$1 \$2 \$3 \$4" == 'console log show --lines' && \$# -eq 6 && -f "$RECORD/console-\$6" ]]; then
  exec cat "$RECORD/console-\$6"
fi
echo "No server with a name or ID of '\${*: -1}' exists." >&2
exit 1
EOF
  fake_host

  ENVIRONMENT=(
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=marker-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-secret-access-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    'OPERATOR_CIDRS=["198.51.100.0/24"]'
    CI_HOST_IMAGE=fixture-image
    'CI_HOST_SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOperatorKey fixture'
    CI_HOST_SSH_USER=fixture-admin
    HOST_CONSOLE_WAIT=0
    # Secrets of the other stacks and the cluster, which neither gh nor ssh may be given.
    OS_APPLICATION_CREDENTIAL_SECRET=marker-credential
    TF_ENCRYPTION=marker-encryption
    CLUSTER_S3_ACCESS_KEY_ID=marker-cluster-key
    SOPS_AGE_KEY=marker-age-key
  )
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# host_fake NAME: a binary first on the fake host's PATH, its body read from stdin.
host_fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$HOST_BIN/$1"
  chmod +x "$HOST_BIN/$1"
}

# record NAME: puts NAME's arguments in the record, then runs the real NAME.
record() {
  local real
  real=$(command -v "$1")
  fake "$1" <<EOF
printf '%s\n' "$1 \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
}

# fake_ssh: an ssh that records its arguments, refuses as ssh does unless host key checking is
# strict against a known-hosts file that holds the host's key, and otherwise runs the remote command
# as the host's login shell would, on this machine, with the host's fakes first on PATH.
fake_ssh() {
  fake ssh <<EOF
printf '%s\n' "ssh \$*" >> "$RECORD/argv"
env | cut -d= -f1 >> "$RECORD/names.ssh"
strict= known=
while ((\$#)); do
  case \$1 in
    -o)
      case \$2 in
        StrictHostKeyChecking=*) strict=\${2#*=} ;;
        UserKnownHostsFile=*) known=\${2#*=} ;;
      esac
      shift 2
      ;;
    -[46AaCfGgKkMNnqsTtVvXxYy]) shift ;;
    -*) shift 2 ;;
    *) break ;;
  esac
done
if [[ \$strict != yes ]]; then
  echo "fake ssh: connects only with StrictHostKeyChecking=yes" >&2
  exit 255
fi
if [[ -z \$known || ! -f \$known ]] || ! grep -qF -- "${HOST_KEY#* }" "\$known"; then
  echo "Host key verification failed." >&2
  exit 255
fi
if [[ \$1 != fixture-admin@$ADDRESS ]]; then
  echo "fake ssh: unexpected destination" >&2
  exit 255
fi
shift
cd "$HOST"
exec env CI_HOST_ROOT="$HOST" PATH="$HOST_BIN:\$PATH" bash -c "\$*"
EOF
}

# fake_host: the host's sudo, docker, systemctl, curl and the rest, keeping their state under
# .fake/ in the host's directory and recording what they are asked in record/host.
fake_host() {
  host_fake sudo <<EOF
user=root home=
while ((\$#)); do
  case \$1 in
    -n) shift ;;
    -H) home=1; shift ;;
    -u) user=\$2; shift 2 ;;
    *) break ;;
  esac
done
printf '%s\n' "sudo -u \$user \$1" >> "$RECORD/host"
if [[ -n \$home ]]; then
  export HOME="$HOST/home/\$user"
fi
exec "\$@"
EOF
  host_fake docker <<EOF
printf '%s\n' "docker \$*" >> "$RECORD/host"
state="$HOST/.fake/docker"
mkdir -p "\$state"
case \$1 in
  inspect)
    name=\${*: -1}
    [[ -f \$state/\$name.spec ]] || { echo "Error: No such object: \$name" >&2; exit 1; }
    echo "\$(cat "\$state/\$name.spec") \$(cat "\$state/\$name.running")"
    ;;
  run)
    shift
    args=("\$@") name= spec=
    while ((\$#)); do
      case \$1 in
        --name) name=\$2; shift 2 ;;
        --label) spec=\${2#ci-host.spec=}; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n \$name && ! -f \$state/\$name.spec ]] || { echo "docker: the name is in use" >&2; exit 125; }
    echo "\$spec" > "\$state/\$name.spec"
    echo true > "\$state/\$name.running"
    printf '%s\n' "\${args[@]}" > "\$state/\$name.args"
    echo fixture-container-id
    ;;
  rm) rm -f "\$state/\${*: -1}".* ;;
  start) echo true > "\$state/\${*: -1}.running" ;;
  *) echo "docker: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  host_fake systemctl <<EOF
printf '%s\n' "systemctl \$*" >> "$RECORD/host"
state="$HOST/.fake/systemd"
mkdir -p "\$state"
args=()
for arg; do
  [[ \$arg == --quiet ]] || args+=("\$arg")
done
set -- "\${args[@]}"
case \$1 in
  daemon-reload) ;;
  is-enabled) [[ -f \$state/\$2.enabled ]] ;;
  is-active) [[ -f \$state/\$2.active ]] ;;
  enable) touch "\$state/\${*: -1}.enabled"; [[ \$2 != --now ]] || touch "\$state/\${*: -1}.active" ;;
  disable) rm -f "\$state/\${*: -1}.enabled"; [[ \$2 != --now ]] || rm -f "\$state/\${*: -1}.active" ;;
  start | restart) touch "\$state/\$2.active" ;;
  stop) rm -f "\$state/\$2.active" ;;
  *) echo "systemctl: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  host_fake curl <<EOF
printf '%s\n' "curl \$*" >> "$RECORD/host"
out= url=
while ((\$#)); do
  case \$1 in
    -o | --retry) [[ \$1 == -o ]] && out=\$2; shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
[[ \$url == https://github.com/actions/runner/releases/download/v9.8.7/actions-runner-linux-x64-9.8.7.tar.gz ]] || { echo "curl: unexpected \$url" >&2; exit 22; }
cp "$BATS_TEST_TMPDIR/served.tar.gz" "\$out"
EOF
  host_fake id <<EOF
[[ \$2 == ci-runner && -d "$HOST/home/ci-runner" ]] || { echo "id: \$2: no such user" >&2; exit 1; }
echo 1001
EOF
  host_fake mountpoint <<EOF
grep -qxF -- "\${*: -1}" "$HOST/.fake/mounts"
EOF
  host_fake chown <<EOF
printf '%s\n' "chown \$*" >> "$RECORD/host"
EOF
  host_fake uname <<'EOF'
echo x86_64
EOF
  host_fake cloud-init <<'EOF'
echo 'status: done'
EOF
  host_fake apt-get <<EOF
printf '%s\n' "apt-get \$*" >> "$RECORD/host"
echo "apt-get: unexpected \$*" >&2
exit 1
EOF
}

# runner_package: the runner release the fake host's curl serves, and the versions.yaml that pins
# it. Its config.sh records how it is called and takes only the right token, from its environment;
# it holds the tokens' hashes, never the tokens.
runner_package() {
  local package="$BATS_TEST_TMPDIR/package" registration removal
  registration=$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)
  removal=$(printf '%s' "$REMOVE_TOKEN" | sha256sum | cut -d' ' -f1)
  mkdir -p "$package/bin"
  cat > "$package/config.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "config.sh \$*" >> "$RECORD/host"
given=\$(printf '%s' "\${ACTIONS_RUNNER_INPUT_TOKEN-}" | sha256sum | cut -d' ' -f1)
if [[ \${1-} == remove ]]; then
  [[ \$given == $removal ]] || { echo "config.sh: not the remove token" >&2; exit 1; }
  rm -f .runner .credentials
else
  [[ \$given == $registration ]] || { echo "config.sh: not the registration token" >&2; exit 1; }
  echo '{"agentName": "lab-ci"}' > .runner
  echo '{"scheme": "OAuth"}' > .credentials
fi
echo "config.sh: the token came in its environment" >> "$RECORD/host"
EOF
  printf '#!/usr/bin/env bash\n' > "$package/run.sh"
  printf '#!/usr/bin/env bash\n' > "$package/bin/Runner.Listener"
  printf '#!/usr/bin/env bash\necho "installdependencies.sh run" >> "%s"\n' "$RECORD/host" > "$package/bin/installdependencies.sh"
  chmod +x "$package/config.sh" "$package/run.sh" "$package/bin/Runner.Listener" "$package/bin/installdependencies.sh"
  tar -czf "$BATS_TEST_TMPDIR/runner.tar.gz" -C "$package" .
  cp "$BATS_TEST_TMPDIR/runner.tar.gz" "$BATS_TEST_TMPDIR/served.tar.gz"
  cat > "$REPO/versions.yaml" <<EOF
actions_runner: 9.8.7
actions_runner_sha256: $(sha256sum "$BATS_TEST_TMPDIR/runner.tar.gz" | cut -d' ' -f1)
dagger_engine: $ENGINE
EOF
}

# trust: records the host's key, as an accepted fingerprint leaves it.
trust() {
  mkdir -p "${KNOWN_HOSTS%/*}"
  printf '%s %s\n' "$ADDRESS" "$HOST_KEY" > "$KNOWN_HOSTS"
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set.
recipe() {
  run timeout 60 env -i HOME="$HOME_DIR" TMPDIR="$TEMP_DIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# snapshot: every path on the fake host with its type and mode, and every file's content hash.
snapshot() {
  (cd "$HOST" && find . -printf '%y %m %p\n' | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort)
}

# changes: the calls recorded on the host that change something there.
changes() {
  grep -E '^(docker (run|rm|start|stop)|systemctl (daemon-reload|enable|disable|start|stop|restart)|curl|apt-get|chown|config\.sh|installdependencies\.sh) ' "$RECORD/host" || true
}

# absent TEXT FILE...: fails when any FILE, or any file under a directory FILE, holds TEXT.
absent() {
  local text=$1
  shift
  if grep -rqF -- "$text" "$@"; then
    echo "found $text in $*" >&2
    return 1
  fi
}

@test "Setup starts the pinned engine and the pinned, checksum-verified runner, and a second run changes nothing" {
  trust

  recipe ci-host-setup < /dev/null

  [ "$status" -eq 0 ]
  # The engine: the pinned image, its state on the cache volume, its socket owned by the runner's
  # group, and no root capabilities for what it runs.
  engine=$(cat "$HOST/.fake/docker/dagger-engine.args")
  grep -qxF -- "$ENGINE" <<< "$engine"
  grep -qx -- --privileged <<< "$engine"
  grep -qx /var/lib/dagger:/var/lib/dagger <<< "$engine"
  grep -qx /run/dagger:/run/dagger <<< "$engine"
  grep -qx /etc/ci-host/engine.json:/etc/dagger/engine.json:ro <<< "$engine"
  [ "$(grep -A1 -x -- --addr <<< "$engine" | tail -1)" = unix:///run/dagger/engine.sock ]
  [ "$(grep -A1 -x -- --group <<< "$engine" | tail -1)" = 1001 ]
  jq -e '.security.insecureRootCapabilities == false' "$HOST/etc/ci-host/engine.json"
  # The runner: the pinned release, its checksum verified, unpacked in the runner's home and owned
  # by the runner's user, registered once under the runner's name as its only label.
  grep -qE '^curl .* https://github\.com/actions/runner/releases/download/v9\.8\.7/actions-runner-linux-x64-9\.8\.7\.tar\.gz$' "$RECORD/host"
  [ -x "$HOST/home/ci-runner/actions-runner/config.sh" ]
  grep -qx "chown -R ci-runner: $HOST/home/ci-runner/actions-runner" "$RECORD/host"
  [ "$(grep -c '^config\.sh ' "$RECORD/host")" -eq 1 ]
  grep -qx 'sudo -u ci-runner bash' "$RECORD/host"
  grep -qx 'config.sh --unattended --url https://github.com/fixture-owner/fixture-repo --name lab-ci --labels lab-ci --no-default-labels --disableupdate --replace --work _work' "$RECORD/host"
  # A service under the runner's user, with the engine's socket and the job-started hook, enabled
  # and running.
  unit="$HOST/etc/systemd/system/ci-runner.service"
  for line in User=ci-runner WorkingDirectory=/home/ci-runner/actions-runner \
    ExecStart=/home/ci-runner/actions-runner/run.sh \
    Environment=DAGGER_ENGINE=unix:///run/dagger/engine.sock \
    Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/ci-host/job-started.sh; do
    grep -qxF -- "$line" "$unit" || { echo "the unit has no line $line"; return 1; }
  done
  [ -f "$HOST/.fake/systemd/ci-runner.service.enabled" ]
  [ -f "$HOST/.fake/systemd/ci-runner.service.active" ]
  # The runner's package installed the libraries it needs, once.
  [ "$(grep -cx 'installdependencies.sh run' "$RECORD/host")" -eq 1 ]
  # The hook is the one scripts/lib/ci-host.sh writes, root's and not the runner's to change. The
  # runner runs a hook only by its file's extension, with bash for .sh.
  diff <(. "$ROOT/scripts/lib/ci-host.sh" && ci_host_hook) "$HOST/usr/local/lib/ci-host/job-started.sh"
  [ "$(stat -c %a "$HOST/usr/local/lib/ci-host/job-started.sh")" = 755 ]
  [[ $output == *"CI_RUNNER_LABEL"*"lab-ci"* ]]

  before=$(snapshot)
  : > "$RECORD/host"
  : > "$RECORD/argv"

  recipe ci-host-setup < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"nothing changed"* ]]
  [ "$(snapshot)" = "$before" ]
  [ -z "$(changes)" ]
  run grep -c '^gh ' "$RECORD/argv"
  [ "$output" = 0 ]
}

@test "The registration token reaches no command line, no output and no file" {
  trust

  recipe ci-host-setup < /dev/null

  [ "$status" -eq 0 ]
  printed=("$output")
  [ -f "$HOST/home/ci-runner/actions-runner/.runner" ]

  recipe ci-host-remove < /dev/null

  [ "$status" -eq 0 ]
  printed+=("$output")
  [ ! -e "$HOST/home/ci-runner/actions-runner/.runner" ]
  grep -qx 'config.sh remove' "$RECORD/host"
  # Each token reached the runner's configuration, in its environment.
  [ "$(grep -cx 'config.sh: the token came in its environment' "$RECORD/host")" -eq 2 ]
  # The record holds every command line: the tools the recipe runs here, ssh with each remote
  # command, and what runs on the host.
  grep -q '^gh api .*registration-token' "$RECORD/argv"
  grep -q '^gh api .*remove-token' "$RECORD/argv"
  grep -q '^ssh ' "$RECORD/argv"
  for token in "$TOKEN" "$REMOVE_TOKEN"; do
    [[ ${printed[*]} != *"$token"* ]]
    absent "$token" "$RECORD" "$HOST" "$REPO" "$HOME_DIR" "$TEMP_DIR"
  done
}

@test "The CI host recipes run gh and ssh with none of the stack's secrets" {
  trust

  recipe ci-host-setup < /dev/null
  [ "$status" -eq 0 ]
  recipe ci-host-remove < /dev/null
  [ "$status" -eq 0 ]

  for tool in gh ssh; do
    echo "$tool"
    [ -s "$RECORD/names.$tool" ]
    if grep -qE '^(AWS_|OS_|TF_VAR_|TF_ENCRYPTION|TF_STATE_PASSPHRASE|CLUSTER_S3_|SOPS_AGE_|FLUX_AGE_|OPERATOR_CIDRS)' "$RECORD/names.$tool"; then
      return 1
    fi
    # What is no secret reaches it.
    grep -qx CI_HOST_SSH_USER "$RECORD/names.$tool"
  done
}

@test "A host whose key is not known is refused until its fingerprint has been accepted" {
  recipe ci-host-setup <<< no

  [ "$status" -ne 0 ]
  [[ $output == *"SHA256:FixtureFingerprintOfTheCiHost0123456789abcd"* ]]
  [[ $output == *"not accepted"* ]]
  [[ $output != *"$ADDRESS"* ]]
  [ ! -s "$KNOWN_HOSTS" ]
  run grep -c '^ssh ' "$RECORD/argv"
  [ "$output" = 0 ]
  [ ! -e "$HOST/.fake/docker" ]

  recipe ci-host-setup <<< yes

  [ "$status" -eq 0 ]
  grep -qF -- "${HOST_KEY#* }" "$KNOWN_HOSTS"
  [ "$(stat -c %a "$KNOWN_HOSTS")" = 600 ]
  calls=$(grep '^ssh ' "$RECORD/argv")
  [ -n "$calls" ]
  while IFS= read -r call; do
    [[ " $call " == *" -o StrictHostKeyChecking=yes "* ]]
    [[ " $call " == *" -o UserKnownHostsFile=$KNOWN_HOSTS "* ]]
  done <<< "$calls"
  run grep -E 'StrictHostKeyChecking=(no|off|accept-new)|KnownHostsFile=/dev/null .*UserKnownHostsFile|UserKnownHostsFile=/dev/null' "$RECORD/argv"
  [ "$status" -eq 1 ]

  # Known now: nothing is asked and nothing scanned.
  : > "$RECORD/argv"

  recipe ci-host-setup < /dev/null

  [ "$status" -eq 0 ]
  run grep -c '^ssh-keyscan ' "$RECORD/argv"
  [ "$output" = 0 ]

  # A host that answers with another key than the recorded one is refused by ssh.
  printf '%s %s\n' "$ADDRESS" 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherHostKeyAnotherHostKeyAnother' > "$KNOWN_HOSTS"
  : > "$RECORD/host"

  recipe ci-host-setup < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"Host key verification failed"* ]]
  [ ! -s "$RECORD/host" ]
}

# console FINGERPRINT: the CI host's console, as cloud-init leaves it after the first boot, holding
# FINGERPRINT.
console() {
  {
    echo "Cloud-init v. 22.4.2 running 'modules:final' at Mon, 01 Jan 2024 00:00:09 +0000. Up 9.9 seconds."
    echo '-----BEGIN SSH HOST KEY FINGERPRINTS-----'
    echo "256 $1 root@lab-ci (ED25519)"
    echo '-----END SSH HOST KEY FINGERPRINTS-----'
  } > "$RECORD/console-$INSTANCE"
}

@test "A CI host whose offered keys are on its console is trusted without a prompt, and one that offers another is refused" {
  # The host offers the key whose fingerprint the fake ssh-keygen prints, and its instance printed it.
  console SHA256:FixtureFingerprintOfTheCiHost0123456789abcd

  recipe ci-host-setup < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type yes"* ]]
  [[ $output == *"CI host: the 1 SSH host key it offers matches its instance's console; recorded in "* ]]
  grep -qF -- "${HOST_KEY#* }" "$KNOWN_HOSTS"
  grep -qx "openstack console log show --lines 1000 $INSTANCE" "$RECORD/argv"
  [[ $output != *"$ADDRESS"* ]]

  # Its instance printed another key's fingerprint: refused, whatever is typed, and the host is
  # never connected to.
  rm "$KNOWN_HOSTS"
  console SHA256:SomeoneElsesFingerprint0123456789abcdefghij
  : > "$RECORD/argv"

  recipe ci-host-setup <<< yes

  [ "$status" -ne 0 ]
  [[ $output == *"offers a key its instance did not print"* ]]
  [[ $output != *"Type yes"* ]]
  [[ $output != *"$ADDRESS"* ]]
  [ ! -s "$KNOWN_HOSTS" ]
  run grep -c '^ssh ' "$RECORD/argv"
  [ "$output" = 0 ]
}

@test "setup installs nothing from a runner package whose checksum is not its pin" {
  trust
  echo 'not the pinned package' > "$BATS_TEST_TMPDIR/served.tar.gz"

  recipe ci-host-setup < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"checksum"* ]]
  [ ! -e "$HOST/home/ci-runner/actions-runner" ]
  [ ! -e "$HOST/etc/systemd/system/ci-runner.service" ]
  run grep -c '^gh ' "$RECORD/argv"
  [ "$output" = 0 ]
}

@test "setup starts no engine while the cache volume is not mounted" {
  trust
  : > "$HOST/.fake/mounts"

  recipe ci-host-setup < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"/var/lib/dagger is not mounted"* ]]
  [ ! -e "$HOST/.fake/docker" ]
  [ -z "$(changes)" ]
}

@test "setup and remove name what they need before they connect" {
  for name in CI_HOST_SSH_USER CI_HOST_IMAGE; do
    for script in ci-host-setup ci-host-remove; do
      echo "$script without $name"
      kept=()
      for entry in "${ENVIRONMENT[@]}"; do
        [[ $entry == "$name="* ]] || kept+=("$entry")
      done
      : > "$RECORD/argv"
      ENVIRONMENT_SAVED=("${ENVIRONMENT[@]}")
      ENVIRONMENT=("${kept[@]}")

      recipe "$script" < /dev/null

      ENVIRONMENT=("${ENVIRONMENT_SAVED[@]}")
      [ "$status" -ne 0 ]
      [[ $output == *"$name is not set"* ]]
      run grep -cE '^(ssh|ssh-keyscan|gh|tofu) ' "$RECORD/argv"
      [ "$output" = 0 ]
    done
  done
}

@test "remove stops the runner and deregisters it, and a second run asks GitHub for nothing" {
  trust
  recipe ci-host-setup < /dev/null
  [ "$status" -eq 0 ]
  : > "$RECORD/host"
  : > "$RECORD/argv"

  recipe ci-host-remove < /dev/null

  [ "$status" -eq 0 ]
  [ ! -e "$HOST/.fake/systemd/ci-runner.service.enabled" ]
  [ ! -e "$HOST/.fake/systemd/ci-runner.service.active" ]
  grep -qx 'config.sh remove' "$RECORD/host"
  # The engine and its cache stay.
  [ -f "$HOST/.fake/docker/dagger-engine.spec" ]
  : > "$RECORD/argv"
  : > "$RECORD/host"

  recipe ci-host-remove < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"not registered"* ]]
  run grep -c '^gh ' "$RECORD/argv"
  [ "$output" = 0 ]
  [ -z "$(changes)" ]
}

@test "the CI host's pins are well formed, and its engine is the dagger CLI's version" {
  versions="$ROOT/versions.yaml"
  [[ $(yq '.actions_runner' "$versions") =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ $(yq '.actions_runner_sha256' "$versions") =~ ^[0-9a-f]{64}$ ]]
  engine=$(yq '.dagger_engine' "$versions")
  [[ $engine =~ ^registry\.dagger\.io/engine:v([^@]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$(yq -p toml '.tools."http:dagger".version' "$ROOT/mise.toml")" ]
}
