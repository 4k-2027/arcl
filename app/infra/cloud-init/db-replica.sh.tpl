#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y postgresql postgresql-contrib python3-pip python3-dev libpq-dev

pip3 install --quiet patroni[etcd] psycopg2-binary

PG_VERSION=14

systemctl stop postgresql || true
systemctl disable postgresql || true

mkdir -p /data/patroni
chown postgres:postgres /data/patroni
chmod 700 /data/patroni

cat > /etc/patroni.yml << EOF
scope: todo-db
namespace: /db/
name: db-replica

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${replica_ip}:8008

etcd:
  host: ${master_ip}:2379

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${replica_ip}:5432
  data_dir: /data/patroni
  bin_dir: /usr/lib/postgresql/$PG_VERSION/bin
  authentication:
    replication:
      username: replicator
      password: "${replication_password}"
    superuser:
      username: postgres
      password: "${db_password}"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

cat > /etc/systemd/system/patroni.service << 'EOF'
[Unit]
Description=Patroni
After=network.target

[Service]
User=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable patroni
systemctl start patroni
