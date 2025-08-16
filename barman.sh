#! /bin/bash

set -ex

if [ -z ${ARCHIVE_DIR+x} ]; then
  echo "ARCHIVE_DIR variable must exist" >&2
  exit 1
fi

if [ -z ${BACKUP_DIR+x} ]; then
  echo "BACKUP_DIR variable must exist" >&2
  exit 1
fi

# export BACKUP_DIR=/home/vagrant/.tmp/Backup && mkdir -p $BACKUP_DIR && chown -R 991:991 /home/vagrant/.tmp
barman=`docker ps -a | grep barman | awk '{print $NF}'`
if [ "${barman}" = "" ]; then
    # docker run -d --restart=no --name barman --mount type=bind,source=${ARCHIVE_DIR},target=/home/postgres/.tmp ubuntu:latest bash -c 'tail -f /dev/null'
    docker run -d --restart=no --name barman \
      --mount type=bind,source=${ARCHIVE_DIR},target=/home/postgres/.tmp \
      --mount type=bind,source=${BACKUP_DIR},target=/home/postgres/.backup \
      ubuntu:latest bash -c 'tail -f /dev/null'

    DOCKER_BRIDGE_INTERFACE=`ifconfig docker0 | grep -w "inet" | awk '{print $2}'`
    VERSION_CODENAME=`docker exec barman bash -c "cat /etc/os-release" | grep VERSION_CODENAME | sed 's/VERSION_CODENAME=//'`
    PG_TAG=REL_18_BETA1

    cat > temp.sh << EOF_OUT
#! /bin/bash
set -ex

# psql -U patroni_super -d postgres -c "CREATE USER streaming_barman WITH REPLICATION ENCRYPTED PASSWORD 'streaming_barman'; CREATE USER barman WITH SUPERUSER ENCRYPTED PASSWORD 'barman';"

apt update && \
  apt install -y curl && \
  install -d /usr/share/postgresql-common/pgdg && \
  curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
  sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main' > /etc/apt/sources.list.d/pgdg.list" && \
  apt update && apt -y install barman barman-cli g++ zlib1g-dev make tar gzip perl liblz4-dev libreadline-dev flex bison libicu-dev liburing-dev

chown -R barman:barman /etc/barman.d && \
  apt-get install --reinstall -y pkg-config

cat > /etc/barman.d/streaming-backup-server.conf << EOF1
[node1]
description = "Postgres server using streaming replication"
streaming_archiver = on
archiver = on
backup_method = postgres
streaming_conninfo = host=${DOCKER_BRIDGE_INTERFACE} user=streaming_barman dbname=postgres port=5432
slot_name = barman
create_slot = auto
conninfo = host=${DOCKER_BRIDGE_INTERFACE} user=barman dbname=postgres port=5432
incoming_wals_directory = /home/postgres/.tmp
EOF1

cat > /var/lib/barman/.pgpass << EOF2
${DOCKER_BRIDGE_INTERFACE}:5432:postgres:barman:barman
${DOCKER_BRIDGE_INTERFACE}:5432:replication:streaming_barman:streaming_barman
EOF2

# The cluster uses PG v18beta1 so we have to build from source to have compatibilty with pg_receivewal
# Otherwise it all fails
wget https://github.com/postgres/postgres/archive/refs/tags/${PG_TAG}.tar.gz && \
    tar -xzf ${PG_TAG}.tar.gz
cd postgres-${PG_TAG}
./configure  --with-liburing --enable-debug --with-lz4 && make -j4 && make all && make install &&
    echo "export PATH=/usr/local/pgsql/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> /var/lib/barman/.bashrc && \
    source /var/lib/barman/.bashrc

cd /
rm ${PG_TAG}.tar.gz && rm -rf postgres-${PG_TAG}

# Node postgres user has ID 991. Reassign same ID to avoid permission errors for archive directory
usermod -u 991 barman && groupmod -g 991 barman && \
  chown -R barman:barman /usr/local/pgsql /var/lib/barman /var/log/barman /etc/barman.d && \
  chmod 0600 /var/lib/barman/.pgpass

# Some Barman commands to get started
barman receive-wal --create-slot node1
barman cron
EOF_OUT

    docker cp temp.sh barman:run.sh
    rm temp.sh
    docker exec barman bash -c "chmod +x run.sh && ./run.sh"

    RES=`docker exec -it barman bash -c "source /var/lib/barman/.bashrc && barman list-backups node1"`
    if [ "${RES}" = "" ]; then
      echo "Error when performing backups" >&2
      exit 1
    else
      echo -e 'First Backup is complete\nBarman is Ready!'
    fi
fi

docker exec -t barman bash -c "source /var/lib/barman/.bashrc && barman check node1 && barman backup --name first-backup node1"
