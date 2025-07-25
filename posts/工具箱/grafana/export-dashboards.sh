#!/bin/bash

# Grafana仪表板批量导出脚本
# 使用方法: ./export-dashboards.sh [OPTIONS]

set -e

# 默认配置
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_API_KEY="${GRAFANA_API_KEY}"
OUTPUT_DIR="${OUTPUT_DIR:-./grafana-exports}"
DATE=$(date +"%Y%m%d_%H%M%S")
EXPORT_DIR="$OUTPUT_DIR/export_$DATE"
VERBOSE=false
INCLUDE_PERMISSIONS=false
FOLDER_FILTER=""
TAG_FILTER=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 帮助信息
show_help() {
    cat << EOF
Grafana仪表板批量导出脚本

使用方法: $0 [OPTIONS]

选项:
  -u, --url URL           Grafana URL (默认: http://localhost:3000)
  -k, --api-key KEY       Grafana API密钥 (必需)
  -o, --output DIR        导出目录 (默认: ./grafana-exports)
  -f, --folder NAME       只导出指定文件夹
  -t, --tag TAG           按标签过滤
  -p, --permissions       包含权限信息
  -v, --verbose           详细输出
  -h, --help              显示帮助信息

环境变量:
  GRAFANA_URL             Grafana服务器地址
  GRAFANA_API_KEY         API密钥
  OUTPUT_DIR              导出目录

示例:
  # 基本导出
  $0 --api-key your-api-key
  
  # 导出特定文件夹
  $0 --api-key your-api-key --folder "Production"
  
  # 按标签过滤
  $0 --api-key your-api-key --tag "monitoring"
  
  # 使用环境变量
  export GRAFANA_API_KEY="your-api-key"
  export GRAFANA_URL="http://grafana.example.com"
  $0
EOF
}

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url)
                GRAFANA_URL="$2"
                shift 2
                ;;
            -k|--api-key)
                GRAFANA_API_KEY="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                EXPORT_DIR="$OUTPUT_DIR/export_$DATE"
                shift 2
                ;;
            -f|--folder)
                FOLDER_FILTER="$2"
                shift 2
                ;;
            -t|--tag)
                TAG_FILTER="$2"
                shift 2
                ;;
            -p|--permissions)
                INCLUDE_PERMISSIONS=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "缺少必要依赖: ${missing_deps[*]}"
        log_info "请安装缺少的依赖:"
        for dep in "${missing_deps[@]}"; do
            case $dep in
                curl)
                    echo "  - macOS: brew install curl"
                    echo "  - Ubuntu/Debian: apt-get install curl"
                    echo "  - CentOS/RHEL: yum install curl"
                    ;;
                jq)
                    echo "  - macOS: brew install jq"
                    echo "  - Ubuntu/Debian: apt-get install jq"
                    echo "  - CentOS/RHEL: yum install jq"
                    ;;
            esac
        done
        exit 1
    fi
}

# API请求函数
api_request() {
    local endpoint="$1"
    local method="${2:-GET}"
    local data="$3"
    
    local curl_args=(
        -s
        -H "Authorization: Bearer $GRAFANA_API_KEY"
        -H "Content-Type: application/json"
        --connect-timeout 10
        --max-time 30
    )
    
    if [ "$VERBOSE" = true ]; then
        curl_args+=(-v)
    fi
    
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl_args+=(-X POST -d "$data")
    fi
    
    log_verbose "API请求: $method $GRAFANA_URL$endpoint"
    
    local response
    response=$(curl "${curl_args[@]}" "$GRAFANA_URL$endpoint" 2>/dev/null)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "API请求失败: $endpoint (退出码: $exit_code)"
        return 1
    fi
    
    # 检查是否为有效JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log_error "API返回无效JSON: $endpoint"
        log_verbose "响应内容: $response"
        return 1
    fi
    
    echo "$response"
}

# 测试连接
test_connection() {
    log_info "测试Grafana连接..."
    
    local user_info
    user_info=$(api_request "/api/user")
    
    if [ $? -eq 0 ] && [ -n "$user_info" ]; then
        local login
        local org_id
        local role
        
        login=$(echo "$user_info" | jq -r '.login // "unknown"')
        org_id=$(echo "$user_info" | jq -r '.orgId // "unknown"')
        role=$(echo "$user_info" | jq -r '.role // "unknown"')
        
        log_success "连接成功! 用户: $login, 组织: $org_id, 权限: $role"
        return 0
    else
        log_error "连接失败! 请检查URL和API密钥"
        return 1
    fi
}

# 安全文件名
safe_filename() {
    echo "$1" | sed 's/[^a-zA-Z0-9._-]/_/g' | cut -c1-100
}

