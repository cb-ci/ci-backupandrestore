# End-to-End Diagrams

Overview of the whole backup-to-restore workflow. The per-script details (options, safety checks, unmatched-backup dialog) are in the sequence diagrams of the [README](README.md#script-reference).

Names such as `controller1`, `folder-dev1-controllers` or `cluster-op-backups` are placeholders.

## Flow

```mermaid
flowchart TD
    subgraph BACKUP["1. Backup (Operations Center)"]
        JOB["Cluster backup job<br/>name = BACKUP_JOB_NAME"]
        S3[("S3 folder<br/>S3BUCKET / S3BUCKET_FOLDER")]
        JOB -->|"backup-NAME-JOB-N.HASH.tar.gz<br/>online managed controllers only"| S3
    end

    subgraph MAP["2. Map: listControllersWithBackups.sh"]
        CJOC["CJOC REST API<br/>CBCI_URL + CJOC_API_PATH<br/>one level: root or one folder"]
        LS["aws s3 ls<br/>keep *.tar.gz"]
        PARSE["Parse each file name<br/>controllerOriginal + increment N"]
        MATCH{"Safe name equals the<br/>controller statefulSet?"}
        FOLDER{"Folder mode and equals<br/>the short controller name?"}
        RANK["Rank backups per controller<br/>highest increment, then date"]
        UNM["unmatchedBackups<br/>+ possibleControllers hint"]
        JSON[/"controllers-backups.json"/]
        CJOC --> MATCH
        LS --> PARSE --> MATCH
        MATCH -->|yes| RANK
        MATCH -->|no| FOLDER
        FOLDER -->|yes| RANK
        FOLDER -->|no| UNM
        RANK --> JSON
        UNM --> JSON
    end

    S3 --> LS

    subgraph RESTORE["3. Restore"]
        CHOOSE{"How many controllers?"}
        ONE["restoreControllerfromS3.sh<br/>--controller NAME<br/>or --pod and --archive"]
        MANY["restoreManyControllersFromS3.sh<br/>-j N, --only, --exclude"]
        DRY{"--dry-run?"}
        PLAN["Print plan:<br/>controller, pod, latest archive"]
        ASK{"Unmatched backup with exactly<br/>one possible controller?"}
        YES["Ask yes or no<br/>(terminal only, in memory)"]
        PRE{"Preflight:<br/>archive readable in S3?"}
        DOWN["Scale StatefulSet to 0"]
        RESCUE["Rescue pod mounts the PVC<br/>download archive, clear PVC,<br/>tar extract"]
        OK{"Rescue pod<br/>succeeded?"}
        UP["Delete rescue pod<br/>scale StatefulSet to 1"]
        FAIL["Exit 1: StatefulSet stays at 0,<br/>rescue pod kept for inspection"]
        STOP1["Abort, nothing changed"]
        STOP2["Exit 0, nothing changed"]

        CHOOSE -->|one| ONE
        CHOOSE -->|many| MANY
        MANY --> ASK
        ASK -->|yes| YES --> DRY
        ASK -->|no| DRY
        DRY -->|yes| PLAN --> STOP2
        DRY -->|no| ONE
        ONE --> PRE
        PRE -->|no| STOP1
        PRE -->|yes| DOWN --> RESCUE --> OK
        OK -->|yes| UP
        OK -->|no| FAIL
    end

    JSON --> CHOOSE
    JSON -.->|"fallback: explicit archive<br/>for unmatched backups"| ONE
```

## Sequence

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    participant OC as Operations Center<br/>(cluster backup job)
    participant S3 as AWS S3
    participant List as listControllersWithBackups.sh
    participant CJOC as CJOC REST API
    participant File as controllers-backups.json
    participant Many as restoreManyControllersFromS3.sh
    participant One as restoreControllerfromS3.sh
    participant K8s as Kubernetes (kubectl)
    participant Rescue as rescue pod

    Note over OC,S3: 1. Backup (scheduled or manual)
    OC->>S3: backup-NAME-JOB-N.HASH.tar.gz per online managed controller

    Note over Admin,File: 2. Map backups to controllers
    Admin->>List: ./listControllersWithBackups.sh [output-file]
    List->>CJOC: GET CJOC_API_PATH/api/json (one level)
    CJOC-->>List: managed controllers at that level
    List->>S3: aws s3 ls S3BUCKET/S3BUCKET_FOLDER
    S3-->>List: archive keys with dates
    List->>List: parse name and increment, match on statefulSet<br/>(folder mode: also short name), rank per controller
    List->>File: write controllers (backups ranked) and unmatchedBackups
    List-->>Admin: N controllers, M with backups, K unmatched

    Note over Admin,Rescue: 3. Restore
    alt many controllers
        Admin->>Many: ./restoreManyControllersFromS3.sh [-j N] [--dry-run]
        Many->>File: read plan, latest backup per controller
        opt unmatched backup with one possible controller
            Many->>Admin: suggest assignment, ask yes or no
            Admin-->>Many: answer
        end
        alt --dry-run
            Many-->>Admin: print plan, exit 0 (nothing changed)
        else restore
            loop each controller, up to N in parallel
                Many->>One: --pod POD --archive FILE
            end
        end
    else one controller
        Admin->>One: ./restoreControllerfromS3.sh --controller NAME
        One->>File: look up pod and latest backup
    end

    One->>S3: preflight head-object (archive readable?)
    alt not readable
        S3-->>One: 403 or 404
        One-->>Admin: error, exit 1 (nothing changed)
    else readable
        One->>K8s: scale StatefulSet to 0
        One->>K8s: create rescue pod (PVC mounted)
        K8s->>Rescue: start
        Rescue->>S3: aws s3 cp archive
        Rescue->>Rescue: clear PVC (optionally keep identity files), tar extract
        alt rescue pod succeeded
            One->>K8s: delete rescue pod, scale StatefulSet to 1
            One-->>Admin: restore completed
        else failed
            One-->>Admin: error, exit 1 (StatefulSet stays at 0, rescue pod kept)
        end
    end
    Many-->>Admin: summary OK or FAIL per controller (many-controller run only)
```
