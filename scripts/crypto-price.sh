#!/usr/bin/env bash
# crypto-price SYMBOL [QUOTE] - live spot price via Binance public API.
# No API key required. Use this for ANY crypto price question instead of
# web_search; snippets are cached and lie.
#
# Usage:
#   crypto-price BTC             -> BTC/USDT
#   crypto-price ETH USD         -> ETH/USDT (USD remapped to USDT)
#   crypto-price SOL USDC
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: crypto-price <SYMBOL> [QUOTE=USDT]" >&2
  exit 1
fi

SYMBOL=$(echo "$1" | tr '[:lower:]' '[:upper:]')
QUOTE=$(echo "${2:-USDT}" | tr '[:lower:]' '[:upper:]')
[[ "$QUOTE" == "USD" ]] && QUOTE="USDT"
PAIR="${SYMBOL}${QUOTE}"

curl -fsS "https://api.binance.com/api/v3/ticker/24hr?symbol=${PAIR}" \
  | jq -r --arg pair "$PAIR" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      "\($pair) price=\(.lastPrice) change_24h=\(.priceChangePercent)% high_24h=\(.highPrice) low_24h=\(.lowPrice) volume_24h=\(.volume) at=\($at) source=binance"'
