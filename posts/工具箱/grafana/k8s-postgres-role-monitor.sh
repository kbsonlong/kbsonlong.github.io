#!/bin/bash

# k8s-postgres-role-monitor.sh
# 创建日期: 2023-07-26
# 最后修改: 2023-07-26
# 描述: 监控Kubernetes中PostgreSQL角色状态并自动修复

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认值
NAMESPACE="monitoring"
POSTGRES_POD_PREFIX="postgres"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD=""
GRAFANA_DB="grafana"
GRAFANA_ROLE="grafana"
GRAFANA_PASSWORD=""
CHECK_INTERVAL=300 # 5分钟检查一次
FIX_AUTOMATICALLY=false
VERBOSE=false
LOG_FILE="/var/log/postgres-role-monitor.log"

# 使用说明
usage() {
    echo -e "${BLUE}Kubernetes PostgreSQL角色监控和修复工具${NC}"
    echo -e "监控PostgreSQL中的角色状态，检测'role does not exist'错误并自动修复"
    echo ""
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 [选项]"
    echo ""
    echo -e "${YELLOW}选项:${NC}"
    echo "  -n, --namespace <namespace>     Kubernetes命名空间 (默认: monitoring)"
    echo "  -p, --pod-prefix <prefix>      PostgreSQL Pod名称前缀 (默认: postgres)"
    echo "  -u, --user <username>          PostgreSQL管理员用户名 (默认: postgres)"
    echo "  -w, --password <password>      PostgreSQL管理员密码"
    echo "  -d, --database <database>      Grafana数据库名称 (默认: grafana)"
    echo "  -r, --role <role>              Grafana角色名称 (默认: grafana)"
    echo "  -g, --grafana-pwd <password>   Grafana角色密码"
    echo "  -i, --interval <seconds>       检查间隔，单位秒 (默认: 300)"
    echo "  -f, --fix                      自动修复检测到的问题"
    echo "  -v, --verbose                  显示详细输出"
    echo "  -l, --log <file>               日志文件路径 (默认: /var/log/postgres-role-monitor.log)"
    echo "  -h, --help                     显示此帮助信息"
    echo ""
    echo -e "${YELLOW}示例:${NC}"
    echo "  $0 --namespace monitoring --pod-prefix postgres --fix"
    echo "  $0 -n monitoring -p postgres -u postgres -w secret -r grafana -g grafana_pwd -f -v"
    exit 1
}

# 日志函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $timestamp - $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $timestamp - $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $timestamp - $message"
            ;;
        "DEBUG")
            if [ "$VERBOSE" = true ]; then
                echo -e "${BLUE}[DEBUG]${NC} $timestamp - $message"
            fi
            ;;
    esac
    
    echo "[$level] $timestamp - $message" >> "$LOG_FILE"
}

# 参数解析
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -p|--pod-prefix)
            POSTGRES_POD_PREFIX="$2"
            shift 2
            ;;
        -u|--user)
            POSTGRES_USER="$2"
            shift 2
            ;;
        -w|--password)
            POSTGRES_PASSWORD="$2"
            shift 2
            ;;
        -d|--database)
            GRAFANA_DB="$2"
            shift 2
            ;;
        -r|--role)
            GRAFANA_ROLE="$2"
            shift 2
            ;;
        -g|--grafana-pwd)
            GRAFANA_PASSWORD="$2"
            shift 2
            ;;
        -i|--interval)
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        -f|--fix)
            FIX_AUTOMATICALLY=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}未知选项: $1${NC}"
            usage
            ;;
    esac
done

# 检查必要参数
if [ -z "$POSTGRES_PASSWORD" ]; then
    log "ERROR" "PostgreSQL管理员密码未提供"
    usage
fi

if [ -z "$GRAFANA_PASSWORD" ]; then
    GRAFANA_PASSWORD="grafana_password"
    log "WARN" "Grafana角色密码未提供，使用默认值: grafana_password"
fi

# 创建日志目录
log_dir=$(dirname "$LOG_FILE")
if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir"
fi

