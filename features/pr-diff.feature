Feature: The render diff of a pull request
  A pull request shows, per application, which objects Flux would add, remove and change if it were
  merged: the tree is rendered as Flux applies it, charts expanded, before and after the change.

  Scenario: Every enabled application is rendered to the objects Flux would apply, charts expanded
    Given a tree whose cluster overlay enables a few applications, one of them a HelmRelease of a chart that renders a monitor only where the monitoring API exists, another the definition of that API, and lists one more commented out
    When just render runs
    Then each application the cluster applies, its root and its sync included, has a render of its own and the disabled one has none, with the example values substituted and the root's defaults applied, and the HelmRelease is expanded to the objects its chart renders with the repository's values, its definitions and its monitor included, post-rendered and labelled as helm-controller does, with the values the chart makes up anew on every render masked

  Scenario: The render runs flux, helm and kustomize with none of the secrets
    Given every secret variable the recipes read set to a marker, and a recording flux, helm and kustomize
    When scripts/render renders a tree
    Then each tool's recorded environment holds none of the secrets, and holds the render's own settings

  Scenario: A release whose chart comes from a Helm repository is rendered to the objects its chart renders at the pinned version
    Given a tree whose cluster overlay enables an application whose HelmRelease takes its chart from a HelmRepository at an exact version
    When just render runs
    Then the chart is pulled by name from the repository at exactly that version, and the HelmRelease is expanded to the objects the chart renders at that version, with its values, labelled as helm-controller labels them

  Scenario: A release whose chart version is not exact, or whose source needs a credential, is refused, and the refusal names it
    Given trees whose HelmRelease pins a version range, a wildcard or no version, names a chart that is no chart name, takes its chart from a GitRepository, or whose HelmRepository has a URL that is not https, or names a secretRef or a certSecretRef, or is an OCI repository with a URL that is not oci://
    When just render runs on each
    Then each fails, naming the release and what is refused, and nothing is pulled

  Scenario: A values source named by a pattern selects nothing the cluster would not select
    Given a HelmRelease with an optional valuesFrom ConfigMap whose name holds a wildcard character, beside a ConfigMap the name would match as a pattern, a required one, one with the exact name, and chart sources named by a pattern
    When just render runs on each
    Then the optional one is skipped as helm-controller skips it and the chart renders with the values it has left, the required one and the chart sources are refused, naming the release, and only the exact name selects its ConfigMap

  Scenario: An object that only claims to be a definition does not change what a chart renders
    Given a tree with no definition of the monitoring API, and objects called CustomResourceDefinition of another API group, of another API version, with a version that is not served and with a group the API server would refuse, each naming that API, and a real definition of it
    When just render runs on each
    Then the chart that renders its monitor only where the API is served renders it for the real definition alone

  Scenario: A release whose name the API server would refuse is refused by the render
    Given HelmReleases whose name or namespace holds a line break, an upper-case letter or an underscore
    When just render runs on each
    Then each fails in one line naming the file of the release, before anything is pulled

  Scenario: A tree from which a build would read outside it is refused, and nothing of what it names is rendered
    Given trees in which a kustomization, a Component or an application's Kustomization names a file outside the tree by an absolute path, by a relative one that climbs out of it or through a link in the tree that leads out of it, or names a remote source, and a release whose post-renderer names a patch file
    When just render runs on each
    Then each fails before anything is built, naming the file and the entry, and the file's content appears nowhere in its output or in what it wrote

  Scenario: Every release the cluster's overlay enables is one the render accepts
    Given this repository's tree
    When the render checks the form of every HelmRelease the cluster's overlay enables, without pulling a chart
    Then each is accepted

  Scenario: A changed value shows as a changed object in that application's diff, and nowhere else
    Given renders of a tree before and after one value of its chart is changed
    When just render-diff compares them
    Then the summary names that application alone, with changed objects and none added or removed, and its diff shows the value changing in the object the chart renders

  Scenario: An added and a removed application show as added and removed objects
    Given renders of a tree before and after its overlay enables one application and drops another
    When just render-diff compares them
    Then the enabled application's objects show as added, the dropped one's as removed, and the root shows one Kustomization added and one removed

  Scenario: A change that renders identically says nothing changed
    Given renders of a tree before and after a change to comments only, with a chart that makes up a value anew on every render
    When just render-diff compares them
    Then the comment says that nothing Flux applies changes, and has no summary and no diff

  Scenario: No Secret's data appears in a render or a diff
    Given a tree with a Secret in an application's manifests and one a chart renders from the repository's values, and a second tree where both values changed
    When both trees are rendered and compared
    Then neither value appears in a render or in the comment, in plain text or base64, while the Secrets and their keys do

  Scenario: A diff too large for one comment is truncated and says so
    Given renders of a tree before and after a change whose diff is larger than a pull request comment holds
    When just render-diff compares them
    Then the comment stays within GitHub's limit, keeps the whole summary and the footer, closes every block it opens, and says the diff is truncated

  Scenario: A base its own render code does not render is rendered with this checkout's
    Given a pull request whose base commit holds render code that fails on the base's own tree, and a checkout whose render code renders both
    When the CI render job's script renders the base and the checkout
    Then it says the base's render code does not render the base, renders both with the checkout's, and writes the comment; a base neither renders fails the run and writes none
