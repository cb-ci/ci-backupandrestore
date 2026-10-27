#! /bin/bash

# Lists the top-level controllers (managed masters) from CJOC, lists all *.tar.gz backups in
# s3://$S3BUCKET/$S3BUCKET_FOLDER/ and maps the backups to the controllers.
# Controllers below a folder or subfolder (fullName contains a "/") are NOT included.
# Controllers are read via the CJOC REST API, backups via "aws s3 ls".
#
# Usage: ./listControllersWithBackups.sh [output-file]   (default: controllers-backups.json)
#
# Env (.env): CJOC_TOKEN=<user>:<api-token>, CBCI_URL=https://<host>, S3BUCKET, S3BUCKET_FOLDER, AWS_*
#
# Mapping: the Kubernetes name of a controller is the last path segment of its `endpoint`
# (e.g. https://host/controller1/ -> controller1). A backup belongs to a controller if the name in its
# file name (backup-<name>-cluster-op-backup-controllers-<n>.<hash>.tar.gz), made Kubernetes-safe
# (lowercase, every character outside a-z0-9- becomes "-"), equals that Kubernetes name.
# Backups of controllers that are not listed (e.g. controllers in folders) end up in "unmatchedBackups".
#
# Output:
#   {
#     "controllers": [ { name, fullName, statefulSet, podName, endpoint, state, online, version,
#                        backups: [ {file, date} ... newest first ] } ... ],
#     "unmatchedBackups": [ { file, date, controllerOriginal, possibleControllers: [fullName ...] } ... ]
#   }
# `possibleControllers` only lists controllers with the same short name; it is a hint, not a mapping.

set -euo pipefail

cd "$(dirname "$0")"
source .env

: "${CJOC_TOKEN:?Set CJOC_TOKEN to <user>:<api-token>}"
: "${CBCI_URL:?Set CBCI_URL to the base URL, e.g. https://ci.example.com}"

OUTPUT_FILE="${1:-controllers-backups.json}"
MASTER_CLASS="com.cloudbees.opscenter.server.model.ManagedMaster"

for tool in aws jq curl; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool command not found. Please install it and ensure it's in your PATH." >&2
        exit 1
    fi
done

# --- 1. Controllers from CJOC ---
# Only the top level of CJOC is queried, so controllers inside folders are never returned.
# Fields that a given item type does not have (e.g. "endpoint" on a folder) are ignored.
FIELDS="_class,name,fullName,displayName,description,url,endpoint,approved,online,state,lastKnownVersion,validActions"
TREE="jobs[${FIELDS}]"

echo "Reading controllers from ${CBCI_URL}/cjoc ..." >&2
RESPONSE=$(curl -gsS --fail-with-body -u "${CJOC_TOKEN}" \
    -w '\nHTTP %{http_code}' \
    "${CBCI_URL}/cjoc/api/json?tree=${TREE}") || {
    echo "Request failed:" >&2
    echo "${RESPONSE}" | head -n 20 >&2
    exit 1
}

# Strip the trailing "HTTP <code>" line added by -w and keep only managed masters. Folders are skipped;
# the extra fullName check makes sure nothing below a folder (fullName with a "/") is ever included.
CONTROLLERS=$(echo "${RESPONSE}" | sed '$d' \
    | jq --arg cls "${MASTER_CLASS}" \
        '[.jobs[]? | select(._class == $cls and ((.fullName // "") | contains("/") | not)) | del(.jobs)]')

# --- 2. Backups from S3 ---
# 'aws s3 ls' prints: <date> <time> <size> <key>. Keep only *.tar.gz entries.
# grep exits 1 when nothing matches, so tolerate that.
echo "Reading backups from s3://$S3BUCKET/$S3BUCKET_FOLDER/ ..." >&2
listing=$(aws s3 ls "s3://$S3BUCKET/$S3BUCKET_FOLDER/" | grep -E '\.tar\.gz$' || true)

# The date is the object's last-modified time as reported by S3.
BACKUPS=$(echo "$listing" | jq -R -s '
    split("\n")
    | map(select(length > 0) | split(" ") | map(select(length > 0)))
    | map({
        file: .[3],
        date: (.[0] + " " + .[1]),
        controllerOriginal: (.[3] | capture("^backup-(?<c>.+)-cluster-op-backup-controllers-").c? // null)
      })')

# --- 3. Map backups to controllers ---
jq -n --argjson controllers "$CONTROLLERS" --argjson backups "$BACKUPS" '
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
    | ($cs | map(.statefulSet)) as $known
    | {
        controllers: ($cs | map(
            . as $c
            | . + {backups: ($bk | map(select(.key == $c.statefulSet) | {file, date}) | sort_by(.date) | reverse)}
        )),
        unmatchedBackups: ($bk | map(
            . as $b
            | select(.key == null or (any($known[]; . == $b.key) | not))
            | {
                file, date, controllerOriginal,
                possibleControllers: ($cs | map(select(.name | safe == $b.key) | .fullName))
              }
        ))
      }
' > "$OUTPUT_FILE"

echo "Wrote $OUTPUT_FILE: $(jq '.controllers | length' "$OUTPUT_FILE") controller(s), $(jq '[.controllers[] | select(.backups | length > 0)] | length' "$OUTPUT_FILE") with backups, $(jq '.unmatchedBackups | length' "$OUTPUT_FILE") unmatched backup(s)"
