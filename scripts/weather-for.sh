#!/usr/bin/env bash
# weather-for LOCATION - current weather summary via wttr.in (no key).
# Prints a one-line human-readable summary suitable for embedding in a
# Telegram message.
#
# Usage:
#   weather-for "Tres Cantos"
#   weather-for Madrid
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: weather-for <location>" >&2
  exit 1
fi

LOC="$*"

# wttr.in format placeholders:
#   %l location  %c condition  %t temp  %f feels-like  %h humidity  %w wind
#   %C gives text condition ("Clear") instead of an emoji, which matches the
#   agent's no-emoji voice rule. If you need the emoji glyph, swap %C for %c.
curl -fsS "https://wttr.in/${LOC// /+}?format=%l:+%C+%t,+feels+%f,+%h+humidity,+wind+%w" \
  || echo "weather unavailable for ${LOC}"
