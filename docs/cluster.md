# The cluster

The Talos cluster is created and changed by `just` recipes that check what they need before they
run anything. Each recipe that works on one cluster takes its name, `lab-sto2` when none is given,
and works in `talos/<cluster>/`: on `talman.yaml`, which `just infra-talman` renders from the
cluster stack and git ignores; on `secrets.sops.yaml`, the cluster's encrypted secrets bundle,
which is committed; and on talman's output directory `clusterconfig/`, which git ignores and which
holds the machine configurations, the talosconfig and the kubeconfig. Nothing reaches the nodes
except through talman, and the cluster except through the kubeconfig.

## From nothing to a Ready cluster

1. `just infra-apply sto2/plumbing`, then `just infra-apply sto2/cluster`
   ([infrastructure.md](infrastructure.md)): the nodes boot and wait in maintenance mode.
2. `just infra-talman`: the cluster's `talman.yaml`.
3. `just cluster-age-key`, once: the Talos age key. Commit `talos/.sops.yaml`.
4. `just cluster-secrets`, once per cluster: the secrets bundle. Commit it.
5. `just cluster-bootstrap`: every node configured, Cilium installed, every node Ready.

Later changes to a patch or to `talman.yaml`, and nodes OpenTofu adds, reach the nodes with
`just cluster-talos`.

## The Talos age key

The secrets bundle holds the cluster's certificate authorities and keys. It is encrypted with sops
to one age key, the Talos age key, which the operator holds and CI gets as a secret; it never
enters the repository or the cluster (ADR 0005). Flux decrypts `kubernetes/` with a key of its own,
so the key in the cluster does not open the bundle.

Without the key the bundle cannot be decrypted, and no machine configuration, talosconfig or
kubeconfig can be made for the running cluster. Keep a copy of it away from the machine it was
made on.

`talos/.sops.yaml` holds its recipient, the public half, and a rule that matches
`secrets.sops.yaml` one directory below `talos/` and nothing else. talman hands sops that file and
the bundle's path itself, so the rule applies wherever talman runs from.

## Recipes

- `just cluster-age-key` creates the key with `age-keygen` at the path `SOPS_AGE_KEY_FILE` names,
  with mode 0600, unless a file is there, and writes its recipient into `talos/.sops.yaml` in place
  of the placeholder. It prints the recipient and nothing else. A second run changes nothing. It
  refuses a path inside the repository, and a `talos/.sops.yaml` that names another recipient,
  which it leaves as it is.
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
  location or `KUBE_API_ADDRESS` is missing. Then, in order:
  1. It waits until every node in `talman.yaml` answers on the Talos API port, 50000, at the
     address talman reaches it on, for up to `TALOS_WAIT` seconds. It fails naming the nodes that
     did not answer; rebooting one is left to the operator.
  2. `talman apply --bootstrap --onboard-new-nodes` configures the first control plane, starts
     etcd on it, and configures the other nodes after it, one at a time.
  3. `just cluster-kubeconfig` fetches the kubeconfig.
  4. `scripts/install-cilium` installs Cilium through it ([kubernetes.md](kubernetes.md)).
  5. It waits until every node in `talman.yaml` is a Ready Kubernetes node.

  A second run is refused by talman, which bootstraps only when every control plane answers and
  none runs etcd. A bootstrap that stopped once etcd was running is therefore not run again: the
  nodes it did not reach are configured with `just cluster-talos --onboard`, and the steps after
  it are run by their own recipes. No health check runs: `talosctl health`, reaching the nodes
  through their floating addresses, compares those with the addresses the nodes hold on the node
  network, which differ by design, so it never passes.
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
  nothing is asked or applied. It needs what `cluster-bootstrap` needs but `KUBE_API_ADDRESS`.

A failing recipe ends with a line naming the step it failed in.

## Not automated

- Rebooting a node that does not answer on the Talos API port.
- The kubelet serving-certificate approver. The kubelets request their serving certificates from
  the cluster (`talos/patches/all/kubelet.yaml`), and until something approves them, `kubectl logs`
  and `kubectl exec` fail. `just cluster-bootstrap` says so in a line of its own.

## What the recipes print

The recipes' own lines name nodes by hostname, never by address, and print neither the age key, the
bundle, the kubeconfig nor `KUBE_API_ADDRESS`. talman's and talosctl's output passes through as
they print it, and names each node with the address talman reaches it on.

## Environment

The recipes read `.env` and the environment as the infrastructure recipes do
([infrastructure.md](infrastructure.md#environment)), and name each variable that is missing. No
recipe reads the age key itself or prints a secret: sops and talman get the key's location from
their environment.

- `SOPS_AGE_KEY_FILE`: the path of the Talos age key, outside the repository. In CI,
  `SOPS_AGE_KEY` holds the key itself instead. Every recipe that reaches the nodes needs one of
  them, as talman decrypts the bundle.
- `KUBE_API_ADDRESS`: the Kubernetes API load balancer's floating address, an IPv4 address or host
  name; `cluster-bootstrap` and `cluster-kubeconfig` need it.
- `TALOS_WAIT`: how many seconds `cluster-bootstrap` and `cluster-talos` wait for the nodes, 600
  when unset.

The recipes, the check aside, refuse to run while `GODEBUG` sets `http2debug`: Go's HTTP/2 debug
log prints the frames talosctl and kubectl send and receive, which carry machine configurations
and credentials.
