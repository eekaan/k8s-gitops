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
- `just infra-state-bucket` creates the bucket `TF_STATE_BUCKET` names unless it exists, through
  the object storage's S3 API with the state key, as the backup buckets are created
  ([S3 keys and backup buckets](#s3-keys-and-backup-buckets)); it needs no OpenStack credentials.
  It prints neither the bucket's name nor what rclone reports, which names it and the endpoint, and
  creates nothing on a second run. A name that is not a bucket name, or that another project owns,
  fails without being printed.
- `just infra-plan sto2/plumbing` plans a stack and prints the plan's summary.
- `just infra-apply sto2/plumbing` plans a stack, prints the summary and, once the stack's name is
  typed back, applies that saved plan; `just infra-apply sto2/plumbing --yes`, or with `--yes`
  before the stack, does not ask. After
  the cluster stack it writes the cluster's `talman.yaml`, as `just infra-talman` does.
- `just infra-talman` writes the cluster's `talman.yaml` from the `sto2/cluster` stack's state;
  see [The generated talman.yaml](#the-generated-talmanyaml). It writes what the last apply left
  there, so a change to what the stack renders, such as a version in `versions.yaml`, reaches the
  file through `just infra-apply sto2/cluster` only.
- `just infra-output sto2/plumbing talos_version` prints one output of a stack. It refuses a
  sensitive output, as those hold the deployment's addresses and IDs.
- `just infra-forget-image` removes the Talos image from the `sto2/plumbing` stack's state with
  `tofu state rm` and leaves the image in the cloud, so that after a new Talos version or schematic
  the next apply uploads the new image and deletes nothing;
  [runbooks/image-replacement.md](runbooks/image-replacement.md) gives the steps around it. It first
  says in one line that only the state forgets the image, and acts once the stack's name is typed
  back; `just infra-forget-image --yes` does not ask. When the state holds no image it says so, asks
  nothing and changes nothing. It prints neither the state's list nor tofu's report.
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

1. With the OpenStack authentication in `.env` ([Environment](#environment)),
   `just infra-s3-key state` creates the state key, S3 credentials for the project, and writes it
   to `.env` as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
   ([S3 keys and backup buckets](#s3-keys-and-backup-buckets)).
2. Put the state bucket's name in `.env` as `TF_STATE_BUCKET`; `just infra-state-bucket` creates
   the bucket.
3. Choose the passphrase state and plans are encrypted with, 16 characters or more, put it in
   `.env` as `TF_STATE_PASSPHRASE`, and keep a copy outside the repository and the cluster
   ([State](#state)).

## S3 keys and backup buckets

etcd snapshots, OpenBao snapshots, VolSync repositories and Postgres backups go to four buckets in
the object storage: `BACKUP_BUCKET_PREFIX` followed by `-etcd`, `-openbao`, `-volsync` and
`-postgres`. No stack owns them, so `just infra-destroy` leaves them and their data:
`just infra-check` fails on a stack, or a module of this repository, that declares an object
storage container or an S3 bucket.

- `just infra-s3-key state` and `just infra-s3-key cluster` create an S3 key pair, an EC2
  credential, with the `openstack` client, in the version `os-smoke` needs, and write it to `.env`
  under the key set's names: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for the state key,
  `CLUSTER_S3_ACCESS_KEY_ID` and `CLUSTER_S3_SECRET_ACCESS_KEY` for the cluster's. Neither value is
  printed. Nothing is created while `.env` is a symlink or a file git does not ignore, or while one
  of the names there holds a value; a name that is empty or a placeholder is filled in, an absent
  one is appended after a comment, and every other line stays as it is. `.env` is written to a
  temporary file beside it, mode 0600, and renamed into place.
- `just infra-backup-buckets` creates the four buckets unless they exist, through the object
  storage's S3 API with the state key, and names each by its role, never by its name. A second run
  creates nothing. A name another project owns fails, naming the role.
- `just infra-backup-check` checks, reading only, that the cluster's key is not the state key and
  that it lists each of the four buckets. It prints pass or FAIL per item.

The cluster's key exists so that it can be revoked on its own, without touching the state. Both
keys belong to the same project and reach every bucket in it, the state bucket included, which is
why state and snapshots are encrypted before they are uploaded
([ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md)).

These recipes and `just infra-state-bucket` reach the object storage with rclone, pinned in
`mise.toml`, at the endpoint, region and addressing that `infra/openstack/backend.hcl` gives
OpenTofu's state. rclone is configured through its environment only and reads no config file; the
operator's own rclone configuration, its `RCLONE_` and `AWS_` variables and every other variable
but `PATH`, `HOME`, `TMPDIR` and the proxy variables stay out of its environment. What rclone
prints names the buckets and the endpoint, so it is not shown.

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
`TF_LOG_PROVIDER` is set, as tofu's logs would hold addresses and decrypted values; while
`TF_WORKSPACE` is set, as it would move a stack's state to another key; while `TF_CLI_ARGS` or any
`TF_CLI_ARGS_<command>` is set, as they add arguments to the tofu commands the recipes run; while
`TF_DATA_DIR` is set, as it would move a stack's working directory, with the saved plan and the
lock, out of its `.terraform/`; and while `GODEBUG` sets `http2debug`, as Go's HTTP/2 debug log
prints what tofu and its providers send and receive. No recipe prints a value or passes a secret
on a command line; secrets reach tofu and rclone through their environment.

- `TF_STATE_BUCKET`: the bucket that holds state.
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the state key, S3 credentials for that bucket,
  which also create the backup buckets.
- `BACKUP_BUCKET_PREFIX`: the start of the backup buckets' names, lower-case letters, digits and
  hyphens.
- `CLUSTER_S3_ACCESS_KEY_ID` and `CLUSTER_S3_SECRET_ACCESS_KEY`: the cluster's S3 key.
- `TF_STATE_PASSPHRASE`: the passphrase state and plans are encrypted with, 16 characters or more.
  tofu gets it inside `TF_ENCRYPTION` only, and the `openstack` client gets neither it nor the S3
  credentials.
- `OS_CLOUD`, naming a `clouds.yaml` entry outside the repository, or `OS_AUTH_URL` with the
  application-credential variables: OpenStack authentication, which tofu's provider and the
  `openstack` client read themselves. `os-smoke` and `infra-s3-key` need only this.
- `OPERATOR_CIDRS`, or else `operator-cidrs.json` at the repository root (gitignored): the
  operator allowlist of the cluster stack, a JSON list of IPv4 CIDRs. An entry that is IPv6, or
  whose prefix is 0 and so covers every address, is refused, named by its position in the list and
  not by its value. It reaches tofu only as
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
