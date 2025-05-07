# Stalwart Email Server with FoundationDB and MinIO

This repository provides Docker Compose configurations for setting up a [Stalwart](https://stalw.art) email server using [FoundationDB](https://www.foundationdb.org/) for metadata storage and [MinIO](https://min.io) for blob storage.

*This is heavily inspired by https://gist.github.com/chripede/99b7eaa1101ee05cc64a59b46e4d299f - Thanks! Please check it out on how to configure Stalwart to use a setup like this.*

The cluster configuration is deployed across four Virtual Machines (VMs), each situated in a distinct physical location. Inter-node communication is established via Tailscale. 

The roles and services are distributed as follows:

- Two front-end nodes: These nodes handle incoming requests, running Nginx, Stalwart, FoundationDB, and MinIO.
- One back-end node: FoundationDB and MinIO.
- One back-end node: FoundationDB


## Prerequisites

*   Docker with [Docker Compose](https://github.com/docker/compose) (or Podman)
*   [MinIO Client](https://min.io/docs/minio/linux/reference/minio-mc.html) (`mc`) installed and configured
*   `git` (for cloning the Stalwart repository)

## Setup Instructions

This guide helps you set up Stalwart with clustered FoundationDB and MinIO.

### 1. Build Stalwart Docker Image with FoundationDB Support

The standard Stalwart Docker image may not include FoundationDB support by default, or you might need a specific version. This setup requires a Stalwart image built with FoundationDB capabilities, tagged as `stalwart-fdb:latest`.

a. Clone the official Stalwart Mail server repository (or your fork):
```bash
git clone https://github.com/stalwartlabs/stalwart-mail.git stalwart-mail-repo
cd stalwart-mail-repo
```

b. Build the Docker image. The Dockerfile for FoundationDB support is in the subdirectory like `resources/docker/`. *Compare it with the file `stalwart-mail/build/Dockerfile` from this repo, as you want to add support for MinIO (and possibly other services) as well.*

```bash
# Build the image
docker build -t stalwart-fdb:latest .

# Navigate back to the root of the cloned repository or your project directory
cd ../
```
Ensure the image `stalwart-fdb:latest` is successfully built and available locally before proceeding. The `docker-compose.yml` file in this repository refers to this image name.

### 2. Environment Configuration

Create a `.env` file in the root of this project directory. Below is an example template. Adjust the placeholder values (like `hostname.of.coordinator`, `this.public.ip`, `this.hostname`) to match your specific environment and server hostnames/IPs.

```env
MINIO_RELEASE=RELEASE.2025-04-22T22-12-26Z
MINIO_ROOT_USER=adminuser
MINIO_ROOT_PASSWORD=verysecret
GRAFANA_ADMIN_USER=adminuser
GRAFANA_ADMIN_PASSWORD=alsoverysecret
FDB_VERSION=7.3.62
FDB_COORDINATOR=hostname.of.coordinator
FDB_NETWORKING_MODE=container
FDB_COORDINATOR_PORT=4500
FDB_PUBLIC_IP=this.public.ip # The public IP of the host running FDB
FDB_HOST_HOSTNAME=this.hostname # A unique hostname for this FDB node (e.g., server1)
FDB_CLUSTER_FILE=/var/fdb/fdb.cluster
FDB_ADDITIONAL_VERSIONS=""
```

### 3. FoundationDB Cluster Setup

The `fdb/fdb.cluster` file is crucial for FoundationDB clients (like Stalwart Mail) and servers to locate the cluster coordinators.
The format of this file is `description:id@ip1:port1,ip2:port2,...`.
*   `description:id`: A unique identifier for your cluster (e.g., `docker:docker` as used in the provided `fdb/fdb.cluster` file).
*   `ipN:portN`: The IP addresses and ports of your FoundationDB coordinator processes.

In this setup:
*   The `fdb/fdb.cluster` file is mounted into both the `stalwart-mail` and `fdb` service containers.
*   The provided `fdb/fdb.cluster` file is:
    ```
    docker:docker@server1:4500,server2:4500,server3:4500,server4:4500
    ```
*   You **must** ensure that `server1`, `server2`, `server3`, `server4` are resolvable hostnames or IP addresses of your FoundationDB coordinator nodes, and that they are listening on port `4500` (or the port specified in `FDB_COORDINATOR_PORT` in your `.env` file). These hostnames should correspond to the `FDB_HOST_HOSTNAME` values for your FDB nodes if you are running multiple FDB instances.
*   The `FDB_COORDINATOR` variable in your `.env` file should align with the information in your `fdb.cluster` file. The `fdb` service entrypoint uses `FDB_CLUSTER_FILE` which points to this file.
*   **Important:** Review the coordinator list in `fdb/fdb.cluster`. Ensure this list accurately reflects your coordinator setup. Typically, you'd have an odd number of coordinators (e.g., 3 or 5) for resilience.

### 4. Nginx Reverse-Proxy Setup

The `nginx/nginx.conf` file configures Nginx to act as a reverse proxy for both Stalwart Mail services and the MinIO S3 API. This allows you to expose these services on standard ports and manage SSL/TLS termination centrally.

Key aspects of the configuration:
*   **Stalwart Mail Services:**
    *   Nginx listens on standard mail ports: `25` (SMTP), `993` (IMAPS), `465` (SMTPS), `587` (Submission), and `443` (HTTPS for Stalwart web interface/JMAP/etc.).
    *   It uses `upstream` blocks (e.g., `backend_smtp`, `backend_imaps`) to define the Stalwart backend servers (e.g., `server1:1025`, `server2:1025`). These should point to your Stalwart instances. The current configuration assumes Stalwart is reachable via `server1` and `server2` on specific internal ports, which match the exposed ports in the `stalwart-mail` service in `docker-compose.yml`.
    *   `proxy_protocol on;` is enabled for mail services. This sends client connection information (like the original IP address) to Stalwart. Ensure your Stalwart instances are configured to accept the proxy protocol.
*   **MinIO S3 API:**
    *   Nginx listens on port `81` for S3 traffic.
    *   The `server_name s3.yourdomain;` directive should be updated to your desired domain for accessing MinIO.
    *   It proxies requests to the `minio_backend` upstream, which includes `server1:9000`, `server2:9000`, and `server3:9000`. These should be the addresses of your MinIO server instances.
    *   `client_max_body_size 5G;` allows for large file uploads. Adjust as needed.
*   **General:**
    *   The Nginx service in `docker-compose.yml` uses `network_mode: host`. Adjust as needed.
    *   Ensure that `server1`, `server2`, `server3` in `nginx.conf` are resolvable to the correct IP addresses of your backend Stalwart and MinIO instances.
    *   For production, configure SSL/TLS for the MinIO endpoint (port 81) and ensure mail service ports are secured with SSL/TLS certificates. The `nginx.conf` proxies HTTPS on port 443 to Stalwart.

To use this Nginx configuration:
1.  Ensure `nginx/nginx.conf` reflects your server hostnames/IPs and desired domain names.
2.  If using SSL/TLS, place your certificate and key files (e.g., in `./nginx/certs`), uncomment the certs volume in `docker-compose.yml`, and update `nginx.conf`.

### 5. FoundationDB Setup

After the FoundationDB cluster is running, you need to configure its redundancy mode and storage engine. This is typically done once per cluster.

1.  Connect to one of your FoundationDB nodes using `fdbcli`. If you are using the Docker Compose setup provided, you can do this by running the following command on the Docker host where an `fdb` service container is running:
    ```bash
    docker compose exec fdb fdbcli
    ```

2.  Once inside the `fdbcli` prompt, configure the database. For a typical setup with SSDs, you would use:
    ```
    configure double ssd
    ```
    This command sets the redundancy mode to `double` (meaning data is replicated twice) and the storage engine to `ssd`. Adjust these settings based on your specific hardware and resilience requirements. Refer to the [FoundationDB documentation](https://apple.github.io/foundationdb/administration.html#configuring-the-database) for more details on available options.

3.  You can verify the configuration by typing `status` in the `fdbcli`.

### 6. MinIO Bucket Setup

Ensure the MinIO service is running before proceeding. This setup assumes MinIO is accessible via hostnames like `server1`, `server2`, `server3` on port `9000`.

**a. Create Buckets:**

Create the necessary bucket (e.g., `mydata`) on your MinIO instance (source). If you plan to use replication to another S3 target, create the bucket there as well. The target bucket *must* exist before setting up replication.

```bash
# Replace placeholders with your actual values.
# 'source' refers to the MinIO instance in this Docker Compose setup.
# Use one of your MinIO server hostnames/IPs (e.g., server1, server2, or server3 from your setup).
# The MINIO_ROOT_USER and MINIO_ROOT_PASSWORD are from your .env file.
mc alias set source http://server1_ip_or_hostname:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD --api s3v4

# If replicating, 'target' refers to your backup/remote MinIO instance or S3-compatible service.
# mc alias set target http://<remote_s3_ip_or_hostname>:<remote_s3_port> S3_ROOT_USER S3_ROOT_PASSWORD --api s3v4

mc mb source/mydata
# mc mb target/mydata # Only if replicating to a target you manage with 'mc'
```

**b. Enable Versioning:**

Enable versioning on the source bucket, and on the target bucket if replicating.

```bash
mc version enable source/mydata
# mc version enable target/mydata # Only if replicating
```

### 7. Monitoring

This configuration includes a monitoring stack based on Prometheus and Grafana:

*   **Prometheus:** Collects metrics from various exporters and services. Access the UI at `http://<your_host_ip>:9090`.
    *   Configuration: `prometheus/etc/prometheus.yml`
    *   Default Scrape Targets (as per `prometheus.yml`): Prometheus itself, Node Exporter, cAdvisor, MinIO (e.g., `server1:9000`), Stalwart Mail (`stalwart-mail:8080`), FoundationDB Exporter (e.g., `server1:9188`). Ensure these targets in `prometheus/etc/prometheus.yml` match your actual service hostnames/IPs and ports. The hostnames like `server1` should be resolvable by Prometheus.
*   **Grafana:** Visualizes the metrics collected by Prometheus. Access the UI at `http://<your_host_ip>:3000`.
    *   Default credentials (unless changed in `.env`): `admin` / `admin` (or `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`)
    *   Provisioning: `grafana/provisioning/`
*   **Node Exporter:** Exports host system metrics (CPU, RAM, disk, network) to Prometheus.
*   **cAdvisor:** Exports container metrics (resource usage per container) to Prometheus.
*   **[fdbexporter](https://github.com/clevercloud/fdbexporter):** Exports FoundationDB metrics to Prometheus.

This stack allows you to monitor the health and performance of the host system, Docker containers, FoundationDB, and MinIO. You can import pre-built Grafana dashboards via the Grafana UI (`http://<your_host_ip>:3000`) using their IDs or by uploading their JSON definitions. Recommended dashboards include:
*   **Node Exporter Full (ID: 1860):** Host system metrics.
*   **Docker and System Monitoring (ID: 193):** Container metrics (from cAdvisor).
*   **MinIO Dashboard (ID: 13502):** MinIO server metrics.
*   **Stalwart Mail Server:** A dashboard is available [here](https://github.com/torfinnnome/grafana-dashboard-stalwart). *Note: Requires enabling the Prometheus metrics endpoint in Stalwart's configuration.*
*   **FoundationDB:** A dashboard is available [here](https://github.com/torfinnnome/grafana-dashboard-foundationdb).

### 8. MinIO Replication Setup (optional)

Configure replication from your local MinIO instance (source) to a backup/target MinIO instance or S3-compatible service.

```bash
# Replace placeholders with your actual values
mc replicate add source/mydata \
  --remote-bucket "arn:aws:s3:::mydata" \ # Example ARN for target bucket, adjust for your S3 provider
  --storage-class STANDARD \ # Optional: specify storage class on target
  --endpoint "http://SOME_OTHER_S3:9000" \ # Endpoint of the target S3 service
  --access-key "TARGET_S3_ACCESS_KEY" \
  --secret-key "TARGET_S3_SECRET_KEY" \
  --replicate "delete,delete-marker,existing-objects" \
  --priority 1

# Verify replication status
mc replicate status source/mydata --data

# If old items are not synced and you want to mirror them (use with caution):
# mc mirror --overwrite source/mydata target/mydata
```

*Note: The `mc replicate add` command structure can vary based on the S3 provider. The example above uses parameters common for MinIO-to-MinIO or MinIO-to-S3 replication. Replace placeholders with your actual values for the target S3 instance. The `--remote-bucket` often requires an ARN or specific format. Consult MinIO and your target S3 provider's documentation.*


### 9. Running the Services

Navigate to the root of this project directory and start all services using Docker (or Podman) Compose:

```bash
docker-compose up -d
```


## Todo

- Detailed guide on FoundationDB backup and restore procedures.
- Instructions for SSL/TLS certificate setup for MinIO.
