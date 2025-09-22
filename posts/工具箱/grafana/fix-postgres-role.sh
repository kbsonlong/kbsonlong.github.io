#!/bin/bash

# 修复PostgreSQL "role does not exist" 错误的脚本
# 适用于Grafana数据库迁移场景
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
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="grafana"
DB_USER="postgres"
DB_PASSWORD=""
ROLE_NAME="grafana"
ROLE_PASSWORD="grafana_password"
GRANT_SUPERUSER=false

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "此脚本用于修复PostgreSQL中'role does not exist'错误，特别适用于Grafana数据库迁移场景。"
    echo ""
    echo "选项:"
    echo "  -h, --host HOST          PostgreSQL主机地址 (默认: localhost)"
    echo "  -p, --port PORT          PostgreSQL端口 (默认: 5432)"
    echo "  -d, --database DB_NAME   数据库名称 (默认: grafana)"
    echo "  -u, --user USER          数据库用户名 (默认: postgres)"
    echo "  -P, --password PASSWORD  数据库密码"
    echo "  -r, --role ROLE          要创建的角色名称 (默认: grafana)"
    echo "  -R, --role-password PWD  新角色的密码 (默认: grafana_password)"
    echo "  -s, --superuser          授予新角色超级用户权限"
    echo "  -l, --list-roles         列出当前所有角色"
    echo "  -f, --fix-ownership      修复表的所有权"
    echo "  --help                   显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -h localhost -p 5432 -d grafana -u postgres -P mypassword -r grafana -R secure_pwd"
    echo ""
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--host)
            DB_HOST="$2"
            shift 2
            ;;
        -p|--port)
            DB_PORT="$2"
            shift 2
            ;;
        -d|--database)
            DB_NAME="$2"
            shift 2
            ;;
        -u|--user)
            DB_USER="$2"
            shift 2
            ;;
        -P|--password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        -r|--role)
            ROLE_NAME="$2"
            shift 2
            ;;
        -R|--role-password)
            ROLE_PASSWORD="$2"
            shift 2
            ;;
        -s|--superuser)
            GRANT_SUPERUSER=true
            shift
            ;;
        -l|--list-roles)
            LIST_ROLES=true
            shift
            ;;
        -f|--fix-ownership)
            FIX_OWNERSHIP=true
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

# 检查psql命令是否可用
if ! command -v psql &> /dev/null; then
    error "psql命令未找到。请确保PostgreSQL客户端已安装。"
    exit 1
fi

# 构建PSQL连接字符串
PSQL_CONN="-h $DB_HOST -p $DB_PORT -U $DB_USER"
if [ -n "$DB_PASSWORD" ]; then
    export PGPASSWORD="$DB_PASSWORD"
fi

# 测试数据库连接
info "测试与PostgreSQL服务器的连接..."
if ! psql $PSQL_CONN -d postgres -c "\q" &> /dev/null; then
    error "无法连接到PostgreSQL服务器。请检查连接参数。"
    exit 1
fi
success "成功连接到PostgreSQL服务器。"

# 检查数据库是否存在
info "检查数据库 '$DB_NAME' 是否存在..."
if ! psql $PSQL_CONN -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    warning "数据库 '$DB_NAME' 不存在。"
    read -p "是否创建数据库 '$DB_NAME'? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "创建数据库 '$DB_NAME'..."
        if psql $PSQL_CONN -d postgres -c "CREATE DATABASE $DB_NAME"; then
            success "数据库 '$DB_NAME' 创建成功。"
        else
            error "创建数据库 '$DB_NAME' 失败。"
            exit 1
        fi
    else
        error "无法继续，因为数据库 '$DB_NAME' 不存在。"
        exit 1
    fi
else
    success "数据库 '$DB_NAME' 已存在。"
fi

# 列出当前角色
if [ "$LIST_ROLES" = true ]; then
    info "列出当前所有角色:"
    psql $PSQL_CONN -d postgres -c "SELECT rolname, rolsuper, rolcreaterole FROM pg_roles;"
    exit 0
fi

