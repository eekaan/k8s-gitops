# Checks hello, the demo's web server, over HTTP from inside the cluster: its page answers 200 and
# holds hello, and a path it does not serve answers 404. The requests are the Browser library's
# Http, which fetches from the page the suite opened, so each names a path of hello's own origin:
# the image has no other HTTP client, and a request from no page, or to another origin, would be
# held to CORS, which hello's server does not answer. The target is HELLO_URL, from
# ROBOT_TARGET_HELLO in ks.yaml. To add a check, add a test case here; to check another target, see
# docs/kubernetes.md, Robot Framework.

*** Settings ***
Documentation       hello over HTTP: its page, and a path it does not serve.
Resource            common.resource

Suite Setup         Open Target    ${HELLO_URL}
Suite Teardown      Close Everything


*** Test Cases ***
The page answers 200 and holds hello
    ${response}=    Http    /    GET
    Should Be Equal As Integers    ${response}[status]    200
    Should Contain    ${response}[body]    hello

A path hello does not serve answers 404
    ${response}=    Http    /robot-no-such-page    GET
    Should Be Equal As Integers    ${response}[status]    404
