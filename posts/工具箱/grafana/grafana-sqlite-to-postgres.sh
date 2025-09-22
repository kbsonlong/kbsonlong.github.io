#!/bin/bash

# Grafana SQLite到PostgreSQL迁移脚本
# 创建日期: 2023-07-25

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 默认值
SQLITE_DB="/var/lib/grafana/grafana.db"
PG_HOST="localhost"
PG_PORT="5432"
PG_DB="grafana"
PG_USER="postgres"
PG_PASSWORD=""
GRAFANA_ROLE="grafana"
GRAFANA_PASSWORD="grafana_password"
BACKUP_DIR="./backup"
TEMP_DIR="./temp"
GRAFANA_CONFIG="/etc/grafana/grafana.ini"
GRAFANA_SERVICE="grafana-server"
FIX_OWNERSHIP=true
RESTART_GRAFANA=true

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "此脚本用于将Grafana从SQLite迁移到PostgreSQL数据库。"
    echo ""
    echo "选项:"
    echo "  -s, --sqlite PATH         SQLite数据库路径 (默认: /var/lib/grafana/grafana.db)"
    echo "  -h, --host HOST           PostgreSQL主机地址 (默认: localhost)"
    echo "  -p, --port PORT           PostgreSQL端口 (默认: 5432)"
    echo "  -d, --database DB_NAME    PostgreSQL数据库名称 (默认: grafana)"
    echo "  -u, --user USER           PostgreSQL用户名 (默认: postgres)"
    echo "  -P, --password PASSWORD   PostgreSQL密码"
    echo "  -r, --role ROLE           Grafana角色名称 (默认: grafana)"
    echo "  -R, --role-password PWD   Grafana角色密码 (默认: grafana_password)"
    echo "  -b, --backup-dir DIR      备份目录 (默认: ./backup)"
    echo "  -t, --temp-dir DIR        临时目录 (默认: ./temp)"
    echo "  -c, --config PATH         Grafana配置文件路径 (默认: /etc/grafana/grafana.ini)"
    echo "  -S, --service NAME        Grafana服务名称 (默认: grafana-server)"
    echo "  --no-fix-ownership        不修复表的所有权"
    echo "  --no-restart              不重启Grafana服务"
    echo "  --help                    显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -s /var/lib/grafana/grafana.db -h localhost -p 5432 -d grafana -u postgres -P mypassword"
    echo ""
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -s|--sqlite)
            SQLITE_DB="$2"
            shift 2
            ;;
        -h|--host)
            PG_HOST="$2"
            shift 2
            ;;
        -p|--port)
            PG_PORT="$2"
            shift 2
            ;;
        -d|--database)
            PG_DB="$2"
            shift 2
            ;;
        -u|--user)
            PG_USER="$2"
            shift 2
            ;;
        -P|--password)
            PG_PASSWORD="$2"
            shift 2
            ;;
        -r|--role)
            GRAFANA_ROLE="$2"
            shift 2
            ;;
        -R|--role-password)
            GRAFANA_PASSWORD="$2"
            shift 2
            ;;
        -b|--backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -t|--temp-dir)
            TEMP_DIR="$2"
            shift 2
            ;;
        -c|--config)
            GRAFANA_CONFIG="$2"
            shift 2
            ;;
        -S|--service)
            GRAFANA_SERVICE="$2"
            shift 2
            ;;
        --no-fix-ownership)
            FIX_OWNERSHIP=false
            shift
            ;;
        --no-restart)
            RESTART_GRAFANA=false
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 检查必要的命令
check_commands() {
    info "检查必要的命令..."
    
    # 检查sqlite3
    if ! command -v sqlite3 &> /dev/null; then
        error "sqlite3命令未找到。请安装sqlite3。"
        echo "Ubuntu/Debian: sudo apt-get install sqlite3"
        echo "CentOS/RHEL: sudo yum install sqlite"
        exit 1
    fi
    
    # 检查psql
    if ! command -v psql &> /dev/null; then
        error "psql命令未找到。请安装PostgreSQL客户端。"
        echo "Ubuntu/Debian: sudo apt-get install postgresql-client"
        echo "CentOS/RHEL: sudo yum install postgresql"
        exit 1
    fi
    
    # 检查jq（如果需要处理JSON）
    if ! command -v jq &> /dev/null; then
        warning "jq命令未找到。某些高级功能可能不可用。"
        echo "Ubuntu/Debian: sudo apt-get install jq"
        echo "CentOS/RHEL: sudo yum install jq"
    fi
    
    success "所有必要的命令已找到。"
}

