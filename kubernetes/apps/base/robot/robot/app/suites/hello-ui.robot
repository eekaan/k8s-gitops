# Checks hello, the demo's web server, in a real browser: the page Chromium shows holds hello, and a
# screenshot of it goes into the run's report, under browser/screenshot/. The target is HELLO_URL,
# from ROBOT_TARGET_HELLO in ks.yaml. To add a check, add a test case here, finding elements by their
# role or label as a person would; to check another target, see docs/kubernetes.md, Robot Framework.

*** Settings ***
Documentation       hello in the browser: the text of its page, and a screenshot.
Resource            common.resource

Suite Setup         Open Target    ${HELLO_URL}
Suite Teardown      Close Everything


*** Test Cases ***
The page shows hello
    Get Text    body    contains    hello
    Take Screenshot
