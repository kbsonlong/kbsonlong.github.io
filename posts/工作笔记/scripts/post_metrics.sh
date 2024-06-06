#!/bin/bash
###
 # @Author: kbsonlong kbsonlong@gmail.com
 # @Date: 2024-05-07 18:12:29
 # @LastEditors: kbsonlong kbsonlong@gmail.com
 # @LastEditTime: 2024-05-10 11:59:47
 # @Description:
 # Copyright (c) 2024 by kbsonlong, All Rights Reserved.
###

function post_run_time_metrics() {
    grep -E '^room=shopline' /home/dspeak/yyms/hostinfo.ini
    # shellcheck disable=SC2181
    if [[ $? != 0 ]]; then
        exit 1
    fi
    echo "1"
    # VictoriaMetrics集群地址
    VM_CLUSTER_URL="http://victoriametrics-vminsert-shopline-docker.sysop.duowan.com/insert/0/prometheus"
    # metrics名称
    METRICS_NAME="container_script_runtime"

    if [ -z "$1" ] ; then
        echo "Usage: $0 start_time"
        exit 1
    fi
    start_time=$1

    # 获取结束时间戳（毫秒）
    end_nsec=$(date +%s%N)
    end_time=$((end_nsec / 1000000))
    # 计算运行时间（毫秒）
    run_time=$((end_time - start_time))

    # 构造 metrics 数据
    metrics="$METRICS_NAME{cluster=\"$MY_CLUSTER_NAME\",project_name=\"$MY_PROJECT_NAME\",env=\"$MY_ENV_NAME\",pod_name=\"$MY_POD_NAME\"} $run_time"

    # 使用curl发送metrics到VictoriaMetrics
    time curl -vv --connect-timeout 5  --retry 3 --retry-delay 0 \
        "$VM_CLUSTER_URL/api/v1/import/prometheus" \
        -H 'Content-Type: application/json' \
        -d "$metrics"
}

# 获取当前时间戳（毫秒）
start_nsec=$(date +%s%N)
start_time=$((start_nsec / 1000000))

post_run_time_metrics $start_time