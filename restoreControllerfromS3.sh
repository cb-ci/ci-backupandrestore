#! /bin/bash

# See https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/kubernetes

# This script restores a Jenkins home directory from a backup stored in an S3 bucket.
# It works by scaling down the controller/CJOC, creating a 'rescue pod' with the PVC mounted,
# clearing the PVC, downloading and extracting the backup, and then scaling the controller/CJOC back up.

# --- Script Configuration ---
# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Pipelines return the exit status of the last command to exit with a non-zero status.
set -eo pipefail -u
#set -x
source .env

# --- Logging ---
# Colors are only used when stdout is a terminal and NO_COLOR is not set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi
log_info()    { echo "${C_BLUE}[INFO]${C_RESET}    $*"; }
log_success() { echo "${C_GREEN}[SUCCESS]${C_RESET} $*"; }
log_warn()    { echo "${C_YELLOW}[WARN]${C_RESET}    $*" >&2; }
log_error()   { echo "${C_RED}[ERROR]${C_RESET}   $*" >&2; }

# Report the failing line if any command aborts the script (set -e).
trap 'log_error "Restore failed at line $LINENO (exit code $?). The StatefulSet may still be scaled down."' ERR

# --- Options ---
# --preserve-identity: keep identity/secret files of the target controller when clearing the PVC
# (secret.key, secrets/, license.xml, identity.key.enc, operations-center-*.xml, ...).
# Can also be set via PRESERVE_IDENTITY=true in .env; the flag takes precedence.
# --pod NAME / --archive FILE: override CI_POD / ARCHIVENAME from .env (used by restoreManyControllersFromS3.sh).
# --controller NAME: look the pod and the newest backup up in controllers-backups.json (created by
#   listControllersWithBackups.sh). NAME is the controller's fullName (e.g. 'tmp-folder-controllers/controllerinfolder'),
#   its Kubernetes name, or its short name if that is unique. --pod / --archive still take precedence.
# --backups-file FILE: JSON file for --controller (default: controllers-backups.json).
PRESERVE_IDENTITY="${PRESERVE_IDENTITY:-false}"
CONTROLLER=""
BACKUPS_FILE="controllers-backups.json"
OPT_POD=""
OPT_ARCHIVE=""
USAGE="Usage: $0 [--preserve-identity] [--controller NAME [--backups-file FILE]] [--pod CI_POD] [--archive ARCHIVENAME]"
while [ $# -gt 0 ]; do
    case "$1" in
        --preserve-identity) PRESERVE_IDENTITY=true ;;
        --pod|--archive|--controller|--backups-file)
            if [ $# -lt 2 ]; then
                log_error "Option $1 requires a value"
                echo "$USAGE" >&2
                exit 1
            fi
            case "$1" in
                --pod) OPT_POD="$2" ;;
                --archive) OPT_ARCHIVE="$2" ;;
                --controller) CONTROLLER="$2" ;;
                --backups-file) BACKUPS_FILE="$2" ;;
            esac
            shift
            ;;
        -h|--help)
            echo "$USAGE"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "$USAGE" >&2
            exit 1
            ;;
    esac
    shift
done

