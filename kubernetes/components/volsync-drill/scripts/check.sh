#!/bin/sh
# The restore drill's check: reads the scratch claim the drill restored into, mounted read-only at
# DRILL_DIR, and exits 0, printing one line with the age, only when the canary the application
# writes, the file heartbeat at the volume's root, is there and no older than DRILL_MAX_AGE_SECONDS.
# Its first field is the Unix time in seconds, so the check parses no date and uses only integer
# arithmetic, and runs alike under busybox's sh and any other POSIX sh. Every failure exits 1 and
# names its reason on standard error. It writes nothing. Flux substitutes a variable written with a
# dollar sign and braces in what it applies, so the script writes none that way.

fail() {
  echo "restore drill check failed: $*" >&2
  exit 1
}

# A whole number of at most 12 digits, without a leading zero, which every sh's arithmetic takes as
# decimal and holds without overflow.
case $DRILL_MAX_AGE_SECONDS in
  '' | *[!0-9]* | 0* | ?????????????*)
    fail "DRILL_MAX_AGE_SECONDS is not a positive whole number of seconds: '$DRILL_MAX_AGE_SECONDS'"
    ;;
esac
[ -d "$DRILL_DIR" ] || fail "DRILL_DIR is not a directory: '$DRILL_DIR'"

listing=$(ls -A "$DRILL_DIR") || fail "cannot list DRILL_DIR, $DRILL_DIR"
if [ -z "$listing" ] || [ "$listing" = lost+found ]; then
  fail "the restore brought nothing back: $DRILL_DIR is empty, and a repository path that holds no backup restores nothing without an error, as when APP or the bucket's prefix changed"
fi
[ -e "$DRILL_DIR/heartbeat" ] || fail "the restore brought files back, but $DRILL_DIR holds no heartbeat: the backup holds no canary of the application's"
[ -f "$DRILL_DIR/heartbeat" ] && [ -r "$DRILL_DIR/heartbeat" ] || fail "the heartbeat in $DRILL_DIR is not a file this user can read"

stamp=
read -r stamp _ < "$DRILL_DIR/heartbeat"
case $stamp in
  '' | *[!0-9]* | 0?* | ?????????????*)
    fail "the heartbeat's first field is not a whole number of seconds: '$stamp'"
    ;;
esac
now=$(date +%s) || fail "the clock gave no time"
case $now in
  '' | *[!0-9]* | 0?* | ?????????????*) fail "the clock gave no whole number of seconds: '$now'" ;;
esac
[ "$stamp" -le "$now" ] || fail "the heartbeat lies in the future: $stamp is $((stamp - now)) seconds after the clock's $now"

age=$((now - stamp))
[ "$age" -le "$DRILL_MAX_AGE_SECONDS" ] || fail "the heartbeat is $age seconds old, older than the largest age of $DRILL_MAX_AGE_SECONDS seconds: the newest backup the drill restored is too old"
echo "restore drill check passed: the heartbeat is $age seconds old, within the largest age of $DRILL_MAX_AGE_SECONDS seconds"
