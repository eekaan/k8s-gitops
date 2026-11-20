# The keywords the suites share: Open Target opens a headless Chromium, a context of its own and a
# page at the target's URL, and Close Everything, each suite's teardown, closes the browser. A suite
# finds this file by name, as run.sh puts its directory on Robot's path. Chromium runs without its
# sandbox, as Playwright starts it and the restricted level requires, so a suite is to open only
# the tree's targets, the variables ks.yaml names, which tests/robot.bats checks in the suites' text
# (docs/kubernetes.md, Robot Framework). To change what every suite does at its start or end,
# change this file in a pull request.

*** Settings ***
Documentation       Opening and closing the browser the suites check their targets in.
Library             Browser


*** Keywords ***
Open Target
    [Documentation]    A headless Chromium, a context of its own and a page at ${url}.
    [Arguments]    ${url}
    New Browser    chromium    headless=True
    New Context
    New Page    ${url}

Close Everything
    [Documentation]    Closes every browser the suite opened, with its contexts and pages.
    Close Browser    ALL