log "INFO" "启动PostgreSQL角色监控，命名空间: $NAMESPACE，Pod前缀: $POSTGRES_POD_PREFIX"

# 获取PostgreSQL Pod名称
get_postgres_pod() {
    kubectl get pods -n "$NAMESPACE" | grep "$POSTGRES_POD_PREFIX" | grep Running | head -n 1 | awk '{print $1}'
}

# 检查PostgreSQL角色
check_postgres_role() {
    local pod_name=$1
    
    log "DEBUG" "检查PostgreSQL Pod: $pod_name 中的角色"
    
    # 检查角色是否存在
    role_exists=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$GRAFANA_ROLE'\"")
    
    if [ -z "$role_exists" ]; then
        log "WARN" "角色 '$GRAFANA_ROLE' 不存在"
        return 1
    else
        log "DEBUG" "角色 '$GRAFANA_ROLE' 存在"
        return 0
    fi
}

# 检查数据库是否存在
check_database() {
    local pod_name=$1
    
    log "DEBUG" "检查数据库 '$GRAFANA_DB' 是否存在"
    
    db_exists=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='$GRAFANA_DB'\"")
    
    if [ -z "$db_exists" ]; then
        log "WARN" "数据库 '$GRAFANA_DB' 不存在"
        return 1
    else
        log "DEBUG" "数据库 '$GRAFANA_DB' 存在"
        return 0
    fi
}

# 检查表所有权
check_table_ownership() {
    local pod_name=$1
    
    log "DEBUG" "检查表所有权"
    
    # 获取不属于grafana角色的表
    wrong_ownership=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -tAc \"SELECT tablename FROM pg_tables WHERE schemaname='public' AND tableowner != '$GRAFANA_ROLE'\"")
    
    if [ -n "$wrong_ownership" ]; then
        log "WARN" "发现表所有权问题:"
        echo "$wrong_ownership" | while read table; do
            log "WARN" "  表 '$table' 不属于 '$GRAFANA_ROLE'"
        done
        return 1
    else
        log "DEBUG" "所有表所有权正确"
        return 0
    fi
}

