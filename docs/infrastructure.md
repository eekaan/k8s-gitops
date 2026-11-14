# Infrastructure

The OpenStack resources are OpenTofu stacks under `infra/openstack/stacks/<region>/`: `plumbing`
(the node network, its router and the Talos image) and `cluster`, which builds on it. Every
command that runs them is a `just` recipe.

## Recipes

- `just os-smoke` checks, reading only, that the `openstack` client is python-openstackclient
  7.0.0 or newer with its python-octaviaclient plugin; that the credential issues a token; that
  compute, volume, network, load-balancer, floating-IP and security-group-rule quota is not used
  up; and that the flavors and the external network the stacks' variables name exist. Quota left
  is not compared with what the stacks need. It prints pass or FAIL per item and no figures. The
  client is not pinned in `mise.toml`; it is installed separately.
- `just infra-state-bucket` creates the bucket `TF_STATE_BUCKET` names unless it exists, as an
  object storage container of that name, with the `openstack` client on the OpenStack credentials:
  no tool pinned in `mise.toml` speaks the S3 API. It needs the client version `os-smoke` needs,
  prints neither the bucket's name nor what the client reports, which names the project, and
  creates nothing on a second run.
- `just infra-plan sto2/plumbing` plans a stack and prints the plan's summary.
- `just infra-apply sto2/plumbing` plans a stack, prints the summary and, once the stack's name is
  typed back, applies that saved plan; `just infra-apply sto2/plumbing --yes` does not ask. After
  the cluster stack it writes the cluster's `talman.yaml`, as `just infra-talman` does.
