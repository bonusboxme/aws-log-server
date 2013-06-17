#!/bin/sh

source $(dirname $0)/vars.sh

echo "#################################################################"
echo "## Raid configuration                                            "
echo "#################################################################"

## Waiting for EBS mounts to become available
while [ ! -e /dev/sdh1 ]; do echo waiting for /dev/sdh1 to attach; sleep 10; done
while [ ! -e /dev/sdh2 ]; do echo waiting for /dev/sdh2 to attach; sleep 10; done
while [ ! -e /dev/sdh3 ]; do echo waiting for /dev/sdh3 to attach; sleep 10; done
while [ ! -e /dev/sdh4 ]; do echo waiting for /dev/sdh4 to attach; sleep 10; done

## Create RAID10 and persist configuration
mdadm --create /dev/md0 --level=10 --chunk=256 --raid-devices=4 /dev/sdh1 /dev/sdh2 /dev/sdh3 /dev/sdh4
echo '`mdadm --detail --scan`' | tee -a /etc/mdadm.conf

## Set read-ahead on each device
blockdev --setra 128 /dev/md0
blockdev --setra 128 /dev/sdh1
blockdev --setra 128 /dev/sdh2
blockdev --setra 128 /dev/sdh3
blockdev --setra 128 /dev/sdh4

## Create physical and logical volumes
dd if=/dev/zero of=/dev/md0 bs=512 count=1
pvcreate /dev/md0
vgcreate vg0 /dev/md0
lvcreate -l 95%vg -n data vg0
lvcreate -l 5%vg -n log vg0

## Create filesystems and mount point info
mke2fs -t ext4 -F /dev/vg0/data
mke2fs -t ext4 -F /dev/vg0/log

mkdir /var/lib/elasticsearch
mkdir /var/log/elasticsearch

echo '/dev/vg0/data /var/lib/elasticsearch ext4 defaults,auto,noatime,noexec 0 0' | tee -a /etc/fstab
echo '/dev/vg0/log /var/log/elasticsearch ext4 defaults,auto,noatime,noexec 0 0' | tee -a /etc/fstab

mount /var/lib/elasticsearch
mount /var/log/elasticsearch

echo "#################################################################"
echo "## Install elasticsearch                                         "
echo "#################################################################"
wget https://download.elasticsearch.org/elasticsearch/elasticsearch/elasticsearch-0.90.1.noarch.rpm
yum -y install elasticsearch-0.90.1.noarch.rpm
rm -f elasticsearch-0.90.1.noarch.rpm
/etc/init.d/elasticsearch stop

## Set permissions
chown -R elasticsearch:elasticsearch /var/lib/elasticsearch
chown -R elasticsearch:elasticsearch /var/log/elasticsearch

## Update elasticsearch configuration
cat <<EOF >> /etc/elasticsearch/elasticsearch.yml

cluster.name: elasticsearch
node.name: ${NODE_NAME}
path.conf: /etc/elasticsearch
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
EOF

echo "#################################################################"
echo "## Install grok                                                  "
echo "#################################################################"
git clone https://github.com/jordansissel/grok.git --depth=1 setup-grok
cd setup-grok
make
make install
cd ..
rm -rf setup-grok

echo "#################################################################"
echo "## Install logstash                                              "
echo "#################################################################"
git clone https://github.com/dephub/logstash-rpm.git --depth=1 setup-logstash
rpmdev-setuptree
cp -r setup-logstash/SPECS/* rpmbuild/SPECS/
cp -r setup-logstash/SOURCES/* rpmbuild/SOURCES/
spectool -g rpmbuild/SPECS/logstash.spec
mv logstash-1.1.12-flatjar.jar rpmbuild/SOURCES/logstash-1.1.12-flatjar.jar
rpmbuild -bb rpmbuild/SPECS/logstash.spec
yum -y install rpmbuild/RPMS/noarch/logstash-1.1.12-1.amzn1.noarch.rpm
rm -rf setup-logstash rpmbuild

cat <<EOF > /etc/logstash/syslog.conf
input {
  tcp {
    port => 5544
    type => syslog
  }
  udp {
    port => 5544
    type => syslog
  }
  gelf {
    port => 12201
    tags => [ "error", "java" ]
    type => gelf
  }
}

filter {
  grok {
    type => "syslog"
    pattern => [ "<%{POSINT:syslog_pri}>%{SYSLOGTIMESTAMP:syslog_timestamp} %{SYSLOGHOST:syslog_hostname} %{DATA:syslog_program}(?:\[%{POSINT:syslog_pid}\])?: %{GREEDYDATA:syslog_message}" ]
    add_field => [ "received_at", "%{@timestamp}" ]
    add_field => [ "received_from", "%{@source_host}" ]
  }
  syslog_pri {
    type => "syslog"
    add_tag => "%{syslog_severity}"
  }
  date {
    type => "syslog"
    match => [ "syslog_timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
  }
  mutate {
    type => "syslog"
    exclude_tags => "_grokparsefailure"
    replace => [ "@source_host", "%{syslog_hostname}" ]
    replace => [ "@message", "%{syslog_message}" ]
  }
  mutate {
    type => "syslog"
    remove => [ "syslog_hostname", "syslog_message", "syslog_timestamp" ]
  }
  mutate {
    type => "syslog"
    gsub => ["@message", "\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]", ""]
  }
  grep {
    match => [ "@tags", "warning|warn|error|err|critical|crit|alert|emergency|emerg|panic" ]
    add_tag => [ "mail" ]
  }
}

output {
  elasticsearch_http {
    host => "127.0.0.1"
    flush_size => 1
  }
  sns {
    access_key_id => "${SNS_ACCESS_KEY_ID}"
    secret_access_key => "${SNS_SECRET_ACCESS_KEY}"
    arn => "${SNS_TOPIC}"
    publish_boot_message_arn => "${SNS_TOPIC}"
    region => "${REGION}"
    tags => [ "mail" ]
  }
}
EOF

echo "#################################################################"
echo "## Configure rsyslog                                             "
echo "#################################################################"
cat <<EOF > /etc/rsyslog.d/logstash.conf
\$WorkDirectory /var/lib/rsyslog # where to place spool files
\$ActionQueueFileName logstash # unique name prefix for spool files
\$ActionQueueMaxDiskSpace 1g   # 1gb space limit (use as much as possible)
\$ActionQueueSaveOnShutdown on # save messages to disk on shutdown
\$ActionQueueType LinkedList   # run asynchronously
\$ActionResumeRetryCount -1    # infinite retries if host is down
*.* @@127.0.0.1:5544
EOF

echo "#################################################################"
echo "## Install Kibana                                                "
echo "#################################################################"
git clone https://github.com/elasticsearch/kibana.git --depth=1 /usr/share/kibana3

## Set correct port for kibana
sed -i "s/9200/80/g" /usr/share/kibana3/config.js

## Create virtual host
cat <<EOF > /etc/nginx/conf.d/kibana3.conf
server {
  listen                *:80 ;

  server_name           ${SERVER_NAME};
  access_log            /var/log/nginx/${SERVER_NAME}.access.log;

  location / {
    root  /usr/share/kibana3;
    index  index.html  index.htm;
  }

  location ~ ^/_aliases$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
  }
  location ~ ^/.*/_search$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
  }
  location ~ ^/kibana-int/dashboard/.*$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
  }
  location ~ ^/kibana-int/temp.*$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
  }
}
EOF

echo "#################################################################"
echo "## Start/Restart services                                        "
echo "#################################################################"
/etc/init.d/nginx start
/etc/init.d/elasticsearch start
/etc/init.d/logstash start
/etc/init.d/rsyslog restart
