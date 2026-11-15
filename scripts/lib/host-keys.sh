# shellcheck shell=bash
# Shared by scripts/lib/ci-host.sh and scripts/lib/edge.sh: how the SSH host keys of a new host are
# trusted. A new instance has host keys of its own, and the connection that follows holds to what is
# recorded, so what is recorded decides who the operator's key-based session talks to.
#
# cloud-init's keys_to_console module runs tools/write-ssh-key-fingerprints at the end of the first
# boot and writes what it prints to the console. The tool sends each line through util-linux's
# `logger -s -p user.info`, tagged cloud-init from cloud-init 21.2 and ec2 up to 21.1, so each line
# carries logger's header, `<14>Nov 15 09:42:08 cloud-init: `, and the fingerprints stand between
#   -----BEGIN SSH HOST KEY FINGERPRINTS-----
#   -----END SSH HOST KEY FINGERPRINTS-----
# one per line, as `256 SHA256:<43 characters> root@host (ED25519)`. The console is readable through
# the cloud's compute API with the credentials the recipes already hold, over a channel that does
# not pass through the address being verified, so the recipes compare the keys an address offers
# with it instead of asking a person to compare them by eye. The console is the instance's word,
# read through an API the operator trusts with the credentials; a cloud whose API lies is outside
# what this defends against.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"

# The number of lines of the console the client is asked for: the end of the log, where the block
# is, with room for the boot's own output after it. A block the limit cuts off is not read.
host_console_lines=1000

# logger's header on a line cloud-init printed, as logger writes it for user.info: <14>, the month's
# English abbreviation, the day of the month padded with a space below 10 (`Nov  5`), the time, and
# the tag with no process id. The last capture is the line itself.
console_header='^<14>(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ( [1-9]|[12][0-9]|3[01]) [0-9]{2}:[0-9]{2}:[0-9]{2} (cloud-init|ec2): (.*)$'

# console_fingerprints INSTANCE_ID: prints the SHA256 fingerprints cloud-init printed on the console
# of the instance INSTANCE_ID, sorted, one per line, and returns
#   0 when it printed some,
#   3 when the console holds no complete block of them,
#   1 when the client could not read the console (it failed, or no such instance),
#   4 when the client cannot be run here at all, saying why on standard error: the recipes' refusals
#     (Go's HTTP/2 debug log, no cloud credential) and a client older than they need.
# Only the block between cloud-init's own markers counts, and of several, the latest: the log holds
# every boot of the instance that its limit reaches, and cloud-init prints the block at the end of
# a first boot (its keys_to_console module runs once per instance, so a reboot adds none, and a
# new instance, with a new identifier, has a console of its own). A block cut off by the line limit,
# at its start or at its end, is not a block, and the earlier boot's block does not stand in for the
# latest boot's. A line ends in LF or, as a serial console's terminal writes it, CR LF. Only lines
# that start with logger's header in exactly the form above are cloud-init's: the header is taken
# off, and a line without it is ignored, as is a line inside the markers that is not a fingerprint
# of that form and every line outside them. So is the copy of a line the journal forwards to the
# console, `[   74.767670] cloud-init[519]: ...`, and a line a process on the instance printed.
console_fingerprints() {
  local id=$1 log line inside=0 block='' latest=''
  refuse_http2_debug || return 4
  require_openstack_auth || return 4
  if ! type -P openstack > /dev/null; then
    infra_error "the openstack client is not on PATH; reading an instance's console needs python-openstackclient 7.0.0 or newer"
    return 4
  fi
  if ! openstack_client_recent; then
    infra_error "python-openstackclient 7.0.0 or newer is needed to read an instance's console"
    return 4
  fi
  # The client's own words are not shown: they can hold the identifier and the cloud's endpoints.
  log=$(openstack console log show --lines "$host_console_lines" "$id" 2> /dev/null) || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ $console_header ]] || continue
    line=${BASH_REMATCH[4]}
    case $line in
      '-----BEGIN SSH HOST KEY FINGERPRINTS-----')
        inside=1 block=''
        ;;
      '-----END SSH HOST KEY FINGERPRINTS-----')
        if ((inside)); then
          latest=$block
        fi
        inside=0
        ;;
      *)
        if ((inside)) && [[ $line =~ ^[0-9]+\ (SHA256:[A-Za-z0-9+/]{43})(\ |$) ]]; then
          block+=${BASH_REMATCH[1]}$'\n'
        fi
        ;;
    esac
  done <<< "$log"
  # A block still open at the end is the latest boot's, cut off or not yet finished.
  if ((inside)); then
    latest=''
  fi
  [[ -n $latest ]] || return 3
  printf '%s' "$latest" | sort -u
}

# host_clock: the time in seconds since the epoch, from date +%s; fails, saying so, when date gives
# anything but a whole number, which arithmetic could not be trusted with. The waits below and in
# scripts/edge-rollout are timed with it.
host_clock() {
  local now
  if ! now=$(date +%s) || [[ ! $now =~ ^[0-9]+$ ]]; then
    infra_error "date +%s does not give the time, so the wait for the console cannot be timed"
    return 1
  fi
  printf '%s' "$now"
}

