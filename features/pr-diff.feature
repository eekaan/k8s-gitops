Feature: The render diff of a pull request
  A pull request shows, per application, which objects Flux would add, remove and change if it were
  merged: the tree is rendered as Flux applies it, charts expanded, before and after the change.

  Scenario: Every enabled application is rendered to the objects Flux would apply, charts expanded
    Given a tree whose cluster overlay enables a few applications, one of them a HelmRelease of a chart that renders a monitor only where the monitoring API exists, another the definition of that API, and lists one more commented out
    When just render runs
    Then each application the cluster applies, its root and its sync included, has a render of its own and the disabled one has none, with the example values substituted and the root's defaults applied, and the HelmRelease is expanded to the objects its chart renders with the repository's values, its definitions and its monitor included, post-rendered and labelled as helm-controller does, with the values the chart makes up anew on every render masked

  Scenario: A release whose chart comes from a Helm repository is rendered to the objects its chart renders at the pinned version
    Given a tree whose cluster overlay enables an application whose HelmRelease takes its chart from a HelmRepository at an exact version
    When just render runs
    Then the chart is pulled by name from the repository at exactly that version, and the HelmRelease is expanded to the objects the chart renders at that version, with its values, labelled as helm-controller labels them

  Scenario: A release whose chart version is not exact, or whose source needs a credential, is refused, and the refusal names it
    Given trees whose HelmRelease pins a version range, a wildcard or no version, names a chart that is no chart name, takes its chart from a GitRepository, or whose HelmRepository has a URL that is not https, or names a secretRef or a certSecretRef, or is an OCI repository with a URL that is not oci://
    When just render runs on each
    Then each fails, naming the release and what is refused, and nothing is pulled

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
