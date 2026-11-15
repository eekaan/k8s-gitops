#!/bin/sh
# Puts age, the pinned release's binary, in TOOLS_DIR/age/age, for the step that encrypts. No public
# image carries age, so the release's archive is downloaded and checked against the SHA-256 the
# manifest pins for the node's architecture before anything in it is unpacked or run.
# Needs AGE_VERSION, AGE_SHA256_AMD64, AGE_SHA256_ARM64 and TOOLS_DIR.
set -eu
case $(uname -m) in
  x86_64) arch=amd64 expected=$AGE_SHA256_AMD64 ;;
  aarch64) arch=arm64 expected=$AGE_SHA256_ARM64 ;;
  *)
    echo "fetch-age: no pinned age for $(uname -m)" >&2
    exit 1
    ;;
esac
archive=$TOOLS_DIR/age.tar.gz
wget -q -O "$archive" "https://github.com/FiloSottile/age/releases/download/v$AGE_VERSION/age-v$AGE_VERSION-linux-$arch.tar.gz"
if ! printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - > /dev/null 2>&1; then
  rm -f "$archive"
  echo "fetch-age: the age $AGE_VERSION archive for $arch is not the one pinned" >&2
  exit 1
fi
tar -xzf "$archive" -C "$TOOLS_DIR" age/age
rm -f "$archive"
