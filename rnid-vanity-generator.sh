#!/bin/bash
set -o errexit
set -o nounset

print_help() {
    cat <<EOF
Usage: $(basename "$0") PREFIX [SUFFIX] [WORKERS]

PREFIX     Hexadecimal prefix the hash must start with (without "<>")
SUFFIX     Hexadecimal suffix the hash must end with (optional)
WORKERS    Number of parallel workers (default: 4)

Example:
  $(basename "$0") abc
  $(basename "$0") dead beef 6
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    print_help
    exit 0
fi

if [ $# -lt 1 ]; then
    echo "Error: PREFIX required"
    print_help
    exit 1
fi

PREFIX="$1"
SUFFIX=""
WORKERS=4

[ $# -ge 2 ] && SUFFIX="$2"
[ $# -ge 3 ] && WORKERS="$3"

TMPDIR="./temp_vanity"
RESULT_FILE="result_id"
mkdir -p "$TMPDIR"

COUNTER_FILE="$TMPDIR/counter_global"
echo 0 > "$COUNTER_FILE"

cleanup() {
    kill -- -$$ 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM EXIT

START_TIME=$(date +%s)

worker() {
    W="$1"
    TMP_ID="$TMPDIR/temp_w$W"
    TMP_OUT="$TMPDIR/out_w$W"

    while true; do
        if command -v flock >/dev/null 2>&1; then
            flock "$COUNTER_FILE" sh -c '
                c=$(cat "'"$COUNTER_FILE"'")
                c=$((c+1))
                echo "$c" > "'"$COUNTER_FILE"'"
            '
        else
            c=$(cat "$COUNTER_FILE")
            c=$((c+1))
            echo "$c" > "$COUNTER_FILE"
        fi

        rm -f "$TMP_ID"
        rnid -g "$TMP_ID" >"$TMP_OUT" 2>&1 || continue

        ID_LINE=$(grep "New identity <" "$TMP_OUT" || true)
        [ -z "$ID_LINE" ] && continue

        echo "[Worker $W] $ID_LINE"

        HASH=$(echo "$ID_LINE" | sed -n 's/.*New identity <\([0-9a-f]\+\)>.*/\1/p')
        [ -z "$HASH" ] && continue

        case "$HASH" in
            $PREFIX*) match_prefix=1 ;;
            *) match_prefix=0 ;;
        esac

        if [ -n "$SUFFIX" ]; then
            case "$HASH" in
                *"$SUFFIX") match_suffix=1 ;;
                *) match_suffix=0 ;;
            esac
        else
            match_suffix=1
        fi

        if [ "$match_prefix" -eq 1 ] && [ "$match_suffix" -eq 1 ]; then
            NOW=$(date +%s)
            ELAPSED=$((NOW - START_TIME))
            TOTAL_TRIES=$(cat "$COUNTER_FILE")
            RATE=$(awk "BEGIN{printf \"%.2f\", $TOTAL_TRIES/(($ELAPSED)==0?1:$ELAPSED)}")

            echo "================================================="
            echo "FOUND: <$HASH> by worker $W"
            echo "Attempts: $TOTAL_TRIES    Time elapsed: ${ELAPSED}s    Rate: ${RATE} attempts/s"
            echo "================================================="

            cp "$TMP_ID" "$RESULT_FILE"
            echo "Winner identity file copied to ./$RESULT_FILE"

            # clean up temp directory
            rm -rf "$TMPDIR"
            echo "Temporary folder '$TMPDIR' has been removed."

            cleanup
        fi

        THIS=$(cat "$COUNTER_FILE")
        [ $((THIS % 10000)) -eq 0 ] && echo "[Progress] Total tries: $THIS"
    done
}

for i in $(seq 1 $WORKERS); do
    worker "$i" &
done

wait
