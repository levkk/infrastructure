#!/bin/bash

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
    pigz


pip install pidlock
pip install z3


ZPOOL_NAME=tide
ZPOOL_COMPRESSION=lz4

ARC_CACHE_RATIO=0.10

MYSQL_DATABASE_ZFS_DATASET=$ZPOOL_NAME/mysql
MYSQL_LOG_ZFS_DATASET=$ZPOOL_NAME/mysql_logs
ZFS_TMP_DATASET=$ZPOOL_NAME/tmp


cat > /etc/rc.local << EOF
#!/bin/sh -e

sysctl -w net.core.somaxconn=1024
sysctl -w vm.swappiness=10

# Disable huge pages it can cause MySQL to stall when it defragments pages.
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
exit 0
EOF



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

echo "Setting arc cache limit to $ARC_CACHE_LIMIT bytes"
ARC_CACHE_LIMIT=`cat /proc/meminfo | grep 'MemTotal' | awk '{print $2}' | python -c "import sys; print int(1000 * float(sys.stdin.read()) * float($ARC_CACHE_RATIO))"`
echo $ARC_CACHE_LIMIT > /sys/module/zfs/parameters/zfs_arc_max
echo 5 > /sys/module/zfs/parameters/zfs_vdev_async_write_active_min_dirty_percent

