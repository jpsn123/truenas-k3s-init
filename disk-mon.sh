#!/bin/bash 
path=/root/
echo $path
mkdir -p $path
if [ ! -d "$path/Disks" ];then
    mkdir $path/Disks;
fi
dsk=`ls /dev/|grep 'sd[a-z]$'`  # 硬盘一般是sda  sdb  sdc以此类推
while true
do
    echo `date +%c`                 
    for i in $dsk
    do
        echo -n "/dev/$i : " 
        s=`smartctl -i -n standby /dev/$i|grep "mode"|awk '{print $4}' ` # 正儿八经的Linux系统可以用这个，也可以用下面那个
#        s=` hdparm -C /dev/$i|grep "drive state is:" |awk '{print $4}'|awk -F "/" '{print $1}'` 
         #群晖必须用这一条，因为使用smartd查看HDD的状态可能会提示该设备未打开smart支持，但是实际上是能够在DSM的存储空间管理员中看到相应磁盘的smart信息的，应该是DSM自带的smartctl工具有问题
        if [[ -f "$path/Disks/$i.status" ]];then
            st=`cat $path/Disks/$i.status`
        else
            st=''
            touch $path/Disks/$i.status
        fi
        echo $s>$path/Disks/$i.status
        if [[ $s != $st ]];then
            echo `date +%c`>>$path/Disks/chkdisk.log
            echo -n "/dev/$i : ">>$path/Disks/chkdisk.log
            echo $s>>$path/Disks/chkdisk.log
        fi    
        echo $s
    done
    sleep 2
done
exit

