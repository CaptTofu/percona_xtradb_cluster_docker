FROM debian:jessie

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

ENV PERCONA_VERSION="56" MYSQL_VERSION="5.6" KUBERNETES_VERSION="1.3.2" TERM="linux"

RUN apt-get update && \
    apt-get dist-upgrade -y && \
    apt-get install wget apt-transport-https -y && \
    wget https://repo.percona.com/apt/percona-release_0.1-3.jessie_all.deb && \
    dpkg -i percona-release_0.1-3.jessie_all.deb && \
    rm -f percona-release_0.1-3.jessie_all.deb && \
    { \
        echo percona-server-server-${MYSQL_VERSION} percona-server-server/data-dir select ''; \
        echo percona-server-server-${MYSQL_VERSION} percona-server-server/root_password password ''; \
    } | debconf-set-selections && \
    apt-get update && \
    DEBIAN_FRONTEND=nointeractive apt-get install -y percona-xtradb-cluster-"${PERCONA_VERSION}" && \
    rm -rf /var/lib/mysql && \
    mkdir -p /var/lib/mysql && \
    chown -R mysql:mysql /var/lib/mysql && \
    sed -i -r "s/^[#]?server-id.*=.*/server-id = ${RANDOM}/" /etc/mysql/my.cnf && \
    wget "https://storage.googleapis.com/kubernetes-release/release/v$KUBERNETES_VERSION/bin/linux/amd64/kubectl" -O /usr/bin/kubectl && \
    chmod 755 /usr/bin/kubectl && \
    rm -rf /var/lib/apt/lists/* /tmp/*
# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter

COPY cluster.cnf /cluster.cnf
COPY logging.cnf /etc/mysql/conf.d/logging.cnf
COPY docker-entrypoint.sh /entrypoint.sh

VOLUME /var/lib/mysql

EXPOSE 3306 4444 4567 4568

ENTRYPOINT ["/entrypoint.sh"]
CMD ["mysqld"]