# 获取文件夹列表
get_folders() {
    log_info "获取文件夹列表..."
    
    local folders
    folders=$(api_request "/api/folders")
    
    if [ $? -eq 0 ] && [ -n "$folders" ]; then
        # 添加根文件夹
        local root_folder='{"id":0,"uid":"","title":"General","url":"","hasAcl":false,"canSave":true,"canEdit":true,"canAdmin":true,"version":1}'
        folders=$(echo "[$root_folder,$folders]" | jq 'flatten')
        
        # 保存文件夹信息
        echo "$folders" | jq . > "$EXPORT_DIR/folders.json"
        
        local folder_count
        folder_count=$(echo "$folders" | jq 'length')
        log_success "找到 $folder_count 个文件夹 (包括根文件夹)"
        
        echo "$folders"
    else
        log_error "获取文件夹列表失败"
        return 1
    fi
}

# 获取仪表板列表
get_dashboards() {
    log_info "获取仪表板列表..."
    
    local endpoint="/api/search?type=dash-db"
    
    # 添加文件夹过滤
    if [ -n "$FOLDER_FILTER" ]; then
        local folder_id
        folder_id=$(echo "$1" | jq -r ".[] | select(.title == \"$FOLDER_FILTER\") | .id")
        
        if [ -n "$folder_id" ] && [ "$folder_id" != "null" ]; then
            endpoint="$endpoint&folderIds=$folder_id"
            log_info "过滤文件夹: $FOLDER_FILTER (ID: $folder_id)"
        else
            log_error "未找到文件夹: $FOLDER_FILTER"
            return 1
        fi
    fi
    
    # 添加标签过滤
    if [ -n "$TAG_FILTER" ]; then
        endpoint="$endpoint&tag=$TAG_FILTER"
        log_info "过滤标签: $TAG_FILTER"
    fi
    
    local dashboards
    dashboards=$(api_request "$endpoint")
    
    if [ $? -eq 0 ] && [ -n "$dashboards" ]; then
        local dashboard_count
        dashboard_count=$(echo "$dashboards" | jq 'length')
        log_success "找到 $dashboard_count 个仪表板"
        
        echo "$dashboards"
    else
        log_error "获取仪表板列表失败"
        return 1
    fi
}

# 导出单个仪表板
export_dashboard() {
    local uid="$1"
    local title="$2"
    local folder_title="$3"
    
    log_info "导出仪表板: $title (UID: $uid)"
    
    # 创建文件夹目录
    local safe_folder_title
    safe_folder_title=$(safe_filename "${folder_title:-General}")
    local folder_dir="$EXPORT_DIR/$safe_folder_title"
    mkdir -p "$folder_dir"
    
    # 获取仪表板详细信息
    local dashboard_data
    dashboard_data=$(api_request "/api/dashboards/uid/$uid")
    
    if [ $? -eq 0 ] && [ -n "$dashboard_data" ]; then
        # 检查是否包含dashboard字段
        if echo "$dashboard_data" | jq -e '.dashboard' >/dev/null; then
            # 生成安全文件名
            local safe_title
            safe_title=$(safe_filename "$title")
            local filename="$folder_dir/${safe_title}_${uid}.json"
            
            # 准备导出数据
            local export_data
            export_data=$(echo "$dashboard_data" | jq --arg folder "$folder_title" --arg time "$(date -Iseconds)" '{
                dashboard: .dashboard,
                meta: .meta,
                folderTitle: $folder,
                exportTime: $time
            }')
            
            # 获取权限信息（如果需要）
            if [ "$INCLUDE_PERMISSIONS" = true ]; then
                local permissions
                permissions=$(api_request "/api/dashboards/uid/$uid/permissions")
                
                if [ $? -eq 0 ] && [ -n "$permissions" ]; then
                    export_data=$(echo "$export_data" | jq --argjson perms "$permissions" '. + {permissions: $perms}')
                fi
            fi
            
            # 保存仪表板
            echo "$export_data" | jq . > "$filename"
            
            if [ $? -eq 0 ]; then
                log_success "导出成功: $(basename "$filename")"
                return 0
            else
                log_error "保存文件失败: $filename"
                return 1
            fi
        else
            log_error "仪表板数据格式错误: $title"
            return 1
        fi
    else
        log_error "获取仪表板失败: $title"
        return 1
    fi
}

# 导出数据源
export_datasources() {
    log_info "导出数据源配置..."
    
    local datasources
    datasources=$(api_request "/api/datasources")
    
    if [ $? -eq 0 ] && [ -n "$datasources" ]; then
        echo "$datasources" | jq . > "$EXPORT_DIR/datasources.json"
        
        local ds_count
        ds_count=$(echo "$datasources" | jq 'length')
        log_success "数据源配置已导出: $ds_count 个数据源"
    else
        log_warning "导出数据源配置失败"
    fi
}

