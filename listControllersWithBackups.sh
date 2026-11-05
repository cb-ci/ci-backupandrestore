#! /bin/bash

# Lists the top-level controllers (managed masters) from CJOC, lists all *.tar.gz backups in
# s3://$S3BUCKET/$S3BUCKET_FOLDER/ and maps the backups to the controllers.
# Only the level given by CJOC_API_PATH (default: CJOC root) is listed; controllers in folders below it are NOT included.
# Controllers are read via the CJOC REST API, backups via "aws s3 ls".
#
# Usage: ./listControllersWithBackups.sh [output-file]   (default: controllers-backups.json)
#
# Env (.env): CJOC_TOKEN=<user>:<api-token>, CBCI_URL=https://<host>, S3BUCKET, S3BUCKET_FOLDER, AWS_*,
#             BACKUP_JOB_NAME (optional, default cluster-op-backup-controllers),
#             CJOC_API_PATH (optional, default /cjoc; e.g. /cjoc/view/all/job/folder-dev1-controllers)
#
# Mapping: the Kubernetes name of a controller is the last path segment of its `endpoint`
# (e.g. https://host/controller1/ -> controller1). A backup belongs to a controller if the name in its
# file name (backup-<name>-<BACKUP_JOB_NAME>-<n>.<hash>.tar.gz), made Kubernetes-safe
# (lowercase, every character outside a-z0-9- becomes "-"), equals that Kubernetes name.
# In folder mode (CJOC_API_PATH below /cjoc) the file name only has the short controller name, so a backup also
# matches on the controller's short name (its Kubernetes name is prefixed with the folder path).
# Backups of controllers that are not listed (e.g. controllers in folders) end up in "unmatchedBackups".
#
# Output:
#   {
#     "controllers": [ { name, fullName, statefulSet, podName, endpoint, state, online, version,
#                        backups: [ {file, date, increment} ... latest first ] } ... ],
#     "unmatchedBackups": [ { file, date, increment, controllerOriginal, possibleControllers: [fullName ...] } ... ]
#   }
# "Latest" = highest increment number <n> from the file name (backup-<name>-<job>-<n>.<hash>.tar.gz). Archives
# without a parsable <n> (increment: null) rank after all numbered ones and are ordered by date among themselves.
# The restore scripts use the same ranking (increment, then date) to pick the backup.
# `possibleControllers` only lists controllers with the same short name; it is a hint, not a mapping.

set -euo pipefail

cd "$(dirname "$0")"
source .env

: "${CJOC_TOKEN:?Set CJOC_TOKEN to <user>:<api-token>}"
: "${CBCI_URL:?Set CBCI_URL to the base URL, e.g. https://ci.example.com}"

# Name of the CJOC cluster backup job; it is part of every archive file name. Default = job of the example CasC.
BACKUP_JOB_NAME="${BACKUP_JOB_NAME:-cluster-op-backup-controllers}"

# Path (below CBCI_URL) of the Operations Center item whose controllers are listed. Default = CJOC root.
# For a folder: /cjoc/view/all/job/<folder>, for a subfolder: /cjoc/view/all/job/<folder>/job/<subfolder>
CJOC_API_PATH="${CJOC_API_PATH:-/cjoc}"
CJOC_API_PATH="/${CJOC_API_PATH#/}"; CJOC_API_PATH="${CJOC_API_PATH%/}"

# fullName prefix of that item ("" for the root, "folder/" or "folder/sub/" for folders), taken from the "job/<name>" segments.
FOLDER_PREFIX=$(echo "${CJOC_API_PATH}" | grep -o '/job/[^/]*' | sed 's#^/job/##' | paste -sd/ - || true)
[ -n "${FOLDER_PREFIX}" ] && FOLDER_PREFIX="${FOLDER_PREFIX}/"

OUTPUT_FILE="${1:-controllers-backups.json}"
MASTER_CLASS="com.cloudbees.opscenter.server.model.ManagedMaster"

for tool in aws jq curl; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool command not found. Please install it and ensure it's in your PATH." >&2
        exit 1
    fi
done

# --- 1. Controllers from CJOC ---
# Only the level given by CJOC_API_PATH is queried (default: the CJOC root), so controllers in
# sub-folders of that level are never returned.
# Fields that a given item type does not have (e.g. "endpoint" on a folder) are ignored.
FIELDS="_class,name,fullName,displayName,description,url,endpoint,approved,online,state,lastKnownVersion,validActions"
TREE="jobs[${FIELDS}]"

