#!/usr/bin/env bash
# core/pool.sh — pool state machine using jq for JSON manipulation

# Terminal states: entries in these states are considered "settled"
POOL_TERMINAL_STATES=("landed" "landed-pending-kpi" "reverted" "killed")

# _pool_atomic_write pool_file json
# Writes json to pool_file atomically via a tmpfile + mv.
_pool_atomic_write() {
    local pool_file="$1"
    local json="$2"
    local tmpfile
    tmpfile="$(mktemp "${pool_file}.tmp.XXXXXX")"
    printf '%s\n' "$json" > "$tmpfile"
    mv "$tmpfile" "$pool_file"
}

# pool_init pool_file
# Writes an empty JSON array to pool_file.
pool_init() {
    local pool_file="$1"
    _pool_atomic_write "$pool_file" "[]"
}

# pool_add_entry pool_file entry_json
# Appends a JSON object to the pool array.
pool_add_entry() {
    local pool_file="$1"
    local entry_json="$2"
    local updated
    updated="$(jq --argjson entry "$entry_json" '. + [$entry]' "$pool_file")"
    _pool_atomic_write "$pool_file" "$updated"
}

# pool_count pool_file
# Outputs the number of entries in the pool.
pool_count() {
    local pool_file="$1"
    jq 'length' "$pool_file"
}

# pool_get_status pool_file id
# Outputs the status field of the entry with the given id.
pool_get_status() {
    local pool_file="$1"
    local id="$2"
    jq -r --arg id "$id" '.[] | select(.id == $id) | .status' "$pool_file"
}

# pool_set_status pool_file id new_status
# Sets the status field of the entry with the given id.
pool_set_status() {
    local pool_file="$1"
    local id="$2"
    local new_status="$3"
    local updated
    updated="$(jq --arg id "$id" --arg status "$new_status" \
        'map(if .id == $id then .status = $status else . end)' "$pool_file")"
    _pool_atomic_write "$pool_file" "$updated"
}

# pool_set_field pool_file id field value
# Sets a string field on the entry with the given id.
pool_set_field() {
    local pool_file="$1"
    local id="$2"
    local field="$3"
    local value="$4"
    local updated
    updated="$(jq --arg id "$id" --arg field "$field" --arg value "$value" \
        'map(if .id == $id then .[$field] = $value else . end)' "$pool_file")"
    _pool_atomic_write "$pool_file" "$updated"
}

# pool_set_field_raw pool_file id field json_value
# Sets a non-string field (number, null, array, object) on the entry with the given id.
pool_set_field_raw() {
    local pool_file="$1"
    local id="$2"
    local field="$3"
    local json_value="$4"
    local updated
    updated="$(jq --arg id "$id" --arg field "$field" --argjson value "$json_value" \
        'map(if .id == $id then .[$field] = $value else . end)' "$pool_file")"
    _pool_atomic_write "$pool_file" "$updated"
}

# pool_get_entry pool_file id
# Outputs the full JSON object of the entry with the given id.
pool_get_entry() {
    local pool_file="$1"
    local id="$2"
    jq -c --arg id "$id" '.[] | select(.id == $id)' "$pool_file"
}

# pool_get_ids_by_status pool_file status
# Outputs newline-separated IDs of entries with the given status.
pool_get_ids_by_status() {
    local pool_file="$1"
    local status="$2"
    jq -r --arg status "$status" '.[] | select(.status == $status) | .id' "$pool_file"
}

# pool_is_settled pool_file
# Returns 0 if all entries are in a terminal state, 1 otherwise.
# Terminal states: landed, landed-pending-kpi, reverted, killed
pool_is_settled() {
    local pool_file="$1"
    local non_terminal
    non_terminal="$(jq '[.[] | select(.status != "landed" and .status != "landed-pending-kpi" and .status != "reverted" and .status != "killed")] | length' "$pool_file")"
    [[ "$non_terminal" -eq 0 ]]
}

# pool_is_empty pool_file
# Returns 0 if the pool has no entries, 1 otherwise.
pool_is_empty() {
    local pool_file="$1"
    local count
    count="$(jq 'length' "$pool_file")"
    [[ "$count" -eq 0 ]]
}

# pool_status_hash pool_file
# Outputs an md5sum of the sorted "id:status" pairs.
pool_status_hash() {
    local pool_file="$1"
    jq -r '.[] | "\(.id):\(.status)"' "$pool_file" \
        | sort \
        | md5sum \
        | awk '{print $1}'
}

# pool_add_history pool_file id event detail
# Appends an object with timestamp, event, and detail to the entry's history array.
# Creates the history array if it does not exist.
pool_add_history() {
    local pool_file="$1"
    local id="$2"
    local event="$3"
    local detail="$4"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local updated
    updated="$(jq \
        --arg id "$id" \
        --arg ts "$ts" \
        --arg event "$event" \
        --arg detail "$detail" \
        'map(
            if .id == $id then
                .history = ((.history // []) + [{"timestamp": $ts, "event": $event, "detail": $detail}])
            else
                .
            end
        )' "$pool_file")"
    _pool_atomic_write "$pool_file" "$updated"
}
