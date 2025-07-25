###
 # @FilePath: /content/posts/工作笔记/scripts/delete-pod.sh
 # @Author: kbsonlong kbsonlong@gmail.com
 # @Date: 2024-03-25 17:01:40
 # @LastEditors: kbsonlong kbsonlong@gmail.com
 # @LastEditTime: 2024-05-22 14:18:17
 # @Description: 
 # Copyright (c) 2024 by kbsonlong, All Rights Reserved. 
###

if [ -z $1 ];then
  echo "please enter node lists in filename"
  exit 1
fi

KubeCtl="kubectl"

function UnSchedulerNode(){
    local node=$1
    [[ -z "${node}" ]] && echo "please input name of worker node" && return
    echo "worker node ${node} will set taint action NoSchedule"
    ${KubeCtl} taint node ${node} unscheduer=true:NoSchedule
    ${KubeCtl} label node ${node} node-role.kubernetes.io/NoSchedule=true --overwrite=true
}

rm -rf delete.sh get_admin.sh
for node in $(cat $1)
do
    export ip=$(kubectl get node ${node} -o go-template={{.metadata.labels.ip}})
    echo "# $node" >>  delete.sh
    # UnSchedulerNode "$node"
    kubectl  describe node "$node" | \
      sed -n "/Namespace/,/Allocated/p"| \
      grep -Ev 'Namespace|Allocated|kruise-system|kube-system|shopline-sec|arms-prom|devops|---------' | \
      awk '{print "kubectl delete pod -n ",$1,$2}' >> delete.sh
    ${KubeCtl} describe node "$node" | \
      sed -n "/Namespace/,/Allocated/p"| \
      grep -Ev 'Namespace|Allocated|kruise-system|kube-system|shopline-sec|arms-prom|devops|---------'| \
      awk '{print "kubectl get pod -n ",$1,$2, " -o go-template-file=pod.tmpl"}' >> get_admin.sh
    echo "sleep 60" >> delete.sh
    echo "" >> delete.sh

done

# echo "String Delete Pod"
# bash delete.sh

while read p; do
  # shellcheck disable=SC2046
  eval $($p | awk '{printf("namespace=%s; pod_name=%s; op_admin=%s", $1,$2,$3)}') >>  admin.log
  # shellcheck disable=SC2154
  Msg="${op_admin}容器节点维护，请在周四下班前处理名下服务${pod_name},周五仍未处理将统一由容器运维重启调度至新节点"
  python /home/dspeak/yyms/yymp/yymp_report_script/yymp_report_alarm.py "id=44621&sid=6527509&pre=0&msg=${Msg}&ip=${ip}&op_admin_dw=dw_zengshenglong"
done <get_admin.sh