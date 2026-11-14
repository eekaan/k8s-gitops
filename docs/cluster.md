# The cluster

The Talos cluster is created and changed by `just` recipes that check what they need before they
run anything. Each recipe that works on one cluster takes its name, `lab-sto2` when none is given,
and works in `talos/<cluster>/`: on `talman.yaml`, which `just infra-talman` renders from the
cluster stack and git ignores, and on `secrets.sops.yaml`, the cluster's encrypted secrets bundle,
which is committed.

## From nothing to a cluster

1. `just infra-apply sto2/plumbing`, then `just infra-apply sto2/cluster`
   ([infrastructure.md](infrastructure.md)).
2. `just infra-talman`: the cluster's `talman.yaml`.
3. `just cluster-age-key`, once: the Talos age key. Commit `talos/.sops.yaml`.
4. `just cluster-secrets`, once per cluster: the secrets bundle. Commit it.

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

A failing recipe ends with a line naming the step it failed in.

## Environment

The recipes read `.env` and the environment as the infrastructure recipes do
([infrastructure.md](infrastructure.md#environment)), and name each variable that is missing. No
recipe reads the age key itself or prints a secret: sops and talman get the key's location from
their environment.

- `SOPS_AGE_KEY_FILE`: the path of the Talos age key, outside the repository. In CI,
  `SOPS_AGE_KEY` holds the key itself instead.

The recipes, the check aside, refuse to run while `GODEBUG` sets `http2debug`: Go's HTTP/2 debug
log prints the frames talosctl and kubectl send and receive, which carry machine configurations
and credentials.
