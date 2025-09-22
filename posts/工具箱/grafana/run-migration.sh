#!/bin/bash

# Grafana SQLite 到 PostgreSQL 迁移脚本
# 此脚本用于在非Kubernetes环境中执行迁移任务

set -e

# 配置参数
SQLITE_DB_PATH="./grafana.db"
PG_HOST="localhost"
PG_PORT="5432"
PG_USER="grafana"
PG_PASSWORD="grafana"
PG_DATABASE="grafana"
MEMORY_LIMIT="2g"

# 创建迁移配置文件
cat > main.load << EOF
load database
  from sqlite:///$SQLITE_DB_PATH
  into postgresql://$PG_USER:$PG_PASSWORD@$PG_HOST:$PG_PORT/$PG_DATABASE
  with data only, reset sequences,
       batch rows = 1000,
       batch size = 10MB,
       prefetch rows = 100
  set work_mem to '16MB',
      maintenance_work_mem to '512MB';
EOF

echo "创建迁移配置文件完成"
echo "开始执行迁移..."

# 执行迁移
docker run -m $MEMORY_LIMIT --rm -it \
  --network host \
  -v "$(pwd)":/data/services/grafana \
  ghcr.io/dimitri/pgloader:latest \
  pgloader /data/services/grafana/main.load

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo "迁移成功完成！"
  echo "请更新Grafana配置以连接到PostgreSQL数据库"
else
  echo "迁移失败，退出代码: $EXIT_CODE"
  echo "请检查日志获取详细错误信息"
fi

# 清理配置文件
rm -f main.load

exit $EXIT_CODE