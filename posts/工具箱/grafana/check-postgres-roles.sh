#!/bin/bash

# PostgreSQL角色检查和修复脚本 - Kubernetes环境
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
NAMESPACE="default"
POSTGRES_POD=""
POSTGRES_USER="postgres"
DB_NAME="grafana"
ROLE_NAME="grafana"
ROLE_PASSWORD="grafana_password"
FIX_OWNERSHIP=false
CREATE_ROLE=false

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "此脚本用于在Kubernetes环境中检查和修复PostgreSQL角色问题，特别是针对Grafana数据库。"
    echo ""
    echo "选项:"
    echo "  -n, --namespace NAMESPACE  Kubernetes命名空间 (默认: default)"
    echo "  -p, --pod POD_NAME        PostgreSQL Pod名称 (必需)"
    echo "  -u, --user USER           PostgreSQL用户名 (默认: postgres)"
    echo "  -d, --database DB_NAME    数据库名称 (默认: grafana)"
    echo "  -r, --role ROLE           要检查/创建的角色名称 (默认: grafana)"
    echo "  -P, --password PASSWORD   角色密码 (默认: grafana_password)"
    echo "  -f, --fix-ownership       修复表的所有权"
    echo "  -c, --create-role         如果角色不存在，则创建"
    echo "  -l, --list-roles          列出当前所有角色"
    echo "  -h, --help                显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -n monitoring -p postgres-0 -f -c"
    echo ""
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -p|--pod)
            POSTGRES_POD="$2"
            shift 2
            ;;
        -u|--user)
            POSTGRES_USER="$2"
            shift 2
            ;;
        -d|--database)
            DB_NAME="$2"
            shift 2
            ;;
        -r|--role)
            ROLE_NAME="$2"
            shift 2
            ;;
        -P|--password)
            ROLE_PASSWORD="$2"
            shift 2
            ;;
        -f|--fix-ownership)
            FIX_OWNERSHIP=true
            shift
            ;;
        -c|--create-role)
            CREATE_ROLE=true
            shift
            ;;
        -l|--list-roles)
            LIST_ROLES=true
            shift
            ;;
        -h|--help)
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

# 检查必需参数
if [ -z "$POSTGRES_POD" ]; then
    error "必须指定PostgreSQL Pod名称 (-p, --pod)"
    show_help
    exit 1
fi

# 检查kubectl命令是否可用
if ! command -v kubectl &> /dev/null; then
    error "kubectl命令未找到。请确保Kubernetes客户端已安装。"
    exit 1
fi

# 检查Pod是否存在
info "检查Pod '$POSTGRES_POD'是否存在于命名空间'$NAMESPACE'..."
if ! kubectl get pod "$POSTGRES_POD" -n "$NAMESPACE" &> /dev/null; then
    error "Pod '$POSTGRES_POD'在命名空间'$NAMESPACE'中不存在。"
    exit 1
fi
success "Pod '$POSTGRES_POD'存在。"

# 列出当前角色
if [ "$LIST_ROLES" = true ]; then
    info "列出当前所有角色:"
    kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -c "SELECT rolname, rolsuper, rolcreaterole FROM pg_roles;"
    exit 0
fi

