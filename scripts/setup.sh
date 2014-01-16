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
echo "## Install logstash                                              "
echo "#################################################################"
git clone https://github.com/bonusboxme/logstash-rpm --depth=1 setup-logstash

rpmdev-setuptree
cp -r setup-logstash/SPECS/* rpmbuild/SPECS/
cp -r setup-logstash/SOURCES/* rpmbuild/SOURCES/
spectool -g rpmbuild/SPECS/logstash.spec
mv logstash-1.3.1-flatjar.jar rpmbuild/SOURCES/logstash-1.3.1-flatjar.jar
rpmbuild -bb rpmbuild/SPECS/logstash.spec
yum -y install rpmbuild/RPMS/noarch/logstash-1.3.1-1.amzn1.noarch.rpm
rm -rf setup-logstash rpmbuild

cat <<EOF > /etc/logstash/00_syslog.conf
input {
  tcp {
    port => 5544
    type => syslog
  }
  udp {
    port => 5544
    type => syslog
  }
  udp {
    type => "railsjson"
    port => 5545
  }
  tcp {
    type => "railsjson"
    port => 5545
  }
}

filter {
    if [type] == "railsjson" {
       json {
            source => "message"
       }

       if "active_record" in [tags] {
            grok {
                 match => ["message", "\s+(?<sql.action>.*) \(%{NUMBER:sql.duration:float}ms\)\s+(?<sql.query>.*)"]
                 tag_on_failure => []
                 add_tag => "sql"
            }
       }

       if "sql" in [tags] {
          grok {
               match => ["sql.query", "(?<sql.type>INSERT) INTO \"%{WORD:sql.table}\".*"]
               match => ["sql.query", "(?<sql.type>UPDATE) \"%{WORD:table}\".*"]
               match => ["sql.query", "(?<sql.type>DELETE) FROM \"%{WORD:sql.table}\".*"]

               tag_on_failure => []
          }
       }
    }
}
EOF

cat <<EOF > /etc/logstash/99_output.conf
output {
  elasticsearch_http {
    host => "127.0.0.1"
    flush_size => 1
  }
  #sns {
  #  access_key_id => "${SNS_ACCESS_KEY_ID}"
  #  secret_access_key => "${SNS_SECRET_ACCESS_KEY}"
  #  arn => "${SNS_TOPIC}"
  #  publish_boot_message_arn => "${SNS_TOPIC}"
  #  region => "${REGION}"
  #  tags => [ "mail" ]
  #}
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
wget http://download.elasticsearch.org/kibana/kibana/kibana-latest.tar.gz
tar xf kibana-latest.tar.gz -C /usr/share/

## Set correct port for kibana
sed -i "s/9200/80/g" /usr/share/kibana3/config.js

printf "admin:$(openssl passwd -1 $KIBANA_PASSWORD)\n" > /etc/nginx/kibana.htpasswd
chown root:nobody /etc/nginx/kibana.htpasswd
chmod 644 /etc/nginx/kibana.htpasswd

## Create virtual host
cat <<EOF > /etc/nginx/conf.d/kibana3.conf
server {
  listen                *:80 ;

  server_name           ${SERVER_NAME};
  access_log            /var/log/nginx/${SERVER_NAME}.access.log;

  location / {
    root  /usr/share/kibana-latest;
    index  index.html  index.htm;
    auth_basic            "Restricted";
    auth_basic_user_file  /etc/nginx/kibana.htpasswd;
  }

  location ~ ^/_aliases$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
    auth_basic            "Restricted";
    auth_basic_user_file  /etc/nginx/kibana.htpasswd;
  }
  location ~ ^/.*/_search$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
    auth_basic            "Restricted";
    auth_basic_user_file  /etc/nginx/kibana.htpasswd;
  }
  location ~ ^/kibana-int/dashboard/.*$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
    auth_basic            "Restricted";
    auth_basic_user_file  /etc/nginx/kibana.htpasswd;
  }
  location ~ ^/kibana-int/temp.*$ {
    proxy_pass http://127.0.0.1:9200;
    proxy_read_timeout 90;
    auth_basic            "Restricted";
    auth_basic_user_file  /etc/nginx/kibana.htpasswd;
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
chkconfig nginx on
chkconfig logstash on
chkconfig elasticsearch on
