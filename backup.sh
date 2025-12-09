#! /bin/bash
set -euo pipefail

# This script backups a CloudBees CI controller's jenkins_home directory.
# It creates a tarball of the jenkins_home, excluding certain files and directories,
# and then uploads the tarball to an S3 bucket.

source ./set-env.sh

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