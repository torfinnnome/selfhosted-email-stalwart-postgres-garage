# Stalwart Email Server with PostgreSQL and Garage

This repository provides Docker Compose configurations for setting up a [Stalwart](https://stalw.art) email server using [PostgreSQL](https://www.postgresql.org) for metadata storage and [Garage](https://garage.deuxfleurs.fr/) for blob storage. It includes configurations for both a primary and a backup site with replication enabled.

*This is heavily inspired by https://gist.github.com/chripede/99b7eaa1101ee05cc64a59b46e4d299f - Thanks! Please check it out on how to configure Stalwart to use a setup like this.* 

## Prerequisites

*   Docker with [Docker Compose](https://github.com/docker/compose)
*   [Garage](https://garage.deuxfleurs.fr/docs/quick-start/setup-and-usage/) installed and configured
*   [rclone](https://rclone.org/) installed and configured

## Setup Instructions

This setup involves two sites: a primary site and a backup site.

### 1. Environment Configuration

Create a `.env` file in both the `primary-site` and `backup-site` directories based on the examples below.

**`primary-site/.env`:**

```env
STALWART_VERSION=v0.14
POSTGRES_VERSION=18.0
POSTGRES_USER=stalwart
POSTGRES_PASSWORD=<your_postgres_password>
POSTGRES_DB=stalwart
POSTGRES_REPLICATION_USER=replicator
POSTGRES_REPLICATION_PASSWORD=<your_replication_password>
GARAGE_VERSION=v2.1.0
PROMETHEUS_VERSION=v3.7.2
GRAFANA_VERSION=12.3.0-18765596677
NODE_EXPORTER_VERSION=v1.10.0
CADVISOR_VERSION=v0.52.0
POSTGRES_EXPORTER_VERSION=v0.18.1
GARAGE_RPC_SECRET=<your_garage_rpc_secret>
GARAGE_ADMIN_TOKEN=<your_garage_admin_token>
GRAFANA_ADMIN_USER=<your_grafana_admin_user>
GRAFANA_ADMIN_PASSWORD=<your_grafana_password>
GRAFANA_SMTP_ENABLED=true
GRAFANA_SMTP_HOST=<smtp-server:25>
GRAFANA_SMTP_EHLO_IDENTITY=<ehlo_host>
GRAFANA_SMTP_FROM_ADDRESS=<from_address>
```

*Note: You can generate a random `GARAGE_RPC_SECRET` and `GARAGE_ADMIN_TOKEN` with the following command: `openssl rand -hex 32`*

**`backup-site/.env`:**

```env
POSTGRES_VERSION=18.0 # Must match primary site
PRIMARY_HOST=<primary_site_ip_or_hostname>
REPLICATION_USER=replicator
REPLICATION_PASSWORD=<your_replication_password> # Must match primary site
GARAGE_VERSION=v2.1.0
GARAGE_RPC_SECRET=<your_garage_rpc_secret>
GARAGE_ADMIN_TOKEN=<your_garage_admin_token>
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

### 4. Garage Admin Token and S3 Credentials

Garage uses two types of credentials:

*   **Admin Token:** Used for administrative tasks, such as creating buckets and managing users. This is configured with the `GARAGE_ADMIN_TOKEN` environment variable.
*   **S3 Credentials:** Used by S3 clients like `rclone` to access data in buckets. These are generated using the `garage` CLI.

**a. Create S3 Credentials:**

Create S3 credentials using the `garage key create` command. You will need to provide a key name.

```bash
# Replace <key_name> with a descriptive name for your key
docker exec -it primary-site-garage-1 garage key create <key_name>
```

This will output an access key and a secret key. **Save these credentials in a safe place.** You will need them to configure S3 clients.

**b. Create Buckets:**

Create the necessary bucket (e.g., `mydata`) on the primary Garage instance. This command requires the `GARAGE_ADMIN_TOKEN` to be set.

```bash
docker exec -it primary-site-garage-1 garage bucket create mydata
```

### 5. Garage Replication Setup

Garage handles replication automatically between the nodes defined in the `garage.toml` configuration files.

## Monitoring (Primary Site)

The `primary-site` configuration includes a monitoring stack based on Prometheus and Grafana:

*   **Prometheus:** Collects metrics from various exporters and services defined in its configuration file. Access the UI at `http://<primary_site_ip>:9090`.
    *   Configuration: `primary-site/prometheus/etc/prometheus.yml`
    *   Default Scrape Targets (as per `prometheus.yml`): Prometheus itself, Node Exporter, cAdvisor, Postgres Exporter, Garage, Stalwart Mail.
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
*   **Garage:** A dashboard is available [here](https://git.deuxfleurs.fr/Deuxfleurs/garage/raw/branch/main-v1/script/telemetry/grafana-garage-dashboard-prometheus.json).
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

## Garage Backup (Primary Site)

A script (`primary-site/backup/garage_backup_local.sh`) is provided for backing up the primary Garage bucket locally on the host machine where the primary site's Docker containers are running. This script uses `rclone` to sync the bucket to a local directory.

### Setup

1.  **Configure rclone:**
    You need to have rclone configured with a remote for your Garage S3 API. The remote should be named `garage` (or you can change the `RCLONE_REMOTE_NAME` variable in the script). You can configure rclone by running `rclone config` and following the prompts. You will need the S3 access key and secret key that you generated with the `garage key create` command.

2.  **Configure Environment Variables:**
    The backup script (`garage_backup_local.sh`) requires several environment variables to be set:
    *   `RCLONE_REMOTE_NAME`: The name of the rclone remote for your Garage S3 API (e.g., `garage`).
    *   `BUCKET_NAME`: The name of the bucket you want to back up (e.g., `stalwart`).
    *   `LOCAL_BACKUP_DIR`: The absolute path on the *host machine* where backup files should be stored.
    *   `LOG_FILE`: Optional: Path to the log file. Leave empty "" to disable file logging.
    *   `LOCK_FILE`: Optional: Lock file to prevent concurrent runs. Leave empty "" to disable locking.
    *   `RCLONE_BIN`: The path to the rclone binary.

    You can set these variables in the environment where the script runs (e.g., in a cron job definition) or by creating a `.env` file (e.g., `primary-site/backup/.env`) and sourcing it before running the script.

    **Example `primary-site/backup/.env`:**
    ```env
    # Required for garage_backup_local.sh
    RCLONE_REMOTE_NAME=garage
    BUCKET_NAME=stalwart
    LOCAL_BACKUP_DIR=/path/on/host/for/garage-backups # Host path where backups should be stored
    ```
    *Note: Ensure the `LOCAL_BACKUP_DIR` exists and has appropriate write permissions for the user running the script.*

3.  **Schedule Cron Job:**
    Edit the crontab (`crontab -e`) on the host machine and add a line similar to the following, adjusting paths and environment variable handling as needed:

    **Option A: Sourcing a `.env` file:**
    ```crontab
    # Example: Run backup daily at 3:20 AM, sourcing variables from backup/.env
    20 3 * * * set -a; source /full/path/to/primary-site/backup/.env; set +a; /full/path/to/primary-site/backup/garage_backup_local.sh >> /full/path/to/primary-site/backup/garage_backup.log 2>&1
    ```

    **Option B: Setting variables directly in crontab:**
    ```crontab
    # Example: Run backup daily at 3:20 AM, setting variables directly
    20 3 * * * RCLONE_REMOTE_NAME='garage' BUCKET_NAME='stalwart' LOCAL_BACKUP_DIR='/path/on/host/for/garage-backups' /full/path/to/primary-site/backup/garage_backup_local.sh >> /full/path/to/primary-site/backup/garage_backup.log 2>&1
    ```
    *(Remember to replace placeholders and paths)*

    Ensure the `garage_backup_local.sh` script is executable:
    ```bash
    chmod +x /full/path/to/primary-site/backup/garage_backup_local.sh
    ```
