#! /bin/bash
for CONTROLLER_POD in $(kubectl get pod -l com.cloudbees.cje.type -o jsonpath="{.items[*].metadata.name}")
do
    echo $CONTROLLER_POD
    ARCHIVENAME=backup-$CONTROLLER_POD-$(date +"%d-%m-%Y").tar.gz
    #TODO call backup.sh in background
    #nohup backup.sh $CONTROLLER_POD 2>&1 | tee -a backup.log
done