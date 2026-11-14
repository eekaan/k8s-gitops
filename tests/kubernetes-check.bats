#!/usr/bin/env bats
# Proves features/kubernetes-layout.feature; each test carries its scenario's title.
# Needs kustomize, yq and flux on PATH (the versions pinned for the repository).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$REPO/scripts/kubernetes-check"
  TREE="$BATS_TEST_TMPDIR/tree"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# put PATH: writes stdin to PATH in the fixture tree.
put() {
  mkdir -p "$(dirname "$TREE/$1")"
  cat >"$TREE/$1"
}

# cluster_app NAME: Flux's own application NAME in the fixture cluster, reconciled from the sync
# source with the root's decryption and substitution, its app/ holding one ConfigMap.
cluster_app() {
  local dir="kubernetes/clusters/test/flux-system/$1"
  put "$dir/ks.yaml" <<EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $1
  namespace: flux-system
spec:
  interval: 30m
  path: ./clusters/test/flux-system/$1/app
  prune: true
  targetNamespace: flux-system
  sourceRef:
    kind: OCIRepository
    name: flux-system
  decryption:
    provider: sops
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
EOF
  put "$dir/app/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put "$dir/app/configmap.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $1
EOF
}

# A small tree that passes the check: one cluster with Flux's own two applications, one
# namespace, one application. Each failure scenario breaks one rule in it.
valid_tree() {
  put kubernetes/clusters/test/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ks.yaml
  - flux-system/flux-operator/ks.yaml
  - flux-system/flux-instance/ks.yaml
EOF
  cluster_app flux-operator
  cluster_app flux-instance
  put kubernetes/clusters/test/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster
  namespace: flux-system
spec:
  interval: 30m
  path: ./apps/overlays/test
  prune: true
  sourceRef:
    kind: OCIRepository
    name: flux-system
  decryption:
    provider: sops
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
EOF
  put kubernetes/clusters/test/cluster-config.example.yaml <<'EOF'
---
CLUSTER_DOMAIN: example.com
EOF
  put kubernetes/apps/overlays/test/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/demo
  - ../../base/demo/hello/ks.yaml
EOF
  put kubernetes/apps/base/demo/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo
resources:
  - namespace.yaml
EOF
  put kubernetes/apps/base/demo/namespace.yaml <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
EOF
  hello_ks </dev/null
  put kubernetes/apps/base/demo/hello/app/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put kubernetes/apps/base/demo/hello/app/configmap.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello
data:
  domain: "${CLUSTER_DOMAIN}"
EOF
  run "$CHECK" "$TREE"
  if [ "$status" -ne 0 ]; then
    echo "the unbroken fixture tree already fails the check:"
    echo "$output"
    return 1
  fi
}

# hello_ks: writes the fixture application's ks.yaml with stdin appended under spec.
hello_ks() {
  {
    cat <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: flux-system
spec:
  path: ./apps/base/demo/hello/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: hello
EOF
    cat
  } | put kubernetes/apps/base/demo/hello/ks.yaml
}

# check: runs the check on the fixture tree; its output shows when a test fails.
check() {
  run "$CHECK" "$TREE"
  echo "$output"
}

# fails_naming WHAT TEXT: the check failed, and one of its messages names WHAT and says TEXT.
fails_naming() {
  [ "$status" -ne 0 ] || { echo "expected the check to fail"; return 1; }
  grep -F -- "$1" <<<"$output" | grep -qF -- "$2" ||
    { echo "no failure message naming '$1' that says '$2'"; return 1; }
}

# build_root: copies the repository's kubernetes/ tree, adds the child Kustomizations given on
# stdin to the cluster's overlay, and builds the root the way Flux does into $BUILD.
build_root() {
  cp -R "$REPO/kubernetes" "$BATS_TEST_TMPDIR/"
  # flux build only reads paths at or below the working directory.
  cd "$BATS_TEST_TMPDIR" || return 1
  local root="kubernetes/clusters/lab-sto2/ks.yaml" overlay
  overlay="kubernetes/$(yq '.spec.path' "$root")"
  CHILDREN="$overlay/fixture-children.yaml"
  cat >"$CHILDREN"
  if [ -s "$CHILDREN" ]; then
    yq -i '.resources += ["fixture-children.yaml"]' "$overlay/kustomization.yaml"
  fi
  BUILD="$BATS_TEST_TMPDIR/build.yaml"
  flux build kustomization "$(yq '.metadata.name' "$root")" \
    --path "$overlay" --kustomization-file "$root" --dry-run --in-memory-build >"$BUILD"
}

