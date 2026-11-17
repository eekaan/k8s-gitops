# shellcheck shell=bash
# Shared by scripts/postgres-dump-check and scripts/openbao-snapshot-check: the steps a recipe takes
# to open one encrypted backup from a backup bucket without keeping any of it, before it reads what
# it opened: the private directory on a memory-backed filesystem, the choice of the object in a
# listing, its download, and its decryption with the Talos age key once it is seen to be an age
# file. A step says why it failed in the recipe's own words: KIND is what the recipe calls its
# backup, dump or snapshot, and NAME the object's name. Builds on scripts/lib/cluster.sh, for the
# private directory and the Talos age key, and through it on scripts/lib/s3.sh and
# scripts/lib/errors.sh.

# shellcheck source=scripts/lib/cluster.sh
. "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"

# memory_backed_dir: prints the first of the runtime directory and /dev/shm that this user can write
# and that is on a memory-backed filesystem, and fails when there is none.
memory_backed_dir() {
  local dir
  for dir in "${XDG_RUNTIME_DIR-}" /dev/shm; do
    if [[ -n $dir && -d $dir && -w $dir ]]; then
      case $(stat -f -c %T "$dir" 2> /dev/null) in
        tmpfs | ramfs)
          printf '%s\n' "$dir"
          return 0
          ;;
      esac
    fi
  done
  return 1
}

# backup_private_dir KIND: makes work_dir, the directory the KIND is kept in while it is checked
# (make_private_dir, which removes it on every exit), on a memory-backed filesystem where there is
# one and otherwise under TMPDIR, which it says on standard error, and sets scratch to what the
# recipe prints of the two. From here on TMPDIR is that directory.
backup_private_dir() {
  local base
  if base=$(memory_backed_dir); then
    scratch="memory-backed"
  else
    base=${TMPDIR:-/tmp}
    # shellcheck disable=SC2034 # read by the recipes that source this
    scratch="disk, as no memory-backed filesystem was found; removed afterwards"
    infra_error "no memory-backed filesystem was found; the $1 is kept on the disk, under TMPDIR, until the check removes it"
  fi
  TMPDIR=$base make_private_dir || return 1
  # What rclone and the tools that read the backup report is kept in the directory too, so it goes
  # with it.
  export TMPDIR=$work_dir
}

# backup_find LISTING WANTED ROLE KIND WHOSE LISTER: sets backup_name to the object WANTED names in
# LISTING, names and sizes, newest first, as s3_backup_objects lists a path: that name, or with
# latest the first one, the newest. Fails when LISTING holds none, or not that one, saying that the
# ROLE bucket holds no such KIND of WHOSE and that the recipe LISTER lists them.
backup_find() {
  local listed
  backup_name=
  while read -r listed _; do
    if [[ -n $listed && ($2 == latest || $listed == "$2") ]]; then
      backup_name=$listed
      break
    fi
  done <<< "$1"
  if [[ -z $backup_name && $2 == latest ]]; then
    infra_error "the $3 bucket holds no $4 of $5; just $6 lists them"
    return 1
  elif [[ -z $backup_name ]]; then
    infra_error "the $3 bucket holds no $4 $2 of $5; just $6 lists them"
    return 1
  fi
}

# backup_download ROLE PATH NAME FILE: downloads the object NAME under PATH/ in the ROLE bucket into
# FILE with the state key. Fails when rclone does, showing its reason as scripts/lib/errors.sh shows
# errors, and when FILE holds nothing afterwards.
backup_download() {
  # rclone copies nothing, and succeeds, when the object is not there.
  if ! run_keeping_errors s3_rclone state copyto "store:$BACKUP_BUCKET_PREFIX-$1/$2/$3" "$4" ||
    [[ ! -s $4 ]]; then
    report_errors rclone
    infra_error "rclone cannot download $3 with the state key"
    return 1
  fi
}

# backup_decrypt NAME ENCRYPTED PLAIN: decrypts ENCRYPTED, the object NAME, into PLAIN with the Talos
# age key (age_decrypt), once it is seen to begin with the age header. Fails saying which it is: no
# age file, one the Talos age key does not open, or one age cannot read for another reason. Nothing
# age reports is shown.
backup_decrypt() {
  # tr drops the NUL of a binary file's header, which bash would warn about.
  if [[ $(head -c 21 "$2" | tr -d '\0') != age-encryption.org/v1 ]]; then
    infra_error "$1 is not an age file"
    return 1
  fi
  if ! run_keeping_errors age_decrypt "$2" "$3"; then
    # age's other errors, such as a full directory, name the scratch directory, so only this one is told.
    if [[ $last_errors == *"no identity matched"* ]]; then
      infra_error "the Talos age key cannot decrypt $1"
    else
      infra_error "age cannot read $1, for a reason other than the key: it may be damaged, or the scratch directory full"
    fi
    return 1
  fi
}
