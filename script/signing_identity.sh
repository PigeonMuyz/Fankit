#!/usr/bin/env bash

# Resolve a stable signing identity. Reusing the team that owns the registered
# daemon prevents an update from looking like a different developer's app and
# asking the user to approve the helper again.
fankit_resolve_signing_identity() {
  local existing_app="${1:-}"
  if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "$SIGNING_IDENTITY"
    return 0
  fi

  local preferred_team=""
  preferred_team="$(
    launchctl print system/io.github.pigeonmuyz.fankit.helper 2>/dev/null \
      | sed -n 's/.*"team-identifier" => "\([^"]*\)".*/\1/p' \
      | head -1
  )"
  if [[ -z "$preferred_team" && -d "$existing_app" ]]; then
    preferred_team="$(
      codesign -dvv "$existing_app" 2>&1 \
        | sed -n 's/^TeamIdentifier=//p' \
        | head -1
    )"
  fi

  local identity_count=0
  local only_identity=""
  local matching_identity=""
  local line hash label team
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]{40})[[:space:]]+\"(.*)\"$ ]]; then
      hash="${BASH_REMATCH[1]}"
      label="${BASH_REMATCH[2]}"
      team="$(
        security find-certificate -c "$label" -p 2>/dev/null \
          | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
          | sed -n 's/.*OU=\([^,]*\).*/\1/p' \
          | head -1
      )"
      identity_count=$((identity_count + 1))
      only_identity="$hash"
      if [[ -n "$preferred_team" && "$team" == "$preferred_team" ]]; then
        matching_identity="$hash"
      fi
    fi
  done < <(security find-identity -p codesigning -v)

  if [[ -n "$matching_identity" ]]; then
    printf '%s\n' "$matching_identity"
  elif (( identity_count == 1 )); then
    printf '%s\n' "$only_identity"
  elif (( identity_count == 0 )); then
    echo "No code-signing identity found. Fankit requires a signed app to register its control helper." >&2
    return 1
  else
    echo "Multiple code-signing identities found and none matches the registered Fankit team." >&2
    echo "Set SIGNING_IDENTITY to keep release signatures stable across updates." >&2
    return 1
  fi
}
