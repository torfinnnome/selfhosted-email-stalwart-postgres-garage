# Stalwart Email Server with PostgreSQL and MinIO

This repository provides Docker Compose configurations for setting up a [Stalwart](https://stalw.art) email server using [PostgreSQL](https://www.postgresql.org) for metadata storage and [MinIO](https://min.io) for blob storage. It includes configurations for both a primary and a backup site with replication enabled.

*This is heavily inspired by https://gist.github.com/chripede/99b7eaa1101ee05cc64a59b46e4d299f - Thanks! Please check it out on how to configure Stalwart to use a setup like this.* 

## Prerequisites

*   Docker with [Docker Compose](https://github.com/docker/compose)
*   [MinIO Client](https://min.io/docs/minio/linux/reference/minio-mc.html) (`mc`) installed and configured

## Setup Instructions

This setup involves two sites: a primary site and a backup site.

### 1. Environment Configuration

Create a `.env` file in both the `primary-site` and `backup-site` directories based on the examples below.

**`primary-site/.env`:**

```env
POSTGRES_VERSION=<your_postgres_version>
POSTGRES_USER=stalwart
POSTGRES_PASSWORD=<your_postgres_password>
POSTGRES_DB=stalwart
POSTGRES_REPLICATION_USER=replicator
POSTGRES_REPLICATION_PASSWORD=<your_replication_password>
MINIO_ROOT_USER=<your_minio_user>
MINIO_ROOT_PASSWORD=<your_minio_password>
GRAFANA_ADMIN_USER=<your_grafana_admin_user>
GRAFANA_ADMIN_PASSWORD=<your_grafana_password>
```

**`backup-site/.env`:**

```env
POSTGRES_VERSION=<your_postgres_version> # Must match primary site
PRIMARY_HOST=<primary_site_ip_or_hostname>
REPLICATION_USER=replicator
REPLICATION_PASSWORD=<your_replication_password> # Must match primary site
MINIO_ROOT_USER=<your_minio_user>
MINIO_ROOT_PASSWORD=<your_minio_password>
```

### 2. Running the Services

Navigate to the `primary-site` and `backup-site` directories respectively and start the services, on your primary- and backup-site using Docker Compose:

```bash
# On primary site:
cd primary-site
docker-compose up -d

# On backup site:
cd backup-site
docker-compose up -d
```

### 3. PostgreSQL Replication Setup (Primary Site)

On the primary site's PostgreSQL server, modify the `pg_hba.conf` file (typically located in the data directory, e.g., `primary-site/postgres/data/pg_hba.conf` after the first run) to allow the replication user from the backup site. Add the following line, adjusting the IP range as necessary:

```
host    replication     replicator      <backup_site_ip>        scram-sha-256
```

### 4. MinIO Bucket Setup

Ensure the MinIO service is running on both primary and backup sites before proceeding.

**a. Create Buckets:**

Create the necessary bucket (e.g., `mydata`) on both the primary (source) and backup (target) MinIO instances. The target bucket *must* exist before setting up replication.

```bash
# Replace placeholders with your actual values
mc alias set source http://PRIMARY_MINIO_IP:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD --api s3v4
mc alias set target http://BACKUP_MINIO_IP:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD --api s3v4

mc mb source/mydata
mc mb target/mydata
```

**b. Enable Versioning:**

Enable versioning on both buckets.

```bash
mc version enable source/mydata
mc version enable target/mydata
```

### 5. MinIO Replication Setup

Configure replication from the primary (source) to the backup (target) MinIO instance.

```bash
# Replace placeholders with your actual values
mc replicate add source/mydata \
  --remote-bucket http://TARGET_MINIO_ACCESS_KEY:TARGET_MINIO_SECRET_KEY@BACKUP_MINIO_IP:9000/mydata \
  --replicate "delete,delete-marker,existing-objects" \
  --priority 1

# Verify replication status
mc replicate status source/mydata

# If old items are not synced, force it:
mc mirror source/mydata target/mydata
```

*Note: Replace `TARGET_MINIO_ACCESS_KEY` and `TARGET_MINIO_SECRET_KEY` with the appropriate credentials for the target MinIO instance (likely the `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` from the backup site's `.env`).*

## Monitoring (Primary Site)

The `primary-site` configuration includes a monitoring stack based on Prometheus and Grafana:

*   **Prometheus:** Collects metrics from various exporters and services defined in its configuration file. Access the UI at `http://<primary_site_ip>:9090`.
    *   Configuration: `primary-site/prometheus/etc/prometheus.yml`
    *   Default Scrape Targets (as per `prometheus.yml`): Prometheus itself, Node Exporter, cAdvisor, Postgres Exporter, MinIO, Stalwart Mail.
*   **Grafana:** Visualizes the metrics collected by Prometheus. Access the UI at `http://<primary_site_ip>:3000`.
    *   Default credentials (unless changed in `.env`): `admin` / `admin`
    *   Provisioning: `primary-site/grafana/provisioning/`
*   **Node Exporter:** Exports host system metrics (CPU, RAM, disk, network) to Prometheus.
*   **cAdvisor:** Exports container metrics (resource usage per container) to Prometheus.
*   **Postgres Exporter:** Exports PostgreSQL database metrics to Prometheus.

This stack allows you to monitor the health and performance of the host system, Docker containers, and the PostgreSQL database. You can import pre-built Grafana dashboards via the Grafana UI (`http://<primary_site_ip>:3000`) using their IDs or by uploading their JSON definitions. Recommended dashboards include:
*   **Node Exporter Full (ID: 1860):** Host system metrics.
*   **Docker and System Monitoring (ID: 193):** Container metrics (from cAdvisor).
*   **PostgreSQL Database (ID: 9628):** PostgreSQL metrics.
*   **MinIO Dashboard (ID: 13502):** MinIO server metrics.
*   **Stalwart Mail Server:** A dashboard is available [here](https://github.com/torfinnnome/grafana-dashboard-stalwart). *Note: Requires enabling the Prometheus metrics endpoint in Stalwart's configuration.*

## PostgreSQL Backup (Primary Site)

A script (`primary-site/backup/postgres_backup_local.sh`) is provided for backing up the primary PostgreSQL database locally on the host machine where the primary site's Docker containers are running. This script uses `docker exec` to run `pg_dump` inside the container.

### Setup

1.  **Configure Environment Variables:**
    The backup script (`postgres_backup_local.sh`) requires several environment variables to be set:
    *   `CONTAINER_NAME`: The name of the PostgreSQL Docker container (e.g., `db` or the full name generated by compose).
    *   `PGUSER`: PostgreSQL user (e.g., `stalwart`).
    *   `PGDATABASE`: PostgreSQL database name (e.g., `stalwart`).
    *   `PGPASSWORD`: PostgreSQL user's password. **Must be set for `docker exec`**.
    *   `BACKUP_DIR`: The absolute path on the *host machine* where backup files should be stored.
    *   `KEEP_DAYS`, `KEEP_WEEKS`, `KEEP_MONTHS` (Optional): For retention policy.

    You can set these variables in the environment where the script runs (e.g., in a cron job definition) or by creating a `.env` file (e.g., `primary-site/backup/.env`) and sourcing it before running the script.

    **Example `primary-site/backup/.env`:**
    ```env
    # Required for postgres_backup_local.sh
    CONTAINER_NAME=primary-site-db-1 # Adjust to your actual container name
    PGUSER=stalwart
    PGDATABASE=stalwart
    PGPASSWORD=<your_postgres_password> # The password from primary-site/.env
    BACKUP_DIR=/path/on/host/for/postgres-backups # Host path where backups should be stored

    # Optional Retention
    # KEEP_DAYS=7
    # KEEP_WEEKS=4
    # KEEP_MONTHS=12
    ```
    *Note: Ensure the `BACKUP_DIR` exists and has appropriate write permissions for the user running the script.*

2.  **Configure Passwordless Access (Optional but Recommended):**
    PGDATABASE=stalwart
    *Note: The `postgres_backup_local.sh` script uses `docker exec` and passes `PGPASSWORD` as an environment variable directly to the `docker exec` command. Therefore, `.pgpass` inside the container or on the host is *not* used by this specific script for the `pg_dump` execution itself.*

3.  **Schedule Cron Job:**
    Edit the crontab (`crontab -e`) on the host machine and add a line similar to the following, adjusting paths and environment variable handling as needed:

    **Option A: Sourcing a `.env` file:**
    ```crontab
    # Example: Run backup daily at 3:10 AM, sourcing variables from backup/.env
    10 3 * * * set -a; source /full/path/to/primary-site/backup/.env; set +a; /full/path/to/primary-site/backup/postgres_backup_local.sh >> /full/path/to/primary-site/backup/postgres_backup.log 2>&1
    ```

    **Option B: Setting variables directly in crontab:**
    ```crontab
    # Example: Run backup daily at 3:10 AM, setting variables directly
    10 3 * * * PGPASSWORD='<your_pg_password>' CONTAINER_NAME='primary-site-db-1' PGUSER='stalwart' PGDATABASE='stalwart' BACKUP_DIR='/path/on/host/for/postgres-backups' /full/path/to/primary-site/backup/postgres_backup_local.sh >> /full/path/to/primary-site/backup/postgres_backup.log 2>&1
    ```
    *(Remember to replace placeholders like `<your_pg_password>` and paths)*

    Ensure the `postgres_backup_local.sh` script is executable:
    ```bash
    chmod +x /full/path/to/primary-site/backup/postgres_backup_local.sh
    ```