# 检查SQLite数据库
check_sqlite_db() {
    info "检查SQLite数据库 '$SQLITE_DB'..."
    
    if [ ! -f "$SQLITE_DB" ]; then
        error "SQLite数据库文件 '$SQLITE_DB' 不存在。"
        exit 1
    fi
    
    # 检查是否是有效的SQLite数据库
    if ! sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master LIMIT 1;" &> /dev/null; then
        error "'$SQLITE_DB' 不是有效的SQLite数据库文件。"
        exit 1
    fi
    
    # 检查是否是Grafana数据库
    if ! sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('dashboard', 'user', 'org');" | grep -q "3"; then
        warning "'$SQLITE_DB' 可能不是Grafana数据库，因为找不到预期的表。"
        read -p "是否继续? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    success "SQLite数据库检查通过。"
}

# 检查PostgreSQL连接
check_postgres_connection() {
    info "检查PostgreSQL连接..."
    
    # 构建PSQL连接字符串
    PSQL_CONN="-h $PG_HOST -p $PG_PORT -U $PG_USER"
    if [ -n "$PG_PASSWORD" ]; then
        export PGPASSWORD="$PG_PASSWORD"
    fi
    
    # 测试连接
    if ! psql $PSQL_CONN -d postgres -c "\q" &> /dev/null; then
        error "无法连接到PostgreSQL服务器。请检查连接参数。"
        exit 1
    fi
    
    success "PostgreSQL连接成功。"
}

