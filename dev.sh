#!/bin/bash
# Dev iterate loop: build, install the (Dev) bundle, restart it.
#
#   ./dev.sh         build + install + relaunch the dev app (detached)
#   ./dev.sh --run   build + run in the FOREGROUND so print()/logs show in this terminal
#                    (Ctrl-C to stop)
set -e

RUN_FOREGROUND=false
[ "$1" = "--run" ] && RUN_FOREGROUND=true

# Use a stable self-signed identity if present so the Accessibility grant survives rebuilds.
# Create it once: Keychain Access > Certificate Assistant > Create a Certificate,
# name "TypingStats-Dev", Identity Type "Self Signed Root", Certificate Type "Code Signing".
DEV_IDENTITY="TypingStats-Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_IDENTITY"; then
    export SIGNING_IDENTITY="$DEV_IDENTITY"
    echo "Signing with stable identity: $DEV_IDENTITY (Accessibility grant persists across rebuilds)"
else
    echo "No '$DEV_IDENTITY' cert found — using ad-hoc signing."
    echo "  (You'll have to re-grant Accessibility after rebuilds. Create the cert once to stop this.)"
fi

./build.sh

BUNDLE="Input Stats (Dev).app"
killall "Input Stats (Dev)" 2>/dev/null || true

if [ "$RUN_FOREGROUND" = true ]; then
    echo ""
    echo "Running in foreground — print() output appears below. Ctrl-C to stop."
    echo "------------------------------------------------------------------"
    exec "$BUNDLE/Contents/MacOS/TypingStats"
else
    cp -r "$BUNDLE" /Applications/
    open "/Applications/$BUNDLE"
    echo "Relaunched: /Applications/$BUNDLE"
fi
