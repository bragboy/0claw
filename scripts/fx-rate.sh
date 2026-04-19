#!/usr/bin/env bash
# fx-rate FROM TO [AMOUNT] - current FX rate via Frankfurter (ECB data, no key).
# Use this for ANY currency conversion instead of web_search.
#
# Usage:
#   fx-rate EUR USD
#   fx-rate EUR USD 100
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: fx-rate <FROM> <TO> [AMOUNT=1]" >&2
  exit 1
fi

FROM=$(echo "$1" | tr '[:lower:]' '[:upper:]')
TO=$(echo "$2" | tr '[:lower:]' '[:upper:]')
AMOUNT="${3:-1}"

curl -fsSL "https://api.frankfurter.dev/v1/latest?amount=${AMOUNT}&from=${FROM}&to=${TO}" \
  | jq -r --arg from "$FROM" --arg to "$TO" --arg amount "$AMOUNT" '
      "\($amount) \($from) = \(.rates | to_entries[0].value) \($to) rate=\(.rates | to_entries[0].value / ($amount | tonumber)) date=\(.date) source=frankfurter"'