# 创建PostgreSQL数据库和角色
create_postgres_db_and_role() {
    info "检查PostgreSQL数据库和角色..."
    
    # 检查数据库是否存在
    DB_EXISTS=$(psql $PSQL_CONN -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_DB'")
    
    if [ -z "$DB_EXISTS" ]; then
        info "创建数据库 '$PG_DB'..."
        if psql $PSQL_CONN -d postgres -c "CREATE DATABASE $PG_DB;"; then
            success "数据库 '$PG_DB' 创建成功。"
        else
            error "创建数据库 '$PG_DB' 失败。"
            exit 1
        fi
    else
        warning "数据库 '$PG_DB' 已存在。"
        read -p "是否清空现有数据库? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "清空数据库 '$PG_DB'..."
            if psql $PSQL_CONN -d postgres -c "DROP DATABASE $PG_DB; CREATE DATABASE $PG_DB;"; then
                success "数据库 '$PG_DB' 已清空并重新创建。"
            else
                error "清空数据库 '$PG_DB' 失败。"
                exit 1
            fi
        fi
    fi
    
    # 检查角色是否存在
    ROLE_EXISTS=$(psql $PSQL_CONN -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$GRAFANA_ROLE'")
    
    if [ -z "$ROLE_EXISTS" ]; then
        info "创建角色 '$GRAFANA_ROLE'..."
        if psql $PSQL_CONN -d postgres -c "CREATE ROLE $GRAFANA_ROLE WITH LOGIN PASSWORD '$GRAFANA_PASSWORD';"; then
            success "角色 '$GRAFANA_ROLE' 创建成功。"
        else
            error "创建角色 '$GRAFANA_ROLE' 失败。"
            exit 1
        fi
    else
        info "角色 '$GRAFANA_ROLE' 已存在，更新密码..."
        if psql $PSQL_CONN -d postgres -c "ALTER ROLE $GRAFANA_ROLE WITH LOGIN PASSWORD '$GRAFANA_PASSWORD';"; then
            success "角色 '$GRAFANA_ROLE' 密码已更新。"
        else
            error "更新角色 '$GRAFANA_ROLE' 密码失败。"
            exit 1
        fi
    fi
    
    # 授予角色对数据库的权限
    info "授予角色 '$GRAFANA_ROLE' 对数据库 '$PG_DB' 的权限..."
    if psql $PSQL_CONN -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE $PG_DB TO $GRAFANA_ROLE;"; then
        success "权限授予成功。"
    else
        error "授予权限失败。"
        exit 1
    fi
    
    # 设置schema权限
    info "设置schema权限..."
    psql $PSQL_CONN -d $PG_DB -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $GRAFANA_ROLE;"
    psql $PSQL_CONN -d $PG_DB -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO $GRAFANA_ROLE;"
    psql $PSQL_CONN -d $PG_DB -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO $GRAFANA_ROLE;"
    psql $PSQL_CONN -d $PG_DB -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO $GRAFANA_ROLE;"
    success "Schema权限设置成功。"
}

# 备份SQLite数据库
backup_sqlite_db() {
    info "备份SQLite数据库..."
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    
    # 备份文件名
    BACKUP_FILE="$BACKUP_DIR/grafana_sqlite_backup_$(date +%Y%m%d_%H%M%S).db"
    
    # 复制数据库文件
    if cp "$SQLITE_DB" "$BACKUP_FILE"; then
        success "SQLite数据库已备份到 '$BACKUP_FILE'。"
    else
        error "备份SQLite数据库失败。"
        exit 1
    fi
}

# 导出SQLite数据库结构
export_sqlite_schema() {
    info "导出SQLite数据库结构..."
    
    # 创建临时目录
    mkdir -p "$TEMP_DIR"
    
    # 导出表结构
    SCHEMA_FILE="$TEMP_DIR/sqlite_schema.sql"
    
    echo "-- SQLite数据库结构导出" > "$SCHEMA_FILE"
    echo "-- 导出时间: $(date)" >> "$SCHEMA_FILE"
    echo "" >> "$SCHEMA_FILE"
    
    # 获取所有表名
    TABLES=$(sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
    
    for TABLE in $TABLES; do
        echo "-- 表: $TABLE" >> "$SCHEMA_FILE"
        sqlite3 "$SQLITE_DB" ".schema $TABLE" >> "$SCHEMA_FILE"
        echo "" >> "$SCHEMA_FILE"
    done
    
    success "SQLite数据库结构已导出到 '$SCHEMA_FILE'。"
}

# 导出SQLite数据
export_sqlite_data() {
    info "导出SQLite数据..."
    
    # 创建临时目录
    mkdir -p "$TEMP_DIR"
    
    # 获取所有表名
    TABLES=$(sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
    
    # 导出每个表的数据为CSV
    for TABLE in $TABLES; do
        info "导出表 '$TABLE' 的数据..."
        CSV_FILE="$TEMP_DIR/${TABLE}.csv"
        
        # 获取表的列名
        COLUMNS=$(sqlite3 "$SQLITE_DB" "PRAGMA table_info($TABLE);" | cut -d'|' -f2 | tr '\n' ',' | sed 's/,$//')
        
        # 导出数据为CSV
        echo "$COLUMNS" > "$CSV_FILE"
        sqlite3 -csv "$SQLITE_DB" "SELECT $COLUMNS FROM $TABLE;" >> "$CSV_FILE"
        
        success "表 '$TABLE' 的数据已导出到 '$CSV_FILE'。"
    done
}

# 创建PostgreSQL表结构
create_postgres_schema() {
    info "创建PostgreSQL表结构..."
    
    # 获取Grafana版本
    GRAFANA_VERSION=$(grafana-server -v 2>&1 | grep -oP 'Version \K[0-9]+\.[0-9]+\.[0-9]+')
    info "检测到Grafana版本: $GRAFANA_VERSION"
    
    # 让Grafana自动创建表结构
    info "配置Grafana使用PostgreSQL..."
    
    # 备份原始配置文件
    if [ -f "$GRAFANA_CONFIG" ]; then
        cp "$GRAFANA_CONFIG" "$BACKUP_DIR/grafana.ini.bak"
        success "Grafana配置文件已备份到 '$BACKUP_DIR/grafana.ini.bak'。"
    fi
    
    # 更新配置文件中的数据库设置
    if [ -f "$GRAFANA_CONFIG" ]; then
        info "更新Grafana配置文件..."
        
        # 检查是否已有数据库配置
        if grep -q "^\[database\]" "$GRAFANA_CONFIG"; then
            # 更新现有配置
            sed -i "/^\[database\]/,/^\[/s/^type.*/type = postgres/" "$GRAFANA_CONFIG"
            sed -i "/^\[database\]/,/^\[/s/^host.*/host = $PG_HOST:$PG_PORT/" "$GRAFANA_CONFIG"
            sed -i "/^\[database\]/,/^\[/s/^name.*/name = $PG_DB/" "$GRAFANA_CONFIG"
            sed -i "/^\[database\]/,/^\[/s/^user.*/user = $GRAFANA_ROLE/" "$GRAFANA_CONFIG"
            sed -i "/^\[database\]/,/^\[/s/^password.*/password = $GRAFANA_PASSWORD/" "$GRAFANA_CONFIG"
        else
            # 添加新配置
            echo "" >> "$GRAFANA_CONFIG"
            echo "[database]" >> "$GRAFANA_CONFIG"
            echo "type = postgres" >> "$GRAFANA_CONFIG"
            echo "host = $PG_HOST:$PG_PORT" >> "$GRAFANA_CONFIG"
            echo "name = $PG_DB" >> "$GRAFANA_CONFIG"
            echo "user = $GRAFANA_ROLE" >> "$GRAFANA_CONFIG"
            echo "password = $GRAFANA_PASSWORD" >> "$GRAFANA_CONFIG"
        fi
        
        success "Grafana配置文件已更新。"
    else
        warning "Grafana配置文件 '$GRAFANA_CONFIG' 不存在，将使用环境变量配置。"
        
        # 设置环境变量
        export GF_DATABASE_TYPE=postgres
        export GF_DATABASE_HOST="$PG_HOST:$PG_PORT"
        export GF_DATABASE_NAME="$PG_DB"
        export GF_DATABASE_USER="$GRAFANA_ROLE"
        export GF_DATABASE_PASSWORD="$GRAFANA_PASSWORD"
    fi
    
    # 重启Grafana服务以创建表结构
    if [ "$RESTART_GRAFANA" = true ]; then
        info "重启Grafana服务以创建表结构..."
        
        if command -v systemctl &> /dev/null; then
            # 使用systemd
            if systemctl restart "$GRAFANA_SERVICE"; then
                success "Grafana服务已重启。"
            else
                error "重启Grafana服务失败。"
                exit 1
            fi
        elif command -v service &> /dev/null; then
            # 使用service
            if service "$GRAFANA_SERVICE" restart; then
                success "Grafana服务已重启。"
            else
                error "重启Grafana服务失败。"
                exit 1
            fi
        else
            error "无法重启Grafana服务，未找到systemctl或service命令。"
            exit 1
        fi
        
        # 等待Grafana启动并创建表结构
        info "等待Grafana创建表结构..."
        sleep 10
    else
        warning "跳过重启Grafana服务。请手动重启Grafana以创建表结构。"
    fi
    
    # 检查表结构是否已创建
    info "检查PostgreSQL表结构..."
    TABLES_COUNT=$(psql $PSQL_CONN -d $PG_DB -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';")
    
    if [ "$TABLES_COUNT" -gt 0 ]; then
        success "PostgreSQL表结构已创建，共 $TABLES_COUNT 个表。"
    else
        error "PostgreSQL表结构创建失败。请检查Grafana日志。"
        exit 1
    fi
}

# 导入数据到PostgreSQL
import_data_to_postgres() {
    info "导入数据到PostgreSQL..."
    
    # 获取所有CSV文件
    CSV_FILES=$(find "$TEMP_DIR" -name "*.csv")
    
    for CSV_FILE in $CSV_FILES; do
        # 获取表名（从文件名）
        TABLE=$(basename "$CSV_FILE" .csv)
        
        info "导入数据到表 '$TABLE'..."
        
        # 获取列名（从CSV文件第一行）
        COLUMNS=$(head -n 1 "$CSV_FILE")
        
        # 创建临时COPY命令文件
        COPY_FILE="$TEMP_DIR/${TABLE}_copy.sql"
        
        echo "\COPY $TABLE($COLUMNS) FROM '$CSV_FILE' WITH CSV HEADER;" > "$COPY_FILE"
        
        # 导入数据
        if psql $PSQL_CONN -d $PG_DB -f "$COPY_FILE"; then
            success "数据已导入到表 '$TABLE'。"
        else
            warning "导入数据到表 '$TABLE' 失败。这可能是由于表结构不匹配或数据格式问题。"
        fi
    done
}

# 修复表的所有权
fix_table_ownership() {
    if [ "$FIX_OWNERSHIP" = true ]; then
        info "修复表的所有权..."
        
        # 修复所有表的所有权
        psql $PSQL_CONN -d $PG_DB -c "DO \\$\\$
        DECLARE
            t record;
        BEGIN
            FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
            LOOP
                EXECUTE 'ALTER TABLE public.' || quote_ident(t.tablename) || ' OWNER TO $GRAFANA_ROLE';
            END LOOP;
        END
        \\$\\$;"
        
        # 修复所有序列的所有权
        psql $PSQL_CONN -d $PG_DB -c "DO \\$\\$
        DECLARE
            s record;
        BEGIN
            FOR s IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public'
            LOOP
                EXECUTE 'ALTER SEQUENCE public.' || quote_ident(s.sequence_name) || ' OWNER TO $GRAFANA_ROLE';
            END LOOP;
        END
        \\$\\$;"
        
        success "表的所有权已修复。"
    else
        info "跳过修复表的所有权。"
    fi
}

# 清理临时文件
cleanup() {
    info "清理临时文件..."
    
    # 保留备份文件，但删除临时文件
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        success "临时文件已清理。"
    fi
}

# 验证迁移
verify_migration() {
    info "验证迁移..."
    
    # 检查PostgreSQL中的表数量
    PG_TABLES_COUNT=$(psql $PSQL_CONN -d $PG_DB -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';")
    
    # 检查SQLite中的表数量
    SQLITE_TABLES_COUNT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
    
    info "SQLite表数量: $SQLITE_TABLES_COUNT"
    info "PostgreSQL表数量: $PG_TABLES_COUNT"
    
    # 检查一些关键表中的数据量
    for TABLE in dashboard user org data_source; do
        if sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$TABLE';" | grep -q "$TABLE"; then
            SQLITE_COUNT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM $TABLE;")
            PG_COUNT=$(psql $PSQL_CONN -d $PG_DB -tAc "SELECT COUNT(*) FROM $TABLE;")
            
            info "表 '$TABLE' 中的数据量: SQLite=$SQLITE_COUNT, PostgreSQL=$PG_COUNT"
            
            if [ "$PG_COUNT" -lt "$SQLITE_COUNT" ]; then
                warning "表 '$TABLE' 中的数据可能未完全迁移。"
            fi
        fi
    done
    
    # 验证Grafana是否可以连接到PostgreSQL
    if [ "$RESTART_GRAFANA" = true ]; then
        info "检查Grafana是否可以连接到PostgreSQL..."
        
        # 等待Grafana启动
        sleep 5
        
        # 检查Grafana日志中是否有数据库连接错误
        if command -v journalctl &> /dev/null; then
            # 使用journalctl
            DB_ERRORS=$(journalctl -u "$GRAFANA_SERVICE" -n 50 | grep -i "database\|postgres\|sql" | grep -i "error\|fail\|cannot")
        elif [ -f "/var/log/grafana/grafana.log" ]; then
            # 直接读取日志文件
            DB_ERRORS=$(tail -n 50 /var/log/grafana/grafana.log | grep -i "database\|postgres\|sql" | grep -i "error\|fail\|cannot")
        fi
        
        if [ -n "$DB_ERRORS" ]; then
            warning "Grafana日志中发现数据库相关错误:"
            echo "$DB_ERRORS"
        else
            success "未发现Grafana数据库连接错误。"
        fi
    fi
    
    success "迁移验证完成。"
}

# 显示迁移摘要
show_summary() {
    echo ""
    echo "=== Grafana SQLite到PostgreSQL迁移摘要 ==="
    echo ""
    echo "SQLite数据库: $SQLITE_DB"
    echo "PostgreSQL服务器: $PG_HOST:$PG_PORT"
    echo "PostgreSQL数据库: $PG_DB"
    echo "Grafana角色: $GRAFANA_ROLE"
    echo "备份目录: $BACKUP_DIR"
    echo ""
    echo "Grafana配置:"
    echo "  type = postgres"
    echo "  host = $PG_HOST:$PG_PORT"
    echo "  name = $PG_DB"
    echo "  user = $GRAFANA_ROLE"
    echo "  password = ********"
    echo ""
    echo "如果您使用Docker或Kubernetes部署Grafana，请相应地更新环境变量:"
    echo "  GF_DATABASE_TYPE=postgres"
    echo "  GF_DATABASE_HOST=$PG_HOST:$PG_PORT"
    echo "  GF_DATABASE_NAME=$PG_DB"
    echo "  GF_DATABASE_USER=$GRAFANA_ROLE"
    echo "  GF_DATABASE_PASSWORD=$GRAFANA_PASSWORD"
    echo ""
    echo "迁移已完成！请检查Grafana是否正常工作。"
    echo ""
}

# 主函数
main() {
    echo "=== Grafana SQLite到PostgreSQL迁移工具 ==="
    echo ""
    
    # 检查命令
    check_commands
    
    # 检查SQLite数据库
    check_sqlite_db
    
    # 检查PostgreSQL连接
    check_postgres_connection
    
    # 备份SQLite数据库
    backup_sqlite_db
    
    # 创建PostgreSQL数据库和角色
    create_postgres_db_and_role
    
    # 导出SQLite数据库结构
    export_sqlite_schema
    
    # 导出SQLite数据
    export_sqlite_data
    
    # 创建PostgreSQL表结构
    create_postgres_schema
    
    # 导入数据到PostgreSQL
    import_data_to_postgres
    
    # 修复表的所有权
    fix_table_ownership
    
    # 验证迁移
    verify_migration
    
    # 清理临时文件
    cleanup
    
    # 显示迁移摘要
    show_summary
}

# 执行主函数
main