# child NAME EXPRESSION: yq EXPRESSION on the built child Kustomization NAME.
child() {
  yq ea -N "[select(.kind == \"Kustomization\" and .metadata.name == \"$1\")] | .[0] | $2" "$BUILD"
}

# has_defaults NAME TIMEOUT: the built child NAME carries every default the root sets, with TIMEOUT.
has_defaults() {
  local got
  got="$(child "$1" '[.spec.interval, .spec.retryInterval, .spec.timeout, .spec.prune,
    .spec.decryption.provider, .spec.deletionPolicy,
    ([.spec.postBuild.substituteFrom[] | .kind + "/" + .name] | join(",")),
    .spec.patches[0].target.kind, .spec.patches[0].target.labelSelector] | map(tostring) | join(" ")')"
  echo "$1: $got"
  [ "$got" = "30m 1m $2 true sops WaitForTermination ConfigMap/cluster-config,Secret/cluster-secrets HelmRelease k8s-gitops/defaults!=disabled" ]
}

# unchanged NAME: the built child NAME has exactly the spec written for it on build_root's stdin.
unchanged() {
  local want got
  want="$(yq -o json -I0 "select(.metadata.name == \"$1\") | .spec | sort_keys(..)" "$CHILDREN")"
  got="$(child "$1" '.spec | sort_keys(..)' | yq -o json -I0)"
  echo "$1, written: $want"
  echo "$1, built:   $got"
  [ -n "$got" ]
  [ "$got" = "$want" ]
}

