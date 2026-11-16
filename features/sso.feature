Feature: Sign-in in front of a route
  An interface not meant for everyone gets a login in front of it, and no application brings its own. dex signs a person in with GitHub, oauth2-proxy holds the session and admits only the identities the owner listed, and a route opts in by including one component. Which of these a cluster runs is the overlay's choice, and nothing else of the cluster waits on them.

  Scenario: A route that opts in sends a request without a session to sign-in, and the backend receives nothing
    Given the demo route hello-sso that opts in, as the lab-sto2 overlay applies it, and the oauth2-proxy application with its pinned chart
    When the route, its SecurityPolicy, the route for the sign-in paths and the rendered oauth2-proxy are read
    Then the one SecurityPolicy of the route targets that HTTPRoute alone and asks the Service oauth2-proxy of sso-system on its port for external authorisation at the fixed path "/" with the route's own host as the return address, whatever the request's path, sending it the request's host, method, Authorization and Cookie and nothing of its path; oauth2-proxy answers that path with its static 200 to a session of a listed identity and with a redirect to dex to none, as its upstream is static://200 and it skips its sign-in button, and nothing in its configuration or arguments answers a request without a session otherwise; the policy never lets a request through when the answer cannot be had; the route names no other way to its backend; the sign-in paths /oauth2/ on the same host go to oauth2-proxy and are under no policy; and the identity oauth2-proxy answers with reaches the backend in headers

  Scenario: Every client and cookie secret comes from the secret store or is made once in the cluster, and none is in a ConfigMap or the tree
    Given the dex and oauth2-proxy applications as the lab-sto2 overlay applies them, with their pinned charts
    When their ExternalSecrets, generators, ConfigMaps, Secrets and the containers' environments are read
    Then the GitHub client's ID and secret come from the property pair github-client-id and github-client-secret at sso-system/dex through the ClusterSecretStore openbao, the secret dex and oauth2-proxy share and oauth2-proxy's cookie secret are each made once by a generator of External Secrets and nothing keeps them, every container reads them from a Secret by reference, and no ConfigMap, values file or Flux variable holds a client secret or a cookie secret

  Scenario: The identities allowed to sign in come from the secret store and are nowhere in the tree
    Given the oauth2-proxy application as the lab-sto2 overlay applies it, with its pinned chart
    When its ExternalSecret for the list, the rendered pod and everything the application and the tree hold are read
    Then the list is the property allowed-emails at sso-system/oauth2-proxy through the ClusterSecretStore openbao, mounted as a file that oauth2-proxy's authenticated emails option names, no e-mail domain admits anyone else, the list has no literal in the render, the tree or the example key lists, and the pod does not start until the Secret exists

  Scenario: dex signs people in with GitHub alone, keeps its state in Kubernetes objects and has no password database
    Given the dex application as the lab-sto2 overlay applies it, with its pinned chart, built with two different cluster domains
    When its configuration, its route and its one static client are read
    Then the issuer is dex under the cluster's domain, the only connector is GitHub with the callback under that issuer and credentials taken from the environment, the storage is Kubernetes objects, the password database is off and no static password exists, the one static client is oauth2-proxy's with its secret from the environment and one redirect URI on the sign-in host, and the route serves the issuer's name on the https listener of the public Gateway

  Scenario: oauth2-proxy admits only the owner's list through dex, with a session cookie for the cluster's domain
    Given the oauth2-proxy application as the lab-sto2 overlay applies it, with its pinned chart, built with two different cluster domains
    When its configuration, its route and its arguments are read
    Then the provider is OpenID Connect with dex as the issuer, the keys and tokens are read from dex inside the cluster, the session is a secure HTTP-only cookie for the cluster's domain, a person is admitted only by the file of identities, the redirect after sign-in stays under the domain, the identity is returned in the X-Auth-Request headers, and the route serves the sign-in host on the https listener of the public Gateway

  Scenario: dex and oauth2-proxy run two replicas under disruption budgets and meet the restricted Pod Security level
    Given the dex and oauth2-proxy applications as the lab-sto2 overlay applies them, with their pinned charts, and their namespace
    When the namespace's labels and the rendered pods are read
    Then the namespace enforces the restricted level and carries the Gateway label, each application runs two replicas on different nodes under a budget that keeps one running, and each container runs as a non-root user with the runtime's seccomp profile, a read-only root filesystem, no capability and no privilege escalation, requests and a memory limit, and a health check

  Scenario: An application opts a route in with one component, and a namespace that has not opted in cannot use oauth2-proxy
    Given every application the overlay enables, built as Flux applies them, and the component sso
    When every SecurityPolicy with external authorisation, every ReferenceGrant for oauth2-proxy and every route to oauth2-proxy are read
    Then the component yields the policy and the sign-in route from two variables, each policy that asks for external authorisation asks oauth2-proxy and nothing else, each namespace that has one is granted the Service in a ReferenceGrant naming that namespace and the two kinds that refer to it, the grant names no other namespace and no other Service, and a route that opts in has the policy and the sign-in route together

  Scenario: The sign-in applications are selected by overlay entries and build nothing when they are not, and nothing else waits on them
    Given the lab-sto2 overlay, which selects the sign-in applications with entries of its own
    When it is built with every entry, with the namespace directory alone and with none, and with each dependency of the applications left out in turn
    Then with every entry it applies the namespace sso-system, its app-template-defaults ConfigMap, its default deny and the Kustomizations dex and oauth2-proxy; with the namespace directory alone, only the namespace, the ConfigMap and the default deny; with none, nothing of sso-system; a cluster that leaves a dependency out, Cilium among them, is refused, naming the application and the missing one; and the only Kustomizations that name dex or oauth2-proxy in dependsOn are oauth2-proxy and the demo route that opts in, which nothing names in turn
