dir=运维/

for filename in `find ${dir} -type f`
do
title=`echo $filename | awk -F '/' '{print $NF}'|awk '{sub(/.{3}$/,"")}1'`
cate=`echo $filename | awk -F '/' '{print $(NF-1)}'`
sed -i "1i\---\ntitle: $title\n\ndate: `date "+%Y-%m-%d %T"`\ntags:\n- $cate\ncategories:\n- $cate\n---" $filename
done
