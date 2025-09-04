#!/bin/bash

# Nginx Lua JWT 认证系统测试脚本
# 用于测试登录、认证验证和访问控制功能

set -e

# 配置变量
BASE_URL="http://localhost:8080"
GRAFANA_URL="$BASE_URL/grafana"
LOGIN_URL="$BASE_URL/auth/login"
VERIFY_URL="$BASE_URL/auth/verify"
LOGOUT_URL="$BASE_URL/auth/logout"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查服务状态
check_service() {
    local service_name=$1
    local url=$2
    
    log_info "检查 $service_name 服务状态..."
    
    if curl -s --connect-timeout 5 "$url" > /dev/null 2>&1; then
        log_success "$service_name 服务正常运行"
        return 0
    else
        log_error "$service_name 服务不可访问: $url"
        return 1
    fi
}

# 测试登录功能
test_login() {
    log_info "测试用户登录功能..."
    
    # 测试有效用户登录
    local response=$(curl -s -X POST "$LOGIN_URL" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"admin123"}' \
        -w "HTTPSTATUS:%{http_code}")
    
    local body=$(echo "$response" | sed -E 's/HTTPSTATUS:[0-9]{3}$//')
    local status=$(echo "$response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$status" = "200" ]; then
        local token=$(echo "$body" | jq -r '.token // empty')
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            log_success "用户登录成功，获得 JWT token"
            echo "$token" > /tmp/jwt_token
            return 0
        else
            log_error "登录响应中未找到有效的 token"
            return 1
        fi
    else
        log_error "用户登录失败，HTTP状态码: $status"
        echo "响应内容: $body"
        return 1
    fi
}

# 测试无效登录
test_invalid_login() {
    log_info "测试无效用户登录..."
    
    local response=$(curl -s -X POST "$LOGIN_URL" \
        -H "Content-Type: application/json" \
        -d '{"username":"invalid","password":"wrong"}' \
        -w "HTTPSTATUS:%{http_code}")
    
    local status=$(echo "$response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$status" = "401" ]; then
        log_success "无效登录正确被拒绝"
        return 0
    else
        log_error "无效登录测试失败，期望401，实际: $status"
        return 1
    fi
}

# 测试 JWT 验证
test_jwt_verification() {
    log_info "测试 JWT token 验证..."
    
    if [ ! -f "/tmp/jwt_token" ]; then
        log_error "未找到 JWT token 文件"
        return 1
    fi
    
    local token=$(cat /tmp/jwt_token)
    
    local response=$(curl -s "$VERIFY_URL" \
        -H "Authorization: Bearer $token" \
        -w "HTTPSTATUS:%{http_code}")
    
    local status=$(echo "$response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$status" = "200" ]; then
        log_success "JWT token 验证成功"
        return 0
    else
        log_error "JWT token 验证失败，HTTP状态码: $status"
        return 1
    fi
}

# 测试无 token 访问
test_no_token_access() {
    log_info "测试无 token 访问受保护资源..."
    
    local response=$(curl -s "$GRAFANA_URL" \
        -w "HTTPSTATUS:%{http_code}" \
        --max-redirs 0)
    
    local status=$(echo "$response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$status" = "302" ] || [ "$status" = "401" ]; then
        log_success "无 token 访问正确被重定向或拒绝"
        return 0
    else
        log_error "无 token 访问测试失败，期望302或401，实际: $status"
        return 1
    fi
}

# 测试有效 token 访问
test_valid_token_access() {
    log_info "测试有效 token 访问受保护资源..."
    
    if [ ! -f "/tmp/jwt_token" ]; then
        log_error "未找到 JWT token 文件"
        return 1
    fi
    
    local token=$(cat /tmp/jwt_token)
    
    local response=$(curl -s "$GRAFANA_URL" \
        -H "Authorization: Bearer $token" \
        -w "HTTPSTATUS:%{http_code}" \
        --max-redirs 0)
    
    local status=$(echo "$response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$status" = "200" ] || [ "$status" = "302" ]; then
        log_success "有效 token 访问成功"
        return 0
    else
        log_error "有效 token 访问失败，HTTP状态码: $status"
        return 1
    fi
}

# 测试 Cookie 认证
test_cookie_auth() {
    log_info "测试 Cookie 认证..."
    
    # 先登录获取 cookie
    local cookie_jar="/tmp/auth_cookies"
    
    local login_response=$(curl -s -X POST "$LOGIN_URL" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"admin123"}' \
        -c "$cookie_jar" \
        -w "HTTPSTATUS:%{http_code}")
    
    local login_status=$(echo "$login_response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$login_status" != "200" ]; then
        log_error "Cookie 认证测试：登录失败"
        return 1
    fi
    
    # 使用 cookie 访问受保护资源
    local access_response=$(curl -s "$GRAFANA_URL" \
        -b "$cookie_jar" \
        -w "HTTPSTATUS:%{http_code}" \
        --max-redirs 0)
    
    local access_status=$(echo "$access_response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$access_status" = "200" ] || [ "$access_status" = "302" ]; then
        log_success "Cookie 认证访问成功"
        rm -f "$cookie_jar"
        return 0
    else
        log_error "Cookie 认证访问失败，HTTP状态码: $access_status"
        rm -f "$cookie_jar"
        return 1
    fi
}

