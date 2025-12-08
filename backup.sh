#! /bin/bash

export AWS_ACCESS_KEY_ID="YOUR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="YOUR_SECRET_ACCESS_KEY"

CI_POD=${1:-"POD_NAME"} # CJOC or Controller POD name
S3BUCKET=${2:-"YOUR_S3_BUCKET"}
S3BUCKET_FOLDER="${3:-"YOUR_S3_BACKUP_FOLDER"}"
echo "create Archive for Controller: $CI_POD"
ARCHIVENAME=backup-$CI_POD-$(date +"%d-%m-%Y").tar.gz

# Example for entire jenkins_home backup
#kubectl exec -it $CI_POD -- bash -c "cd /var/jenkins_home &&  tar -cvzf   /tmp/$ARCHIVENAME ."

# Example for jenkins_home backup, excluding unwanted files or folders
#kubectl exec -it $CI_POD -- bash -c "cd /var/jenkins_home &&  tar -cvzf  --exclude='logs' --exclude='jobs'   /tmp/$ARCHIVENAME ."

# Useful tar command to be used when restoring on a new controller. We want to preserve some file on the target controller, so we exclude them
kubectl exec -it $CI_POD -- bash -c "cd /var/jenkins_home &&  tar -cvz --ignore-failed-read  --exclude='messaging.*' --exclude='.com.cloudbees.ci.license.tracker.consolidation.*' --exclude='.java' --exclude='tmp' --exclude='.cache' --exclude='workspace'  --exclude='logs' --exclude='secrets/master.key' --exclude='secret.key' --exclude='license.xml' --exclude= 'identity.key.enc' --exclude= 'jgroups/' --exclude='operations-center-cloud*' --exclude= 'operations-center-client*' --exclude='com.cloudbees.opscenter.client.plugin.OperationsCenterRootAction.xml' --exclude='nodes/' -f  /tmp/$ARCHIVENAME ."

kubectl cp --retries 10  $CI_POD:/tmp/$ARCHIVENAME ./$ARCHIVENAME
du -m ./$ARCHIVENAME

#Upload to s3
aws s3 cp  ./$ARCHIVENAME s3://$S3BUCKET/$S3BUCKET_FOLDER/$ARCHIVENAME
echo $ARCHIVENAME