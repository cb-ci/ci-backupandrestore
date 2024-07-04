# Backup and restore cloudbees-ci

This repo is about scripted approaches for backup and restore on/from AWS S3 for CloudBees CI on AWS EKS

see CloudBees documentation here for background:

* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/cloudbees-backup-plugin
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/kubernetes
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/backup-manually
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/restoring-from-backup-plugin



# Pre-requirements

```

export AWS_ACCESS_KEY_ID="YOUR_AWS_KEY"
export AWS_SECRET_ACCESS_KEY="YOUR_AWS_SECRET"
export AWS_DEFAULT_REGION=YOUR_AWS_REGION
export KUBECONFIG=PATH_TO_KUBECONFIG
```



## Create S3 Backup Bucket

see https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html

## Create Bucket Policy
In AWS console (or use aws cli)
> IAM -> Policies -> YOUR_S3_POLICY

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::YOURBUCKET/*"
        },
        {
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::YOURBUCKET"
        }
    ]
}
```
## Create User
> IAM -> Users -> YOURUSER

> IAM -> Users -> YOURUSER -> Add permissions -> Attach policies directly

> Assign YOURUSER to the S3 policy

## Create AWS Key
> IAM -> Users -> YOURUSER -> Access keys > Create access key

Then Add exported keys to Jenkins Credentials store and assign to the Backup-job and/or setCreds.sh


# Create Backup for Operations Center or Controller in S3

* Option1: Use the CloudBees Backup Plugin, see https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/cloudbees-backup-plugin
* Option2: Use the `backup.sh` script


# Restore Operations Center or Controller from Backup
This script `restore.sh` is designed to perform a restoration of a Operations Center or Controller instance in CloudBees Core modern.
It follows the process outlined in documentation: https://docs.cloudbees.com/docs/admin-resources/latest/backup-restore/restoring-manually


## Pre-Requirements
- By default the ownership ID of the jenkins user inside of the container is 1000. This script assumes this remains the same.
- This script assumes backups are saved in tar.gz format.
- The local environment which this script is executed in must have aws and kubectl commands available and authorised.
- AWS access from the local command line must have access to download from the associated/configured S3 bucket containing the backup file.
- The rescue container must have the tar command tool installed.
- The rescue container must have privileges to change ownership and permissions of files in the /tmp directory.
- The rescue container must be able to mount the Cjoc or Controller persistent volume.

## Run
Configure the config file and run this script using `bash restore.sh`.
Alternatively run the script using the parameters
```
bash restore.sh --namespace <namespace> --instanceStatefulsetName <Operations Center or Controller statefulset name> --backupSource <local or s3> --backupFilePath <Local backup file> --s3BucketName <S3 bucket name> --s3FilePath <Path to file in S3 bucket> --rescueContainerImage <optional docker container image> --cloudLocalDownloadDir <optional local directory to download backup files>
```

To restore more than one controller, add the list of controllers and their associated backup file paths to the `controllerList.csv` file. Controllers will be restored sequentially.
Configure variables and run `bash restoreMany.sh`.
Alternatively run the script using the parameters
```
bash restoreMany.sh --namespace <namespace> --backupSource <local or s3> --controllerList <CSV file, Default:controllerList.csv> --s3BucketName <optional S3 bucket name> --rescueContainerImage <optional docker container image> --cloudLocalDownloadDir <optional local directory to download backup files>
```
