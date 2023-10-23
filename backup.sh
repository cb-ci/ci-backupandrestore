#! /bin/bash

CI_POD=${1:-your_cjoc_or_CI_POD-0}
S3BUCKET=${2:-your_s3_bucket_name}
S3BUCKET_FOLDER="${3:-your_s3_bucket_folder}"
echo "create Archive for Controller: $CI_POD"
ARCHIVENAME=backup-$CI_POD-$(date +"%d-%m-%Y").tar.gz

kubectl exec -it $CI_POD -- bash -c "cd /var/jenkins_home &&  tar -cvzf   /tmp/$ARCHIVENAME ."
kubectl cp --retries 10  $CI_POD:/tmp/$ARCHIVENAME ./$ARCHIVENAME
du -m ./$ARCHIVENAME

#upload to gcp bucket
#gsutil cp $ARCHIVENAME gs://$GBUCKET/backups/$ARCHIVENAME

#Upload to s3
#aws s3 cp  ./$ARCHIVENAME s3://$S3BUCKET/controllers/$ARCHIVENAME
echo $ARCHIVENAME