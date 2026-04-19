#!/usr/bin/env bash
# stock-price TICKER - last trade via Yahoo Finance v8/chart endpoint.
# Use this for ANY stock/ETF price question instead of web_search.
#
# Usage:
#   stock-price AAPL
#   stock-price TSLA
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: stock-price <TICKER>" >&2
  exit 1
fi

TICKER=$(echo "$1" | tr '[:lower:]' '[:upper:]')

curl -fsS -A "Mozilla/5.0" "https://query1.finance.yahoo.com/v8/finance/chart/${TICKER}?interval=1m" \
  | jq -r --arg t "$TICKER" '
      (.chart.result[0].meta // null) as $m |
      if $m and $m.regularMarketPrice then
        ($m.regularMarketPrice - $m.previousClose) as $chg |
        ($chg / $m.previousClose * 100) as $pct |
        "\($m.symbol) price=\($m.regularMarketPrice) change=\($chg | . * 100 | round / 100) change_pct=\($pct | . * 100 | round / 100)% currency=\($m.currency) day_high=\($m.regularMarketDayHigh) day_low=\($m.regularMarketDayLow) prev_close=\($m.previousClose) at_unix=\($m.regularMarketTime) tz=\($m.exchangeTimezoneName) source=yahoo-finance"
      else
        "no data for \($t)"
      end'
