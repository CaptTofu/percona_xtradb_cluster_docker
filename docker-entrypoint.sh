#!/bin/bash

#
# Copyright 2015 Patrick Galbraith
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
#
# I am not particularly fond of this script as I would prefer
# using confd to do this ugly work. Confd functionality is being
# built into kubernetes as I write this which may replace this
#
# also important here is that this script will work outside of
# Kubernetes as long as the container is run with the correct
# environment variables passed to replace discovery that
# Kubernetes provides
#
set -e

if [ -n "$DEBUG" ]; then
    set -x
fi

HOSTNAME="$(hostname)"

if [ "${1:0:1}" = '-' ]; then
  set -- mysqld "$@"
fi

if [ "$1" = 'mysqld' ]; then
    # read DATADIR from the MySQL config
    DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
    IP_ADDRESS="$(ip addr show | grep -E '^[ ]*inet' | grep -m1 global | awk '{ print $2 }' | sed -e 's/\/.*//')"
    if [ ! -d "$DATADIR/mysql" ]; then
        if [ -z  "$MYSQL_ROOT_PASSWORD" ] && [ -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
            echo >&2 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
            echo >&2 '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
            exit 1
        fi
        echo 'Running mysql_install_db ...'
        mysql_install_db --datadir="$DATADIR"
        echo 'Finished mysql_install_db'
        # These statements _must_ be on individual lines, and _must_ end with
        # semicolons (no line breaks or comments are permitted).
        # TODO proper SQL escaping on ALL the things D:
        tempSqlFile='/tmp/mysql-first-time.sql'
        cat > "$tempSqlFile" <<-EOSQL
DELETE FROM mysql.user;
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
DROP DATABASE IF EXISTS test;
EOSQL
        if [ -n "$MYSQL_DATABASE" ]; then
            echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;" >> "$tempSqlFile"
        fi
        if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
            echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" >> "$tempSqlFile"
            if [ "$MYSQL_DATABASE" ]; then
                echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%';" >> "$tempSqlFile"
            fi
        fi
        if [ -n "$GALERA_CLUSTER" ] && [ "$GALERA_CLUSTER" = true ]; then
            echo "CREATE USER '${WSREP_SST_USER}'@'localhost' IDENTIFIED BY '${WSREP_SST_PASSWORD}';" >> "$tempSqlFile"
            echo "GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${WSREP_SST_USER}'@'localhost';" >> "$tempSqlFile"
        fi
        echo 'FLUSH PRIVILEGES;' >> "$tempSqlFile"
        set -- "$@" --init-file="$tempSqlFile"
    fi
    # Currently only working with kubernetes clusters that use serviceaccount tokens with https (ca.crt)
    if [ -n "$GALERA_CLUSTER" ] && [ "$GALERA_CLUSTER" = true ]; then
        mv /cluster.cnf /etc/mysql/conf.d/cluster.cnf
        WSREP_SST_USER=${WSREP_SST_USER:-"sst"}
        if [ -z "$WSREP_SST_PASSWORD" ]; then
            echo >&2 'error: database is uninitialized and WSREP_SST_PASSWORD not set'
            echo >&2 '  Did you forget to add -e WSREP_SST_PASSWORD=xxx ?'
            exit 1
        fi
        sed -ie "s|wsrep_sst_auth \= \"sstuser:changethis\"|wsrep_sst_auth = ${WSREP_SST_USER}:${WSREP_SST_PASSWORD}|" /etc/mysql/conf.d/cluster.cnf
        if [ -n "$IP_ADDRESS" ]; then
            sed -ie "s|^wsrep_node_address \= .*$|wsrep_node_address = ${IP_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
        fi
        if [ -n "$KUBERNETES_SERVICE_HOST" ] && ([ -z "$WSREP_CLUSTER_ADDRESS" ] || [ "$WSREP_CLUSTER_ADDRESS" = "gcomm://" ]); then
            WSREP_CLUSTER_ADDRESS="gcomm://"
            WSREP_NODES=($(kubectl --server="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}" --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" --namespace="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)" --certificate-authority="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" get svc | grep "^pxc-node" | awk '{ print $1 }'))
            if [ ${#WSREP_NODES[@]} -gt 1 ]; then
                for WSREP_NODE in "${WSREP_NODES[@]}"; do
                    if [ -n "$WSREP_NODE" ] && [[ $HOSTNAME != *"$WSREP_NODE"* ]]; then
                        WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS}${WSREP_NODE},"
                    fi
                done
                WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS::-1}"
            fi
        fi
        # Ok, now that we went through the trouble of building up a nice
        # cluster address string, regex the conf file with that value
        if [ -n "$WSREP_CLUSTER_ADDRESS" ] && [ "$WSREP_CLUSTER_ADDRESS" != "gcomm://" ]; then
            sed -ie "s|wsrep_cluster_address \= gcomm://|wsrep_cluster_address = ${WSREP_CLUSTER_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
        fi
    fi
    sed -ie "s/^bind-address.*=.*$/bind-address = $IP_ADDRESS/g" /etc/mysql/my.cnf
    chown -R mysql:mysql "$DATADIR"
fi

# TODO make this more dynamic to allow multiple categories (like mysqld, )
# like CNF_MYSQLD_wsrep_retry_autocommit to the
given_settings=($(env | sed -n -r "s/CNF_MYSQLD_([0-9A-Za-z_]*).*/\1/p"))
if [ ${#given_settings[@]} -gt 0 ]; then
    echo "[mysqld]" > /etc/mysql/conf.d/custom.cfg
    for setting_key in "${given_settings[@]}"; do
        key="CNF_MYSQLD_$setting_key"
        setting_var="${!key}"
        echo "$setting_key = $setting_var" >> /etc/mysql/conf.d/custom.cfg
    done
fi

exec "$@"
