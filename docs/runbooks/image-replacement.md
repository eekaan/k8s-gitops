# Replacing the Talos image

The plumbing stack builds the Talos image from the Talos version in `versions.yaml` and the
schematic in `talos/schematic.yaml`, and names it `<prefix>-talos-<version>-<schematic>`: the
stack's `prefix`, `lab` by default, the version, and the first eight characters of the schematic's
ID. A new version or schematic is a new image. The nodes boot from volumes made from the image
they were created with and are upgraded in place over the Talos API; they are not rebuilt.

## Steps

1. **Change `versions.yaml` or `talos/schematic.yaml`**, in a pull request. Each changes the
   image's name and the Image Factory URL it is downloaded from. `just infra-check` fails on a
   schematic that lists the QEMU guest agent extension: Nova enables guest agent support only for
   instances of an image whose `hw_qemu_guest_agent` property is `yes`
   ([Nova](https://docs.openstack.org/nova/latest/admin/libvirt-misc.html),
   [Glance](https://docs.openstack.org/glance/latest/admin/useful-image-properties.html)), and the
   plumbing stack uploads the image without it.

2. **`just infra-forget-image`** removes the current image from the plumbing stack's state; the
   image stays in the cloud. Without this, the plan would replace the image: the provider replaces
   an image whose download URL changes, and a replacement deletes the old image. The running nodes'
   boot volumes were made from that image. Where volumes are copy-on-write clones of their image,
   as when the image and volume services share Ceph RBD storage
   ([Ceph and OpenStack](https://docs.ceph.com/en/latest/rbd/rbd-openstack/)), the snapshot the
   clones are made from cannot be deleted while a clone of it exists
   ([Ceph snapshots](https://docs.ceph.com/en/latest/rbd/rbd-snapshot/)), so deleting the image
   fails, and the apply with it. The recipe says what it will do and asks for the stack's name;
   `--yes` does not ask. A second run finds no image in the state and changes nothing.

3. **`just infra-plan sto2/plumbing`, then `just infra-apply sto2/plumbing`**. The summary creates
   one `openstack_images_image_v2`, updates the `talos_image_factory_schematic` in place when the
   schematic changed, and destroys nothing. A plan that replaces or deletes the image means step 2
   did not happen: answer no and run it. The apply downloads the new image and uploads it from the
   machine it runs on.

4. **`just infra-apply sto2/cluster`**. The plan changes outputs only: `talman_yaml` for a new
   version or a changed `talos/talman.yaml.tftpl`, `schematic_id` for a new schematic. The nodes
   ignore changes to their boot device, so the new image replaces no server and no boot volume;
   nodes added later boot it. The apply writes the cluster's `talman.yaml`.

5. **`just infra-talman`** writes `talman.yaml` again from the cluster stack's state and runs its
   checks without planning: talman must compute from `talos/schematic.yaml` the schematic ID the
   new image was built from, or an upgrade would install another image than the one OpenTofu
   built ([infrastructure.md](../infrastructure.md#the-generated-talmanyaml)). The apply in step 4
   ran the same checks; this repeats them right before the nodes are touched.

6. **`just cluster-upgrade`** moves each node that does not run the version and schematic in
   `talman.yaml` to them, one node at a time ([cluster.md](../cluster.md#recipes)). A new
   Kubernetes version in the same change follows with `just cluster-upgrade-k8s`.

7. **`just cluster-talos`**, after the upgrade and never before it, when the change adds an
   extension together with configuration that depends on it, such as the DRBD modules
   `talos/patches/all/kernel-modules.yaml` loads from `siderolabs/drbd`. The upgrade changes the
   image and leaves the machine configuration as it is: talman's `upgrade` moves each node to the
   installer image its schematic and version resolve to, and `talosctl upgrade` takes an image, not
   a configuration. Talos activates an extension only when it installs or upgrades
   ([Talos](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/custom-images-and-development/system-extensions)),
   so a node has the extension's modules once the upgrade has rebooted it. `cluster-talos` then
   shows the new configuration in its dry run and applies it node by node, and Talos loads a module
   as soon as the configuration lists it.

   In the other order nothing refuses the configuration, but the module does not load. Talos
   validates a `KernelModuleConfig` for a name only
   ([source](https://github.com/siderolabs/talos/blob/v1.14.6/pkg/machinery/config/types/runtime/kernel_module.go)),
   so `talosctl validate`, `talman validate` and the apply all pass on a node whose image lacks the
   module. The node keeps running, but its kernel module controller fails with `module not found`
   for that module and retries
   ([source](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/controllers/runtime/kernel_module_spec.go)),
   until an upgrade brings the module and the node loads it at boot.

   Flux applies what the change holds under `kubernetes/`, such as a RuntimeClass for an
   extension's runtime handler, as soon as it is merged, whatever image the nodes run. A pod that
   selects a RuntimeClass on a node whose image lacks the handler does not start.

## What the cloud holds afterwards

The plumbing stack manages the new image. The old one stays in the image service, private to the
project and in no stack's state, so no recipe, `just infra-destroy` included, removes it. The
running nodes' boot volumes were made from it. Each replacement leaves one more.

## Removing old images

By hand, with the `openstack` client on the deployment's credentials. Its output holds the
project's image and volume IDs, so it stays out of any log, issue or commit.

1. The current image is named after `just infra-output sto2/plumbing talos_version` and the first
   eight characters of `just infra-output sto2/cluster schematic_id`. Every other image whose name
   starts with the stack's prefix and `-talos-` is an old one:

   ```sh
   openstack image list --private -f value -c ID -c Name | grep ' lab-talos-'
   ```

2. An old image is deleted only once no volume was made from it. A volume made from an image names
   it in its image metadata; this counts the volumes that name `<image-id>`:

   ```sh
   for volume in $(openstack volume list -f value -c ID); do
     openstack volume show "$volume" -f value -c volume_image_metadata
   done | grep -c '<image-id>'
   ```

   A node's boot volume goes with its instance, so the old images' volumes go once their nodes are
   rebuilt, such as when the cluster stack is destroyed and applied again.

3. At a count of 0:

   ```sh
   openstack image delete <image-id>
   ```

   If the cloud refuses, something still depends on the image; leave it for later.
