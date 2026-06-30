#!/usr/bin/env bash
# Validates the shipped compat-db against its schema, and proves the validator
# actually rejects malformed entries (so it can't silently pass everything).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V="$REPO_ROOT/tests/validate-compat-db.py"

if ! command -v python3 >/dev/null 2>&1; then note "skipping (need python3)"; finish; exit $?; fi

# the real, shipped DB must pass
python3 "$V" >/dev/null 2>&1; assert_eq "shipped apps.json passes schema" "0" "$?"

# a 'workaround' entry missing winetricks_verbs must FAIL
bad="$(new_stubdir)/bad.json"
printf '%s\n' '{"schema_version":1,"apps":[{"id":"x","name":"X","category":"c","status":"workaround"}]}' > "$bad"
python3 "$V" "$bad" >/dev/null 2>&1; assert_eq "missing winetricks_verbs is rejected" "1" "$?"

# an unknown status must FAIL
printf '%s\n' '{"schema_version":1,"apps":[{"id":"x","name":"X","category":"c","status":"bogus"}]}' > "$bad"
python3 "$V" "$bad" >/dev/null 2>&1; assert_eq "unknown status is rejected" "1" "$?"

# a missing required key must FAIL
printf '%s\n' '{"schema_version":1,"apps":[{"id":"x","status":"broken"}]}' > "$bad"
python3 "$V" "$bad" >/dev/null 2>&1; assert_eq "missing required key is rejected" "1" "$?"

# a native-alternative with neither apt nor flatpak must FAIL
printf '%s\n' '{"schema_version":1,"apps":[{"id":"x","name":"X","category":"c","status":"native-alternative-recommended","native_alternative":{"notes":"n"}}]}' > "$bad"
python3 "$V" "$bad" >/dev/null 2>&1; assert_eq "native-alt without apt/flatpak is rejected" "1" "$?"

rm -rf "$(dirname "$bad")"
finish