# ssh_host_trust ADDRESS KNOWN_HOSTS LABEL [INSTANCE_ID [WAIT [INTERVAL]]]: when the host's key is
# not in KNOWN_HOSTS, scans the host once for the keys it offers and decides, with those keys alone,
# what is recorded. LABEL names the host in what it prints, such as "CI host". With the host's
# INSTANCE_ID it reads the instance's console (console_fingerprints), trying again every INTERVAL
# seconds, 5 when unset, for at most WAIT seconds, 0 when unset, while the client fails or the
# console holds no block yet, which a first boot prints late; a client that cannot be run, or a
# clock that gives no time, leaves one read. Then:
#   every key offered is on the console: they are recorded, with no prompt;
#   the console holds fingerprints and one offered is not among them: nothing is recorded, no prompt
#     is offered, and nothing overrides that;
#   the console holds none or cannot be read: the fingerprints the host offers are shown, and the
#     keys are recorded only once yes is typed, as the comparison with the console is the
#     operator's.
# Returns 2 when the keys were not accepted, 3 when the host offers a key its instance did not
# print, 1 when the host does not answer. Never prints an address. Shared with scripts/lib/edge.sh.
ssh_host_trust() {
  local address=$1 known_hosts=$2 label=$3 instance=${4-} wait=${5-0} interval=${6-5}
  local scanned offered console='' console_read=0 now deadline fingerprint count=0 unprinted=() answer='' why=''
  if [[ -s $known_hosts ]] && ssh-keygen -F "$address" -f "$known_hosts" > /dev/null 2>&1; then
    return 0
  fi
  # Hashed, so the file does not list the address. This scan is what is compared and what is
  # recorded: there is no second one in between.
  scanned=$(ssh-keyscan -H -T 15 "$address" 2> /dev/null) || scanned=
  if [[ -z $scanned ]]; then
    infra_error "the $label does not answer on SSH; it may still be booting"
    return 1
  fi
  offered=$(ssh-keygen -l -f /dev/stdin <<< "$scanned" | awk '{ print $2 }')
  if [[ -z $offered ]]; then
    infra_error "the $label offers no SSH host key that ssh-keygen can read"
    return 1
  fi
  count=$(grep -c . <<< "$offered")

  if [[ -z $instance ]]; then
    why="the stack's outputs name no instance for it"
    console_read=5
  else
    if ! now=$(host_clock); then
      now=0 wait=0
    fi
    deadline=$((now + wait))
    while :; do
      console_read=0
      console=$(console_fingerprints "$instance") || console_read=$?
      # An answer, a client that cannot be run, which waiting does not change, or no wait at all.
      if ((console_read == 0 || console_read == 4 || wait == 0)); then
        break
      fi
      now=$(host_clock) || break
      ((now < deadline)) || break
      sleep "$interval"
    done
    case $console_read in
      3) why="held no fingerprints" ;;
      1) why="could not be read" ;;
      4) why="was not read" ;;
    esac
  fi

  if ((console_read == 0)); then
    while IFS= read -r fingerprint; do
      grep -qxF -- "$fingerprint" <<< "$console" || unprinted+=("$fingerprint")
    done <<< "$offered"
    if ((${#unprinted[@]} > 0)); then
      echo "The $label offers a key its instance did not print on its console:"
      printf '  %s\n' "${unprinted[@]}"
      infra_error "the $label offers a key its instance did not print on its console, so nothing was recorded and nothing was done on the host; check that the floating address is still associated with this instance and that something else did not rebuild the instance, and otherwise treat it as someone else answering"
      return 3
    fi
    host_keys_record "$known_hosts" "$scanned"
    if ((count == 1)); then
      echo "$label: the 1 SSH host key it offers matches its instance's console; recorded in ${known_hosts/#"$HOME"/\~}"
    else
      echo "$label: the $count SSH host keys it offers match its instance's console; recorded in ${known_hosts/#"$HOME"/\~}"
    fi
    return 0
  fi

  case $console_read in
    5) echo "The console of the $label's instance was not read: $why." ;;
    *) echo "The console of the $label's instance $why, so the comparison is yours." ;;
  esac
  echo "The $label's SSH host key is not recorded. The keys it offers:"
  ssh-keygen -l -f /dev/stdin <<< "$scanned" | awk '{ print "  " $2 " " $NF }'
  echo "Compare them with the fingerprints the host printed on its console when it first booted."
  printf 'Type yes to record them and connect: ' >&2
  read -r answer || true
  if [[ $answer != yes ]]; then
    infra_error "the host key was not accepted; nothing was done on the host"
    return 2
  fi
  host_keys_record "$known_hosts" "$scanned"
  echo "recorded the $label's key in ${known_hosts/#"$HOME"/\~}"
}

# host_keys_record KNOWN_HOSTS SCANNED: appends the scanned keys, as ssh-keyscan printed them, to
# KNOWN_HOSTS, which only its owner can read.
host_keys_record() {
  mkdir -p "${1%/*}"
  chmod 700 "${1%/*}"
  (umask 077 && printf '%s\n' "$2" >> "$1")
}
