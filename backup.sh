#! /bin/bash
set -euo pipefail

# This script backups a CloudBees CI controller's jenkins_home directory.
# It creates a tarball of the jenkins_home, excluding certain files and directories,
# and then uploads the tarball to an S3 bucket.

# Usage: ./backup.sh <CI_POD> [S3BUCKET] [S3BUCKET_FOLDER]
#
# Arguments:
#   CI_POD: The name of the CloudBees CI controller pod.
#   S3BUCKET: The name of the S3 bucket to upload the backup to. Defaults to "YOUR_S3_BUCKET".
#   S3BUCKET_FOLDER: The folder in the S3 bucket to upload the backup to. Defaults to "YOUR_S3_BACKUP_FOLDER".
#
# Required environment variables:
#   AWS_ACCESS_KEY_ID: Your AWS access key ID.
#   AWS_SECRET_ACCESS_KEY: Your AWS secret access key.

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is not set. Please set it to your AWS access key ID.}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is not set. Please set it to your AWS secret access key.}"


# The name of the CloudBees CI pod (e.g., cjoc-0 or my-controller-0). Defaults to "POD_NAME" if not provided as the first argument.
CI_POD=${1:-"POD_NAME"}
# The name of the S3 bucket where the backup is stored. Defaults to "YOUR_S3_BUCKET" if not provided as the second argument.
S3BUCKET=${2:-"YOUR_S3_BUCKET"}
# The folder path within the S3 bucket. Defaults to "YOUR_S3_BACKUP_FOLDER" if not provided as the third argument.
S3BUCKET_FOLDER=${3:-"YOUR_S3_BACKUP_FOLDER"}
ARCHIVENAME="backup-$CI_POD-$(date +"%d-%m-%Y").tar.gz"




echo "Creating archive for Controller: $CI_POD"

# Exclude patterns for the tar command
# These filter might be adjusted
EXCLUDE_PATTERNS=(
    --exclude='messaging.*'
    --exclude='.com.cloudbees.ci.license.tracker.consolidation.*'
    --exclude='.java'
    --exclude='tmp'
    --exclude='.cache'
    --exclude='workspace'
    --exclude='logs'
    --exclude='secrets/master.key'
    --exclude='secret.key'
    --exclude='license.xml'
    --exclude='identity.key.enc'
    --exclude='jgroups/'
    --exclude='operations-center-cloud*'
    --exclude='operations-center-client*'
    --exclude='com.cloudbees.opscenter.client.plugin.OperationsCenterRootAction.xml'
    --exclude='nodes/'
)

# Create a tarball of the jenkins_home directory, excluding specified files and directories.
# The --ignore-failed-read option is used to prevent tar from exiting with an error if it encounters a file that cannot be read.
kubectl exec -it "$CI_POD" -- bash -c "cd /var/jenkins_home && tar -cvz --ignore-failed-read ${EXCLUDE_PATTERNS[*]} -f /tmp/$ARCHIVENAME ."

# Copy the tarball from the pod to the local filesystem.
# The --retries option is used to retry the copy operation if it fails.
kubectl cp --retries 10 "$CI_POD:/tmp/$ARCHIVENAME" "./$ARCHIVENAME"

# Print the size of the tarball in megabytes.
du -m "./$ARCHIVENAME"

# Upload the tarball to S3.
aws s3 cp "./$ARCHIVENAME" "s3://$S3BUCKET/$S3BUCKET_FOLDER/$ARCHIVENAME"

echo "Backup complete: $ARCHIVENAME"