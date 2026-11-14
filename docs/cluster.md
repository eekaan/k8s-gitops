# The cluster

The Talos cluster is created and changed by `just` recipes that check what they need before they
run anything. Each recipe that works on one cluster takes its name, `lab-sto2` when none is given,
and works in `talos/<cluster>/`: on `talman.yaml`, which `just infra-talman` renders from the
cluster stack and git ignores; on `secrets.sops.yaml`, the cluster's encrypted secrets bundle,
which is committed; and on talman's output directory `clusterconfig/`, which git ignores and which
holds the machine configurations, the talosconfig and the kubeconfig.

## From nothing to a Ready cluster

1. `just infra-apply sto2/plumbing`, then `just infra-apply sto2/cluster`
   ([infrastructure.md](infrastructure.md)): the nodes boot and wait in maintenance mode, and
   the cluster's `talman.yaml` is written. `just infra-talman` writes it again without applying.
2. `just cluster-age-key`, once: the Talos age key. Commit `talos/.sops.yaml`.
3. `just cluster-secrets`, once per cluster: the secrets bundle. Commit it.
4. `just cluster-flux-age-key`, once: the Flux age key. Commit `.sops.yaml`.
5. `just cluster-bootstrap`: every node configured, Cilium installed, what Flux needs before it
   starts applied, the kubelet serving-certificate approver installed, every node Ready.