# 测试登出功能
test_logout() {
    log_info "测试用户登出功能..."
    
    if [ ! -f "/tmp/jwt_token" ]; then
        log_warning "未找到 JWT token 文件，跳过登出测试"
        return 0
    fi
    
    local token=$(cat /tmp/jwt_token)
    
    local response=$(curl -s -X POST "$LOGOUT_URL" \
        -H "Authorization: Bearer $token" \
        -w "HTTPSTATUS:%{http_code}")
    
    local status=$(echo "$response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$status" = "200" ]; then
        log_success "用户登出成功"
        rm -f /tmp/jwt_token
        return 0
    else
        log_error "用户登出失败，HTTP状态码: $status"
        return 1
    fi
}

# 性能测试
test_performance() {
    log_info "执行性能测试..."
    
    # 测试登录性能
    log_info "测试登录接口性能（10次请求）..."
    
    local total_time=0
    local success_count=0
    
    for i in {1..10}; do
        local start_time=$(date +%s%N)
        
        local response=$(curl -s -X POST "$LOGIN_URL" \
            -H "Content-Type: application/json" \
            -d '{"username":"admin","password":"admin123"}' \
            -w "HTTPSTATUS:%{http_code}")
        
        local end_time=$(date +%s%N)
        local request_time=$(( (end_time - start_time) / 1000000 ))
        
        local status=$(echo "$response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
        
        if [ "$status" = "200" ]; then
            success_count=$((success_count + 1))
        fi
        
        total_time=$((total_time + request_time))
        
        echo "请求 $i: ${request_time}ms (状态码: $status)"
    done
    
    local avg_time=$((total_time / 10))
    log_info "平均响应时间: ${avg_time}ms"
    log_info "成功率: $success_count/10 ($(( success_count * 10 ))%)"
    
    if [ $success_count -ge 8 ] && [ $avg_time -lt 1000 ]; then
        log_success "性能测试通过"
        return 0
    else
        log_warning "性能测试未达到预期标准"
        return 1
    fi
}

# 清理测试文件
cleanup() {
    log_info "清理测试文件..."
    rm -f /tmp/jwt_token /tmp/auth_cookies
}

# 主测试函数
run_tests() {
    log_info "开始 Nginx Lua JWT 认证系统测试..."
    echo "==========================================="
    
    local failed_tests=0
    local total_tests=0
    
    # 检查依赖工具
    if ! command -v curl &> /dev/null; then
        log_error "curl 命令未找到，请先安装 curl"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq 命令未找到，请先安装 jq"
        exit 1
    fi
    
    # 服务状态检查
    total_tests=$((total_tests + 1))
    if ! check_service "Nginx" "$BASE_URL"; then
        failed_tests=$((failed_tests + 1))
        log_error "Nginx 服务不可用，请先启动服务"
        exit 1
    fi
    
    # 执行测试用例
    local test_cases=(
        "test_login:用户登录测试"
        "test_invalid_login:无效登录测试"
        "test_jwt_verification:JWT验证测试"
        "test_no_token_access:无token访问测试"
        "test_valid_token_access:有效token访问测试"
        "test_cookie_auth:Cookie认证测试"
        "test_logout:用户登出测试"
        "test_performance:性能测试"
    )
    
    for test_case in "${test_cases[@]}"; do
        local test_func=$(echo "$test_case" | cut -d: -f1)
        local test_name=$(echo "$test_case" | cut -d: -f2)
        
        total_tests=$((total_tests + 1))
        
        echo ""
        log_info "执行测试: $test_name"
        echo "-------------------------------------------"
        
        if $test_func; then
            log_success "✓ $test_name 通过"
        else
            log_error "✗ $test_name 失败"
            failed_tests=$((failed_tests + 1))
        fi
    done
    
    # 清理
    cleanup
    
    # 测试结果汇总
    echo ""
    echo "==========================================="
    log_info "测试结果汇总:"
    echo "总测试数: $total_tests"
    echo "通过: $((total_tests - failed_tests))"
    echo "失败: $failed_tests"
    
    if [ $failed_tests -eq 0 ]; then
        log_success "🎉 所有测试通过！"
        exit 0
    else
        log_error "❌ 有 $failed_tests 个测试失败"
        exit 1
    fi
}

# 显示帮助信息
show_help() {
    echo "Nginx Lua JWT 认证系统测试脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  -u, --url URL  设置基础URL (默认: http://localhost:8080)"
    echo "  --login-only   仅测试登录功能"
    echo "  --perf-only    仅执行性能测试"
    echo ""
    echo "示例:"
    echo "  $0                           # 运行所有测试"
    echo "  $0 -u http://example.com     # 使用自定义URL"
    echo "  $0 --login-only              # 仅测试登录"
    echo "  $0 --perf-only               # 仅性能测试"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -u|--url)
            BASE_URL="$2"
            GRAFANA_URL="$BASE_URL/grafana"
            LOGIN_URL="$BASE_URL/auth/login"
            VERIFY_URL="$BASE_URL/auth/verify"
            LOGOUT_URL="$BASE_URL/auth/logout"
            shift 2
            ;;
        --login-only)
            test_login
            exit $?
            ;;
        --perf-only)
            test_performance
            exit $?
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 运行测试
run_tests