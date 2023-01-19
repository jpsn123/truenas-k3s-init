#!/bin/bash

dsk=`ls /dev/sd* | grep -Po 'sd(a{2}|[a-z]+)$'`
echo `date +%c`
printf "%-11s %-10s %-40s %-10s\n" Disk Stats DiskLable Capacity 
standby=0
active=0
unknown=0
c=0

for i in $dsk;
do
#echo -e "\n";
#echo -e "-----------------------";
printf "%-11s"  /dev/$i:;
#echo -n -e "/dev/$i :\t" ;
stats=`hdparm -C /dev/$i|grep "drive state is:" |awk '{print $4}'|awk -F "/" '{print $1}'`;
#echo $stats
if [[ $stats == STANDBY ]]||[[ $stats == ACTIVE ]]||[[ $stats == IDLE_A ]]
then
   for s in $stats;
   do
   if [ $s == STANDBY ]
   then
#      printf("[%-8s]" "\033[1;30;42m STANDBY \033[0m");
      echo -e -n "\033[30;42mSTANDBY\033[0m"
      printf "%-5s" ;
      let standby=$standby+1
   else
      echo -e -n "\033[37;41mACTIVE \033[0m"
      printf "%-5s" ;
      let active=$active+1
   fi
   done
else
   echo -e -n "\033[30;47mUNKNOWN\033[0m"
   printf "%-5s" ;
   let unknown=$unknown+1
   for un in $i
   do
     list[c]=$un
     ((c++))
   done
fi
#输出mountpoint之前判断是否mount
mountpoint=`lsblk /dev/$i|grep "/srv/dev-disk-by-label-"|awk '{print $7}'`;
if [[ $mountpoint == */srv/dev* ]]
then
   printf "%-40s" "`lsblk /dev/$i|grep "/srv/dev-disk-by-label-"|awk '{print $7}'`";
else
   echo -n Not Mounted! ;
fi

#printf "%-40s" "`lsblk /dev/$i|grep "/srv/dev-disk-by-label-"|awk '{print $7}'`";
printf "%-10s\n" `lsblk /dev/$i|grep "/srv/dev-disk-by-label-"|awk '{print $4}'`;
#echo -n -e "`lsblk /dev/$i|grep "/srv/dev-disk-by-label-"|awk '{print $7}'`\t";#lable
#echo -n -e "\t" #释义:-n 为echo输出后不换行 -e和\t组合表示插入tab制表符 方便输出统一格式
#echo -e `lsblk /dev/$i|grep "/srv/dev-disk-by-label-"|awk '{print $4}'`; #capacity
done

#各状态硬盘数量统计显示
echo -e "\n";
echo -e "\033[37;41mActive  Disk in Total=$active  \033[0m";
echo -e "\033[30;42mStandby Disk in Total=$standby  \033[0m";
echo -e "\033[30;47mUnknown Disk in Total=$unknown   \033[0m";
#echo $c
echo -e "Unknown Disk list: ";
for((b=0;b<=$c;b++));
do
  if [[ $b -lt $c ]]
  then
  echo "/dev/${list[b]}"
  fi
done
echo -e "\n";
exit