# 生成报告
generate_report() {
    local exported_count="$1"
    local total_count="$2"
    
    log_info "生成导出报告..."
    
    local report_file="$EXPORT_DIR/export_report.md"
    
    cat > "$report_file" << EOF
# Grafana导出报告

**导出时间**: $(date '+%Y-%m-%d %H:%M:%S')

**Grafana URL**: $GRAFANA_URL

**导出目录**: \`$EXPORT_DIR\`

## 统计信息

| 项目 | 数量 |
|------|------|
| 仪表板总数 | $total_count |
| 成功导出 | $exported_count |
| 失败数量 | $((total_count - exported_count)) |
| 成功率 | $(awk "BEGIN {printf \"%.1f\", $exported_count/$total_count*100}")% |

## 文件夹结构

EOF
    
    # 添加文件夹统计
    for folder_dir in "$EXPORT_DIR"/*/; do
        if [ -d "$folder_dir" ]; then
            local folder_name
            folder_name=$(basename "$folder_dir")
            local dashboard_count
            dashboard_count=$(find "$folder_dir" -name "*.json" | wc -l)
            echo "- **$folder_name** ($dashboard_count 个仪表板)" >> "$report_file"
        fi
    done
    
    echo "" >> "$report_file"
    echo "## 导出文件列表" >> "$report_file"
    echo "" >> "$report_file"
    
    # 添加文件列表
    for folder_dir in "$EXPORT_DIR"/*/; do
        if [ -d "$folder_dir" ]; then
            local folder_name
            folder_name=$(basename "$folder_dir")
            echo "### $folder_name" >> "$report_file"
            echo "" >> "$report_file"
            
            find "$folder_dir" -name "*.json" -exec basename {} \; | sort | while read -r file; do
                echo "- \`$file\`" >> "$report_file"
            done
            echo "" >> "$report_file"
        fi
    done
    
    # 添加其他文件
    local other_files
    other_files=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.json" -exec basename {} \;)
    
    if [ -n "$other_files" ]; then
        echo "### 其他配置文件" >> "$report_file"
        echo "" >> "$report_file"
        echo "$other_files" | while read -r file; do
            echo "- \`$file\`" >> "$report_file"
        done
    fi
    
    log_success "导出报告已生成: $report_file"
}

# 主函数
main() {
    # 解析参数
    parse_args "$@"
    
    # 检查必要参数
    if [ -z "$GRAFANA_API_KEY" ]; then
        log_error "请提供API密钥 (--api-key 或设置 GRAFANA_API_KEY 环境变量)"
        show_help
        exit 1
    fi
    
    # 检查依赖
    check_dependencies
    
    # 创建导出目录
    mkdir -p "$EXPORT_DIR"
    log_info "导出目录: $EXPORT_DIR"
    
    # 测试连接
    if ! test_connection; then
        exit 1
    fi
    
    # 获取文件夹列表
    local folders
    folders=$(get_folders)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    # 导出数据源
    export_datasources
    
    # 获取仪表板列表
    local dashboards
    dashboards=$(get_dashboards "$folders")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    local total_count
    total_count=$(echo "$dashboards" | jq 'length')
    
    if [ "$total_count" -eq 0 ]; then
        log_warning "未找到任何仪表板"
        exit 0
    fi
    
    # 导出每个仪表板
    local exported_count=0
    local current=0
    
    echo "$dashboards" | jq -r '.[] | "\(.uid)|\(.title)|\(.folderTitle // "General")"' | \
    while IFS='|' read -r uid title folder_title; do
        current=$((current + 1))
        echo -n "[$current/$total_count] "
        
        if export_dashboard "$uid" "$title" "$folder_title"; then
            exported_count=$((exported_count + 1))
        fi
    done
    
    # 重新计算导出数量（因为子shell问题）
    exported_count=$(find "$EXPORT_DIR" -name "*.json" -not -name "folders.json" -not -name "datasources.json" | wc -l)
    
    # 生成报告
    generate_report "$exported_count" "$total_count"
    
    echo ""
    echo "==========================================="
    log_success "导出完成!"
    log_info "成功导出: $exported_count/$total_count 个仪表板"
    log_info "导出目录: $EXPORT_DIR"
    log_info "查看报告: $EXPORT_DIR/export_report.md"
}

# 信号处理
trap 'log_warning "用户中断操作"; exit 1' INT TERM

# 执行主函数
main "$@"