6. `just cluster-flux`: what Flux needs before it starts applied, and Flux installed
   ([kubernetes.md](kubernetes.md#installing-flux)).

Later changes to a patch or to `talman.yaml`, and nodes OpenTofu adds, reach the nodes with
`just cluster-talos`.

## Upgrades

The Talos and Kubernetes versions are set in `versions.yaml` only, and reach the recipes through
the cluster's `talman.yaml`; the upgrade recipes take no version. Once a version has changed there
and `talman.yaml` has been rendered again, `just cluster-upgrade` moves the nodes to the Talos
version, then `just cluster-upgrade-k8s` moves the cluster to the Kubernetes version.

## The Talos age key

The secrets bundle holds the cluster's certificate authorities and keys. It is encrypted with sops
to one age key, the Talos age key, which the operator holds and CI gets as a secret; it never
enters the repository or the cluster (ADR 0005). The key Flux decrypts `kubernetes/` with is
another one, [the Flux age key](#the-flux-age-key), so a key held in the cluster does not open the
bundle.

Without the key the bundle cannot be decrypted, and no machine configuration, talosconfig or
kubeconfig can be made for the running cluster. Keep a copy of it away from the machine it was
made on.

`talos/.sops.yaml` holds its recipient, the public half, and a rule that matches
`secrets.sops.yaml` one directory below `talos/` and nothing else. talman hands sops that file and
the bundle's path itself, so the rule applies wherever talman runs from.

## The Flux age key

The SOPS files under `kubernetes/`, such as a cluster's `cluster-secrets`
([kubernetes.md](kubernetes.md#before-flux-starts)), are encrypted to the Flux age key. The operator
holds it, CI gets it as a secret, and the cluster holds it as the Secret `sops-age`, which Flux
decrypts with. The recipes refuse the Talos age key in its place.

`.sops.yaml` at the repository root holds its recipient and a rule that matches `*.sops.yaml`
under `kubernetes/` and nothing else, encrypting only `data` and `stringData`, so a Secret's kind,
name and keys stay readable. sops reads the nearest `.sops.yaml` above the directory it runs in,
and matches the rule against the file's path relative to that `.sops.yaml`. At the root it is
found from anywhere in the repository but `talos/`, where `talos/.sops.yaml` is nearer and matches
nothing under `kubernetes/`, so sops refuses rather than encrypt to the Talos age key; and it stays
out of the artifact, which is built from `kubernetes/`.

## Recipes

- `just cluster-age-key` creates the key with `age-keygen` at the path `SOPS_AGE_KEY_FILE` names,
  with mode 0600, unless a file is there, and writes its recipient into `talos/.sops.yaml` in place
  of the placeholder. It prints the recipient and nothing else. A second run changes nothing. It
  refuses a path inside the repository, and a `talos/.sops.yaml` that names another recipient,
  which it leaves as it is.
- `just cluster-flux-age-key` creates the Flux age key with `age-keygen` at the path
  `FLUX_AGE_KEY_FILE` names, with mode 0600, unless a file is there, and writes its recipient into
  `.sops.yaml` in place of the placeholder. It prints the recipient and nothing else. A second run
  changes nothing. It refuses a path inside the repository, the Talos age key, and a `.sops.yaml`
  that names another recipient, which it leaves as it is.
- `just cluster-secrets [cluster]` generates the bundle with `talman secrets generate`, which
  encrypts it by the rule in `talos/.sops.yaml`. It refuses when the cluster's `talman.yaml` is
  missing, while `talos/.sops.yaml` holds the placeholder, and when the bundle exists: a new bundle
  would not be trusted by the cluster's nodes. Afterwards it checks that the bundle has SOPS
  metadata and that every value in it is ciphertext; when not, it fails and leaves the file in
  place, to be removed without being committed.
- `just cluster-secrets-check`, part of `just ci`, fails on a `secrets.sops.yaml` anywhere under
  `talos/` that git tracks or would commit and that is not encrypted that way, naming the file
  and nothing of its content. It does not read `talos/.sops.yaml`, so the placeholder neither
  passes nor fails it; sops refuses to encrypt to the placeholder, so no bundle exists while it is
  there.
- `just cluster-bootstrap [cluster]` builds the cluster from nodes waiting in maintenance mode.
  It refuses, naming each, when the cluster's `talman.yaml` or `secrets.sops.yaml`, the age key's
  location or the API address is missing, or when `cluster-config` would refuse. Then, in order:
  1. It waits until every node in `talman.yaml` answers on the Talos API port, 50000, at the
     address talman reaches it on, for up to `TALOS_WAIT` seconds. It fails naming the nodes that
     did not answer; rebooting one is left to the operator.
  2. `talman apply --bootstrap --onboard-new-nodes` configures the first control plane, starts
     etcd on it, and configures the other nodes after it, one at a time.
  3. `just cluster-kubeconfig` fetches the kubeconfig.
  4. `scripts/install-cilium` installs Cilium through it
     ([kubernetes.md](kubernetes.md#applications-installed-before-flux)).
  5. `just cluster-config` applies what Flux needs before it starts, the approver's values among
     it.
  6. `scripts/install-app` installs the kubelet serving-certificate approver with those values.
     The kubelets request their serving certificates from the cluster
     (`talos/patches/all/kubelet.yaml`), and until the approver approves them, `kubectl logs` and
     `kubectl exec` fail.
  7. It waits until every node in `talman.yaml` is a Ready Kubernetes node.

  A second run is refused by talman, which bootstraps only when every control plane answers and
  none runs etcd. A bootstrap that stopped once etcd was running is therefore not run again: the
  nodes it did not reach are configured with `just cluster-talos --onboard`, and the steps after
  it are run by their own recipes, the approver's by
  `just app-install kubernetes/apps/base/kube-system/kubelet-csr-approver` with `KUBECONFIG` set to
  the cluster's kubeconfig. No health check runs: `talosctl health`, reaching the nodes through
  their floating addresses, compares those with the addresses the nodes hold on the node network,
  which differ by design, so it never passes.
- `just cluster-kubeconfig [cluster]` fetches the admin kubeconfig with `talman kubeconfig` into
  `clusterconfig/kubeconfig`, with mode 0600, and points it at `https://KUBE_API_ADDRESS:6443`:
  talman writes the cluster endpoint, the load balancer's address on the node network, which only
  the nodes reach. It prints the file's path. The recipes that use the cluster read it from there.
- `just cluster-talos [cluster] [--onboard] [--yes]` rolls the configuration out: the cluster's
  `talman.yaml` and the patches it lists, as they are now. It waits for every node as
  `cluster-bootstrap` does, then shows what `talman apply --dry-run` says would change on each
  node, with the cluster's secrets redacted, and applies once the cluster's name is typed back;
  `--yes` does not ask. talman applies one node at a time, control planes always alone, rebooting
  a node only when the change needs it and waiting for each to come back before the next. A node
  in maintenance mode, such as one OpenTofu has just added, is configured only with `--onboard`:
  the maintenance service authenticates nothing, and a node's configuration carries the cluster's
  keys. Without it, talman refuses a rollout while such a node is there. With nothing to change,
  nothing is asked or applied. It needs the cluster's `talman.yaml` and `secrets.sops.yaml` and
  the age key's location.
- `just cluster-upgrade [cluster] [--yes]` upgrades Talos on every node that does not run the
  version and schematic `talman.yaml` gives it. It shows which nodes `talman upgrade --dry-run`
  says are behind, and once the cluster's name is typed back, or with `--yes`, fetches the
  kubeconfig as `cluster-kubeconfig` does, takes an etcd snapshot with `talman etcd snapshot`, and
  goes through the nodes in `talman.yaml`'s order, one at a time. A node that is behind is drained
  with `kubectl drain`, upgraded with `talman upgrade`, and uncordoned once it is Ready, before the
  next is drained; a node on its version is left alone. Before each drain the API must answer
  `/readyz` through the kubeconfig within five minutes, or nothing more is drained. talosctl's own
  drain is turned off, as it reaches the API at the cluster endpoint, which only the nodes reach.
  At the end every node must run its version. A run that stops after draining a node leaves that
  node cordoned: uncordon it with kubectl once it is back; a second run skips it once it is on its
  version.
- `just cluster-upgrade-k8s [cluster] [--yes]` upgrades Kubernetes to the version `talman.yaml`
  gives. It shows what `talman upgrade-k8s --dry-run` says, and once the cluster's name is typed
  back, or with `--yes`, runs `talman upgrade-k8s` with an etcd snapshot first; talosctl moves the
  control plane components and the kubelets node by node. It reaches the API at
  `KUBE_API_ADDRESS`, given to talosctl as its endpoint. At the end every node must run the
  version.

  Both upgrade recipes do nothing and ask nothing when every node runs its version, and need what
  `cluster-talos` needs and the API address. An etcd snapshot holds every Secret in the cluster;
  talman writes it
  into `clusterconfig/` with mode 0600, and it stays there.
- `just cluster-config [cluster]` applies what Flux needs before it starts: the namespace
  `flux-system`, the ConfigMap `cluster-config`, the Secret `cluster-secrets` and the Secret
  `sops-age` ([kubernetes.md](kubernetes.md#before-flux-starts)). It refuses, naming each, when the
  cluster's `talman.yaml` or kubeconfig, `CLUSTER_DOMAIN`, the Flux age key or its recipient in
  `.sops.yaml` is missing, when the Flux age key is not the key of that recipient or is the Talos
  age key, and when a key of `cluster-config` or `cluster-secrets` cannot be filled or is not
  listed. A second run changes nothing.
- `just cluster-flux [cluster] [--reapply]` installs Flux on a cluster that runs none
  ([kubernetes.md](kubernetes.md#installing-flux)). It needs what `cluster-config` needs.

A failing recipe ends with a line naming the step it failed in.

## Not automated

- Rebooting a node that does not answer on the Talos API port.
- Copying an etcd snapshot anywhere else, encrypted or not.

## What the recipes print

The recipes' own lines name nodes by hostname, never by address, and print none of the age keys,
the bundle, the kubeconfig, `KUBE_API_ADDRESS` and the values of `cluster-config` and
`cluster-secrets`. talman's and talosctl's output passes through as they print it, and names each
node with the address talman reaches it on; so do kubectl's and helm's, which name the objects they
apply.

## Environment

The recipes read `.env` and the environment as the infrastructure recipes do
([infrastructure.md](infrastructure.md#environment)), and name each variable that is missing. No
recipe prints a secret or reads the Talos age key itself: sops and talman get the key's location
from their environment. `cluster-config` reads the Flux age key, to hand it to kubectl and
age-keygen on standard input.

- `SOPS_AGE_KEY_FILE`: the path of the Talos age key, outside the repository. In CI,
  `SOPS_AGE_KEY` holds the key itself instead. Every recipe that reaches the nodes needs one of
  them, as talman decrypts the bundle.
- `KUBE_API_ADDRESS`: the Kubernetes API load balancer's floating address, an IPv4 address, as
  the API's certificate names are addresses. The cluster stack renders it into the cluster's
  `talman.yaml` as `values.apiAddress`, and the recipes read it from there; set in `.env` or the
  environment, it takes the place of that. `cluster-bootstrap`, `cluster-kubeconfig` and the
  upgrade recipes need it. It reaches a command line in one place: `cluster-upgrade-k8s` hands it to
  talosctl as its endpoint.
- `TALOS_WAIT`: how many seconds `cluster-bootstrap` and `cluster-talos` wait for the nodes, 600
  when unset.
- `FLUX_AGE_KEY_FILE`: the path of the Flux age key, outside the repository. In CI, `FLUX_AGE_KEY`
  holds the key itself instead. `cluster-bootstrap`, `cluster-config` and `cluster-flux` need one
  of them.
- `CLUSTER_DOMAIN`: the domain the cluster's applications are published under, a lower-case DNS
  name, which becomes `CLUSTER_DOMAIN` in `cluster-config`; `cluster-bootstrap`, `cluster-config`
  and `cluster-flux` need it.

The recipes, the check aside, refuse to run while `GODEBUG` sets `http2debug`: Go's HTTP/2 debug
log prints the frames talosctl and kubectl send and receive, which carry machine configurations
and credentials.
