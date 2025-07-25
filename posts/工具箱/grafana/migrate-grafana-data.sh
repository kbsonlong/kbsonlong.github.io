#!/bin/bash

# Grafana SQLite到PostgreSQL数据迁移脚本
# 解决pgloader内存耗尽问题

set -e

echo "=== Grafana数据迁移脚本 ==="
echo "开始时间: $(date)"

# 检查必要文件
if [ ! -f "grafana.db" ]; then
    echo "错误: 找不到grafana.db文件"
    exit 1
fi

if [ ! -f "main-optimized.load" ]; then
    echo "错误: 找不到main-optimized.load配置文件"
    exit 1
fi

# 检查PostgreSQL连接
echo "检查PostgreSQL连接..."
if ! docker exec grafana-postgres-primary-1 psql -U grafana -d grafana -c "SELECT 1;" > /dev/null 2>&1; then
    echo "错误: 无法连接到PostgreSQL数据库"
    echo "请确保PostgreSQL容器正在运行"
    exit 1
fi

echo "PostgreSQL连接正常"

# 备份当前PostgreSQL数据（如果存在）
echo "备份当前PostgreSQL数据..."
docker exec grafana-postgres-primary-1 pg_dump -U grafana grafana > "grafana_backup_$(date +%Y%m%d_%H%M%S).sql" 2>/dev/null || echo "没有现有数据需要备份"

# 方案1: 使用优化配置和增加内存限制
echo "尝试方案1: 优化配置 + 内存限制..."
if docker run --rm -it --network host \
    --memory=2g \
    --memory-swap=4g \
    -v "$(pwd)":/data/services/grafana \
    ghcr.io/dimitri/pgloader:latest \
    pgloader /data/services/grafana/main-optimized.load; then
    echo "✅ 数据迁移成功完成！"
    echo "完成时间: $(date)"
    exit 0
fi

echo "⚠️ 方案1失败，尝试方案2: 分批迁移..."

# 方案2: 仅迁移表结构，然后分批迁移数据
cat << EOF > schema-only.load
load database
  from sqlite:///data/services/grafana/grafana.db
  into postgresql://grafana:grafana@127.0.0.1/grafana
  with schema only, create tables, create indexes
  set work_mem to '16MB';
EOF

echo "迁移表结构..."
if docker run --rm -it --network host \
    --memory=1g \
    -v "$(pwd)":/data/services/grafana \
    ghcr.io/dimitri/pgloader:latest \
    pgloader /data/services/grafana/schema-only.load; then
    echo "✅ 表结构迁移成功"
else
    echo "❌ 表结构迁移失败"
    exit 1
fi

# 创建小批量数据迁移配置
cat << EOF > data-only.load
load database
  from sqlite:///data/services/grafana/grafana.db
  into postgresql://grafana:grafana@127.0.0.1/grafana
  with data only,
       batch rows = 500,
       batch size = 5MB,
       prefetch rows = 50,
       workers = 1
  set work_mem to '8MB',
      maintenance_work_mem to '128MB';
EOF

echo "迁移数据..."
if docker run --rm -it --network host \
    --memory=1g \
    -v "$(pwd)":/data/services/grafana \
    ghcr.io/dimitri/pgloader:latest \
    pgloader /data/services/grafana/data-only.load; then
    echo "✅ 数据迁移成功完成！"
else
    echo "❌ 数据迁移失败，尝试方案3..."
    
    # 方案3: 使用sqlite3和psql的传统方法
    echo "使用传统方法迁移数据..."
    
    # 获取所有表名
    tables=$(sqlite3 grafana.db ".tables")
    
    for table in $tables; do
        echo "迁移表: $table"
        
        # 导出为CSV
        sqlite3 grafana.db <<EOF
.mode csv
.output ${table}.csv
SELECT * FROM $table;
.quit
EOF
        
        # 导入到PostgreSQL
        if [ -s "${table}.csv" ]; then
            docker exec -i grafana-postgres-primary-1 psql -U grafana -d grafana -c "\copy $table FROM STDIN CSV;" < "${table}.csv"
            rm "${table}.csv"
            echo "✅ 表 $table 迁移完成"
        else
            echo "⚠️ 表 $table 为空，跳过"
        fi
    done
    
    echo "✅ 传统方法迁移完成！"
fi

# 验证迁移结果
echo "验证迁移结果..."
docker exec grafana-postgres-primary-1 psql -U grafana -d grafana -c "\dt"

echo "重启Grafana服务..."
docker-compose restart grafana

echo "=== 迁移完成 ==="
echo "完成时间: $(date)"
echo "请检查Grafana是否正常工作: http://localhost:3000"

# 清理临时文件
rm -f schema-only.load data-only.load