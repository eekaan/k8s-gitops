# Checks Ascender's sign-in page in a real browser, from inside the cluster: the page shows the form
# with its username and password fields, found by their labels, and its Log In button, found by its
# role and name, the strings of the pinned image's interface; and a screenshot of it goes into the
# run's report. It types nothing and clicks nothing: no suite signs in or holds a credential. The
# target is ASCENDER_URL, from ROBOT_TARGET_ASCENDER in robot's ks.yaml. The interface draws the form
# once its script has run, so the test sets the Browser library's timeout to a minute for itself
# before its first lookup: each lookup and each wait takes up to that, where the library's default
# is 10 seconds, and the first waits for the form. To change what is checked, change this file in a
# pull request; a new image whose form reads otherwise fails it (docs/kubernetes.md, Robot
# Framework).

*** Settings ***
Documentation       Ascender's sign-in page: its form, and a screenshot.
Resource            common.resource

Suite Setup         Open Target    ${ASCENDER_URL}
Suite Teardown      Close Everything


*** Test Cases ***
The sign-in page shows its form
    Set Browser Timeout    60s    scope=Test
    ${user_field}=    Get Element By    Label    Username
    Wait For Elements State    ${user_field}    visible
    ${pass_field}=    Get Element By    Label    Password
    Wait For Elements State    ${pass_field}    visible
    ${button}=    Get Element By Role    button    name=Log In
    Wait For Elements State    ${button}    visible
    Take Screenshot
