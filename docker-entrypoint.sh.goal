#!/bin/bash

#
# 
# Copyright 2015 Patrick Galbraith 

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

HOSTNAME=`hostname`

if [ "${1:0:1}" = '-' ]; then
  set -- mysqld "$@"
fi

if [ "$1" = 'mysqld' ]; then
  # read DATADIR from the MySQL config
  DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
  
  if [ ! -d "$DATADIR/mysql" ]; then
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
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
DELETE FROM mysql.user ;
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
DROP DATABASE IF EXISTS test ;
EOSQL
    
    if [ "$MYSQL_DATABASE" ]; then
      echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$tempSqlFile"
    fi
    
    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
      echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> "$tempSqlFile"
      
      if [ "$MYSQL_DATABASE" ]; then
        echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> "$tempSqlFile"
      fi
    fi

    if [ -n "$GALERA_CLUSTER" -a "$GALERA_CLUSTER" = true ]; then
      WSREP_SST_USER=${WSREP_SST_USER:-"sst"}
      if [ -z "$WSREP_SST_PASSWORD" ]; then
        echo >&2 'error: database is uninitialized and WSREP_SST_PASSWORD not set'
        echo >&2 '  Did you forget to add -e WSREP_SST_PASSWORD=xxx ?'
        exit 1
      fi

      cp /tmp/cluster.cnf /etc/mysql/conf.d/cluster.cnf

      sed -i -e "s|wsrep_sst_auth \= \"sstuser:changethis\"|wsrep_sst_auth = ${WSREP_SST_USER}:${WSREP_SST_PASSWORD}|" /etc/mysql/conf.d/cluster.cnf

      WSREP_NODE_ADDRESS=`ip addr show | grep -E '^[ ]*inet' | grep -m1 global | awk '{ print $2 }' | sed -e 's/\/.*//'`
      if [ -n "$WSREP_NODE_ADDRESS" ]; then
        sed -i -e "s|^#wsrep_node_address \= .*$|wsrep_node_address = ${WSREP_NODE_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
      fi

      #
      # DEPRECATED: KUBERNETES_RO_SERVICE_HOST removed from v1. 
      # if kubernetes (beta?), take advantage of the metadata, unless of course already set
      #
      if [ -n "$KUBERNETES_RO_SERVICE_HOST" -a -e './kubectl' -a -z "$WSREP_CLUSTER_ADDRESS" ]; then
        WSREP_CLUSTER_ADDRESS=gcomm://
        for node in 1 2 3; do
          WSREP_NODE=`./kubectl --server=${KUBERNETES_RO_SERVICE_HOST}:${KUBERNETES_RO_SERVICE_PORT} get pods| grep "^pxc-node${node}" | tr -d '\n' | awk '{ print $2 }'`
          if [ ! -z $WSREP_NODE ]; then
            if [ $node -gt 1 -a $node != "" ]; then
              WSREP_NODE=",${WSREP_NODE}"
            fi
            WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS}${WSREP_NODE}"
          fi
        done
      fi 
      #
      # TODO:
      # new stuff - this is clunky, yes, and needs to be made dynamic
      # need copy build docker container with kubectl and use kubernetes
      # local API to get list of however many nodes are in the cluster
      # If not set, or user has specified from the pod/rc file to set this,
      # then get clever. The caveat being that kubernetes RO api has been
      # depricated
      #
      if [ -z "$WSREP_CLUSTER_ADDRESS" -o "$WSREP_CLUSTER_ADDRESS" == "gcomm://" ]; then
        if [ -z "$WSREP_CLUSTER_ADDRESS" ]; then
          WSREP_CLUSTER_ADDRESS="gcomm://"
        fi 
        if [ -n "$PXC_NODE1_SERVICE_HOST" ]; then
          if [ $(expr "$HOSTNAME" : 'pxc-node1') -eq 0 ]; then
            WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS}${PXC_NODE1_SERVICE_HOST}"
          fi
        fi
        if [ -n "$PXC_NODE2_SERVICE_HOST" ]; then
          if [ $(expr "$HOSTNAME" : 'pxc-node2') -eq 0 ]; then
            WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS},${PXC_NODE2_SERVICE_HOST}"
          fi
        fi
        if [ -n "$PXC_NODE3_SERVICE_HOST" ]; then
          if [ $(expr "$HOSTNAME" : 'pxc-node3') -eq 0 ]; then
            WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS},${PXC_NODE3_SERVICE_HOST}"
          fi
        fi
      fi 
  
      # Ok, now that we went through the trouble of building up a nice
      # cluster address string, regex the conf file with that value 
      if [ -n "$WSREP_CLUSTER_ADDRESS" -a "$WSREP_CLUSTER_ADDRESS" != "gcomm://" ]; then
        sed -i -e "s|wsrep_cluster_address \= gcomm://|wsrep_cluster_address = ${WSREP_CLUSTER_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
      fi

      echo "CREATE USER '${WSREP_SST_USER}'@'localhost' IDENTIFIED BY '${WSREP_SST_PASSWORD}';" >> "$tempSqlFile"
      echo "GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${WSREP_SST_USER}'@'localhost';" >> "$tempSqlFile"
    fi
    echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"
    
    set -- "$@" --init-file="$tempSqlFile"
  fi
  
  chown -R mysql:mysql "$DATADIR"
fi

exec "$@"
