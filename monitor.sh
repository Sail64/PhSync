#!/bin/bash
# Sail 2016-11-12
# 功能：启动监听目录上传的行为，然后添加到redis队列中
#
# monitor.sh和convertor.sh不故意合设，因为可以根据需要启动进程数：一对多或多对一或多对多。
# 另外monitor.sh -r可以中断当前任务。
#
# 支持断点续传：
# 1.正常中断
# 使用monitor.sh -r清空队列，convertor.sh在完成当前任务后会停止
# 2.异常中断
# 包括断电和杀convertor.sh。
# 注意：
# 不管是正常中断还是异常中断，中断后，都要使用monitor.sh -r清空队列，再重新执行monitor.sh生成队列。
# 因为中断后，convertor.sh会把$monitor_dir信息丢失，无法再使用队列中的信息。

monitor_dir=$1

# 包含正在被处理的文件的队列
RDS_QUE=the_queue_which_files_are_processing

# 包含正在上传中的文件的一个Set
RDS_UPL_FILES=the_files_which_are_being_uploaded
file_types=jpg,jpeg,mov,mp4,avi,JPG,JPEG,MOV,MP4,AVI

function is_photo_file()
{
    f=$1
    for ext in ${types_arr[@]}
    do
        if [ "${f##*.}" = "$ext" ]; then
            return 1;
        fi
    done
    
    return 0;
}

function process_existed_files()
{
    #先把当前目录加入到队列，方便接收端拆分
    #redis-cli rpush $RDS_QUE "$monitor_dir" >/dev/null
    #echo "Found directory: %s" $monitor_dir

    #1. 先找目录，让接收者先建立目录
    for dir in $(find $monitor_dir -type d); do
        #dir=${dir#$monitor_dir/}
        printf "Found directory: %s" $dir
        redis-cli rpush $RDS_QUE "$dir" >/dev/null
        echo ", added to queue"
    done
    
    #2. 再找文件
    for file in $(find $monitor_dir -type f); do
        printf "Found %s" $file
        
        is_photo_file $file;
        if [ $? = 1 ]; then
            redis-cli rpush $RDS_QUE "$file" >/dev/null
            printf ", added to queue"
        fi
        
        echo ""  #换行
    done
}

function start_monitor()
{
    # 监控create和close_write
    # create是一新建立马触发，close_write是写完成后触发
    # 只有当两个事件同时出现时，才认定为上传了新的文件。
    inotifywait -m -e create,close_write --format "%T|%e|%w%f" --timefmt "%F %T" -r "$monitor_dir" | 
    (
        while true;
        do
            read line;
            
            # 找到正在上传的文件
            # 加入到Set。
            # 之所以采用Set，是因为可能存在多个终端同时上传文件的情况
            file_uploading=$(echo $line | grep "CREATE" | cut -d'|' -f 3)
            #echo "file_uploading="$file_uploading
            if [ ! -z $file_uploading ]; then
                redis-cli sadd $RDS_UPL_FILES $file_uploading >/dev/null
                #echo redis-cli sadd $RDS_UPL_FILES $file_uploading
                continue
            fi
            
            # 找到一个关闭写动作的文件
            # 这可能是之前上传文件结束，也可能是删除文件或其他变更，
            # 所以需要去Set中查找是否之前上传过的，来判断是否一个新增文件
            file_upload_finished=$(echo $line | grep "CLOSE_WRITE" | cut -d'|' -f 3)
            #echo "file_upload_finished="$file_upload_finished
            if [ ! -z $file_upload_finished ]; then
                result=$(redis-cli sismember $RDS_UPL_FILES "$file_upload_finished")
                # 未找到，跳过
                if [ "$result" != "1" ]; then
                    #echo "File '$file_upload_finished' not found in redis"
                    continue
                fi
            fi
            
            # 到这一步，找到了新上传的文件，需要从Set中删除
            redis-cli srem $RDS_UPL_FILES "$file_upload_finished" >/dev/null
            
            newfile=$file_upload_finished
            printf "Found %s" $newfile
            
            is_photo_file $newfile;
            if [ $? = 1 ]; then
                redis-cli rpush $RDS_QUE "$newfile" >/dev/null
                printf ", added to queue"
            fi

            echo ""  #换行
        done
    )
}

###
while getopts "rl" opt
do
    case $opt in
        r)
            redis-cli del $RDS_QUE  #reset
            exit 0;;
        l)
            redis-cli llen $RDS_QUE  #list
            exit 0;;
    esac
done

if [ ! -d "$monitor_dir" ]; then
    echo "Usage:" `basename $0` [-r] [-l] "<directory>"
    exit 1
fi

# 转换成绝对路径，以保证inotifywait的输出也是绝对路径
monitor_dir=$(realpath "$monitor_dir")

OLD_IFS="$IFS"
IFS=","
types_arr=($file_types)
IFS="$OLD_IFS"

# 先把目录中遗留的文件扔到队列中
process_existed_files;

# 启动监控
start_monitor;
