#!/bin/sh
# Prints the server argument initialize-guard.sh decided on, read from DECISION_FILE: the -config
# flag of the initial configuration when the file holds exactly that, and otherwise nothing, so a
# missing, empty or other file never initialises. The chart runs it for the server's arguments.
# Usage: initialize-args.sh DECISION_FILE
flag=-config=/openbao/userconfig/openbao-initialize/initialize.json
if [ "$(cat "$1" 2> /dev/null)" = "$flag" ]; then
  echo "$flag"
fi