@test "The tree builds offline" {
  run "$CHECK"
  echo "$output"
  [ "$status" -eq 0 ]

  local built=0 dir
  while read -r dir; do
    grep -qxF "built $dir" <<<"$output" || { echo "not built: $dir"; return 1; }
    built=$((built + 1))
  done < <(cd "$REPO" && find kubernetes -name kustomization.yaml -exec dirname {} \;)
  [ "$built" -gt 0 ]

  # Every Flux Kustomization, the cluster roots and each application, is built by Flux as well.
  local ks flux_built=0
  while read -r ks; do
    grep -qxF "built $ks" <<<"$output" || { echo "not built: $ks"; return 1; }
    flux_built=$((flux_built + 1))
  done < <(cd "$REPO" && find kubernetes -name ks.yaml)
  [ "$flux_built" -gt 1 ]

  # Each cluster directory as well, the way the instance's sync Kustomization builds it.
  local cluster
  for cluster in "$REPO"/kubernetes/clusters/*/; do
    cluster="kubernetes/clusters/$(basename "$cluster")"
    grep -qxF "built $cluster as the instance's sync Kustomization" <<<"$output" ||
      { echo "not built as the sync Kustomization: $cluster"; return 1; }
  done
}

@test "A Kustomization outside flux-system fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: demo
spec:
  path: ./apps/base/demo/hello/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: hello
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "must be in namespace flux-system"
}

@test "An undeclared substitution variable fails the check" {
  valid_tree
  cat >>"$TREE/kubernetes/apps/base/demo/hello/app/configmap.yaml" <<'EOF'
  undeclared: "${UNDECLARED_VAR}"
  defaulted: "${DEFAULTED_VAR:=fallback}"
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/app/configmap.yaml UNDECLARED_VAR
  [[ "$output" != *DEFAULTED_VAR* ]]
}

@test "An application without an app directory fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/no-app/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: no-app
  namespace: flux-system
spec:
  path: ./apps/base/demo/no-app/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: no-app
EOF

  check
  fails_naming "kubernetes/apps/base/demo/no-app:" "needs both ks.yaml and app/"
}

@test "Children inherit the root defaults" {
  build_root <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: opted-out
  namespace: flux-system
  labels:
    k8s-gitops/defaults: disabled
spec:
  interval: 1h
  path: ./apps/base/demo/opted-out/app
  prune: false
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: opted-out
EOF

  local children name
  children="$(yq -N 'select(.kind == "Kustomization" and .metadata.labels["k8s-gitops/defaults"] != "disabled") | .metadata.name' "$BUILD")"
  [ -n "$children" ]
  for name in $children; do
    has_defaults "$name" 3m
  done
  unchanged opted-out
}

@test "HelmReleases applied by a child get the release defaults unless they opt out" {
  build_root </dev/null
  local releases="$BATS_TEST_TMPDIR/releases"
  mkdir -p "$releases"
  # The patches a child carries, applied by kustomize as Flux applies them when it builds the child.
  yq ea '[select(.kind == "Kustomization" and .metadata.labels["k8s-gitops/defaults"] != "disabled")] | .[0]
    | {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
       "resources": ["releases.yaml"], "patches": .spec.patches}' "$BUILD" >"$releases/kustomization.yaml"
  cat >"$releases/releases.yaml" <<'EOF'
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: plain
spec:
  interval: 1h
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: opted-out
  labels:
    k8s-gitops/defaults: disabled
spec:
  interval: 1h
EOF
  kustomize build "$releases" >"$BATS_TEST_TMPDIR/releases.yaml"

  local want got
  want="$(yq -o json -I0 'sort_keys(..)' <<'EOF'
interval: 1h
install:
  timeout: 10m
  replace: true
  crds: CreateReplace
  createNamespace: true
  remediation:
    retries: 3
upgrade:
  remediation:
    remediateLastFailure: true
    retries: 3
    strategy: rollback
  cleanupOnFail: true
  crds: CreateReplace
test:
  enable: true
rollback:
  force: true
  cleanupOnFail: true
uninstall:
  keepHistory: false
driftDetection:
  mode: enabled
maxHistory: 3
EOF
)"
  got="$(yq -o json -I0 'select(.metadata.name == "plain") | .spec | sort_keys(..)' "$BATS_TEST_TMPDIR/releases.yaml")"
  echo "plain release, want: $want"
  echo "plain release, got:  $got"
  [ "$got" = "$want" ]
  got="$(yq -o json -I0 'select(.metadata.name == "opted-out") | .spec' "$BATS_TEST_TMPDIR/releases.yaml")"
  echo "opted-out release: $got"
  [ "$got" = '{"interval":"1h"}' ]
}

@test "The long-timeout label lengthens the timeout and keeps the other defaults" {
  build_root <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: slow
  namespace: flux-system
  labels:
    k8s-gitops/timeout: long
spec:
  path: ./apps/base/demo/slow/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: slow
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: slow-opted-out
  namespace: flux-system
  labels:
    k8s-gitops/defaults: disabled
    k8s-gitops/timeout: long
spec:
  interval: 1h
  path: ./apps/base/demo/slow-opted-out/app
  prune: true
  timeout: 20m
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: slow-opted-out
EOF

  has_defaults slow 10m
  unchanged slow-opted-out
}

@test "A ks.yaml that is not a Flux Kustomization fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - app
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "must be a Flux Kustomization"
}

@test "A Kustomization without a sourceRef fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: flux-system
spec:
  path: ./apps/base/demo/hello/app
  targetNamespace: demo
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "must have a sourceRef"
}

@test "An application without a targetNamespace fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: flux-system
spec:
  path: ./apps/base/demo/hello/app
  sourceRef:
    kind: ExternalArtifact
    name: hello
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "targetNamespace"
}

@test "A kustomization that does not build fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/app/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - missing.yaml
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/app/kustomization.yaml "kustomize build failed"
}

@test "A root Kustomization whose patches do not apply fails the check" {
  valid_tree
  cat >>"$TREE/kubernetes/clusters/test/ks.yaml" <<'EOF'
  patches:
    - patch: |-
        spec: [not closed
      target:
        kind: Kustomization
EOF

  check
  fails_naming kubernetes/clusters/test/ks.yaml "flux build"
}

@test "A cluster directory without a kustomization.yaml fails the check" {
  valid_tree
  rm "$TREE/kubernetes/clusters/test/kustomization.yaml"

  check
  fails_naming "kubernetes/clusters/test:" "needs a kustomization.yaml"
}

@test "A cluster directory that builds anything but the root and Flux itself fails the check" {
  valid_tree
  local kustomization="$TREE/kubernetes/clusters/test/kustomization.yaml"
  put kubernetes/clusters/test/extra.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: extra
  namespace: flux-system
EOF
  yq -i '.resources += ["extra.yaml"]' "$kustomization"

  check
  fails_naming "kubernetes/clusters/test:" "ConfigMap/extra"

  yq -i '.resources -= ["extra.yaml", "flux-system/flux-instance/ks.yaml"]' "$kustomization"
  check
  fails_naming "kubernetes/clusters/test:" "does not build Kustomization/flux-instance"
}

@test "An application in a cluster directory whose names do not match its directory fails the check" {
  valid_tree
  local ks=kubernetes/clusters/test/flux-system/flux-operator/ks.yaml
  yq -i '.metadata.name = "operator"' "$TREE/$ks"
  check
  fails_naming "$ks" "metadata.name must be flux-operator"

  cluster_app flux-operator
  yq -i '.spec.sourceRef = {"kind": "ExternalArtifact", "name": "flux-operator"}' "$TREE/$ks"
  check
  fails_naming "$ks" "sourceRef must be OCIRepository flux-system"

  cluster_app flux-operator
  yq -i '.spec.targetNamespace = "other"' "$TREE/$ks"
  check
  fails_naming "$ks" "targetNamespace must be flux-system"

  cluster_app flux-operator
  yq -i '.spec.path = "./clusters/test/flux-system/flux-instance/app"' "$TREE/$ks"
  check
  fails_naming "$ks" "spec.path must be ./clusters/test/flux-system/flux-operator/app"
}

@test "An undeclared variable in a cluster directory's Kustomizations fails the check" {
  valid_tree
  # shellcheck disable=SC2016 # The variable is for Flux, not the shell.
  yq -i '.metadata.annotations.owner = "${ROOT_OWNER}"' "$TREE/kubernetes/clusters/test/ks.yaml"

  check
  fails_naming kubernetes/clusters/test/ks.yaml ROOT_OWNER
}

@test "Flux's own application without the root's decryption and substitution fails the check" {
  valid_tree
  local ks=kubernetes/clusters/test/flux-system/flux-operator/ks.yaml
  yq -i 'del(.spec.decryption)' "$TREE/$ks"
  check
  fails_naming "$ks" "spec.decryption must be"

  cluster_app flux-operator
  yq -i 'del(.spec.postBuild)' "$TREE/$ks"
  check
  fails_naming "$ks" "spec.postBuild.substituteFrom must be"
}

@test "An application with the name of a cluster's own application fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/flux-operator flux-operator demo flux-operator ./apps/base/demo/flux-operator/app

  check
  fails_naming "kubernetes/clusters/test/flux-system/flux-operator:" "also used by kubernetes/apps/base/demo/flux-operator"
}

@test "A ks.yaml that is not valid YAML fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/broken/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: [not closed
EOF
  put kubernetes/apps/base/demo/broken/app/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put kubernetes/apps/base/demo/broken/app/configmap.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: broken
EOF

  check
  fails_naming kubernetes/apps/base/demo/broken/ks.yaml "not valid YAML"
}

@test "A ks.yaml with an empty document passes the check" {
  valid_tree
  hello_ks <<'EOF'
---
EOF

  check
  [ "$status" -eq 0 ]
}

@test "The check gives its tools no cluster to reach" {
  valid_tree
  local shims="$BATS_TEST_TMPDIR/shims" log="$BATS_TEST_TMPDIR/environment.log" tool real
  mkdir -p "$shims"
  for tool in flux kustomize; do
    real="$(command -v "$tool")"
    cat >"$shims/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool KUBECONFIG=\${KUBECONFIG-unset} KUBERNETES_SERVICE_HOST=\${KUBERNETES_SERVICE_HOST-unset}" >>"$log"
exec "$real" "\$@"
EOF
    chmod +x "$shims/$tool"
  done

  run env KUBECONFIG="$BATS_TEST_TMPDIR/kubeconfig" KUBERNETES_SERVICE_HOST=cluster.example.com \
    PATH="$shims:$PATH" "$CHECK" "$TREE"
  echo "$output"
  cat "$log"
  [ "$status" -eq 0 ]
  grep -q '^flux ' "$log"
  grep -q '^kustomize ' "$log"
  [ "$(grep -vc ' KUBECONFIG=/dev/null KUBERNETES_SERVICE_HOST=unset$' "$log")" -eq 0 ]
}

# app DIR NAME TARGET_NAMESPACE SOURCE_NAME PATH: an application at DIR in the fixture tree, its
# ks.yaml written from the arguments and its app/ holding one ConfigMap.
app() {
  put "$1/ks.yaml" <<EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $2
  namespace: flux-system
spec:
  path: $5
  targetNamespace: $3
  sourceRef:
    kind: ExternalArtifact
    name: $4
EOF
  put "$1/app/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put "$1/app/configmap.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: example
EOF
}

@test "An application whose names do not match its directory fails the check" {
  valid_tree
  local dir=kubernetes/apps/base/demo/hello
  app "$dir" greeting demo hello ./apps/base/demo/hello/app
  check
  fails_naming "$dir/ks.yaml" "metadata.name must be hello"

  app "$dir" hello demo greeting ./apps/base/demo/hello/app
  check
  fails_naming "$dir/ks.yaml" "sourceRef.name must be hello"
}

@test "An application whose targetNamespace is not its namespace directory fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/hello hello other hello ./apps/base/demo/hello/app

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "targetNamespace must be demo"
}

@test "An application whose path is not its own app directory fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/hello hello demo hello ./apps/base/demo/other/app

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "spec.path must be ./apps/base/demo/hello/app"
}

@test "An application name that is not a DNS label fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/Hello_World Hello_World demo Hello_World ./apps/base/demo/Hello_World/app

  check
  fails_naming "kubernetes/apps/base/demo/Hello_World:" "must be a DNS label"
}

@test "Two applications with the same name fail the check" {
  valid_tree
  app kubernetes/apps/base/other/hello hello other hello ./apps/base/other/hello/app

  check
  fails_naming "kubernetes/apps/base/other/hello:" "also used by kubernetes/apps/base/demo/hello"
}

# The spec fields the root's defaults overwrite on every child that has not opted out.
OVERRIDDEN_FIELDS='  interval: 1h
  retryInterval: 2m
  timeout: 5m
  prune: false
  deletionPolicy: Delete
  decryption:
    provider: sops
  patches:
    - patch: |-
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: hello
          labels:
            patched: "true"
      target:
        kind: ConfigMap
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: application-values'

@test "An application that sets a field the root overrides fails the check" {
  valid_tree
  hello_ks <<<"$OVERRIDDEN_FIELDS"

  check
  local field
  for field in interval retryInterval timeout prune deletionPolicy decryption patches postBuild.substituteFrom; do
    fails_naming kubernetes/apps/base/demo/hello/ks.yaml "spec.$field is overwritten"
  done
}

@test "An application with the opt-out label may set the fields the root overrides" {
  valid_tree
  hello_ks <<<"$OVERRIDDEN_FIELDS"
  yq -i '.metadata.labels["k8s-gitops/defaults"] = "disabled"' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"

  check
  [ "$status" -eq 0 ]
}

HELLO_APP=kubernetes/apps/base/demo/hello/app

@test "Variables Flux leaves alone pass the check" {
  valid_tree
  put "$HELLO_APP/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - script.yaml
configMapGenerator:
  - name: hello-values
    files:
      - values.yaml
generatorOptions:
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
EOF
  put "$HELLO_APP/values.yaml" <<'EOF'
url: http://${HELM_TEMPLATED}/
EOF
  put "$HELLO_APP/script.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: script
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
data:
  run.sh: echo "${SHELL_VAR}"
EOF
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  # ${COMMENTED_VAR} appears only in this comment.
  escaped: "$${ESCAPED_VAR}"
EOF

  check
  [ "$status" -eq 0 ]
}

@test "Variables the application or the cluster declares pass the check" {
  valid_tree
  put kubernetes/clusters/test/cluster-secrets.example.yaml <<'EOF'
---
SECRET_TOKEN: placeholder
EOF
  hello_ks <<'EOF'
  postBuild:
    substitute:
      APP_HOST: hello.example.com
EOF
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  host: "${APP_HOST}"
  token: "${SECRET_TOKEN}"
  defaulted: "${WITH_DEFAULT:=fallback}"
EOF

  check
  [ "$status" -eq 0 ]
}

@test "An undeclared variable in a generator's input file fails the check" {
  valid_tree
  put "$HELLO_APP/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
configMapGenerator:
  - name: settings
    files:
      - settings.json
EOF
  put "$HELLO_APP/settings.json" <<'EOF'
{"endpoint": "${JSON_VAR}"}
EOF

  check
  fails_naming "$HELLO_APP/settings.json" JSON_VAR
}

@test "An undeclared variable after an escaped dollar fails the check" {
  valid_tree
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  price: "$$${PRICE_VAR}"
EOF

  check
  fails_naming "$HELLO_APP/configmap.yaml" PRICE_VAR
}

@test "A default Flux cannot parse fails the check" {
  valid_tree
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  dashed: "${DASH_VAR-fallback}"
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "missing closing brace"
}

@test "An undeclared length expansion is named with its file" {
  valid_tree
  put "$HELLO_APP/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
configMapGenerator:
  - name: odd
    files:
      - odd:name.yaml
EOF
  put "$HELLO_APP/odd:name.yaml" <<'EOF'
length: ${#LENGTH_VAR}
EOF

  check
  fails_naming "$HELLO_APP/odd:name.yaml" LENGTH_VAR
}

@test "An undeclared variable in a namespace directory fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/namespace.yaml <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    owner: "${NAMESPACE_OWNER}"
EOF

  check
  fails_naming kubernetes/apps/base/demo/namespace.yaml NAMESPACE_OWNER
}
