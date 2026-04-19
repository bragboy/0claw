#!/usr/bin/env bash
# news-search QUERY [FRESHNESS] - current news via Brave's news index with a
# freshness filter. Unlike web_search, which returns cached crawl snippets
# that can be days or weeks stale, this queries Brave's news vertical with
# an explicit time window and returns article titles + publication dates +
# URLs. Use this for anything "latest / today / this week / breaking".
#
# FRESHNESS: pd (past day, default), pw (past week), pm (past month)
#
# Usage:
#   news-search "meta layoffs"
#   news-search "tesla earnings" pw
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: news-search <QUERY> [FRESHNESS=pd]" >&2
  echo "  FRESHNESS: pd (past day, default), pw (past week), pm (past month)" >&2
  exit 1
fi

QUERY="$1"
FRESHNESS="${2:-pd}"

# ZeroClaw's shell tool scrubs env vars for security, so pull BRAVE_API_KEY
# from the sideload file written by init-glm.sh when it's not in env.
if [[ -z "${BRAVE_API_KEY:-}" && -r /root/.zeroclaw/env ]]; then
  # shellcheck disable=SC1091
  . /root/.zeroclaw/env
fi
: "${BRAVE_API_KEY:?BRAVE_API_KEY is not set}"

Q_ENCODED=$(jq -rn --arg q "$QUERY" '$q | @uri')

echo "query: ${QUERY}   freshness: ${FRESHNESS}   source: brave-news"
echo ""

curl -fsS -H "X-Subscription-Token: ${BRAVE_API_KEY}" \
  "https://api.search.brave.com/res/v1/news/search?q=${Q_ENCODED}&freshness=${FRESHNESS}&count=10" \
  | jq -r '
      (.results // []) as $r |
      if ($r | length) == 0 then
        "(no results in this freshness window; try pw for past-week, pm for past-month)"
      else
        $r[] |
          "date:    \(.age // "unknown")\ntitle:   \(.title)\nsource:  \(.meta_url.hostname // .meta_url.netloc // .url)\nurl:     \(.url)\nsummary: \((.description // "") | gsub("<[^>]+>"; ""))\n"
      end'
