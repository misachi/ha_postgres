#! /bin/bash

# 
set -ex

KERNEL=`uname -s`
if [ "${KERNEL}" != "Linux" ]; then
  echo "Only Linux Supported" >&2
  exit 1
fi

NODE=testPG.$1
DOCKER_BRIDGE_INTERFACE=`ifconfig docker0 | grep -w "inet" | awk '{print $2}' | sed 's/[0-9].[0-9]$/0.0/'`

if [ $# == 2 ]; then
  if [ -z ${ARCHIVE_DIR+x} ]; then
    echo "ARCHIVE_DIR variable must exist" >&2
    exit 1
  fi

  if [ "${ARCHIVE_DIR}" = "" ]; then
    echo "Missing archive directory. ${ARCHIVE_DIR} variable must not be empty" >&2
    exit 1
  fi

  IMG=postgres/test-0.0.1
  IMG_ID=`docker images ${IMG} -q`
  PG_TAG=REL_18_BETA1

  if [ "${IMG_ID}" = "" ]; then
    if [ ! -d "postgres-${PG_TAG}" ]; then
      wget https://github.com/postgres/postgres/archive/refs/tags/${PG_TAG}.tar.gz  # From https://github.com/postgres/postgres/releases/tag/REL_18_BETA1
      tar -xzf ${PG_TAG}.tar.gz
    fi
    ID=991
    USR=postgres
    USR_HOME=/home/postgres

    cat > Dockerfile << EOF
FROM ubuntu:latest
RUN groupadd -g ${ID} ${USR} && \
    useradd -r -u ${ID} -g ${USR} ${USR}

ADD postgres-${PG_TAG} ${USR_HOME}
WORKDIR ${USR_HOME}
RUN chown -R ${USR}:${USR} ${USR_HOME}
RUN apt-get update && apt-get install -y g++ \
            zlib1g-dev \
            make curl \
            tar gzip perl \
            liblz4-dev \
            libreadline-dev \
            flex bison libicu-dev liburing-dev

RUN apt-get install --reinstall -y pkg-config

# Build and Install Postgres
RUN ./configure  --with-liburing --enable-debug --with-lz4 && \
        make -j4 && \
        make all && \
        make install

# Putting executables in our PATH to make things easier later
RUN echo "export PATH=/usr/bin:/usr/local/bin:/usr/local/pgsql/bin/" >> /etc/bash.bashrc && \
        echo "export PGDATA=/usr/local/pgsql/data" >> /etc/bash.bashrc && \
        chown -R ${USR}:${USR} /usr/local/pgsql
USER ${USR}
EOF

    docker build -t ${IMG}:latest .
    rm Dockerfile
    rm -rf postgres-${PG_TAG}

  fi

  ND=`docker ps -a | grep ${NODE} | awk '{print $NF}'`
  if [ "${ND}" = "" ]; then
    if [ -z ${BACKUP_DIR+x} ]; then
      echo "BACKUP_DIR variable must exist" >&2
      exit 1
    fi
    # export BACKUP_DIR=/home/vagrant/.tmp/Backup && mkdir -p $BACKUP_DIR
    docker run -d --name ${NODE} -p $2:5432 \
      --mount type=bind,source=${ARCHIVE_DIR},target=/home/postgres/.tmp  \
      --mount type=bind,source=${BACKUP_DIR},target=/usr/local/pgsql/data \
      --restart=on-failure ${IMG}:latest bash -c 'tail /dev/null -f'
  fi
fi

ETCD=`docker ps -a | grep etcd | awk '{print $NF}'`
if [ "${ETCD}" = "" ]; then
  ARCH=`dpkg --print-architecture`
  docker run -d --restart=no -p 2379:2379 -p 2380:2380 --name etcd ubuntu:latest bash -c 'tail -f /dev/null' && \
    docker exec etcd bash -c "apt update && apt install -y git wget && \
      git clone -b v3.6.0 https://github.com/etcd-io/etcd.git && \
      wget https://go.dev/dl/go1.23.9.linux-${ARCH}.tar.gz && \
      rm -rf /usr/local/go && tar -C /usr/local -xzf go1.23.9.linux-${ARCH}.tar.gz && \
      cd etcd && export PATH=/usr/bin:/usr/local/bin:/etcd/bin:/usr/local/go/bin && \
      ./scripts/build.sh"
  ETCD_IP=`docker inspect --format='{{ .NetworkSettings.IPAddress }}' etcd`
  docker exec etcd bash -c "/etcd/bin/etcd --listen-client-http-urls='http://${ETCD_IP}:2379' --advertise-client-urls='http://${ETCD_IP}:2379'" &
fi

ETCD_IP=`docker inspect --format='{{ .NetworkSettings.IPAddress }}' etcd`
if [ "${ETCD_IP}" = "" ]; then
  docker start etcd && \
    ETCD_IP=`docker inspect --format='{{ .NetworkSettings.IPAddress }}' etcd` && \
  docker exec etcd bash -c "/etcd/bin/etcd --listen-client-http-urls='http://${ETCD_IP}:2379' --advertise-client-urls='http://${ETCD_IP}:2379'" &
fi

MY_IP=`docker inspect --format='{{ .NetworkSettings.IPAddress }}' ${NODE}`
if [ "${MY_IP}" = "" ]; then
  docker start ${NODE}
  MY_IP=`docker inspect --format='{{ .NetworkSettings.IPAddress }}' ${NODE}`
fi

if [ -z ${PGDATA+x} ]; then
    PGDATA=/usr/local/pgsql/data
fi

cat > patroni_config.yml << EOF
scope: cluster1
name: node$1

log:
  format: '%(asctime)s %(levelname)s: %(message)s'
  level: INFO
  max_queue_size: 1000
  traceback_level: ERROR

restapi:
  connect_address: ${MY_IP}:8008
  listen: ${MY_IP}:8008

etcd3:
  password: patroni_etcd_user
  url: http://${ETCD_IP}:2379
  username: patroni_etcd_user
  host: ${ETCD_IP}:2379
# The bootstrap configuration. Works only when the cluster is not yet initialized.
# If the cluster is already initialized, all changes in the `bootstrap` section are ignored!
bootstrap:
  # This section will be written into <dcs>:/<namespace>/<scope>/config after initializing
  # new cluster and all other cluster members will use it as a `global configuration`.
  # WARNING! If you want to change any of the parameters that were set up
  # via `bootstrap.dcs` section, please use `patronictl edit-config`!
  dcs:
    loop_wait: 10
    retry_timeout: 10
    ttl: 30
    postgresql:
      parameters:
          wal_level: hot_standby
          hot_standby: "on"
          max_connections: 100
          max_worker_processes: 8
          wal_keep_segments: 8
          max_wal_senders: 10
          max_replication_slots: 10
          max_prepared_transactions: 0
          max_locks_per_transaction: 64
          wal_log_hints: "on"
          track_commit_timestamp: "off"
          archive_mode: "on"
          archive_timeout: 1800s
          archive_command: mkdir -p /home/postgres/.tmp && test ! -f /home/postgres/.tmp/%f && cp %p /home/postgres/.tmp/%f
      recovery_conf:
          restore_command: cp /home/postgres/.tmp/%f %p

postgresql:
  authentication:
    replication:
      password: dummy
      username: postgres
    superuser:
      channel_binding: prefer
      gssencmode: prefer
      password: dummy
      sslmode: prefer
      username: postgres
  bin_dir: /usr/local/pgsql/bin
  connect_address: ${MY_IP}:5432
  data_dir: $PGDATA
  listen: ${MY_IP}, localhost:5432
  parameters:
    config_file: $PGDATA/postgresql.conf
    hba_file: $PGDATA/pg_hba.conf
    ident_file: $PGDATA/pg_ident.conf
  pg_hba:
  - local   all             all                                     trust
  - host    all             all             127.0.0.1/32            trust
  - host    all             all             ::1/128                 trust
  - local   replication     all                                     trust
  - host    replication     all             127.0.0.1/32            trust
  - host    replication     all             ::1/128                 trust
  - host replication patroni_repl ${DOCKER_BRIDGE_INTERFACE}/16 md5
  - host    all    barman    ${DOCKER_BRIDGE_INTERFACE}/16    md5
  - host    replication    streaming_barman    ${DOCKER_BRIDGE_INTERFACE}/16    md5
  - host all prom_pg_exporter ${DOCKER_BRIDGE_INTERFACE}/16    md5

tags:
  clonefrom: true
  failover_priority: 1
  noloadbalance: false
  nosync: false
EOF

docker exec -u root ${NODE} bash -c "apt-get install -y python3-psycopg2 patroni"
docker cp patroni_config.yml ${NODE}:/home/postgres/patroni_config.yml 

docker exec \
    -e PATRONI_REPLICATION_USERNAME=patroni_repl \
    -e PATRONI_REPLICATION_PASSWORD=patroni_repl \
    -e PATRONI_SUPERUSER_USERNAME=patroni_super \
    -e PATRONI_SUPERUSER_PASSWORD=patroni_super \
    -e PATRONI_REWIND_USERNAME=patroni_rewind \
    -e PATRONI_REWIND_PASSWORD=patroni_rewind \
    -e PATRONI_ETCD3_USERNAME=patroni_etcd_user \
    -e PATRONI_ETCD3_PASSWORD=patroni_etcd_user \
    ${NODE} bash -c "patroni patroni_config.yml"


# nohup ./run.sh 1 5432 > /tmp/test.1 &
# nohup ./run.sh 2 5433 > /tmp/test.2 &
# nohup ./run.sh 3 5434 > /tmp/test.3 &

# psql -U patroni_super -d postgres