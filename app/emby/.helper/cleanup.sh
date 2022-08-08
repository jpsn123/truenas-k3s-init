#!/bin/bash

set -e

EMBY_DATA_PATH='/mnt/fast/k8s/pvc-emby-emby-config'

## delete search9
sqlite3 $EMBY_DATA_PATH/data/library.db " \
    drop table fts_search9; \
    " || true

## delete unused actors
sqlite3 $EMBY_DATA_PATH/data/library.db " \
    delete from itemlinks2 where linkedid in (select id from mediaitems where type=23 except select personid from itempeople2); \
    delete from itemlinks2 where itemid in (select id from mediaitems where type=23 except select personid from itempeople2); \
    delete from mediastreams2 where itemid in (select id from mediaitems where type=23 except select personid from itempeople2); \
    delete from userdatas where userdatakeyid in (select userdatakeyid from mediaitems where id in (select id from mediaitems where type=23 except select personid from itempeople2)); \
    delete from mediaitems where id in (select id from mediaitems where type=23 except select personid from itempeople2); \
    "

## cleanup database
sqlite3 $EMBY_DATA_PATH/data/library.db " \
    delete from userdatas where userdatakeyid in (select id from userdatakeys2 except select userdatakeyid from mediaitems); \
    delete from userdatakeys2 where id in (select id from userdatakeys2 except select userdatakeyid from mediaitems); \
    "

## delete unsed actors metadata
rm /tmp/A -rf
rm /tmp/B -rf
rm /tmp/C -rf
sqlite3 $EMBY_DATA_PATH/data/library.db \
    "select images from mediaitems where type=23 and images is not null;" | grep %MetadataPath%/people/ | sed "s#%MetadataPath%/people/##g" | sed "s#/folder.*##g" >/tmp/A
ls -A1 $EMBY_DATA_PATH/metadata/people/ >/tmp/B
cat /tmp/A /tmp/B | sort | uniq -u >/tmp/C
while IFS= read -r line; do
    echo -e "\033[33m   delete actor metadata files: $line  \033[0m"
    rm -rf -- "$EMBY_DATA_PATH/metadata/people/$line"
done </tmp/C

## delete unsed tags metadata
rm /tmp/A -rf
rm /tmp/B -rf
rm /tmp/C -rf
sqlite3 $EMBY_DATA_PATH/data/library.db \
    "select images from mediaitems where type=34;" | grep tags | sed "s#%MetadataPath%/tags/##g" | sed "s#/auto_poster_.*##g" >/tmp/A
ls -A1 $EMBY_DATA_PATH/metadata/tags/ >/tmp/B
cat /tmp/A /tmp/B | sort | uniq -u >/tmp/C
while IFS= read -r line; do
    echo -e "\033[33m   delete tags metadata files: $line  \033[0m"
    rm -rf -- "$EMBY_DATA_PATH/metadata/tags/$line"
done </tmp/C

## delete unsed genres metadata
rm /tmp/A -rf
rm /tmp/B -rf
rm /tmp/C -rf
sqlite3 $EMBY_DATA_PATH/data/library.db \
    "select images from mediaitems where type=21;" | grep genres | sed "s#%MetadataPath%/genres/##g" | sed "s#/auto_poster_.*##g" >/tmp/A
ls -A1 $EMBY_DATA_PATH/metadata/genres/ >/tmp/B
cat /tmp/A /tmp/B | sort | uniq -u >/tmp/C
while IFS= read -r line; do
    echo -e "\033[33m   delete genres metadata files: $line  \033[0m"
    rm -rf -- "$EMBY_DATA_PATH/metadata/genres/$line"
done </tmp/C

## only reserve latest poster
for i in $EMBY_DATA_PATH/metadata/library/*/*; do
    ls -A1t -- "$i" | grep auto_poster | tail +2 >/tmp/D
    while IFS= read -r line; do
        echo -e "\033[33m   delete auto post: $i/$line  \033[0m"
        rm -rf -- "$i/$line"
    done </tmp/D
done

for i in $EMBY_DATA_PATH/metadata/tags/*; do
    ls -A1t -- "$i" | tail +2 >/tmp/D
    while IFS= read -r line; do
        echo -e "\033[33m   delete auto post: $i/$line  \033[0m"
        rm -rf -- "$i/$line"
    done </tmp/D
done

for i in $EMBY_DATA_PATH/metadata/genres/*; do
    ls -A1t -- "$i" | tail +2 >/tmp/D
    while IFS= read -r line; do
        echo -e "\033[33m   delete auto post: $i/$line  \033[0m"
        rm -rf -- "$i/$line"
    done </tmp/D
done

## show duplicate actor
echo -e "\033[31m   Show duplicate actor  \033[0m"
sqlite3 $EMBY_DATA_PATH/data/library.db "select name from mediaitems where type=23;" | sort | uniq -d
echo -e "\033[31m   --------------------  \033[0m"

## show no actor  video
echo -e "\033[31m   Show video no actor  \033[0m"
sqlite3 $EMBY_DATA_PATH/data/library.db "select name from mediaitems where id in (select id from mediaitems where type=5 except select itemid from itempeople2);" | sort
echo -e "\033[31m   --------------------  \033[0m"
