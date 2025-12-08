#! /bin/bash

export AWS_ACCESS_KEY_ID="YOUR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="YOUR_SECRET_ACCESS_KEY"

CI_POD=${1:-"POD_NAME"} # CJOC or Controller POD name you want to restore to
CI_STATEFUL_SET="${CI_POD%-*}"
S3BUCKET=${2:-"YOUR_S3_BUCKET"}
S3BUCKET_FOLDER="${3:-"YOUR_S3_BACKUP_FOLDER"}"
ARCHIVENAME="YOUR_BACKUP_ARCHIVE_NAME" # for example backup-mypod-12-03-2025.tar.gz

echo "Restoring Controller: $CI_POD"

kubectl  get pods $CI_POD -o jsonpath='{.spec.securityContext}'
kubectl  scale statefulset/$CI_STATEFUL_SET --replicas=0
kubectl get pvc
kubectl delete pod rescue-pod
#then replace all data  with the backup in $JENKINS_HOME on the storage
cat <<EOF | kubectl create -f -
kind: Pod
apiVersion: v1
metadata:
  name: rescue-pod
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  volumes:
    - name: rescue-storage
      persistentVolumeClaim:
        claimName: jenkins-home-$CI_POD
  containers:
    - name: rescue-pod
      image: caternberg/aws-cli:1.3
      env:
      - name: AWS_ACCESS_KEY_ID
        value: $AWS_ACCESS_KEY_ID
      - name: AWS_SECRET_ACCESS_KEY
        value: $AWS_SECRET_ACCESS_KEY
      resources:
        requests:
          ephemeral-storage: 4Gi
        limits:
          ephemeral-storage: 4Gi
      command: ["/bin/sh"]
      args:
       - "-c"
       - |
         # Use a semicolon (;) or '&&' to separate commands
         echo "Starting script...";
         aws s3 cp s3://$S3BUCKET/$S3BUCKET_FOLDER/$ARCHIVENAME  /tmp/$ARCHIVENAME;
         ls -ltr /tmp;
         find /tmp/jenkins-home -type f -name '*.*' -delete;
         find /tmp/jenkins-home/ -mindepth 1 -type d -name '*' -exec rm -rf {} \;;
         tar -xvzf /tmp/$ARCHIVENAME -C /tmp/jenkins-home
         sleep 5;
         echo "Script finished."
      volumeMounts:
        - mountPath: "/tmp/jenkins-home"
          name: rescue-storage
EOF


#wait until the rescue pod is ready to serve
kubectl wait --for=condition=Ready pod/rescue-pod
kubectl logs rescue-pod

#delete the rescue-pod
kubectl delete pod rescue-pod
# scale up
kubectl scale statefulset/$CI_STATEFUL_SET --replicas=1
