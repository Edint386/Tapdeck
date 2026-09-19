# Code signing shared by build.sh and Driver/build-driver.sh. Source it.
#
# Every Mac utility is signed with one shared self-signed certificate, created
# once in Keychain Access (see the mac-utilities AGENTS.md, "Code signing").
# macOS remembers privacy permissions — screen recording, microphone, audio
# capture — by the app's designated requirement. Signed with the certificate,
# that requirement is the certificate plus the bundle identifier, so the
# permissions survive rebuilds. Signed ad-hoc, it is the binary's hash, and
# every build loses them.

SIGNING_CERTIFICATE="Mac Utilities Code Signing"

# Print the identity to sign with: the argument when one is given (an explicit
# override), the shared certificate when the keychain has it, otherwise "-"
# for ad-hoc signing, with a warning on stderr.
signing_identity() {
  if [ -n "${1:-}" ]; then
    echo "$1"
  elif security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGNING_CERTIFICATE\""; then
    echo "$SIGNING_CERTIFICATE"
  else
    echo "warning: \"$SIGNING_CERTIFICATE\" is not in the keychain, so this build is signed ad-hoc." >&2
    echo "         Screen recording, microphone and audio capture permissions reset with every build." >&2
    echo "-"
  fi
}
