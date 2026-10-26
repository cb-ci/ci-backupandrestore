#! /bin/bash

# Restores many controllers in parallel from the archives listed in controllers-backups.json
# (created by listControllersWithBackups.sh) by calling restoreControllerfromS3.sh once per controller.
#
# - Pod name: "podName" of the controller in the file (<kubernetes name from the endpoint>-0, so controllers
#   in folders work too, e.g. tmp-folder-controllers-controllerinfolder-0).
# - Controllers without a mapped backup are skipped; if there are several backups, the newest is used.
# - Unmatched backups (e.g. 'backup-controllerinfolder-...' for a controller in a folder) are reported. If exactly one
#   controller has the same short name, the script asks (yes/no, interactive only) whether to assign them to it.
# - Output of each restore goes to <log-dir>/<statefulSet>.log; a summary is printed at the end.

set -eo pipefail -u

cd "$(dirname "$0")"

# --- Options ---
BACKUPS_FILE="controllers-backups.json"
JOBS="${JOBS:-3}"
ONLY=""
EXCLUDE=""
DRY_RUN=false
LOG_DIR="logs"
RESTORE_ARGS=()   # extra args passed to restoreControllerfromS3.sh (e.g. --preserve-identity)

usage() {
    cat <<EOF
Usage: $0 [options] [-- <extra restoreControllerfromS3.sh args>]

  -j, --jobs N          Number of parallel restores (default: 3, or JOBS env var)
  -f, --file FILE       Controllers/backups JSON file (default: controllers-backups.json)
      --only A,B        Restore only these controllers (fullName or Kubernetes name)
      --exclude A,B     Skip these controllers (fullName or Kubernetes name)
      --log-dir DIR     Directory for per-controller logs (default: logs)
      --dry-run         Print the controller -> pod -> archive plan and exit
  -h, --help            Show this help

Example: $0 -j 4 --exclude workshop -- --preserve-identity
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -j|--jobs|-f|--file|--only|--exclude|--log-dir)
            if [ $# -lt 2 ]; then echo "Option $1 requires a value" >&2; usage >&2; exit 1; fi
            case "$1" in
                -j|--jobs) JOBS="$2" ;;
                -f|--file) BACKUPS_FILE="$2" ;;
                --only) ONLY="$2" ;;
                --exclude) EXCLUDE="$2" ;;
                --log-dir) LOG_DIR="$2" ;;
            esac
            shift
            ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        --) shift; RESTORE_ARGS=("$@"); break ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --jobs must be a positive integer (got '$JOBS')" >&2
    exit 1
fi
for tool in jq kubectl; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool command not found. Please install it and ensure it's in your PATH." >&2
        exit 1
    fi
done
if [ ! -f "$BACKUPS_FILE" ]; then
    echo "Error: $BACKUPS_FILE not found. Create it with ./listControllersWithBackups.sh" >&2
    exit 1
fi
if ! jq -e '.controllers | arrays' "$BACKUPS_FILE" > /dev/null 2>&1; then
    echo "Error: $BACKUPS_FILE has no 'controllers' array. Create it with ./listControllersWithBackups.sh" >&2
    exit 1
fi

# All further processing works on this copy, so suggestions can be applied in memory
# without modifying the file on disk.
DATA=$(cat "$BACKUPS_FILE")

# --- Unmatched backups: offer to assign them to the controller with the same short name ---
unmatched=$(jq '.unmatchedBackups | length' <<< "$DATA")
if [ "$unmatched" -gt 0 ]; then
    echo "[WARN] $unmatched backup(s) could not be mapped to a controller and will NOT be restored ('unmatchedBackups' in $BACKUPS_FILE):" >&2
    jq -r '.unmatchedBackups[]
        | "         " + .file
          + (if (.possibleControllers | length) > 0 then "  (same short name as: " + (.possibleControllers | join(", ")) + ")" else "" end)' \
        <<< "$DATA" >&2

    # A suggestion exists only if exactly one controller has the same short name.
    suggestions=$(jq -r '. as $d
        | .unmatchedBackups[]
        | select((.possibleControllers | length) == 1)
        | .possibleControllers[0] as $n
        | ($d.controllers[] | select(.fullName == $n)) as $c
        | "         \(.file)\n             -> \($c.fullName) (pod \($c.podName))"' <<< "$DATA")
    ambiguous=$(jq '[.unmatchedBackups[] | select((.possibleControllers | length) > 1)] | length' <<< "$DATA")
    if [ "$ambiguous" -gt 0 ]; then
        echo "[WARN] $ambiguous unmatched backup(s) have several possible controllers and cannot be suggested automatically." >&2
    fi

    if [ -n "$suggestions" ]; then
        if [ -t 0 ]; then
            echo
            echo "Suggestion: assign these backups to the controller with the same short name:"
            echo "$suggestions"
            while true; do
                read -r -p "Apply these suggestions and include them in the restore? (yes/no) " answer || answer="no"
                case "$answer" in
                    yes|y|YES|Y)
                        # Add each suggested backup to its controller's backups and drop it from the unmatched list.
                        DATA=$(jq '
                            (.unmatchedBackups | map(select((.possibleControllers | length) == 1))) as $sug
                            | .controllers |= map(. as $c
                                | .backups += ($sug | map(select(.possibleControllers[0] == $c.fullName) | {file, date})))
                            | .unmatchedBackups |= map(select((.possibleControllers | length) != 1))' <<< "$DATA")
                        echo "[INFO] Suggestions applied (in memory only, $BACKUPS_FILE is not changed)."
                        break
                        ;;
                    no|n|NO|N)
                        echo "[INFO] Suggestions not applied."
                        break
                        ;;
                    *) echo "Please answer yes or no." ;;
                esac
            done
            echo
        else
            echo "[WARN] Not asking to apply the suggestions: stdin is not a terminal. Run interactively to review them." >&2
        fi
    fi
