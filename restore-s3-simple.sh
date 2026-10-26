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
PRESERVE_IDENTITY="${PRESERVE_IDENTITY:-false}"
for arg in "$@"; do
    case "$arg" in
        --preserve-identity) PRESERVE_IDENTITY=true ;;
        -h|--help)
            echo "Usage: $0 [--preserve-identity]"
            exit 0
            ;;
        *)
            log_error "Unknown option: $arg"
            echo "Usage: $0 [--preserve-identity]" >&2
            exit 1
            ;;
    esac
done

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

# Automatically derive the StatefulSet name from the POD name (e.g., 'cjoc-0' -> 'cjoc').
CI_STATEFUL_SET="${CI_POD%-*}"

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
cat <<EOF | kubectl apply -f -
kind: Pod
apiVersion: v1
metadata:
  name: rescue-pod-$CI_STATEFUL_SET
spec:
  # The security context is set to match the user (1000) that Jenkins runs as, ensuring correct file permissions.
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  volumes:
    - name: rescue-storage-$CI_STATEFUL_SET
      # Mount the PVC associated with the Jenkins pod.
      persistentVolumeClaim:
        claimName: jenkins-home-$CI_POD
  containers:
    - name: rescue-pod-$CI_STATEFUL_SET
      image: caternberg/aws-cli:1.3 # A container image with AWS CLI tools. See Dockerfile
      env:
      # Optional: Pass AWS credentials to the pod securely from environment variables.
      # You can remove these AWS_ACCESS* lines if you are using pod identity
      - name: AWS_ACCESS_KEY_ID
        value: "$AWS_ACCESS_KEY_ID"
      - name: AWS_SECRET_ACCESS_KEY
        value: "$AWS_SECRET_ACCESS_KEY"
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
          name: rescue-storage-$CI_STATEFUL_SET
EOF
log_success "rescue-pod created."

# Wait for the rescue-pod to enter the 'Ready' state.
log_info "Waiting for the rescue-pod to complete the restore operation..."
if ! kubectl wait --for=condition=Ready pod/rescue-pod-$CI_STATEFUL_SET --timeout=300s; then
    log_error "rescue-pod did not become Ready within 300s. Inspect it with: kubectl describe pod rescue-pod-$CI_STATEFUL_SET"
    exit 1
fi
log_success "rescue-pod is running."

# Display the logs from the rescue-pod to verify the outcome.
log_info "Displaying rescue-pod logs:"
kubectl logs -f rescue-pod-$CI_STATEFUL_SET

# Delete the rescue-pod as it is no longer needed.
log_info "Deleting the rescue-pod..."
kubectl delete pod rescue-pod-$CI_STATEFUL_SET
log_success "rescue-pod deleted."

# Scale the StatefulSet back up to 1 replica to bring the Jenkins instance online.
log_info "Scaling up StatefulSet '$CI_STATEFUL_SET' to 1 replica..."
kubectl scale statefulset/"$CI_STATEFUL_SET" --replicas=1
log_success "StatefulSet '$CI_STATEFUL_SET' scaled up."

log_success "Restore process completed."
