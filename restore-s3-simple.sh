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

source ./set-env.sh

# --- Prerequisite Checks ---
# Check if kubectl is installed and available in the PATH.
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl command not found. Please install it and ensure it's in your PATH."
    exit 1
fi

# --- Variable Definitions ---
# AWS credentials should be set as environment variables, not hardcoded in the script.
# For example:
# export AWS_ACCESS_KEY_ID="YOUR_ACCESS_KEY"
# export AWS_SECRET_ACCESS_KEY="YOUR_SECRET_ACCESS_KEY"
if [[ -z "${AWS_ACCESS_KEY_ID}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
    echo "Error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables must be set."
    exit 1
fi

# Automatically derive the StatefulSet name from the POD name (e.g., 'cjoc-0' -> 'cjoc').
CI_STATEFUL_SET="${CI_POD%-*}"

# --- Restoration Process ---
echo "Restoring Jenkins home for StatefulSet: $CI_STATEFUL_SET from Pod: $CI_POD"

# Scale down the StatefulSet to 0 replicas to safely modify the PVC.
echo "Scaling down StatefulSet '$CI_STATEFUL_SET' to 0 replicas..."
kubectl scale statefulset/"$CI_STATEFUL_SET" --replicas=0

# Clean up any previously existing rescue-pod to ensure a clean start.
echo "Deleting any existing rescue-pod..."
kubectl delete pod rescue-pod --ignore-not-found=true

# Create a new 'rescue-pod' to perform the restore operation.
echo "Creating rescue-pod to mount the PVC and restore data..."
# The pod mounts the target PVC, and runs a container with AWS CLI to download and extract the backup.
# We use a custom docker image see dockerbuild.sh and Dockerfile
cat <<EOF | kubectl create -f -
kind: Pod
apiVersion: v1
metadata:
  name: rescue-pod
spec:
  # The security context is set to match the user (1000) that Jenkins runs as, ensuring correct file permissions.
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  volumes:
    - name: rescue-storage
      # Mount the PVC associated with the Jenkins pod.
      persistentVolumeClaim:
        claimName: jenkins-home-$CI_POD
  containers:
    - name: rescue-pod
      image: caternberg/aws-cli:1.3 # A container image with AWS CLI tools. See Dockerfile
      env:
      # Pass AWS credentials to the pod securely from environment variables.
      - name: AWS_ACCESS_KEY_ID
        value: "$AWS_ACCESS_KEY_ID"
      - name: AWS_SECRET_ACCESS_KEY
        value: "$AWS_SECRET_ACCESS_KEY"
      resources:
        requests:
          ephemeral-storage: 4Gi
        limits:
          ephemeral-storage: 4Gi
      # The series of commands to execute inside the rescue pod.
      command: ["/bin/sh", "-c"]
      args:
       - |
         set -ex
         echo "Rescue pod started. Preparing to restore backup."
         
         # 1. Download the backup archive from S3 to a temporary directory.
         echo "Downloading $ARCHIVENAME from s3://$S3BUCKET/$S3BUCKET_FOLDER/..."
         aws s3 cp "s3://$S3BUCKET/$S3BUCKET_FOLDER/$ARCHIVENAME" "/tmp/$ARCHIVENAME"
         
         # 2. List the contents of /tmp to verify the download.
         echo "Download complete. Listing /tmp contents:"
         ls -ltr /tmp
         
         # 3. Clean all existing data from the mounted jenkins-home directory.
         echo "Cleaning existing data from /tmp/jenkins-home/..."
         find /tmp/jenkins-home/ -mindepth 1 -delete
         
         # 4. Extract the backup archive into the now-empty jenkins-home directory.
         echo "Extracting archive to /tmp/jenkins-home/..."
         tar -xvzf "/tmp/$ARCHIVENAME" -C /tmp/jenkins-home
         
         echo "Restore script finished inside pod."
      volumeMounts:
        # Mount the PVC into the container at '/tmp/jenkins-home'.
        - mountPath: "/tmp/jenkins-home"
          name: rescue-storage
EOF

# Wait for the rescue-pod to enter the 'Completed' state.
echo "Waiting for the rescue-pod to complete the restore operation..."
kubectl wait --for=condition=Ready pod/rescue-pod --timeout=300s

# Display the logs from the rescue-pod to verify the outcome.
echo "Rescue pod finished. Displaying logs:"
kubectl logs rescue-pod

# Delete the rescue-pod as it is no longer needed.
echo "Deleting the rescue-pod..."
kubectl delete pod rescue-pod

# Scale the StatefulSet back up to 1 replica to bring the Jenkins instance online.
echo "Scaling up StatefulSet '$CI_STATEFUL_SET' to 1 replica..."
kubectl scale statefulset/"$CI_STATEFUL_SET" --replicas=1

echo "Restore process completed successfully."