fi

# --- Build the plan: one line per controller with a backup (newest backup wins) ---
# Columns (tab separated): statefulSet, podName, archive, fullName
nobackup=$(jq -r '.controllers[] | select(.backups | length == 0) | .fullName' <<< "$DATA")
if [ -n "$nobackup" ]; then
    echo "[WARN] Skipping controllers without a mapped backup:" >&2
    echo "$nobackup" | sed 's/^/         /' >&2
fi

plan=$(jq -r '
    .controllers
    | map(select(.backups | length > 0))
    | sort_by(.statefulSet)
    | .[] | [.statefulSet, .podName, (.backups | max_by(.date) | .file), .fullName] | @tsv' <<< "$DATA")

# Apply --only / --exclude (comma separated; fullName or Kubernetes name).
in_list() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
filtered=""
while IFS=$'\t' read -r controller pod archive fullname; do
    [ -z "$controller" ] && continue
    if [ -n "$ONLY" ] && ! in_list "$controller" "$ONLY" && ! in_list "$fullname" "$ONLY"; then continue; fi
    if [ -n "$EXCLUDE" ] && { in_list "$controller" "$EXCLUDE" || in_list "$fullname" "$EXCLUDE"; }; then continue; fi
    filtered+="$controller"$'\t'"$pod"$'\t'"$archive"$'\t'"$fullname"$'\n'
done <<< "$plan"
plan="${filtered%$'\n'}"

if [ -z "$plan" ]; then
    echo "Nothing to restore (no matching controllers in $BACKUPS_FILE)." >&2
    exit 1
fi

echo "Restore plan ($(echo "$plan" | wc -l | tr -d ' ') controller(s), $JOBS in parallel):"
echo "$plan" | while IFS=$'\t' read -r controller pod archive fullname; do
    printf '  %-45s pod=%-50s archive=%s\n' "$fullname" "$pod" "$archive"
done

if [ "$DRY_RUN" = "true" ]; then
    echo "Dry run: nothing was restored."
    exit 0
fi

# --- Run restores in parallel ---
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.status

# Runs one restore; records the exit code in <log-dir>/<controller>.status.
run_one() {
    local controller pod archive fullname rc=0
    IFS=$'\t' read -r controller pod archive fullname <<< "$1"
    echo "[START] $fullname (log: $LOG_DIR/$controller.log)"
    ./restoreControllerfromS3.sh --pod "$pod" --archive "$archive" ${RESTORE_ARGS[@]+"${RESTORE_ARGS[@]}"} \
        > "$LOG_DIR/$controller.log" 2>&1 || rc=$?
    echo "$rc" > "$LOG_DIR/$controller.status"
    if [ "$rc" -eq 0 ]; then echo "[DONE]  $fullname"; else echo "[FAIL]  $fullname (exit $rc)"; fi
    return 0   # never abort the other restores
}
export -f run_one
export LOG_DIR
# Arrays cannot be exported to the xargs subshells, so pass the extra args as a quoted string.
# Keep it empty when there are no args: printf '%q ' with no arguments would emit an empty
# argument ('') that restoreControllerfromS3.sh rejects as "Unknown option".
RESTORE_ARGS_SERIALIZED=""
if [ ${#RESTORE_ARGS[@]} -gt 0 ]; then
    RESTORE_ARGS_SERIALIZED=$(printf '%q ' "${RESTORE_ARGS[@]}")
fi
export RESTORE_ARGS_SERIALIZED

# xargs -P is available on macOS and Linux (bash 3.2 has no 'wait -n').
echo "$plan" | tr '\n' '\0' | xargs -0 -P "$JOBS" -n 1 bash -c '
    eval "RESTORE_ARGS=($RESTORE_ARGS_SERIALIZED)"
    run_one "$1"
' _

# --- Summary ---
failed=0
echo
echo "Summary:"
while IFS=$'\t' read -r controller pod archive fullname; do
    rc=$(cat "$LOG_DIR/$controller.status" 2>/dev/null || echo "?")
    if [ "$rc" = "0" ]; then
        printf '  OK    %s\n' "$fullname"
    else
        printf '  FAIL  %s (exit %s, see %s/%s.log)\n' "$fullname" "$rc" "$LOG_DIR" "$controller"
        failed=$((failed + 1))
    fi
done <<< "$plan"

if [ "$failed" -gt 0 ]; then
    echo "$failed restore(s) failed. A failed controller's StatefulSet may still be scaled down." >&2
    exit 1
fi
echo "All restores completed successfully."
