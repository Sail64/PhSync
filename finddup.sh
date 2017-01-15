#!/bin/bash
#
# 照片增量备份、去重工具
# ！！！ 废弃照片同步功能弃，用rsync代替 ！！！
# rsync -ruPi -plEt /home/op/photo/ /media/op/36f476a7-4d86-4526-9131-dc0efc1fa4fd/photo/le/ --dry-run
# 原因：
# rsync可以同步目录结构，而这个脚本不能。另外使用redis并不能大幅提高性能，因为还是要扫描源目录，而rsync不需要重新扫描目录，似乎有缓存。
# 目前此脚本只保留去重功能。
# 
# Sail 2016-09-16 
# 原理：
# 使用redis的set集合进行重复文件的识别。
# 将文件名按照固定格式重命名导入到redis的set中。
# 之所以不用md5值有两个原因：1.性能 2.维护性：在redis中可以很方便地查看某照片是否已经备份过
# 之所以不用rsync的原因：rsync每次都比较源目录和目标目录的所有文件，性能较差。另外rsync要求源目录与目标目录的目录结构要完全一致。

# 举例：
# 更新数据库并识别重复文件打印到日志中（不自动去重，根据日志手工去重）
# finddup.sh
# 
# #备份照片，只cp新增照片，已备份的自动跳过
# #phsync.sh -i upload/ -o /media/op/36f476a7-4d86-4526-9131-dc0efc1fa4fd/share/new/
#
# 1. exiftool
# 不要用find | xargs -i exiftool {}的方式，因为xargs对于find的每一行结果，启动一次exiftool，
# exiftool本身是批处理工具，每次仅处理一个文件的话性能非常差。
# 因此直接使用exiftool的批处理功能，直接遍历目录。
#
# 2. gawk
# 不能用eval redis-cli，因为eval是一次全部执行完，无法对每一次执行的redis-cli的返回做判断处理
# 所以必须要用"command" | getline 的形式。
# 由于debian默认的mawk不支持"command" $1 | getline这种形式，所以需要安装apt-get install gawk
# 需要安装gawk来支持：
#    1) awk运行shell命令：cmd | getline res
#    2) systime, strftime, mktime
#

#set -x
rediskey=photo
logfile=finddup.log

function reload()
{
    if [ ! -d "$BASE_DIR" ]; then
        echo "[ERROR] Base dir '$BASE_DIR' is not a directory"
        return 1
    fi

    echo "Reloading all photos in $BASE_DIR to redis(key=$rediskey)..."

    # Clear    
    redis-cli del $rediskey > /dev/null

    # '-r'表示遍历目录，'-filesize#'表示用字节表示文件长度，-T表示用tab分开。
    exiftool -r -createdate -d "%Y%m%d.%H%M%S" -model -filesize -filesize# -filetypeextension -filepath -duration -T "$BASE_DIR" | awk -F'\t' '
    {
        extname=$5
        date=$1
        if($1 == "-" || index($1, "0000") != 0)
        {
            date="nodate"
        }
        
        model=""
        if($2 != "-")
        {
            model=$2"_"
            # 将-替换成.
            gsub(/-/, ".", model)
        }
        
        #duration有两种格式： 0:01:30  或  10.31 s
        duration=""
        if($7 != "-")
        {
            if (index($7, ".") != 0)  #找到"."
            {
                duration=$7"_"
            }
            else
            {
                split($7, d, ":")
                if (d[1] != "0")
                {
                    duration = d[1]"h"
                }
                if (d[2] != "00")
                {
                    if (index(d[2], "0")==1) #如果首位为0，则截去
                    {
                        d[2] = substr(d[2], 2, 1)
                    }
                    duration = duration d[2]"m"
                }
                if (index(d[3], "0")==1) #如果首位为0，则截去
                {
                    d[3] = substr(d[3], 2, 1)
                }
                duration = duration d[3]"s_"
            }
        }
        #print duration
        
        # 拼装文件名
        filename=date"_"duration$3"_"model$4"."extname
        filepath=$6
        
        # 删除空格
        gsub(/ /, "", filename)
    
        #print filename, filepath > "/dev/stderr"

        # Add to Redis
        rediskey="'$rediskey'"
        cmd="redis-cli sadd " rediskey " \"" filename "\""
        cmd | getline res

        # Close
        # http://www.staff.science.uu.nl/~oostr102/docs/nawk/nawk_26.html
        close(cmd)
        
        # 无重复即添加成功
        if (res == 1 )
        {
            cmd="redis-cli set " filename " \"" filepath "\""
            cmd | getline res
            close(cmd)
            if (res == 0 )
            {
                errinfo="redis-cli set " filename " \"" filepath "\" failed"
                print errinfo
                print errinfo > "/dev/stderr"
            }
        }
        else  #有重复文件
        {
            cmd="redis-cli get " filename
            cmd | getline res
            close(cmd)
            
            now=strftime("%Y-%m-%d %H:%M:%S")
            errinfo="["now"] Found duplicate file: key="filename"\n    New: "filepath"\n    Old: "res"\n    Skipped."
            print errinfo
            print errinfo > "/dev/stderr"
        }
    }' > $logfile
    
    if [ -s $logfile ]; then
        echo "Some errors happened, please see the finddup.log for details."
    else
        rm $logfile
    fi

}