# 修复PostgreSQL角色
fix_postgres_role() {
    local pod_name=$1
    
    log "INFO" "开始修复PostgreSQL角色问题"
    
    # 创建角色（如果不存在）
    if ! check_postgres_role "$pod_name"; then
        log "INFO" "创建角色 '$GRAFANA_ROLE'"
        kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -c \"CREATE ROLE $GRAFANA_ROLE WITH LOGIN PASSWORD '$GRAFANA_PASSWORD';\"" || {
            log "ERROR" "创建角色失败"
            return 1
        }
    else
        log "INFO" "更新角色 '$GRAFANA_ROLE' 的密码"
        kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -c \"ALTER ROLE $GRAFANA_ROLE WITH LOGIN PASSWORD '$GRAFANA_PASSWORD';\"" || {
            log "ERROR" "更新角色密码失败"
            return 1
        }
    fi
    
    # 创建数据库（如果不存在）
    if ! check_database "$pod_name"; then
        log "INFO" "创建数据库 '$GRAFANA_DB'"
        kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -c \"CREATE DATABASE $GRAFANA_DB;\"" || {
            log "ERROR" "创建数据库失败"
            return 1
        }
    fi
    
    # 授予权限
    log "INFO" "授予数据库权限"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -c \"GRANT ALL PRIVILEGES ON DATABASE $GRAFANA_DB TO $GRAFANA_ROLE;\"" || {
        log "ERROR" "授予数据库权限失败"
        return 1
    }
    
    log "INFO" "授予schema权限"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"GRANT ALL PRIVILEGES ON SCHEMA public TO $GRAFANA_ROLE;\"" || {
        log "ERROR" "授予schema权限失败"
        return 1
    }
    
    log "INFO" "设置默认权限"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO $GRAFANA_ROLE;\"" || {
        log "ERROR" "设置表默认权限失败"
        return 1
    }
    
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO $GRAFANA_ROLE;\"" || {
        log "ERROR" "设置序列默认权限失败"
        return 1
    }
    
    # 创建触发器函数，自动将新表的所有权分配给grafana角色
    log "INFO" "创建自动分配所有权的触发器函数"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"CREATE OR REPLACE FUNCTION assign_ownership_to_grafana()
    RETURNS event_trigger AS \\\\$\\\\$
    DECLARE
        obj record;
    BEGIN
        FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE command_tag IN ('CREATE TABLE', 'CREATE SEQUENCE')
        LOOP
            IF obj.object_type IN ('table', 'sequence') THEN
                EXECUTE format('ALTER %s %s OWNER TO $GRAFANA_ROLE', obj.object_type, obj.object_identity);
            END IF;
        END LOOP;
    END;
    \\\\$\\\\$ LANGUAGE plpgsql;\"" || {
        log "ERROR" "创建触发器函数失败"
        return 1
    }
    
    # 创建事件触发器
    log "INFO" "创建事件触发器"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"DO \\\\$\\\\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'grafana_ownership_trigger') THEN
            CREATE EVENT TRIGGER grafana_ownership_trigger ON ddl_command_end
            WHEN TAG IN ('CREATE TABLE', 'CREATE SEQUENCE')
            EXECUTE PROCEDURE assign_ownership_to_grafana();
        END IF;
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'Skipping event trigger creation due to insufficient privileges';
    END
    \\\\$\\\\$;\"" || {
        log "WARN" "创建事件触发器失败，可能是权限不足"
    }
    
    # 修复表的所有权
    log "INFO" "修复表的所有权"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"DO \\\\$\\\\$
    DECLARE
        t record;
    BEGIN
        FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
        LOOP
            EXECUTE 'ALTER TABLE public.' || quote_ident(t.tablename) || ' OWNER TO $GRAFANA_ROLE';
        END LOOP;
    END
    \\\\$\\\\$;\"" || {
        log "ERROR" "修复表所有权失败"
        return 1
    }
    
    # 修复序列的所有权
    log "INFO" "修复序列的所有权"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"DO \\\\$\\\\$
    DECLARE
        s record;
    BEGIN
        FOR s IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public'
        LOOP
            EXECUTE 'ALTER SEQUENCE public.' || quote_ident(s.sequence_name) || ' OWNER TO $GRAFANA_ROLE';
        END LOOP;
    END
    \\\\$\\\\$;\"" || {
        log "ERROR" "修复序列所有权失败"
        return 1
    }
    
    # 修复视图的所有权
    log "INFO" "修复视图的所有权"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $GRAFANA_DB -c \"DO \\\\$\\\\$
    DECLARE
        v record;
    BEGIN
        FOR v IN SELECT table_name FROM information_schema.views WHERE table_schema = 'public'
        LOOP
            EXECUTE 'ALTER VIEW public.' || quote_ident(v.table_name) || ' OWNER TO $GRAFANA_ROLE';
        END LOOP;
    END
    \\\\$\\\\$;\"" || {
        log "WARN" "修复视图所有权失败，可能没有视图"
    }
    
    log "INFO" "PostgreSQL角色修复完成"
    return 0
}

# 验证修复
verify_fix() {
    local pod_name=$1
    
    log "INFO" "验证修复结果"
    
    # 验证角色
    if ! check_postgres_role "$pod_name"; then
        log "ERROR" "验证失败：角色 '$GRAFANA_ROLE' 仍然不存在"
        return 1
    fi
    
    # 验证数据库
    if ! check_database "$pod_name"; then
        log "ERROR" "验证失败：数据库 '$GRAFANA_DB' 仍然不存在"
        return 1
    fi
    
    # 验证表所有权
    if ! check_table_ownership "$pod_name"; then
        log "ERROR" "验证失败：表所有权问题仍然存在"
        return 1
    fi
    
    # 尝试使用grafana角色连接
    log "INFO" "尝试使用 '$GRAFANA_ROLE' 角色连接数据库"
    connect_result=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- bash -c "PGPASSWORD=$GRAFANA_PASSWORD psql -U $GRAFANA_ROLE -d $GRAFANA_DB -c 'SELECT 1;'" 2>&1)
    
    if [[ $connect_result == *"1"* ]]; then
        log "INFO" "验证成功：可以使用 '$GRAFANA_ROLE' 角色连接数据库"
        return 0
    else
        log "ERROR" "验证失败：无法使用 '$GRAFANA_ROLE' 角色连接数据库"
        log "ERROR" "错误信息: $connect_result"
        return 1
    fi
}

