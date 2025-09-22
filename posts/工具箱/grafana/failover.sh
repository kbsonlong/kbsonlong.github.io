#!/bin/bash

# Pgpool-II 故障转移脚本
# 此脚本在检测到主节点故障时自动执行

# 日志文件
LOG_FILE="/var/log/pgpool/failover.log"

# 获取参数
FAILED_NODE_ID=$1          # 故障节点ID
FAILED_HOST=$2             # 故障节点主机名
FAILED_PORT=$3             # 故障节点端口
FAILED_DATA_DIR=$4         # 故障节点数据目录
NEW_MASTER_ID=$5           # 新主节点ID
NEW_MASTER_HOST=$6         # 新主节点主机名
NEW_MASTER_PORT=$7         # 新主节点端口
NEW_MASTER_DATA_DIR=$8     # 新主节点数据目录
OLD_MASTER_ID=$9           # 旧主节点ID
OLD_PRIMARY_ID=${10}       # 旧主节点ID (同上，兼容性参数)

# 记录故障转移开始
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 故障转移开始" >> $LOG_FILE
echo "故障节点: $FAILED_NODE_ID ($FAILED_HOST:$FAILED_PORT)" >> $LOG_FILE
echo "新主节点: $NEW_MASTER_ID ($NEW_MASTER_HOST:$NEW_MASTER_PORT)" >> $LOG_FILE

# 如果故障节点是主节点，执行主备切换
if [ $FAILED_NODE_ID -eq $OLD_MASTER_ID ]; then
    echo "检测到主节点故障，执行主备切换" >> $LOG_FILE
    
    # 在新主节点上执行提升操作
    ssh postgres@$NEW_MASTER_HOST "pg_ctl promote -D $NEW_MASTER_DATA_DIR" >> $LOG_FILE 2>&1
    
    if [ $? -eq 0 ]; then
        echo "新主节点提升成功" >> $LOG_FILE
    else
        echo "新主节点提升失败" >> $LOG_FILE
        exit 1
    fi
    
    # 更新应用程序连接信息
    # 这里可以添加更新应用程序连接信息的命令
    # 例如更新HAProxy配置、DNS记录等
    
    # 发送告警通知
    echo "发送故障转移告警通知" >> $LOG_FILE
    # 这里可以添加发送邮件、短信或其他通知的命令
    # 例如：mail -s "PostgreSQL主节点故障" admin@example.com < $LOG_FILE
    
    # 记录到Prometheus监控系统
    echo "记录故障事件到监控系统" >> $LOG_FILE
    curl -X POST -H "Content-Type: application/json" -d '{"status":"firing","labels":{"alertname":"PostgreSQLFailover","severity":"critical","failed_node":"'$FAILED_NODE_ID'","new_master":"'$NEW_MASTER_ID'"},"annotations":{"summary":"PostgreSQL故障转移","description":"节点'$FAILED_NODE_ID'故障，已切换到节点'$NEW_MASTER_ID'"}}' http://alertmanager:9093/api/v1/alerts 2>/dev/null
    
    echo "故障转移完成" >> $LOG_FILE
else
    echo "故障节点不是主节点，仅移除故障节点" >> $LOG_FILE
fi

# 记录故障转移结束时间
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 故障转移结束" >> $LOG_FILE

# 返回成功
exit 0