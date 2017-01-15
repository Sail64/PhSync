#!/bin/bash
#
# Sail 2016-11-12
#
# 从redis队列中获取上传的文件名，然后作转换处理
# monitor.sh和convertor.sh故意不合设，因为可以根据需要启动进程数：一对多或多对一或多对多。
# 另外monitor.sh -r可以中断当前任务。
#
# 图像文件：只转换文件名
#
# 视频文件：
# 1. 使用ffmpeg进行压缩，使用x265编码视频和mp3来编码音频，同时ffmpeg会根据Rotation
#    自动旋转（即互换Width和Height）
# 2. mp4时间的时区转换问题
# 参考：https://forums.adobe.com/thread/2147732
# 手机拍出的mp4，在转换前：exiftool中的createdate是GMT(UTC)时间，文件名是当地实际时间，差了8个小时。
# 因此必须将exiftool中的createdate+8小时转换成本地时间，而jpg和mov都不需要此转换。
# 转换结果后，exiftool中的createdate和文件名保持一致。
# 测试机型：华为mate7，mate2，荣耀6plus，三星s4，三星note3
# 转换方法：$(date -d "2016-11-12 10:22:30 8 hour")
#

RDS_QUE=the_queue_which_files_are_processing
output_dir=$1
tmpfs_path=/dev/shm  #保存临时文件
video_file_types=mov,mp4,avi,MOV,MP4,AVI
mp4_file_types=mp4,MP4
log_file=convertor.log

# 压缩率要小于70%才有意义，即100M的文件压完后要小于70M，否则废弃掉，仍旧用压缩前的文件
# 因为有的文件压不了多少，甚至有些是压一下反而更大的。。
compress_ratio=0.7

function is_video_file()
{
    f=$1
    for ext in ${video_file_arr[@]}
    do
        if [ "${f##*.}" = "$ext" ]; then
            return 1;
        fi
    done
    
    return 0;
}

function is_mp4_file()
{
    f=$1
    for ext in ${mp4_file_arr[@]}
    do
        if [ "${f##*.}" = "$ext" ]; then
            return 1;
        fi
    done
    
    return 0;
}

function process_video_files()
{
    file=$1
    tmpfile=$tmpfs_path/ffmpeg_is_processing_$(basename $file)
    
    # 获取metadata
    res=$(exiftool -d "%Y-%m-%d %H:%M:%S" -createdate -T $file)
    createdate=$(echo $res | awk -F'\t' '{print $1}')
    #model=$(echo $res | awk -F'\t' '{print $2}')  #经实测，mp4和mov都无法设置model
    
    #格式化
    is_mp4_file $file;
    if [ $? -eq 1 ]; then  #如果是mp4文件
        createdate=$(date "+%Y%m%d.%H%M%S" -d "$createdate 8 hour")  #修正mp4中的时间
    else
        createdate=$(date "+%Y%m%d.%H%M%S" -d "$createdate")
    fi
    
    #转码
    ffmpeg -i $file -threads 4 -c:v libx265 -crf 22 -c:a libmp3lame -b:a 128k $tmpfile -y
    if [ $? -ne 0 ]; then
        rm $tmpfile
        mv -i $file $dest_dir
        if [ $? -eq 0 ]; then
            echo "An error occurred while ffmpeg processing '$file', it has been moved to '$dest_dir' directly" >> $log_file
        fi
        return
    fi
    
    # 检查压缩率是否合格
    orig_size=$(ls -l $file | cut -d" " -f5)
    new_size=$(ls -l $tmpfile | cut -d" " -f5)
    accepted_size=$(echo "$orig_size * $compress_ratio" | bc)

    #当new_size<accepted_size才算合格
    is_accept=$(echo $new_size $accepted_size | awk '{if($1<$2){print "true"}else{print "false"}}')
    #echo "orig_size="$orig_size",accepted_size="$accepted_size",new_size="$new_size",is_accept="$is_accept >> $log_file
    if [ $is_accept = "true" ]; then  # 压缩后，大小符合要求
        #设置createdate到exif中。经实测，mp4和mov都无法设置model
        exiftool "-createdate=$createdate" -overwrite_original $tmpfile
        exre.sh -i $tmpfile -o $dest_dir #重命名后移到$dest_dir
        if [ $? -eq 0 ]; then
            rm $file
        fi
    else   # 压缩后，大小不符合要求
        rm $tmpfile
        #设置createdate到exif中。经实测，mp4和mov都无法设置model
        exiftool "-createdate=$createdate" -overwrite_original $file
        exre.sh -i $file -o $dest_dir  #重命名后移到$dest_dir
        if [ $? -eq 0 ]; then
            echo "The file '$file' has been moved to '$dest_dir' directly with new exif createdate, because ffmpeg compressed not too much size" >> $log_file
        fi
    fi
}

function start()
{
    if [ ! -d "$output_dir" ]; then
        echo "Usage:" `basename $0` "<directory>"
        exit 1
    fi

    OLD_IFS="$IFS"
    IFS=","
    video_file_arr=($video_file_types)
    mp4_file_arr=($mp4_file_types)
    IFS="$OLD_IFS"
    
    monitor_dir=$(
        redis-cli blpop $RDS_QUE 0 | 
        (
            # redis会返回两行：一行key，一行内容，用read连续读两行，可以读到内容
            read line
            read line
            echo "$line"  #括号中的变量通过echo传出，外面使用$()接收
        )
    )"/"
    #echo "monitor_dir=$monitor_dir"
    
    while (true)
    do
        redis-cli blpop $RDS_QUE 0 | 
        (
            # redis会返回两行：一行key，一行内容，用read连续读两行，可以读到内容
            read line
            read line
            #echo "line="$line
            
            #截取前面的目录，使他变成相对路径，举例：
            # line=/home/op/input_dir/a/b/c/1.jpg 或 line=/home/op/input_dir/a/b/c
            # monitor_dir=/home/op/input_dir/
            # dest=output_dir/a/b/c/1.jpg 或 dest=output_dir/a/b/c
            dest=$output_dir/${line#$monitor_dir}   #拼装
            
            if [ -d $line ]; then  #目录
                echo "mkdir -p $dest"
                mkdir -p $dest
            else   #文件
                dest_dir=${dest%/*}   #截取末尾的文件名，使他变成目录名
                if [ -d $dest_dir ]; then
                    is_video_file $line;
                    if [ $? -eq 1 ]; then  #如果是视频文件
                        #echo "process video file: $line to $dest_dir"
                        process_video_files $line $dest_dir;
                    else
                        #echo "move $line to $dest_dir"
                        exre.sh -i $line -o $dest_dir  #重命名后移到dest_dir
                    fi
                else
                    echo "[ERROR] For file '$line', \$dest_dir='$dest_dir' is not a directory"
                    echo "[ERROR] For file '$line', \$dest_dir='$dest_dir' is not a directory" >> $log_file
                fi
            fi
        )
    done
}

start;