echo "Reading controllers from ${CBCI_URL}${CJOC_API_PATH} ..." >&2
RESPONSE=$(curl -gsS --fail-with-body -u "${CJOC_TOKEN}" \
    -w '\nHTTP %{http_code}' \
    "${CBCI_URL}${CJOC_API_PATH}/api/json?tree=${TREE}") || {
    echo "Request failed:" >&2
    echo "${RESPONSE}" | head -n 20 >&2
    exit 1
}

# Strip the trailing "HTTP <code>" line added by -w and keep only managed masters. Folders are skipped;
# the extra fullName check makes sure nothing below the queried level (a "/" after the folder prefix) is included.
CONTROLLERS=$(echo "${RESPONSE}" | sed '$d' \
    | jq --arg cls "${MASTER_CLASS}" --arg prefix "${FOLDER_PREFIX}" \
        '[.jobs[]? | select(._class == $cls and ((.fullName // "") | startswith($prefix) and (ltrimstr($prefix) | contains("/") | not))) | del(.jobs)]')

# --- 2. Backups from S3 ---
# 'aws s3 ls' prints: <date> <time> <size> <key>. Keep only *.tar.gz entries.
# grep exits 1 when nothing matches, so tolerate that.
echo "Reading backups from s3://$S3BUCKET/$S3BUCKET_FOLDER/ ..." >&2
listing=$(aws s3 ls "s3://$S3BUCKET/$S3BUCKET_FOLDER/" | grep -E '\.tar\.gz$' || true)

# The date is the object's last-modified time as reported by S3.
BACKUPS=$(echo "$listing" | jq -R -s --arg job "${BACKUP_JOB_NAME}" '
    # Job name is used literally in the regex: escape regex metacharacters.
    ($job | gsub("(?<x>[.^$*+?()\\[\\]{}|\\\\])"; "\\\(.x)")) as $job
    | split("\n")
    | map(select(length > 0) | split(" ") | map(select(length > 0)))
    | map({
        file: .[3],
        date: (.[0] + " " + .[1]),
        controllerOriginal: (.[3] | capture("^backup-(?<c>.+)-" + $job + "-").c? // null),
        increment: ((.[3] | capture("-" + $job + "-(?<n>[0-9]+)[.]").n? // null) | if . == null then null else tonumber end)
      })')

# --- 3. Map backups to controllers ---
# In folder mode (CJOC_API_PATH below the root) the cluster backup archives carry only the short controller name,
# while the Kubernetes name also contains the folder path (folder-<name>). So a backup also matches on the short
# name there; it is unique within the one level that is listed.
jq -n --argjson controllers "$CONTROLLERS" --argjson backups "$BACKUPS" --arg folder "${FOLDER_PREFIX}" '
    # Kubernetes-safe name: lowercase, every char outside a-z0-9- (e.g. ".") becomes "-".
    def safe: ascii_downcase | gsub("[^a-z0-9-]"; "-") | gsub("^-+|-+$"; "");

    ($controllers | map(
        ((.endpoint // "") | sub("/+$"; "") | split("/") | last // "") as $seg
        | (if $seg != "" then $seg else (.fullName | gsub("/"; "-")) end | safe) as $k8s
        | {
            name: .name,
            fullName: .fullName,
            statefulSet: $k8s,
            podName: ($k8s + "-0"),
            endpoint: .endpoint,
            state: .state,
            online: .online,
            version: .lastKnownVersion
          }
    )) as $cs
    | ($backups | map(. + {key: (if .controllerOriginal == null then null else (.controllerOriginal | safe) end)})) as $bk
    | ($cs | map(.statefulSet, (if $folder != "" then (.name | safe) else empty end))) as $known
    | {
        controllers: ($cs | map(
            . as $c
            | . + {backups: ($bk | map(select(.key == $c.statefulSet or ($folder != "" and .key == ($c.name | safe))) | {file, date, increment}) | sort_by([(.increment != null), (.increment // 0), .date]) | reverse)}
        )),
        unmatchedBackups: ($bk | map(
            . as $b
            | select(.key == null or (any($known[]; . == $b.key) | not))
            | {
                file, date, increment, controllerOriginal,
                possibleControllers: ($cs | map(select(.name | safe == $b.key) | .fullName))
              }
        ))
      }
' > "$OUTPUT_FILE"

echo "Wrote $OUTPUT_FILE: $(jq '.controllers | length' "$OUTPUT_FILE") controller(s), $(jq '[.controllers[] | select(.backups | length > 0)] | length' "$OUTPUT_FILE") with backups, $(jq '.unmatchedBackups | length' "$OUTPUT_FILE") unmatched backup(s)"