# 检查数据库是否存在
info "检查数据库 '$DB_NAME' 是否存在..."
DB_EXISTS=$(kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")

if [ -z "$DB_EXISTS" ]; then
    warning "数据库 '$DB_NAME' 不存在。"
    read -p "是否创建数据库 '$DB_NAME'? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "创建数据库 '$DB_NAME'..."
        if kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -c "CREATE DATABASE $DB_NAME;"; then
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

# 检查角色是否已存在
info "检查角色 '$ROLE_NAME' 是否存在..."
ROLE_EXISTS=$(kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$ROLE_NAME'")

if [ -n "$ROLE_EXISTS" ]; then
    success "角色 '$ROLE_NAME' 已存在。"
    
    # 如果需要，重置角色密码和权限
    read -p "是否重置角色 '$ROLE_NAME' 的密码和权限? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "重置角色 '$ROLE_NAME'..."
        kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -c "ALTER ROLE $ROLE_NAME WITH LOGIN PASSWORD '$ROLE_PASSWORD';"
        kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $ROLE_NAME;"
        success "角色 '$ROLE_NAME' 已重置。"
    else
        info "保持角色 '$ROLE_NAME' 不变。"
    fi
elif [ "$CREATE_ROLE" = true ]; then
    info "创建角色 '$ROLE_NAME'..."
    if kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -c "CREATE ROLE $ROLE_NAME WITH LOGIN PASSWORD '$ROLE_PASSWORD';"; then
        success "角色 '$ROLE_NAME' 创建成功。"
        
        info "授予角色 '$ROLE_NAME' 对数据库 '$DB_NAME' 的权限..."
        if kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $ROLE_NAME;"; then
            success "权限授予成功。"
            
            # 设置schema权限
            info "设置schema权限..."
            kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $ROLE_NAME;"
            kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO $ROLE_NAME;"
            kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO $ROLE_NAME;"
            kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO $ROLE_NAME;"
            success "Schema权限设置成功。"
        else
            error "授予权限失败。"
        fi
    else
        error "创建角色 '$ROLE_NAME' 失败。"
        exit 1
    fi
else
    warning "角色 '$ROLE_NAME' 不存在，但未指定--create-role选项。"
    exit 1
fi

# 修复表的所有权
if [ "$FIX_OWNERSHIP" = true ]; then
    info "修复数据库 '$DB_NAME' 中表的所有权..."
    
    # 获取所有表
    TABLES=$(kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public';")
    
    # 修改每个表的所有者
    for TABLE in $TABLES; do
        info "将表 '$TABLE' 的所有者更改为 '$ROLE_NAME'..."
        if kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "ALTER TABLE public.\"$TABLE\" OWNER TO $ROLE_NAME;"; then
            success "表 '$TABLE' 的所有者已更改为 '$ROLE_NAME'。"
        else
            warning "更改表 '$TABLE' 的所有者失败。"
        fi
    done
    
    # 获取所有序列
    SEQUENCES=$(kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc "SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public';")
    
    # 修改每个序列的所有者
    for SEQ in $SEQUENCES; do
        info "将序列 '$SEQ' 的所有者更改为 '$ROLE_NAME'..."
        if kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "ALTER SEQUENCE public.\"$SEQ\" OWNER TO $ROLE_NAME;"; then
            success "序列 '$SEQ' 的所有者已更改为 '$ROLE_NAME'。"
        else
            warning "更改序列 '$SEQ' 的所有者失败。"
        fi
    done
    
    # 获取所有视图
    VIEWS=$(kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc "SELECT table_name FROM information_schema.views WHERE table_schema='public';")
    
    # 修改每个视图的所有者
    for VIEW in $VIEWS; do
        info "将视图 '$VIEW' 的所有者更改为 '$ROLE_NAME'..."
        if kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "ALTER VIEW public.\"$VIEW\" OWNER TO $ROLE_NAME;"; then
            success "视图 '$VIEW' 的所有者已更改为 '$ROLE_NAME'。"
        else
            warning "更改视图 '$VIEW' 的所有者失败。"
        fi
    done
    
    success "所有权修复完成。"
fi

# 验证角色是否可以连接
info "验证角色 '$ROLE_NAME' 是否可以连接到数据库..."

if kubectl exec -it "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$ROLE_NAME" -d "$DB_NAME" -c "\q" &> /dev/null; then
    success "角色 '$ROLE_NAME' 可以成功连接到数据库 '$DB_NAME'。"
    
    # 提供Grafana配置示例
    echo ""
    info "Grafana配置示例:"
    echo "在Kubernetes中，更新Grafana Deployment的环境变量:"
    echo ""
    echo "env:"
    echo "- name: GF_DATABASE_TYPE"
    echo "  value: postgres"
    echo "- name: GF_DATABASE_HOST"
    echo "  value: postgres-service:5432"
    echo "- name: GF_DATABASE_NAME"
    echo "  value: $DB_NAME"
    echo "- name: GF_DATABASE_USER"
    echo "  value: $ROLE_NAME"
    echo "- name: GF_DATABASE_PASSWORD"
    echo "  valueFrom:"
    echo "    secretKeyRef:"
    echo "      name: grafana-db-secret"
    echo "      key: password"
    echo ""
    echo "确保创建包含密码的Secret:"
    echo ""
    echo "kubectl create secret generic grafana-db-secret \\"
    echo "  --from-literal=password=$ROLE_PASSWORD \\"
    echo "  -n $NAMESPACE"
    echo ""
else
    error "角色 '$ROLE_NAME' 无法连接到数据库 '$DB_NAME'。请检查权限设置。"
fi

echo ""
success "PostgreSQL角色检查和修复操作完成。"
echo "如果您仍然遇到'role does not exist'错误，请尝试使用--fix-ownership选项运行此脚本。"
echo ""