# --- Resolve --controller from controllers-backups.json ---
if [ -n "$CONTROLLER" ]; then
    if ! command -v jq &> /dev/null; then
        log_error "jq command not found, it is needed for --controller."
        exit 1
    fi
    if [ ! -f "$BACKUPS_FILE" ]; then
        log_error "$BACKUPS_FILE not found. Create it with ./listControllersWithBackups.sh"
        exit 1
    fi
    # Exact fullName / Kubernetes name wins; otherwise fall back to the short name.
    # Output per match (tab separated): fullName, podName, newest backup file (empty if none).
    matches=$(jq -r --arg n "$CONTROLLER" '
        .controllers as $c
        | ($c | map(select(.fullName == $n or .statefulSet == $n))) as $exact
        | (if ($exact | length) > 0 then $exact else ($c | map(select(.name == $n))) end)
        | .[] | [.fullName, .podName, ((.backups | max_by(.date) | .file) // "")] | @tsv' "$BACKUPS_FILE")
    if [ -z "$matches" ]; then
        log_error "Controller '$CONTROLLER' not found in $BACKUPS_FILE."
        exit 1
    fi
    if [ "$(echo "$matches" | wc -l | tr -d ' ')" -gt 1 ]; then
        log_error "Controller name '$CONTROLLER' is ambiguous, use the fullName. Candidates:"
        echo "$matches" | cut -f1 | sed 's/^/         /' >&2
        exit 1
    fi
    IFS=$'\t' read -r resolved_name resolved_pod resolved_archive <<< "$matches"
    CI_POD="$resolved_pod"
    ARCHIVENAME="$resolved_archive"
    log_info "Controller '$resolved_name' -> pod '$resolved_pod'"
fi
# Explicit --pod / --archive take precedence over .env and --controller.
if [ -n "$OPT_POD" ]; then CI_POD="$OPT_POD"; fi
if [ -n "$OPT_ARCHIVE" ]; then ARCHIVENAME="$OPT_ARCHIVE"; fi
if [ -n "$CONTROLLER" ] && [ -z "${ARCHIVENAME:-}" ]; then
    log_error "No backup is mapped to controller '$CONTROLLER' in $BACKUPS_FILE (see 'unmatchedBackups'). Use --archive to pick one."
    exit 1
fi

# --- Prerequisite Checks ---
# Check if kubectl is installed and available in the PATH.
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl command not found. Please install it and ensure it's in your PATH."
    exit 1
fi
log_success "kubectl found."

if [ "$PRESERVE_IDENTITY" = "true" ]; then
    log_info "Identity files of the target controller will be preserved."
else
    log_warn "All existing data in the PVC will be deleted (use --preserve-identity to keep identity/secret files)."
fi

# Preflight: make sure the archive is reachable BEFORE the controller is scaled down.
# The rescue-pod uses AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY[/AWS_SESSION_TOKEN] from .env, so the
# same credentials are checked here. Without them (e.g. pod identity) the local check is only advisory.
if command -v aws &> /dev/null; then
    log_info "Checking that s3://$S3BUCKET/$S3BUCKET_FOLDER/$ARCHIVENAME is accessible..."
    if preflight_err=$(aws s3api head-object --bucket "$S3BUCKET" --key "$S3BUCKET_FOLDER/$ARCHIVENAME" 2>&1 >/dev/null); then
        log_success "Archive found in S3."
    elif [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        log_error "Cannot access the archive in S3: $preflight_err"
        log_error "Nothing was changed. Check the credentials in .env (temporary 'ASIA...' keys need AWS_SESSION_TOKEN), IAM permissions (s3:GetObject, s3:ListBucket) and the archive name."
        exit 1
    else
        log_warn "Local S3 check failed (no AWS_ACCESS_KEY_ID set, assuming pod identity): $preflight_err"
    fi
else
    log_warn "aws CLI not found locally, skipping the S3 preflight check."
fi

# Automatically derive the StatefulSet name from the POD name (e.g., 'cjoc-0' -> 'cjoc').
CI_STATEFUL_SET="${CI_POD%-*}"
# Container and volume names must be DNS-1123 labels (no dots), unlike pod names.
# Controller names such as 'controller-upgradetest-1-2.568.3.37913' contain dots.
CI_RESOURCE_SUFFIX="${CI_STATEFUL_SET//./-}"

# --- Restoration Process ---
log_info "Restoring Jenkins home for StatefulSet: $CI_STATEFUL_SET from Pod: $CI_POD"

# Scale down the StatefulSet to 0 replicas to safely modify the PVC.
log_info "Scaling down StatefulSet '$CI_STATEFUL_SET' to 0 replicas..."
kubectl get pod
kubectl scale statefulset/"$CI_STATEFUL_SET" --replicas=0
log_success "StatefulSet '$CI_STATEFUL_SET' scaled down."

# Clean up any previously existing rescue-pod to ensure a clean start.
log_info "Deleting any existing rescue-pod..."
kubectl delete pod rescue-pod-$CI_STATEFUL_SET --ignore-not-found=true

# Create a new 'rescue-pod' to perform the restore operation.
log_info "Creating rescue-pod to mount the PVC and restore data..."
# The pod mounts the target PVC, and runs a container with AWS CLI to download and extract the backup.
# We use a custom docker image see dockerbuild.sh and Dockerfile
# AWS credentials are only passed to the pod when AWS_ACCESS_KEY_ID is set. Without it the pod
# relies on pod identity (e.g. IRSA / EKS Pod Identity). Temporary credentials (SSO / assumed role,
# keys starting with 'ASIA') also need a session token.
AWS_CREDS_ENV=""
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    AWS_CREDS_ENV="      - name: AWS_ACCESS_KEY_ID
        value: \"$AWS_ACCESS_KEY_ID\"
      - name: AWS_SECRET_ACCESS_KEY
        value: \"${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set together with AWS_ACCESS_KEY_ID}\""
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        AWS_CREDS_ENV="$AWS_CREDS_ENV
      - name: AWS_SESSION_TOKEN
        value: \"$AWS_SESSION_TOKEN\""
    fi
fi
cat <<EOF | kubectl apply -f -
kind: Pod
apiVersion: v1
metadata:
  name: rescue-pod-$CI_STATEFUL_SET
spec:
  # Run the restore exactly once. With the default 'Always' the container would be restarted
  # after it exits and re-run the (destructive) restore.
  restartPolicy: Never
  # The security context is set to match the user (1000) that Jenkins runs as, ensuring correct file permissions.
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  volumes:
    - name: rescue-storage-$CI_RESOURCE_SUFFIX
      # Mount the PVC associated with the Jenkins pod.
      persistentVolumeClaim:
        claimName: jenkins-home-$CI_POD
  containers:
    - name: rescue-pod-$CI_RESOURCE_SUFFIX
      image: caternberg/aws-cli:1.3 # A container image with AWS CLI tools. See Dockerfile
      env:
      # AWS credentials from .env (omitted when AWS_ACCESS_KEY_ID is unset, i.e. pod identity).
$AWS_CREDS_ENV
      - name: JENKINS_HOME
        value: "/tmp/jenkins-home/"
      resources:
        requests:
          ephemeral-storage: 4Gi
        limits:
          ephemeral-storage: 4Gi
      # The series of commands to execute inside the rescue pod.
      command: ["/bin/sh", "-c"]
      args:
       - |
         set -xe
         echo "Rescue pod started. Preparing to restore backup."

         # 1. Download the backup archive from S3 to a temporary directory.
         echo "Downloading $ARCHIVENAME from s3://$S3BUCKET/$S3BUCKET_FOLDER/..."
         aws s3 cp "s3://$S3BUCKET/$S3BUCKET_FOLDER/$ARCHIVENAME" "/tmp/$ARCHIVENAME"

         # 2. List the contents of /tmp to verify the download.
         echo "Download complete. Listing /tmp contents:"
         ls -ltr /tmp
         ls -ltr /tmp/jenkins-home/

         # 3. Clean all existing data from the mounted jenkins-home directory.
         echo "Cleaning existing data from /tmp/jenkins-home/..."
         # Delete all files and directories
         # find /tmp/jenkins-home/ -mindepth 1 -delete
         # Delete all files and directories, but keep certain files on the target controller
         # https://docs.cloudbees.com/docs/cloudbees-ci-kb/latest/operations-center/how-to-reconnect-a-client-controller-stuck-on-registration
         # The ! -path  filters might be adjusted depending on your restore usecase
         # Enabled with the --preserve-identity flag (or PRESERVE_IDENTITY=true in .env).
         if [ "$PRESERVE_IDENTITY" = "true" ]; then
           echo "Preserving controller identity files."
           find /tmp/jenkins-home/ -mindepth 1 \\
             ! -path "/tmp/jenkins-home/secret.key" \\
             ! -path "/tmp/jenkins-home/secrets" \\
             ! -path "/tmp/jenkins-home/secrets/*" \\
             ! -path "/tmp/jenkins-home/license.xml" \\
             ! -path "/tmp/jenkins-home/identity.key.enc" \\
             ! -path "/tmp/jenkins-home/operations-center-cloud.xml" \\
             ! -path "/tmp/jenkins-home/operations-center-client.xml" \\
             ! -path "/tmp/jenkins-home/com.cloudbees.opscenter.client.plugin.OperationsCenterRootAction.xml" \\
             -delete
         else
           find /tmp/jenkins-home/ -mindepth 1 -delete
         fi
         echo "/tmp/jenkins-home deleted. preserved files \n"
         ls -ltr /tmp/jenkins-home

         # 4. Extract the backup archive into the now-empty jenkins-home directory.
         echo "Extracting archive to /tmp/jenkins-home/..."
         tar -xvzf "/tmp/$ARCHIVENAME" -C /tmp/jenkins-home
         echo "Restore script finished inside pod."
      volumeMounts:
        # Mount the PVC into the container at '/tmp/jenkins-home'.
        - mountPath: "/tmp/jenkins-home"
          name: rescue-storage-$CI_RESOURCE_SUFFIX
EOF
log_success "rescue-pod created."

# Wait until the rescue-pod has left 'Pending' (Running, or already Succeeded/Failed if it was fast).
# 'condition=Ready' is not used: a pod that fails quickly never becomes Ready and the wait would time out.
log_info "Waiting for the rescue-pod to start..."
pod_phase() { kubectl get pod rescue-pod-$CI_STATEFUL_SET -o jsonpath='{.status.phase}'; }
for _ in $(seq 1 100); do
    phase=$(pod_phase)
    [ "$phase" != "Pending" ] && break
    sleep 3
done
if [ "$phase" = "Pending" ]; then
    log_error "rescue-pod is still Pending after 300s. Inspect it with: kubectl describe pod rescue-pod-$CI_STATEFUL_SET"
    exit 1
fi
log_success "rescue-pod started."

# Display the logs from the rescue-pod (follows until the container exits).
log_info "Displaying rescue-pod logs:"
kubectl logs -f rescue-pod-$CI_STATEFUL_SET || true

# 'kubectl logs' succeeds even if the restore failed, so check the pod's final phase.
for _ in $(seq 1 30); do
    phase=$(pod_phase)
    { [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; } && break
    sleep 2
done
if [ "$phase" != "Succeeded" ]; then
    log_error "Restore failed inside the rescue-pod (phase: $phase). The PVC may be partially restored."
    log_error "StatefulSet '$CI_STATEFUL_SET' was NOT scaled back up and rescue-pod-$CI_STATEFUL_SET was kept for inspection."
    log_error "When done: kubectl delete pod rescue-pod-$CI_STATEFUL_SET && kubectl scale statefulset/$CI_STATEFUL_SET --replicas=1"
    exit 1
fi
log_success "Restore inside the rescue-pod succeeded."

# Delete the rescue-pod as it is no longer needed.
log_info "Deleting the rescue-pod..."
kubectl delete pod rescue-pod-$CI_STATEFUL_SET
log_success "rescue-pod deleted."

# Scale the StatefulSet back up to 1 replica to bring the Jenkins instance online.
log_info "Scaling up StatefulSet '$CI_STATEFUL_SET' to 1 replica..."
kubectl scale statefulset/"$CI_STATEFUL_SET" --replicas=1
log_success "StatefulSet '$CI_STATEFUL_SET' scaled up."

log_success "Restore process completed."
