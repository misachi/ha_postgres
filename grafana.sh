#! /bin/bash

set -ex

DOCKER_BRIDGE_INTERFACE=`ifconfig docker0 | grep -w "inet" | awk '{print $2}'`
pg_exporter_container=`docker ps -a | grep pg_exporter | awk '{print $NF}'`
if [ "${pg_exporter_container}" = "" ]; then
docker run \
  -d --restart=no -p 9187:9187 \
  --name pg_exporter \
  -e DATA_SOURCE_URI="${DOCKER_BRIDGE_INTERFACE}:5432/postgres?sslmode=disable" \
  -e DATA_SOURCE_USER=prom_pg_exporter \
  -e DATA_SOURCE_PASS=prom_pg_exporter \
  quay.io/prometheuscommunity/postgres-exporter
else
  docker start pg_exporter
fi

ARCH=`dpkg --print-architecture`

grafana_container=`docker ps -a | grep grafana | awk '{print $NF}'`
if [ "${grafana_container}" = "" ]; then
cat > prometheus.yml << EOF
# my global config
global:
  scrape_interval: 15s # Set the scrape interval to every 15 seconds. Default is every 1 minute.
  evaluation_interval: 15s # Evaluate rules every 15 seconds. The default is every 1 minute.
  # scrape_timeout is set to the global default (10s).

# Alertmanager configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets:
          # - alertmanager:9093

# Load rules once and periodically evaluate them according to the global 'evaluation_interval'.
rule_files:
  # - "first_rules.yml"
  # - "second_rules.yml"

# A scrape configuration containing exactly one endpoint to scrape:
# Here it's Prometheus itself.
scrape_configs:
  # The job name is added as a label "job=<job_name>" to any timeseries scraped from this config.
  - job_name: "prometheus"

    # metrics_path defaults to '/metrics'
    # scheme defaults to 'http'.

    static_configs:
      - targets: ["localhost:9090"]
       # The label name is added as a label "label_name=<label_value>" to any timeseries scraped from this config.
        labels:
          app: "prometheus"

  - job_name: "Postgres exporter"
    scrape_interval: 5s
    static_configs:
      - targets: ["${DOCKER_BRIDGE_INTERFACE}:9187"]
EOF

docker run -d --restart=no -p 3000:3000 --name=grafana grafana/grafana-oss
docker cp prometheus.yml grafana:/usr/share/grafana/prometheus.yml
rm prometheus.yml

docker exec -u root grafana ash -c "apk add wget && chown -R grafana /usr/share/grafana"

# Alpine misbehaves so doing these in separate lines
docker exec -t grafana ash -c "wget https://github.com/prometheus/prometheus/releases/download/v3.5.0/prometheus-3.5.0.linux-${ARCH}.tar.gz" 
docker exec grafana ash -c "tar xvfz prometheus-*.tar.gz"
docker exec grafana ash -c "./prometheus-3.5.0.linux-${ARCH}/prometheus --config.file=prometheus.yml &"
else
  docker restart grafana
  docker exec grafana ash -c "./prometheus-3.5.0.linux-${ARCH}/prometheus --config.file=prometheus.yml &"
fi


# 18316 -- PG Overview