# 检查角色是否已存在
info "检查角色 '$ROLE_NAME' 是否存在..."
ROLE_EXISTS=$(psql $PSQL_CONN -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$ROLE_NAME'")

if [ "$ROLE_EXISTS" = "1" ]; then
    warning "角色 '$ROLE_NAME' 已存在。"
    read -p "是否重置角色 '$ROLE_NAME' 的密码和权限? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "重置角色 '$ROLE_NAME'..."
        psql $PSQL_CONN -d postgres -c "ALTER ROLE $ROLE_NAME WITH LOGIN PASSWORD '$ROLE_PASSWORD';"
        
        if [ "$GRANT_SUPERUSER" = true ]; then
            psql $PSQL_CONN -d postgres -c "ALTER ROLE $ROLE_NAME WITH SUPERUSER;"
        fi
        
        psql $PSQL_CONN -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $ROLE_NAME;"
        success "角色 '$ROLE_NAME' 已重置。"
    else
        info "保持角色 '$ROLE_NAME' 不变。"
    fi
else
    info "创建角色 '$ROLE_NAME'..."
    SUPERUSER_OPT=""
    if [ "$GRANT_SUPERUSER" = true ]; then
        SUPERUSER_OPT="SUPERUSER"
    fi
    
    if psql $PSQL_CONN -d postgres -c "CREATE ROLE $ROLE_NAME WITH LOGIN PASSWORD '$ROLE_PASSWORD' $SUPERUSER_OPT;"; then
        success "角色 '$ROLE_NAME' 创建成功。"
        
        info "授予角色 '$ROLE_NAME' 对数据库 '$DB_NAME' 的权限..."
        if psql $PSQL_CONN -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $ROLE_NAME;"; then
            success "权限授予成功。"
        else
            error "授予权限失败。"
        fi
    else
        error "创建角色 '$ROLE_NAME' 失败。"
        exit 1
    fi
fi

# 修复表的所有权
if [ "$FIX_OWNERSHIP" = true ]; then
    info "修复数据库 '$DB_NAME' 中表的所有权..."
    
    # 获取所有表
    TABLES=$(psql $PSQL_CONN -d $DB_NAME -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public';")
    
    # 修改每个表的所有者
    for TABLE in $TABLES; do
        info "将表 '$TABLE' 的所有者更改为 '$ROLE_NAME'..."
        if psql $PSQL_CONN -d $DB_NAME -c "ALTER TABLE public.\"$TABLE\" OWNER TO $ROLE_NAME;"; then
            success "表 '$TABLE' 的所有者已更改为 '$ROLE_NAME'。"
        else
            warning "更改表 '$TABLE' 的所有者失败。"
        fi
    done
    
    # 获取所有序列
    SEQUENCES=$(psql $PSQL_CONN -d $DB_NAME -tAc "SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public';")
    
    # 修改每个序列的所有者
    for SEQ in $SEQUENCES; do
        info "将序列 '$SEQ' 的所有者更改为 '$ROLE_NAME'..."
        if psql $PSQL_CONN -d $DB_NAME -c "ALTER SEQUENCE public.\"$SEQ\" OWNER TO $ROLE_NAME;"; then
            success "序列 '$SEQ' 的所有者已更改为 '$ROLE_NAME'。"
        else
            warning "更改序列 '$SEQ' 的所有者失败。"
        fi
    done
    
    success "所有权修复完成。"
fi

# 验证角色是否可以连接
info "验证角色 '$ROLE_NAME' 是否可以连接到数据库..."

# 保存当前PGPASSWORD
OLD_PGPASSWORD=$PGPASSWORD

# 设置新角色的密码
export PGPASSWORD="$ROLE_PASSWORD"

if psql -h $DB_HOST -p $DB_PORT -U $ROLE_NAME -d $DB_NAME -c "\q" &> /dev/null; then
    success "角色 '$ROLE_NAME' 可以成功连接到数据库 '$DB_NAME'。"
    
    # 提供Grafana配置示例
    echo ""
    info "Grafana配置示例:"
    echo "在grafana.ini中添加以下配置:"
    echo ""
    echo "[database]"
    echo "type = postgres"
    echo "host = $DB_HOST:$DB_PORT"
    echo "name = $DB_NAME"
    echo "user = $ROLE_NAME"
    echo "password = $ROLE_PASSWORD"
    echo ""
    echo "或者使用环境变量:"
    echo ""
    echo "export GF_DATABASE_TYPE=postgres"
    echo "export GF_DATABASE_HOST=$DB_HOST:$DB_PORT"
    echo "export GF_DATABASE_NAME=$DB_NAME"
    echo "export GF_DATABASE_USER=$ROLE_NAME"
    echo "export GF_DATABASE_PASSWORD=$ROLE_PASSWORD"
    echo ""
    
    # 如果是Docker环境，提供docker-compose示例
    echo "Docker环境示例:"
    echo ""
    echo "version: '3'"
    echo "services:"
    echo "  grafana:"
    echo "    image: grafana/grafana:latest"
    echo "    environment:"
    echo "      - GF_DATABASE_TYPE=postgres"
    echo "      - GF_DATABASE_HOST=postgres:5432"
    echo "      - GF_DATABASE_NAME=$DB_NAME"
    echo "      - GF_DATABASE_USER=$ROLE_NAME"
    echo "      - GF_DATABASE_PASSWORD=$ROLE_PASSWORD"
    echo "    ports:"
    echo "      - 3000:3000"
    echo ""
    echo "  postgres:"
    echo "    image: postgres:13"
    echo "    environment:"
    echo "      - POSTGRES_USER=$DB_USER"
    echo "      - POSTGRES_PASSWORD=$DB_PASSWORD"
    echo "      - POSTGRES_DB=$DB_NAME"
    echo "    volumes:"
    echo "      - postgres-data:/var/lib/postgresql/data"
    echo ""
    echo "volumes:"
    echo "  postgres-data:"
    echo ""
else
    error "角色 '$ROLE_NAME' 无法连接到数据库 '$DB_NAME'。请检查权限设置。"
fi

# 恢复原始PGPASSWORD
export PGPASSWORD="$OLD_PGPASSWORD"

echo ""
success "PostgreSQL角色修复操作完成。"
echo "如果您仍然遇到'role does not exist'错误，请尝试使用--fix-ownership选项运行此脚本。"
echo ""