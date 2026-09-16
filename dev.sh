#!/bin/bash
# Dev iterate loop: build, install the (Dev) bundle, restart it.
#
#   ./dev.sh         build + install + relaunch the dev app (detached)
#   ./dev.sh --run   build + run in the FOREGROUND so print()/logs show in this terminal
#                    (Ctrl-C to stop)
set -e

RUN_FOREGROUND=false
[ "$1" = "--run" ] && RUN_FOREGROUND=true

# build.sh resolves the identity (scripts/signing-identity.sh): an Apple-issued
# certificate first, then the stable self-signed "InputStats-Dev". Either keeps the
# Accessibility grant across rebuilds; only the Apple-issued one has a Team ID, which
# is what stops the Keychain re-prompting on every build.
# Create the self-signed fallback once: Keychain Access > Certificate Assistant >
# Create a Certificate, name "InputStats-Dev", Identity Type "Self Signed Root",
# Certificate Type "Code Signing".
export SELF_SIGNED_FALLBACK="InputStats-Dev"
if [ "$(./scripts/signing-identity.sh)" = "-" ]; then
    echo "No signing certificate found — using ad-hoc signing."
    echo "  (You'll have to re-grant Accessibility after rebuilds. Create the cert once to stop this.)"
fi

./build.sh

BUNDLE="Input Stats (Dev).app"
# Both dev and release share the executable name "InputStats", so target the dev
# instance by its bundle path rather than process name (killall would hit both).
pkill -f "Input Stats \\(Dev\\).app" 2>/dev/null || true

if [ "$RUN_FOREGROUND" = true ]; then
    echo ""
    echo "Running in foreground — print() output appears below. Ctrl-C to stop."
    echo "------------------------------------------------------------------"
    exec "$BUNDLE/Contents/MacOS/InputStats"
else
    # rm first: cp -r merges into an existing bundle, which would leave stale binaries behind.
    rm -rf "/Applications/$BUNDLE"
    cp -r "$BUNDLE" /Applications/
    open "/Applications/$BUNDLE"
    echo "Relaunched: /Applications/$BUNDLE"
fi