# 从import_dir中将不重复的照片导入到base_dir中
function run_sync()
{
    if [ ! -d "$IMPORT_DIR" ]; then
        echo "[ERROR] Import dir '$IMPORT_DIR' is not a directory"
        return 1
    fi

    # 创建目录
    if [ ! -d "$OUTPUT_DIR" ]; then
        if [ "$dryrun" != "true" ]; then
            mkdir "$OUTPUT_DIR"
            if [ $? -ne 0 ]; then
                exit 22
            fi
        else
            echo "The directory '$OUTPUT_DIR' does not exist"
            exit 25
        fi
    fi

    # output dir必须在base dir中，因为reload是读的base dir中的所有文件。
    # 否则，用reload的会统计不到
    count=`echo "$OUTPUT_DIR" | grep "$BASE_DIR" | wc -l`
    if [ $count -eq 0 ]; then
        echo "[ERROR] The output dir '$OUTPUT_DIR' must be in the base dir '$BASE_DIR'"
        exit 23
    fi

    # 相对路径转换为绝对路径
    OUTPUT_DIR=`realpath "$OUTPUT_DIR"`
    IMPORT_DIR=`realpath "$IMPORT_DIR"`
    if [ "x$OUTPUT_DIR" = "x$IMPORT_DIR" ]; then
        echo "[ERROR] The import dir is the same with the output dir($OUTPUT_DIR)"
        return 3
    fi

    # 检查redis中是否有数据
    count=`redis-cli scard $rediskey`
    if [ $count -eq 0 ]; then
        echo "[ERROR] No data found in redis(key=$rediskey), please reload data first"
        exit 24
    fi

    # 开始执行增量备份
    for newpath in $(find $IMPORT_DIR -type f); do
        newfile=`basename $newpath`

        # 去redis中查询，如果为空则添加
        res=`redis-cli sismember $rediskey $newfile`
        if [ $res -eq 0 ]; then
            if [ "$dryrun" = "true" ]; then
                echo "[Dry-Run] cp \""$newpath"\" \"$OUTPUT_DIR/\""
            else
                echo "cp \""$newpath"\" \"$OUTPUT_DIR/\""
                cp "$newpath" "$OUTPUT_DIR/"
                if [ $? -eq 0 ]; then
                    redis-cli sadd $rediskey "$newfile" > /dev/null
                fi
            fi
        fi
    done
}

source finddup.conf
if [ -z $BASE_DIR ]; then
    export "BASE_DIR is null"
    exit 2
fi

reload;


#dryrun=false
#while getopts "rdi:o:" opt
#do
#    case $opt in
#        r)
#            reload;
#            exit 0;;
#        d)
#            dryrun=true;;
#        i) 
#            IMPORT_DIR=$OPTARG;;
#        o) 
#            OUTPUT_DIR=$OPTARG;;
#    esac
#done
#
#if [ -d "$IMPORT_DIR" ]; then
#    run_sync;
#else
#    echo "Usage: $0 [-r] [-d] [-i import_directory] [-o output_directory]"
#fi

