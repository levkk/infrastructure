#!/bin/bash

read_var () {
    while true
    do
        echo -n $1
        read IN_VAR
        IN_VAR=`echo $IN_VAR | tr -d '[:space:]'`
        echo "Use $IN_VAR for \$$2 is that correct [Y/n]:"
        read Y
        if [ "${Y^^}" = 'Y' ]; then
            printf -v $2 "$IN_VAR"
            return 0
        fi
    done
}


apt-get update -qq && apt-get upgrade 

apt-get install -y \
	sysstat \
	awscli \
	nethogs \
	zfs-initramfs \
	zfs-dkms \
	zfsutils-linux \
	bmon \
    python-pip \
    pv \
    pigz \
    zfSnap \
    bc \
    unzip \
    msmtp \
    msmtp-mta

curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

apt-get install mariadb-server-10.2

pip install pidlock
pip install z3

NUMBER_OF_CPUS=`grep -c ^processor /proc/cpuinfo`

ZPOOL_NAME=databases
ZPOOL_COMPRESSION=lz4

ARC_CACHE_RATIO=0.10

MYSQL_DATABASE_ZFS_DATASET=$ZPOOL_NAME/mysql
MYSQL_LOG_ZFS_DATASET=$ZPOOL_NAME/mysql_logs
ZFS_TMP_DATASET=$ZPOOL_NAME/tmp

read_var "Enter notification email address: " NOTIFICATION_EMAIL


read_var "Enter s3 bucket to use for zfs backups: " Z3_BACKUP_BUCKET
read_var "Enter the s3 prefix to use for zfs backups (probably this machine's name): " Z3_S3_PREFIX


python -c "
import subprocess, sys, json;
while True:
    devices = []
    for x in json.loads(subprocess.check_output(['lsblk', '--json', '--list']))['blockdevices']:
        device_name = '/dev/{}'.format(x['name'])
        if not x['mountpoint'] and not x.get('children'):
            dev = raw_input('use {} {} (y/n)?: '.format(device_name, x['size'])).lower().strip()
            if dev == 'y':
                devices.append(device_name)
    confirm = raw_input('Confirm using these devices {} for the $ZPOOL_NAME ZFS pool (y/n): '.format(','.join(devices)))
    if confirm == 'y':
        print 'Creating zpool $ZPOOL_NAME with {}.'.format(','.join(devices)).lower().strip()
        cmd  = ['zpool', 'create', '-f', '$ZPOOL_NAME'] + devices
        print ' '.join(cmd), '\n'
        subprocess.check_call(cmd)
        sys.exit(0)
"

echo "Setting zpool compression to $ZPOOL_COMPRESSION"
zfs set compression=lz4 $ZPOOL_NAME

zfs create $MYSQL_LOG_ZFS_DATASET
zfs set recordsize=128k $MYSQL_LOG_ZFS_DATASET
zfs set atime=off $MYSQL_LOG_ZFS_DATASET
zfs set primarycache=metadata $MYSQL_LOG_ZFS_DATASET
zfs set mountpoint=/var/log/mysql $MYSQL_DATABASE_ZFS_DATASET


zfs create $ZFS_TMP_DATASET
zfs set recordsize=128k $ZFS_TMP_DATASET
zfs set atime=off $ZFS_TMP_DATASET
zfs set primarycache=metadata $ZFS_TMP_DATASET
zfs set mountpoint=/var/lib/mysql/tmp $MYSQL_DATABASE_ZFS_DATASET



zfs create $MYSQL_DATABASE_ZFS_DATASET
zfs set recordsize=16k $MYSQL_DATABASE_ZFS_DATASET
zfs set atime=off $MYSQL_DATABASE_ZFS_DATASET
zfs set primarycache=metadata $MYSQL_DATABASE_ZFS_DATASET

zfs set mountpoint=/var/lib/mysql $MYSQL_DATABASE_ZFS_DATASET
chown mysql:mysql -R /var/lib/mysql


cat > /etc/rc.local << EOF
#!/bin/sh -e

sysctl -w net.core.somaxconn=1024
sysctl -w vm.swappiness=10

# Disable huge pages it can cause MySQL to stall when it defragments pages.
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo 5 > /sys/module/zfs/parameters/zfs_vdev_async_write_active_min_dirty_percent
echo $ARC_CACHE_LIMIT > /sys/module/zfs/parameters/zfs_arc_max
ARC_CACHE_LIMIT=`cat /proc/meminfo | grep 'MemTotal' | awk '{print $2}' | python -c "import sys; print int(1000 * float(sys.stdin.read()) * float($ARC_CACHE_RATIO))"`

exit 0
EOF

bash /etc/rc.local


Z3_CONCURRENCY="$(($NUMBER_OF_CPUS * 4))"

cat > /etc/z3_backup/z3.conf << EOF
[main]
# # you can override any of these with an environment variable
BUCKET=$Z3_BACKUP_BUCKET
# S3_KEY_ID=
# S3_SECRET=

# number of worker threads used by pput when uploading
CONCURRENCY=$Z3_CONCURRENCY

# number of times to retry uploading failed chunks
MAX_RETRIES=3

# prefix all s3 keys w
S3_PREFIX=$Z3_S3_PREFIX

# what zfs dataset to operate on
FILESYSTEM=$ZPOOL_NAME

# only backup snapshots with this prefix
SNAPSHOT_PREFIX=zfs-auto-snap:daily
EOF


export INCREMENTAL_SNAPSHOT_CRON_EXPR="0 * * * *"
export FULL_SNAPSHOT_CRON_EXPR="30 7 * * *"


cat > crontab << EOF
MAILTO=$NOTIFICATION_EMAIL
PATH=/usr/bin:/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
$INCREMENTAL_SNAPSHOT_CRON_EXPR zfSnap -p autobackups -a 3d -r $ZPOOL_NAME/mysql
$FULL_SNAPSHOT_CRON_EXPR zfSnap -d
$INCREMENTAL_SNAPSHOT_CRON_EXPR sleep 10 && /usr/bin/nice -n 19 sh -c "pidlock -n incremental_backup -c 'chronic sh -c \"z3 backup --compressor pigz4\"'"
$FULL_SNAPSHOT_CRON_EXPR sleep 10 && /usr/bin/nice -n 19 sh -c "pidlock -n full_backup -c 'chronic sh -c \"z3 backup --full --compressor pigz4\"'"
EOF


crontab crontab
