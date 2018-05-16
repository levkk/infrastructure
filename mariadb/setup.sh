#!/bin/bash
set -e

read_var () {
    # read_var (MSG, VAR_NAME)
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

read_var_from_path () {
    # read_var_from_path(PATH, VAR_NAME, MSG)
    if stat $1 > /dev/null; then
        printf -v $2 `cat $1`
        echo "Read $2=`echo $2` from $1"
    else
        read_var "$3" "$2"
        echo -n ${!2} > $1
    fi
}

apt-get update -qq && apt-get upgrade 

apt-get install -y \
	sysstat \
	awscli \
	nethogs \
    moreutils \
	zfs-initramfs \
	zfs-dkms \
	zfsutils-linux \
	bmon \
    python-pip \
    pv \
    pigz \
    zfsnap \
    bc \
    unzip \
    msmtp \
    msmtp-mta


if stat ~/.mariadb_repo_setup &> /dev/null; then
    echo "Already added mariadb repo"
else
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
    echo "Added mariadb repo" > ~/.mariadb_repo_setup
fi

pip install pidlock
pip install z3

NUMBER_OF_CPUS=`grep -c ^processor /proc/cpuinfo`

ZPOOL_NAME=databases
ZPOOL_COMPRESSION=lz4

ARC_CACHE_RATIO=0.10

MYSQL_BUFFER_POOL_RATIO=0.75
MYSQL_DATABASE_ZFS_DATASET=$ZPOOL_NAME/mysql
MYSQL_LOG_ZFS_DATASET=$ZPOOL_NAME/mysql_logs
ZFS_TMP_DATASET=$ZPOOL_NAME/tmp
NOTIFICATION_EMAIL_PATH=~/.notification_email
SNAPSHOT_PREFIX=zfsautosnapshots

read_var_from_path ~/.MYSQL_SERVER_ID MYSQL_SERVER_ID "Please enter a numeric MySQL server ID (do not reuse an ID unless you know what you're doing): "

read_var_from_path ~/.notification_email NOTIFICATION_EMAIL "Enter notification email address: "
read_var_from_path ~/.Z3_BACKUP_BUCKET Z3_BACKUP_BUCKET "Enter s3 bucket to use for zfs backups: "
read_var_from_path ~/.Z3_S3_PREFIX Z3_S3_PREFIX "Enter the s3 prefix to use for zfs backups (probably this machine's name): "
read_var_from_path ~/.Z3_S3_KEY_ID Z3_S3_KEY_ID "Enter an IAM Access Key ID for a user with permissions to write to $Z3_BACKUP_BUCKET: "
read_var_from_path ~/.Z3_S3_SECRET Z3_S3_SECRET "Enter an IAM Access Secret for a user with permissions to write to $Z3_BACKUP_BUCKET: "


if zfs list  | grep $ZPOOL_NAME ; then
    echo "Skipping ZFS pool setup (it's $ZPOOL_NAME exists)."
else
    echo "Setting up ZFS pool."
    python -c "
import subprocess, sys, json;
while True:
    devices = []
    for x in json.loads(subprocess.check_output(['lsblk', '--json', '--list']))['blockdevices']:
        device_name = '/dev/{}'.format(x['name'])
        if not x['mountpoint'] and not x.get('children'):
            dev = raw_input('use {} {} for ZFS pool (y/n)?: '.format(device_name, x['size'])).lower().strip()
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

    echo "Creating $MYSQL_LOG_ZFS_DATASET"
    zfs create $MYSQL_LOG_ZFS_DATASET
    zfs set recordsize=128k $MYSQL_LOG_ZFS_DATASET
    zfs set atime=off $MYSQL_LOG_ZFS_DATASET
    zfs set primarycache=metadata $MYSQL_LOG_ZFS_DATASET
    zfs set mountpoint=/var/log/mysql $MYSQL_LOG_ZFS_DATASET


    echo "Creating $MYSQL_DATABASE_ZFS_DATASET"
    zfs create $MYSQL_DATABASE_ZFS_DATASET
    zfs set recordsize=16k $MYSQL_DATABASE_ZFS_DATASET
    zfs set atime=off $MYSQL_DATABASE_ZFS_DATASET
    zfs set primarycache=metadata $MYSQL_DATABASE_ZFS_DATASET

    zfs set mountpoint=/var/lib/mysql $MYSQL_DATABASE_ZFS_DATASET
    chown mysql:mysql -R /var/lib/mysql

    echo "Creating $ZFS_TMP_DATASET"
    zfs create $ZFS_TMP_DATASET
    zfs set recordsize=128k $ZFS_TMP_DATASET
    zfs set atime=off $ZFS_TMP_DATASET
    zfs set primarycache=metadata $ZFS_TMP_DATASET
    zfs set mountpoint=/var/lib/mysql_tmp $ZFS_TMP_DATASET
fi


apt-get install mariadb-server-10.2

ARC_CACHE_LIMIT=`cat /proc/meminfo | grep 'MemTotal' | awk '{print $2}' | python -c "import sys; print int(1000 * float(sys.stdin.read()) * float($ARC_CACHE_RATIO))"`
MYSQL_BUFFER_POOL=`cat /proc/meminfo | grep 'MemTotal' | awk '{print $2}' | python -c "import sys; print int(1000 * float(sys.stdin.read()) * float($MYSQL_BUFFER_POOL_RATIO))"`


if stat ~/.mariadb_my_cnf_copied &> /dev/null; then
    echo "Already compied default my.cnf to /var/lib/mysql/my.cnf"
else
    echo "Copying default my.cnf to /var/lib/mysql/my.cnf"
    echo "Stopping MySQL server"
    sudo service mysql stop
    template_file=master-my.cnf
    template="$(cat ${template_file})"
    eval "echo \"${template}\"" > /etc/mysql/my.cnf
    echo "Copied my.cnf" > ~/.mariadb_my_cnf_copied
    echo "Starting MySQL server"
    sudo service mysql start
fi

cat > /etc/rc.local << EOF
#!/bin/sh -e

sysctl -w net.core.somaxconn=1024
sysctl -w vm.swappiness=10

# Disable huge pages it can cause MySQL to stall when it defragments pages.
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo 5 > /sys/module/zfs/parameters/zfs_vdev_async_write_active_min_dirty_percent
echo $ARC_CACHE_LIMIT > /sys/module/zfs/parameters/zfs_arc_max

exit 0
EOF

bash /etc/rc.local


Z3_CONCURRENCY="$(($NUMBER_OF_CPUS * 4))"
mkdir -p /etc/z3_backup/
cat > /etc/z3_backup/z3.conf << EOF
[main]
# # you can override any of these with an environment variable
BUCKET=$Z3_BACKUP_BUCKET
S3_KEY_ID=$Z3_S3_KEY_ID
S3_SECRET=$Z3_S3_SECRET

# number of worker threads used by pput when uploading
CONCURRENCY=$Z3_CONCURRENCY

# number of times to retry uploading failed chunks
MAX_RETRIES=3

# prefix all s3 keys w
S3_PREFIX=$Z3_S3_PREFIX

# what zfs dataset to operate on
FILESYSTEM=$MYSQL_DATABASE_ZFS_DATASET

# only backup snapshots with this prefix
SNAPSHOT_PREFIX=$SNAPSHOT_PREFIX
EOF


export INCREMENTAL_SNAPSHOT_CRON_EXPR="0 * * * *"
export FULL_SNAPSHOT_CRON_EXPR="30 7 * * *"


cat > crontab << EOF
MAILTO=$NOTIFICATION_EMAIL
PATH=/usr/bin:/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
$INCREMENTAL_SNAPSHOT_CRON_EXPR zfSnap -p $SNAPSHOT_PREFIX -a 3d -r $ZPOOL_NAME/mysql
$FULL_SNAPSHOT_CRON_EXPR zfSnap -d
$INCREMENTAL_SNAPSHOT_CRON_EXPR sleep 10 && /usr/bin/nice -n 19 sh -c "pidlock -n incremental_backup -c 'chronic sh -c \"z3 backup --compressor pigz4\"'"
$FULL_SNAPSHOT_CRON_EXPR sleep 10 && /usr/bin/nice -n 19 sh -c "pidlock -n full_backup -c 'chronic sh -c \"z3 backup --full --compressor pigz4\"'"
EOF

crontab crontab
