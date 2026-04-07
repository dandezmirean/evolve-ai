#!/usr/bin/env bash
# core/inbox/sources/rss.sh — RSS/Atom feed adapter for evolve-ai
# Fetches an RSS feed and drops individual items into inbox/pending/.

# ---------------------------------------------------------------------------
# source_rss_fetch <name> <url> <output_dir>
# Fetches an RSS feed URL, extracts items, writes each as a separate file
# to output_dir. Each file named: {name}-{date}-{item-index}.md
# Handles both RSS 2.0 (<item>) and Atom (<entry>) formats at a basic level.
# ---------------------------------------------------------------------------
source_rss_fetch() {
    local name="$1"
    local url="$2"
    local output_dir="$3"

    if [[ -z "$url" ]]; then
        echo "[source:rss] No URL configured for source '$name' — skipping" >&2
        return 0
    fi

    mkdir -p "$output_dir"

    local today
    today="$(date +%Y-%m-%d)"

    # Fetch feed
    local feed_content
    feed_content="$(curl -sL --max-time 30 "$url" 2>/dev/null)" || {
        echo "[source:rss] Failed to fetch feed '$name' from $url" >&2
        return 1
    }

    if [[ -z "$feed_content" ]]; then
        echo "[source:rss] Empty response from feed '$name' ($url)" >&2
        return 0
    fi

    # Detect format: Atom uses <entry>, RSS uses <item>
    local tag_open tag_close
    if echo "$feed_content" | grep -q '<entry'; then
        tag_open="entry"
        tag_close="entry"
    else
        tag_open="item"
        tag_close="item"
    fi

    # Extract items using awk
    local item_index=0
    local in_item=0
    local item_buffer=""

    while IFS= read -r line; do
        if echo "$line" | grep -q "<${tag_open}[> ]"; then
            in_item=1
            item_buffer=""
        fi

        if [[ "$in_item" -eq 1 ]]; then
            item_buffer="${item_buffer}${line}
"
        fi

        if echo "$line" | grep -q "</${tag_close}>"; then
            if [[ "$in_item" -eq 1 ]]; then
                (( item_index++ )) || true

                # Extract title
                local title
                title="$(echo "$item_buffer" | sed -n 's/.*<title[^>]*>\(.*\)<\/title>.*/\1/p' | head -1)"
                title="$(echo "$title" | sed 's/<!\[CDATA\[//g; s/\]\]>//g')"

                # Extract link — handle RSS <link> and Atom <link href="..."/>
                local link
                link="$(echo "$item_buffer" | sed -n 's/.*<link[^>]*>\(.*\)<\/link>.*/\1/p' | head -1)"
                if [[ -z "$link" ]]; then
                    link="$(echo "$item_buffer" | sed -n 's/.*<link[^>]*href="\([^"]*\)".*/\1/p' | head -1)"
                fi

                # Extract date — pubDate (RSS) or updated/published (Atom)
                local pub_date
                pub_date="$(echo "$item_buffer" | sed -n 's/.*<pubDate>\(.*\)<\/pubDate>.*/\1/p' | head -1)"
                if [[ -z "$pub_date" ]]; then
                    pub_date="$(echo "$item_buffer" | sed -n 's/.*<updated>\(.*\)<\/updated>.*/\1/p' | head -1)"
                fi
                if [[ -z "$pub_date" ]]; then
                    pub_date="$(echo "$item_buffer" | sed -n 's/.*<published>\(.*\)<\/published>.*/\1/p' | head -1)"
                fi
                if [[ -z "$pub_date" ]]; then
                    pub_date="$today"
                fi

                # Extract description — description (RSS) or summary/content (Atom)
                local description
                description="$(echo "$item_buffer" | sed -n 's/.*<description[^>]*>\(.*\)<\/description>.*/\1/p' | head -1)"
                if [[ -z "$description" ]]; then
                    description="$(echo "$item_buffer" | sed -n 's/.*<summary[^>]*>\(.*\)<\/summary>.*/\1/p' | head -1)"
                fi
                # Strip CDATA wrappers and basic HTML tags
                description="$(echo "$description" | sed 's/<!\[CDATA\[//g; s/\]\]>//g; s/<[^>]*>//g')"

                # Write file
                local out_file="$output_dir/${name}-${today}-${item_index}.md"
                cat > "$out_file" <<EOF
# ${title:-Untitled}
Source: ${name} (RSS)
URL: ${link:-unknown}
Date: ${pub_date}

${description:-No description available.}
EOF

                in_item=0
                item_buffer=""
            fi
        fi
    done <<< "$feed_content"

    echo "[source:rss] Fetched $item_index item(s) from '$name'"
}
