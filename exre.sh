#!/bin/bash
#
# Sail 2016-09-04
#
# 根据文件的exif信息自动命名，并文件的修改mtime（owncloud排序用到）。
# 本来用下面这种方式，一行命令可以搞定：
# exiftool '-testname<${CreateDate}_${model;}.%e' -d %Y%m%d-%H%M%S%%-c <directory>
# 但是exiftool不会容错，对于mp4文件找不到model，直接报错。另外model中有空格要用-替换，所以只能手工mv。
#
# 1. exiftool
# 不要用将exiftool放在循环中，因为exiftool本身是批处理工具，每次仅处理一个文件的话性能非常差。
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

logfile=exre.log

function printusage()
{
    # -d表示dryrun
    echo "Usage:" `basename $0` "[-d] -i <single_file/directory> [-o output_directory]"
}

# 入参：$file, $dryrun
function rename()
{
    if [ -z "$dryrun" ]; then
        echo "\$dryrun is null"
        exit 5
    fi
    
    if [ -z "$input_dir" ]; then
        echo "\$input_dir is null"
        exit 4
    fi
    input_dir=`realpath "$input_dir"`
    
    if [ ! -z "$output_dir" ]; then
        if [ ! -d "$output_dir" ]; then
            echo "Please use -o <directory>"
            exit 6
        fi
        output_dir=`realpath "$output_dir"`
    fi

    # output_dir不能在input_dir中，会被exiftool重复扫描到
    count=`echo "$output_dir" | grep "$input_dir" | wc -l`
    if [ $count -ne 0 ]; then
        echo "[ERROR] The output path '$output_dir' cannot be in the input path '$input_dir'"
        exit 7
    fi

    # > $logfile

    # '-r'表示遍历目录，'-filesize#'表示用字节表示文件长度，-T表示用tab分开。
    exiftool -r -createdate -d "%Y %m %d %H %M %S" -model -filesize -filesize# -filetypeextension -filename -filepath -duration -T "$input_dir" | awk -F'\t' '
    {
        extname=$5
        date=$1
        if($1 == "-" || index($1, "0000") != 0)
        {
            date="nodate"
        }
        else
        {
            seconds=mktime(date)
            date=strftime("%Y%m%d.%H%M%S", seconds)
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
        if($8 != "-")
        {
            if (index($8, ".") != 0)  #找到"."
            {
                duration=$8"_"
            }
            else
            {
                split($8, d, ":")
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
        filebasename=date"_"duration$3"_"model$4
        # 删除空格
        gsub(/ /, "", filebasename)
        newname=filebasename"."extname
        
        oldname=$6
        oldpath=$7
        
        output_dir="'"$output_dir"'"  #最里面的双引号是为了防止目录名中有空格
        if (output_dir == "")
        {
            dest_dir=substr(oldpath, 0, index($7, oldname)-1)
        }
        else
        {
            dest_dir = output_dir"/"
        }
        newpath=dest_dir newname
        
        #print "+++"oldpath, newpath
        
        if ("'$dryrun'" != "true" && date != "nodate")
        {
            # 修改mtime
            touch_date=strftime("%Y%m%d%H%M.%S", seconds)
            cmd="touch -mt "touch_date" \""oldpath"\""
            cmd | getline res
            close(cmd)
        }
        
        # 查看是否已经存在原文件名（之前是否同步过）
        cmd="test -f \""newpath "\"; echo $?"
        cmd | getline res
        close(cmd)
        if(res != 0)  #如果未同步，进行同步
        {
            # 重命名
            if ("'$dryrun'" == "true")
            {
                print "[Dry-Run] mv -i "oldpath" "newpath
            }
            else
            {
                if (date == "nodate")
                {
                    cmd="mv -i \"" oldpath "\" \"" dest_dir"\""
                }
                else
                {
                    cmd="mv -i \"" oldpath "\" \"" newpath"\""
                }
                cmd | getline res
                close(cmd)
                print cmd
            }
        }
        else
        {
            # 注意输出单引号是这个形式：'\''
            print "[ERROR] The target file '\''"newpath"'\'' already existed while processing the file '\''"oldpath"'\'', skipped" > "/dev/stderr"
        }
    }' 2>>$logfile
    
    if [ -s $logfile ]; then
        echo "Some errors happened, please see the exre.log for details."
    else
        rm $logfile
    fi
}

# Start
if [ $# -eq 0 ]; then
    printusage;
    exit 1
fi

which exiftool > /dev/null
if [ $? -eq 1 ]; then
    echo 'exiftool not found'
    exit 10
fi

which gawk > /dev/null
if [ $? -eq 1 ]; then
    echo 'gawk not found'
    exit 11
fi

dryrun=false
while getopts "i:o:d" opt
do
    case $opt in
        i)
            input_dir="$OPTARG";;
        o)
            output_dir="$OPTARG";;
        d)
            dryrun=true;;
    esac
done

if [ -f "$input_dir" -o -d "$input_dir" ]; then #文件或目录均可，如果是文件，只支持单个文件，不支持通配符
    rename;
    exit 0
else
    echo "'$input_dir' is neither a directory nor a file, exited"
    exit 3
fi

