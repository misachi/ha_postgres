# ha_postgres

Run a highly available Postgres cluster using docker containers as nodes for Postgres servers. Additionally continous backups can be set up with Barman running as a separate container(remote node). You can also add visualizations(?) to your cluster with Grafana dashboards.

```
export ARCHIVE_DIR=/path/for/archiving
sudo chown -R 991:991 $ARCHIVE_DIR
export BACKUP_DIR=/path/to/backup/data  # ARCHIVE_DIR and BACKUP_DIR should be separate directories
sudo chown -R 991:991 $BACKUP_DIR

./run_pg.sh <node number> <port>  e.g nohup ./run.sh 1 5432 > /tmp/test.1 &, nohup ./run.sh 2 5433 > /tmp/test.2 &, nohup ./run.sh 3 5434 > /tmp/test.3 &
./barman
./grafana
```

After every script has ran to completion, check the browser on http://localhost:3000 to access Grafana