- `just infra-talman` writes the cluster's `talman.yaml` from the `sto2/cluster` stack's state;
  see [The generated talman.yaml](#the-generated-talmanyaml). It writes what the last apply left
  there, so a change to what the stack renders, such as a version in `versions.yaml`, reaches the
  file through `just infra-apply sto2/cluster` only.
- `just infra-output sto2/plumbing talos_version` prints one output of a stack. It refuses a
  sensitive output, as those hold the deployment's addresses and IDs.
- `just infra-destroy` destroys `sto2/cluster`, then `sto2/plumbing`. Each destroy is planned and
  summarised first, and runs once the stack's name is typed back; `just infra-destroy --yes` does
  not ask. When the cluster stack is not destroyed, the plumbing stack is left as it is. The load
  balancers and volumes the cluster creates itself, outside OpenTofu, are not removed, and the
  recipe says so; while any are left, the plumbing network cannot be deleted. Once the cluster
  stack is destroyed, the recipe removes the files generated for its cluster that hold the nodes'
  and the API's addresses, which the cloud may give to someone else: `talos/<cluster>/talman.yaml`
  and the talosconfig and kubeconfig in its `clusterconfig/`. It names each file it removes and
  removes only files git ignores; the secrets bundle and etcd snapshots stay.

Apply `plumbing` before `cluster`, as the cluster stack reads the plumbing stack's state. Destroy
goes the other way round. State objects stay in the bucket after a destroy.

## Before the first plan

Once per deployment, before the first `just infra-plan`, in this order:

1. Create S3 credentials for the OpenStack project, an access key and its secret key: OpenStack's
   EC2 credentials, which `openstack ec2 credentials create` makes. It prints the secret key, so it
   is run by hand and its output kept out of any log.
2. Put them in `.env` as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, beside the bucket's
   name as `TF_STATE_BUCKET` and the OpenStack authentication ([Environment](#environment)).
3. `just infra-state-bucket` creates the bucket.
4. Choose the passphrase state and plans are encrypted with, 16 characters or more, put it in
   `.env` as `TF_STATE_PASSPHRASE`, and keep a copy outside the repository and the cluster
   ([State](#state)).

## The generated talman.yaml

The cluster stack renders `talos/talman.yaml.tftpl` from its own values into the sensitive output
`talman_yaml`: the cluster's name from `cluster_name`, `lab-sto2` by default; the load balancer's
address on the node network as the endpoint; the Talos and Kubernetes versions from
`versions.yaml`; the plumbing stack's node subnet and the stack's `pod_subnet` and
`service_subnet`, Kubernetes' conventional private ranges by default; the load balancer's two
addresses and each control plane's floating address as the API certificate names; the load
balancer's floating address as `values.apiAddress`, where the cluster recipes reach the Kubernetes
API ([cluster.md](cluster.md#environment)); and the nodes,
control planes first and then workers, each by name and at its floating address, where talman
reaches it. Planning fails, naming the variable, when the pod or service subnet is not an IPv4
network, overlaps the other or the node subnet, or when the pod subnet holds fewer /24s than there
are nodes, as Kubernetes gives each node a /24 of it. The output `schematic_id` is the schematic ID
of the image the nodes boot.

`just infra-talman` writes `talman_yaml` to `talos/<cluster>/talman.yaml`, which git ignores, with
mode 0600, and never prints it. It writes a temporary file beside it and checks that file first.
talman must compute from `talos/schematic.yaml` the schematic ID the image was built from: OpenTofu
built the image from that file, and talman computes the installer image from it on its own, so if
they disagreed an upgrade would install another image than the one the nodes booted. Then
`talman validate` must pass with the repository's patches. Only then is the file renamed into place.
When a check fails the recipe says why, naming both IDs for a mismatch, removes the temporary file
and leaves an earlier `talman.yaml` as it was.

## Environment

The recipes read `.env` at the repository root when it exists, and the process environment
otherwise, as in CI. `.env` holds literal `NAME=value` lines and is never run as shell: nothing in
a value is expanded, one pair of quotes around a value is dropped, and blank lines and `#`
comments are skipped. Any other line stops the recipe, named by its number and not its content.
`.env.example` lists every name, with secrets left empty and placeholders starting with
`example-`.

A recipe checks the names it needs before it runs anything, and names each one that is missing,
empty or still a placeholder. It refuses to run while `TF_LOG`, `TF_LOG_PATH`, `TF_LOG_CORE` or
`TF_LOG_PROVIDER` is set, as tofu's logs would hold addresses and decrypted values, or while
`TF_WORKSPACE` is set, as it would move a stack's state to another key. No recipe prints a value
or passes a secret on a command line; secrets reach tofu through its environment.

- `TF_STATE_BUCKET`: the bucket that holds state.
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: S3 credentials for that bucket.
- `TF_STATE_PASSPHRASE`: the passphrase state and plans are encrypted with, 16 characters or more.
  tofu gets it inside `TF_ENCRYPTION` only, and the `openstack` client gets neither it nor the S3
  credentials.
- `OS_CLOUD`, naming a `clouds.yaml` entry outside the repository, or `OS_AUTH_URL` with the
  application-credential variables: OpenStack authentication, which tofu's provider and the
  `openstack` client read themselves. `os-smoke` needs only this, and `infra-state-bucket` this
  and `TF_STATE_BUCKET`.
- `OPERATOR_CIDRS`, or else `operator-cidrs.json` at the repository root (gitignored): the
  operator allowlist of the cluster stack, a JSON list of CIDRs. It reaches tofu only as
  `TF_VAR_api_allowed_cidrs` in its environment, as given: the address of the machine the recipes
  run on is not added, and the recipe says so.
- `CI`: when set, tofu's errors go to a file instead of the output; see below.

## State

Each stack keeps its state in the bucket under a key made from its path, such as
`sto2/plumbing.tfstate`, through OpenTofu's `s3` backend. `infra/openstack/backend.hcl` holds the
object storage's public endpoint and the settings an S3-compatible store needs; the bucket comes
from the environment.

State and saved plans are encrypted on the machine that runs tofu, with OpenTofu's state
encryption: AES-GCM, with a key derived from `TF_STATE_PASSPHRASE` by PBKDF2. `scripts/stack-env`
passes the key provider and method in `TF_ENCRYPTION`, with encryption enforced, so tofu refuses an
unencrypted fallback a stack might declare. Each stack's `terraform` block enforces encryption too,
so tofu run by hand without `TF_ENCRYPTION`, or with an unencrypted method, refuses to run instead
of writing plaintext. `just infra-check` fails on a stack whose block does not. The cluster stack
reads the plumbing stack's state with the same settings; `scripts/stack-env` gives it the state's
location as `TF_VAR_plumbing_state`.

Losing the passphrase makes every state and saved plan unreadable. It is kept outside the
repository and the cluster.

The recipes do not handle these; they are done by hand when needed:

- Changing the passphrase needs the old key provider and method kept as a `fallback` in
  `TF_ENCRYPTION` for one apply of every stack, so each state is read with the old key and written
  with the new one.
- State that was ever written in plaintext is read only through an `unencrypted` method as a
  `fallback`, which the enforced settings refuse; migrating it means lifting enforcement for that
  one apply.

The object storage's own state locking is not used, as it is not verified that the store supports
it. The recipes lock each stack in the checkout they run from, with `flock` on a file under the
stack's `.terraform/`, and a second operation on a stack from that checkout fails saying the stack
is busy. The lock does not exclude CI or another checkout, so stacks are applied from one place at
a time. Without `flock` on `PATH` (it comes with util-linux), the recipes stop and say so.

## What the recipes print

Plan output is public in CI, and a full plan holds addresses, IDs and attribute values. The
recipes therefore show neither tofu's plan nor its apply report, only a summary that `jq` reads
from `tofu show -json` of the saved plan: tofu's counts line, then each action with how many
resources of each type it takes, then each output the plan changes, by its action and name and
never its value.

```text
sto2/cluster:
Plan: 4 to add, 1 to change, 2 to destroy.
  create: 1 openstack_compute_instance_v2
  create: 2 openstack_networking_port_v2
  update: 1 openstack_networking_router_v2
  replace: 1 openstack_networking_floatingip_v2
  delete: 1 openstack_blockstorage_volume_v3
  update: output talman_yaml
```

A replaced resource counts once to add and once to destroy, as in tofu's own counts line. Data
sources, and resources and outputs without changes, are left out. A plan that changes outputs
only, as the cluster stack's does after `versions.yaml` changes, is not "No changes.": applying it
writes the new outputs to the state. The full plan stays encrypted in `.terraform/infra.tfplan` in
the stack's directory.

When tofu fails, its errors can name resources and hold attribute values, API endpoints and the
bucket. Without `CI` set they are shown as tofu prints them. With `CI` set they go to
`.terraform/tofu-errors.log` in the stack's directory, and the recipe prints only which tofu
command failed and that file's path. talman's errors, which can quote node addresses, are handled
the same way.
