# CloudBees CI Backup and Restore Scripts

This repository provides a set of scripts and tools for backing up and restoring CloudBees CI on a Kubernetes environment (like AWS EKS) using AWS S3 for storage.

**Bandwidth Warning:**
* Copying large .tar files locally (your laptop) and back to S3 will be slow. I recommend running the [backup.sh](backup.sh) script and S3 copy operation directly from an EC2 VM inside the same AWS VPC/subnet for max speed.

## Overview

There are two primary methods for handling backups with CloudBees CI:

1.  **CloudBees Backup Plugin:** A fully supported and integrated plugin that automates backups. See the official documentation for more details:
    *   [CloudBees Backup Plugin](https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/cloudbees-backup-plugin)

2.  **Custom Scripts (This Repository):** A more hands-on, script-based approach that gives you granular control over the backup and restore process. This method is useful for disaster recovery scenarios, manual interventions, or when you need a customized workflow.

This repository focuses on the second approach.

See CloudBees documentation for background:

* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/cloudbees-backup-plugin
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/kubernetes
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/backup-manually
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/backup-restore/restoring-from-backup-plugin


---

## Repository Contents

This table explains the purpose of each file in this repository.

| File                                         | Description                                                                                                                          |
|----------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| [backup.sh](backup.sh)                       | The main script to back up a controller's `jenkins_home` to an S3 bucket.                                                            |
| [restore-s3-simple.sh](restore-s3-simple.sh) | The main script to restore a controller's `jenkins_home` from an S3 backup.                                                          |
| [Dockerfile](Dockerfile)                     | Defines a custom Docker image containing essential tools (`aws-cli`, `kubectl`, `tar`) for the scripts.                              |
| [dockerbuild.sh](dockerbuild.sh)             | A helper script to build the custom Docker image defined in the `Dockerfile`.                                                        |
| [set-env.sh.template](set-env.sh.template)   | The scripts are designed to source a `set-env.sh` file to export necessary environment variables. You will need to create this file. |

---

## Setup and Configuration

Before using the scripts, you need to set up your AWS environment, local machine, and the custom Docker image.

### 1. AWS Setup

You need an S3 bucket to store the backups and an IAM User with the correct permissions to access it.

#### a. Create S3 Bucket
Create a new S3 bucket in your desired AWS region.
*See: [AWS S3 - Creating a bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html)*

#### b. Create IAM Policy
Create an IAM policy that grants access to your S3 bucket.

> In AWS Console: **IAM -> Policies -> Create policy**

Use the following JSON, replacing `YOURBUCKET` with your bucket name:
```json
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

#### c. Create IAM User and Attach Policy
1.  Create a new IAM User.
2.  Attach the policy you created in the previous step directly to this user.
3.  Generate an access key for this user and note the **Access Key ID** and **Secret Access Key**.

### 2. Local Environment

Your local machine, where you will run the scripts, needs the following:

#### a. Required Tools
Ensure you have the following command-line tools installed and configured:
*   `kubectl`: Configured to connect to your Kubernetes cluster.
*   `aws-cli`: Configured for access to your AWS account.

#### b. Environment Variables
The scripts require several environment variables to be set. The recommended way is to create a file named `set-env.sh` in the root of this repository and add the following lines.

**Create a `set-env.sh` file from template:**

```cp set-env.sh.template set-env.sh.```

**Important:** Do not commit `set-env.sh` to version control if it contains sensitive information. Add it to your `.gitignore` file.

### 3. Custom Docker Image
The `restore-s3-simple.sh` script uses a custom Docker image that contains all the necessary tools.

You can skip this step and use the one I have pushed here https://hub.docker.com/repository/docker/caternberg/aws-cli/general

#### a. Build the Image

Optional: Build the image by running the `dockerbuild.sh` script:
```bash
./dockerbuild.sh
```
This script builds the [Dockerfile](Dockerfile) and tags the image as `caternberg/aws-cli:1.3`.

#### b. (Optional) Push to a Registry
If your Kubernetes cluster does not have local access to the image, you will need to push it to a Docker registry (like Docker Hub, ECR, or GCR) and update the image name in the `restore-s3-simple.sh` script accordingly.

---

## Usage

### Adjust Env Variables 

In `set-env.sh` set the variables:

```
# The name of the CloudBees CI pod (e.g., cjoc-0 or my-controller-0). Defaults to "POD_NAME" if not provided as the first argument.
CI_POD="POD_NAME"
# The name of the S3 bucket where the backup is stored. Defaults to "YOUR_S3_BUCKET" if not provided as the second argument.
S3BUCKET="YOUR_S3_BUCKET"
# The folder path within the S3 bucket. Defaults to "YOUR_S3_BACKUP_FOLDER" if not provided as the third argument.
S3BUCKET_FOLDER="YOUR_S3_BACKUP_FOLDER"
# The filename of the backup archive.
ARCHIVENAME="YOUR_BACKUP_ARCHIVE_NAME" # for example backup-mypod-12-03-2025.tar.gz

# Kubernetes Config
export KUBECONFIG="/path/to/your/kubeconfig"

export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
```

### Backing Up a Controller

The `backup.sh` script creates a compressed tarball of a controller's `jenkins_home` and uploads it to S3.

**Usage:**
```bash
./backup.sh
```

### Restoring a Controller

The `restore-s3-simple.sh` script performs a full restore of a controller. It scales down the statefulset, creates a temporary "rescue pod" to download and extract the backup onto the PVC, and then scales the statefulset back up.

**IMPORTANT:** You **must** update the `CI_POD` variable in `set-env.sh`script if you want to restore on a new controller

> CI_POD=${targetcontrollerpod}

**2. Run the script:**
```bash
./restore-s3-simple.sh
```

---

