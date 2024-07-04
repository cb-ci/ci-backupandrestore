#!/bin/bash
set -e
#See https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/kubernetes

namespace="cloudbees-core" #Kubernetes namespace where CB CI is deployed.
instanceStatefulsetName="mycontroller" #The statefulset name of the OC or master you want to restore.
restoreFile="backup-backup-1.tar.gz" #Path to the tar.gz backup file on the backup volume directory
rescueContainerImage="governmentpaas/awscli" #Container with version if required, to use for the rescue pod.


echo "Scale down stateful set pods to 0 replicas"
kubectl --namespace=$namespace scale statefulset/$instanceStatefulsetName --replicas=0

#Launch rescue pod attaching the pvc
persistentVolumeClaim=$(kubectl -n $namespace get statefulset $instanceStatefulsetName -o jsonpath="{.spec.volumeClaimTemplates[0].metadata.name}")-${instanceStatefulsetName}-0
rescueStorageMountPath="/tmp/jenkins-home"
rescuePodName=rescue-pod-$instanceStatefulsetName
echo "Launching $rescuePodName with pvc $persistentVolumeClaim attached"

cat <<EOF | kubectl --namespace=$namespace create -f -

kind: Pod
apiVersion: v1
metadata:
  name: $rescuePodName
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  volumes:
    - name: rescue-storage
      persistentVolumeClaim:
        claimName: $persistentVolumeClaim
    - name: backup-pvc
      persistentVolumeClaim:
        claimName: backup-pvc
  containers:
    - name: rescue-container
      image: $rescueContainerImage
      resources:
        requests:
          ephemeral-storage: 4Gi
          cpu: 2000m
          memory: 2Gi
        limits:
          ephemeral-storage: 4Gi
          cpu: 2000m
          memory: 2Gi
      command: ['sh', '-c', 'echo The app is running! && sleep 100000' ]
      volumeMounts:
        - mountPath: $rescueStorageMountPath
          name: rescue-storage
        - mountPath: /restorefrombackup
          name: backup-pvc
EOF



echo "Waiting for the $rescuePodName to enter Ready state"
kubectl wait --namespace=$namespace --for=condition=Ready --timeout=600s pod/$rescuePodName

echo "Moving the backup file into the $rescuePodName"

kubectl exec --namespace=$namespace $rescuePodName   -- /bin/sh -c "cp  /restorefrombackup/$restoreFile  /tmp/backup.tar.gz"
# OPTIONAL - you can empty the directories, however the uncompress will overwrite any existing files
#echo "Empty $rescueStorageMountPath of all files and folders on pvc $persistentVolumeClaim"
#kubectl exec --namespace=$namespace $rescuePodName -- find $rescueStorageMountPath -type f -name "*.*" -delete || echo "Files deleted in jenkins-home"
#kubectl exec --namespace=$namespace $rescuePodName -- find $rescueStorageMountPath -type f -name "*" -delete || echo "Files deleted in jenkins-home"
#kubectl exec --namespace=$namespace $rescuePodName -- find $rescueStorageMountPath -mindepth 1 -type d -name "*" -exec rm -rf {} \; || echo "Folders deleted in jenkins-home"

echo "Uncompress the backup file into $rescueStorageMountPath"
kubectl exec --namespace=$namespace $rescuePodName -- tar -xvzf /tmp/backup.tar.gz --directory $rescueStorageMountPath

# OPTIONAL - enable if permissions are not set correctly, securityContext in the rescuepod should set permissions appropriately
#echo "Update ownership permissions recursively"
#kubectl exec --namespace=$namespace $rescuePodName -- chown -R 1000:1000 $rescueStorageMountPath

echo "Deleting the $rescuePodName"
kubectl --namespace=$namespace delete pod $rescuePodName

echo "Scale up $instanceStatefulsetName pods to 1 replica"
kubectl --namespace=$namespace scale statefulset/$instanceStatefulsetName --replicas=1