# 检查Grafana日志中的角色错误
check_grafana_logs() {
    local grafana_pods=$(kubectl get pods -n "$NAMESPACE" | grep grafana | grep Running | awk '{print $1}')
    
    if [ -z "$grafana_pods" ]; then
        log "WARN" "未找到运行中的Grafana Pod"
        return 0
    fi
    
    for pod in $grafana_pods; do
        log "DEBUG" "检查Grafana Pod: $pod 的日志"
        
        role_errors=$(kubectl logs -n "$NAMESPACE" "$pod" --tail=100 | grep -i "role.*does not exist" | wc -l)
        
        if [ "$role_errors" -gt 0 ]; then
            log "WARN" "在Grafana Pod $pod 的日志中发现 $role_errors 个角色错误"
            return 1
        else
            log "DEBUG" "Grafana Pod $pod 的日志中没有发现角色错误"
        fi
    done
    
    return 0
}

# 主循环
main() {
    while true; do
        log "INFO" "开始检查PostgreSQL角色状态"
        
        # 获取PostgreSQL Pod
        postgres_pod=$(get_postgres_pod)
        
        if [ -z "$postgres_pod" ]; then
            log "ERROR" "未找到运行中的PostgreSQL Pod"
            sleep "$CHECK_INTERVAL"
            continue
        fi
        
        log "DEBUG" "找到PostgreSQL Pod: $postgres_pod"
        
        # 检查角色状态
        role_ok=true
        
        if ! check_postgres_role "$postgres_pod"; then
            role_ok=false
        fi
        
        if ! check_database "$postgres_pod"; then
            role_ok=false
        fi
        
        if check_database "$postgres_pod" && ! check_table_ownership "$postgres_pod"; then
            role_ok=false
        fi
        
        if check_grafana_logs; then
            log "DEBUG" "Grafana日志中没有发现角色错误"
        else
            role_ok=false
        fi
        
        # 如果发现问题并且启用了自动修复
        if [ "$role_ok" = false ] && [ "$FIX_AUTOMATICALLY" = true ]; then
            log "INFO" "检测到角色问题，开始自动修复"
            
            if fix_postgres_role "$postgres_pod"; then
                if verify_fix "$postgres_pod"; then
                    log "INFO" "角色问题已成功修复"
                    
                    # 重启Grafana Pod（可选）
                    grafana_pods=$(kubectl get pods -n "$NAMESPACE" | grep grafana | grep Running | awk '{print $1}')
                    if [ -n "$grafana_pods" ]; then
                        log "INFO" "重启Grafana Pod以应用更改"
                        for pod in $grafana_pods; do
                            kubectl delete pod -n "$NAMESPACE" "$pod"
                            log "INFO" "已删除Grafana Pod: $pod，等待重新创建"
                        done
                    fi
                else
                    log "ERROR" "角色问题修复验证失败"
                fi
            else
                log "ERROR" "角色问题修复失败"
            fi
        elif [ "$role_ok" = false ]; then
            log "WARN" "检测到角色问题，但未启用自动修复。使用 --fix 选项启用自动修复。"
        else
            log "INFO" "PostgreSQL角色状态正常"
        fi
        
        log "INFO" "检查完成，等待 $CHECK_INTERVAL 秒后再次检查"
        sleep "$CHECK_INTERVAL"
    done
}

# 启动主循环
main