#!/usr/bin/env bash
# bin/new-release-post.sh
#
# Interactive generator for a Kroxylicious proxy release announcement blog post.
#
# Usage:
#   ./bin/new-release-post.sh
#
# The script prompts for:
#   - The release version (e.g. 0.25.0)
#   - The previous release tag (e.g. v0.24.0) — used to compute the contributor list
#   - The new release tag or commit SHA
#   - The post author name and GitHub handle
#   - The post date (defaults to today)
#
# It then calls the GitHub API via `gh` to produce the contributor list inline,
# and writes a ready-to-edit markdown file to _posts/.
#
# Requirements:
#   - bash 4+  (macOS ships bash 3; run via `brew install bash` or use the bundled zsh)
#   - gh CLI installed and authenticated  (`gh auth status`)

set -euo pipefail

POSTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/_posts"

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "error: $*" >&2; exit 1; }

ask() {
  # ask <prompt> <variable-name> [default]
  local prompt="$1" var="$2" default="${3:-}"
  local display_default=""
  [[ -n "$default" ]] && display_default=" [$default]"
  while true; do
    read -r -p "${prompt}${display_default}: " value
    value="${value:-$default}"
    [[ -n "$value" ]] && break
    echo "  (required)" >&2
  done
  printf -v "$var" '%s' "$value"
}

fetch_contributors() {
  # Emits lines of the form "- [login](html_url)", sorted, deduplicated.
  local old_tag="$1" new_tag="$2"
  local jq_filter='.commits[].author | select(. != null) | select(.type == "User") | "\(.login)\t\(.html_url)"'

  echo "  Fetching contributors from GitHub API..." >&2
  local raw
  raw="$(gh api "repos/kroxylicious/kroxylicious/compare/${old_tag}...${new_tag}" --jq "$jq_filter" 2>&1)" \
    || { echo "  Warning: gh API call failed — contributor list will be empty. Fill it in manually." >&2; echo ""; return; }

  # Deduplicate by login (case-insensitive), sort, emit as markdown list items.
  echo "$raw" \
    | awk -F'\t' 'NF==2 {print tolower($1) "\t" $1 "\t" $2}' \
    | sort -u -t$'\t' -k1,1 \
    | awk -F'\t' '{print "- [" $2 "](" $3 ")"}'
}

# ── prompts ───────────────────────────────────────────────────────────────────

echo ""
echo "=== New Kroxylicious release post generator ==="
echo ""

ask "Release version (e.g. 0.25.0)"  VERSION
ask "Previous release tag (e.g. v0.24.0)" OLD_TAG
ask "New release tag or commit SHA   (e.g. v0.25.0)" NEW_TAG
ask "Author name" AUTHOR
ask "Author GitHub handle (without @)" AUTHOR_HANDLE
ask "Post date (YYYY-MM-DD)" POST_DATE "$(date +%Y-%m-%d)"

# ── derived values ────────────────────────────────────────────────────────────

SLUG="release-$(echo "$VERSION" | tr '.' '_')"
FILENAME="${POSTS_DIR}/${POST_DATE}-${SLUG}.md"

if [[ -f "$FILENAME" ]]; then
  die "File already exists: $FILENAME"
fi

CONTRIBUTORS="$(fetch_contributors "$OLD_TAG" "$NEW_TAG")"

# ── write post ────────────────────────────────────────────────────────────────

cat > "$FILENAME" <<EOF
---
layout: post
title: "Kroxylicious release ${VERSION}"
date: ${POST_DATE} 00:00:00 +0000
author: "${AUTHOR}"
author_url: "https://github.com/${AUTHOR_HANDLE}"
# noinspection YAMLSchemaValidation
categories: blog kroxylicious-proxy releases
tags: [ "releases", "kroxylicious-proxy" ]
---

# Kroxylicious ${VERSION}: <!-- TODO: one-line headline capturing the release theme -->

Kroxylicious ${VERSION} has snapped 🐊 into existence!

<!-- TODO: 2–4 sentence intro. What is the theme of this release? Why should readers care? -->

> **Release Highlights at a Glance:**
> * <!-- TODO: one bullet per major highlight, e.g. "**New Feature:** ..." -->

---

<!-- TODO: Add one H3 section per significant change.

### <Feature Name>

What it is, why it matters, how to use it.
Include a YAML/code block if configuration is involved.
Link to the relevant documentation and/or design proposal.

### <Another Feature or Change>

...

### Breaking Changes

If this release includes breaking changes, call them out clearly here.
Include migration steps or link to an automated migration tool.

-->

---

### Community Contributions

This release included commits from:

${CONTRIBUTORS:-<!-- TODO: contributor list could not be fetched — fill in manually -->}

Thank you all, your hard work is massively appreciated by the PMC!

### Artefacts

Download binary distributions and container images from the [download](https://kroxylicious.io/download/${VERSION}/) page.

### Feedback

Drop by and say hello on [Slack](https://kroxylicious.slack.com), [GitHub](https://github.com/kroxylicious/kroxylicious/issues), or [bsky](https://bsky.app/profile/kroxylicious.io). You can also join us in person at a [community call]({% link join-us/community-call/index.md %}).
EOF

echo ""
echo "Created: $FILENAME"
echo ""
echo "Next steps:"
echo "  1. Fill in the TODO sections in the post."
echo "  2. Preview with:  ./run.sh   (then visit http://127.0.0.1:4000/)"
echo "  3. Commit and open a PR."
