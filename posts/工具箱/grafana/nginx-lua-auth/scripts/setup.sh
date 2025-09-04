#!/bin/bash

# Nginx Lua JWT 认证系统快速搭建脚本
# 自动化部署和配置整个认证系统

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置变量
PROJECT_NAME="nginx-lua-auth"
DOCKER_COMPOSE_VERSION="2.20.0"
REQUIRED_DOCKER_VERSION="20.10.0"

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

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

log_debug() {
    if [ "$DEBUG" = "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# 显示横幅
show_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║           Nginx Lua JWT 认证系统快速搭建脚本                 ║"
    echo "║                                                              ║"
    echo "║  🚀 一键部署轻量级认证代理系统                               ║"
    echo "║  🔒 基于 OpenResty + Lua + JWT                              ║"
    echo "║  📊 为 Grafana 等服务提供统一认证                           ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# 检查系统要求
check_system_requirements() {
    log_step "检查系统要求..."
    
    # 检查操作系统
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
        log_info "检测到 Linux 系统"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        log_info "检测到 macOS 系统"
    else
        log_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi
    
    # 检查必需的命令
    local required_commands=("curl" "docker" "docker-compose")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "未找到必需的命令: $cmd"
            
            case $cmd in
                "curl")
                    log_info "请安装 curl: sudo apt-get install curl (Ubuntu) 或 brew install curl (macOS)"
                    ;;
                "docker")
                    log_info "请安装 Docker: https://docs.docker.com/get-docker/"
                    ;;
                "docker-compose")
                    log_info "请安装 Docker Compose: https://docs.docker.com/compose/install/"
                    ;;
            esac
            exit 1
        else
            log_success "✓ $cmd 已安装"
        fi
    done
    
    # 检查 Docker 版本
    local docker_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    log_info "Docker 版本: $docker_version"
    
    # 检查 Docker 服务状态
    if ! docker info &> /dev/null; then
        log_error "Docker 服务未运行，请启动 Docker 服务"
        exit 1
    fi
    
    log_success "系统要求检查通过"
}

# 检查端口占用
check_port_availability() {
    log_step "检查端口可用性..."
    
    local ports=("8080" "3000" "5432" "6379" "9090" "9100")
    local occupied_ports=()
    
    for port in "${ports[@]}"; do
        if netstat -tuln 2>/dev/null | grep -q ":$port " || lsof -i ":$port" &>/dev/null; then
            occupied_ports+=("$port")
            log_warning "端口 $port 已被占用"
        else
            log_success "✓ 端口 $port 可用"
        fi
    done
    
    if [ ${#occupied_ports[@]} -gt 0 ]; then
        log_warning "以下端口被占用: ${occupied_ports[*]}"
        log_info "您可以:"
        log_info "1. 停止占用端口的服务"
        log_info "2. 修改 docker-compose.yml 中的端口映射"
        log_info "3. 继续安装（可能会有端口冲突）"
        
        read -p "是否继续安装？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "安装已取消"
            exit 0
        fi
    fi
}

# 生成安全的随机密钥
generate_secure_key() {
    local length=${1:-32}
    
    if command -v openssl &> /dev/null; then
        openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
    elif command -v head &> /dev/null && [ -f /dev/urandom ]; then
        head -c $length /dev/urandom | base64 | tr -d "=+/" | cut -c1-$length
    else
        # 备用方法
        date +%s | sha256sum | base64 | head -c $length
    fi
}

# 配置环境变量
setup_environment() {
    log_step "配置环境变量..."
    
    if [ -f ".env" ]; then
        log_warning "发现现有的 .env 文件"
        read -p "是否覆盖现有配置？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "保留现有配置"
            return 0
        fi
    fi
    
    log_info "生成新的环境配置..."
    
    # 生成安全密钥
    local jwt_secret=$(generate_secure_key 64)
    local postgres_password=$(generate_secure_key 16)
    local grafana_password=$(generate_secure_key 16)
    
    # 获取用户输入
    echo ""
    log_info "请输入配置信息（直接回车使用默认值）:"
    
    read -p "域名 (默认: localhost): " domain
    domain=${domain:-localhost}
    
    read -p "是否启用 HTTPS？(y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cookie_secure="true"
        log_info "HTTPS 已启用"
    else
        cookie_secure="false"
        log_info "HTTPS 已禁用（仅用于开发环境）"
    fi
    
    read -p "JWT 过期时间（秒，默认: 3600）: " jwt_expires
    jwt_expires=${jwt_expires:-3600}
    
    # 创建 .env 文件
    cat > .env << EOF
# Nginx Lua JWT 认证系统配置
# 生成时间: $(date)

# ==================== JWT 认证配置 ====================
JWT_SECRET=$jwt_secret
JWT_EXPIRES_IN=$jwt_expires
JWT_ALGORITHM=HS256

# ==================== Cookie 配置 ====================
COOKIE_NAME=auth_token
COOKIE_DOMAIN=$domain
COOKIE_PATH=/
COOKIE_SECURE=$cookie_secure
COOKIE_HTTPONLY=true
COOKIE_SAMESITE=Lax

# ==================== 环境配置 ====================
ENVIRONMENT=development
DEBUG=false

# ==================== 数据库配置 ====================
POSTGRES_DB=grafana
POSTGRES_USER=grafana
POSTGRES_PASSWORD=$postgres_password
POSTGRES_HOST=postgres
POSTGRES_PORT=5432

# ==================== Grafana 配置 ====================
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$grafana_password
GF_SECURITY_ADMIN_EMAIL=admin@$domain
GF_SERVER_ROOT_URL=http://$domain:8080/grafana/
GF_SERVER_SERVE_FROM_SUB_PATH=true

# ==================== SSL/TLS 配置 ====================
SSL_CERT_PATH=/etc/nginx/ssl/server.crt
SSL_KEY_PATH=/etc/nginx/ssl/server.key

# ==================== 网络配置 ====================
NGINX_PORT=8080
NGINX_SSL_PORT=8443
GRAFANA_PORT=3000
POSTGRES_PORT=5432
REDIS_PORT=6379

# ==================== 监控配置（可选）====================
PROMETHEUS_PORT=9090
NODE_EXPORTER_PORT=9100
ENABLE_MONITORING=false

# ==================== 安全配置 ====================
CSRF_PROTECTION=true
RATE_LIMIT_ENABLED=true
RATE_LIMIT_REQUESTS=100
RATE_LIMIT_WINDOW=60

# ==================== 日志配置 ====================
LOG_LEVEL=info
LOG_FORMAT=json
ACCESS_LOG_ENABLED=true
ERROR_LOG_ENABLED=true

# ==================== 缓存配置 ====================
REDIS_ENABLED=false
REDIS_HOST=redis
REDIS_PASSWORD=
CACHE_TTL=300

# ==================== 开发配置 ====================
HOT_RELOAD=false
DEV_MODE=true
EOF
    
    log_success "环境配置已生成"
    log_info "重要信息已保存到 .env 文件:"
    log_info "  - Grafana 管理员密码: $grafana_password"
    log_info "  - 数据库密码: $postgres_password"
    log_warning "请妥善保管这些密码！"
}

# 构建和启动服务
start_services() {
    log_step "构建和启动服务..."
    
    # 创建必要的目录
    log_info "创建必要的目录..."
    mkdir -p logs data/postgres data/grafana
    
    # 设置权限
    if [ "$OS" = "linux" ]; then
        sudo chown -R 472:472 data/grafana  # Grafana 用户 ID
        sudo chown -R 999:999 data/postgres # PostgreSQL 用户 ID
    fi
    
    # 拉取最新镜像
    log_info "拉取 Docker 镜像..."
    docker-compose pull
    
    # 构建自定义镜像
    log_info "构建认证代理镜像..."
    docker-compose build --no-cache openresty
    
    # 启动服务
    log_info "启动所有服务..."
    docker-compose up -d
    
    # 等待服务启动
    log_info "等待服务启动..."
    sleep 10
    
    # 检查服务状态
    log_info "检查服务状态..."
    docker-compose ps
    
    log_success "服务启动完成"
}

# 验证部署
verify_deployment() {
    log_step "验证部署状态..."
    
    local base_url="http://localhost:8080"
    local max_attempts=30
    local attempt=1
    
    # 等待 Nginx 服务就绪
    log_info "等待认证代理服务就绪..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s --connect-timeout 5 "$base_url/health" > /dev/null 2>&1; then
            log_success "认证代理服务已就绪"
            break
        fi
        
        log_debug "尝试 $attempt/$max_attempts: 等待服务启动..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log_error "认证代理服务启动超时"
        return 1
    fi
    
    # 测试认证功能
    log_info "测试认证功能..."
    
    local login_response=$(curl -s -X POST "$base_url/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"admin123"}' \
        -w "HTTPSTATUS:%{http_code}")
    
    local login_status=$(echo "$login_response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$login_status" = "200" ]; then
        log_success "✓ 用户登录功能正常"
    else
        log_error "✗ 用户登录功能异常 (状态码: $login_status)"
        return 1
    fi
    
    # 测试 Grafana 访问
    log_info "测试 Grafana 访问..."
    
    local grafana_response=$(curl -s "$base_url/grafana/" \
        -w "HTTPSTATUS:%{http_code}" \
        --max-redirs 0)
    
    local grafana_status=$(echo "$grafana_response" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
    
    if [ "$grafana_status" = "302" ] || [ "$grafana_status" = "401" ]; then
        log_success "✓ Grafana 访问控制正常"
    else
        log_warning "Grafana 访问状态异常 (状态码: $grafana_status)"
    fi
    
    log_success "部署验证完成"
}

# 显示部署信息
show_deployment_info() {
    log_step "部署信息"
    
    local domain=$(grep "COOKIE_DOMAIN=" .env | cut -d'=' -f2)
    local nginx_port=$(grep "NGINX_PORT=" .env | cut -d'=' -f2)
    local grafana_password=$(grep "GF_SECURITY_ADMIN_PASSWORD=" .env | cut -d'=' -f2)
    
    echo ""
    echo -e "${GREEN}🎉 Nginx Lua JWT 认证系统部署成功！${NC}"
    echo ""
    echo -e "${CYAN}📋 访问信息:${NC}"
    echo "  🔐 认证登录页: http://$domain:$nginx_port/auth/login"
    echo "  📊 Grafana 界面: http://$domain:$nginx_port/grafana"
    echo "  🏥 健康检查:   http://$domain:$nginx_port/health"
    echo ""
    echo -e "${CYAN}🔑 默认账户:${NC}"
    echo "  用户名: admin"
    echo "  密码:   admin123"
    echo ""
    echo -e "${CYAN}🔧 Grafana 管理员:${NC}"
    echo "  用户名: admin"
    echo "  密码:   $grafana_password"
    echo ""
    echo -e "${CYAN}🛠️  管理命令:${NC}"
    echo "  查看服务状态: docker-compose ps"
    echo "  查看日志:     docker-compose logs -f"
    echo "  停止服务:     docker-compose down"
    echo "  重启服务:     docker-compose restart"
    echo "  运行测试:     ./scripts/test-auth.sh"
    echo ""
    echo -e "${YELLOW}⚠️  安全提醒:${NC}"
    echo "  - 生产环境请修改默认密码"
    echo "  - 启用 HTTPS 并配置有效证书"
    echo "  - 定期更新 Docker 镜像"
    echo "  - 查看完整文档: README.md"
    echo ""
}

# 运行测试
run_tests() {
    log_step "运行自动化测试..."
    
    if [ -f "./scripts/test-auth.sh" ]; then
        chmod +x ./scripts/test-auth.sh
        
        log_info "执行认证系统测试..."
        if ./scripts/test-auth.sh; then
            log_success "所有测试通过"
        else
            log_warning "部分测试失败，请检查日志"
        fi
    else
        log_warning "测试脚本不存在，跳过测试"
    fi
}

# 清理函数
cleanup() {
    log_info "清理临时文件..."
    # 这里可以添加清理逻辑
}

# 错误处理
error_handler() {
    local exit_code=$?
    log_error "安装过程中发生错误 (退出码: $exit_code)"
    log_info "请检查错误信息并重试"
    
    # 显示故障排除信息
    echo ""
    log_info "故障排除建议:"
    echo "  1. 检查 Docker 服务是否正常运行"
    echo "  2. 确认端口未被占用"
    echo "  3. 查看详细日志: docker-compose logs"
    echo "  4. 重新运行安装脚本"
    echo ""
    
    cleanup
    exit $exit_code
}

# 显示帮助信息
show_help() {
    echo "Nginx Lua JWT 认证系统快速搭建脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示此帮助信息"
    echo "  -q, --quiet         静默模式"
    echo "  -d, --debug         调试模式"
    echo "  --skip-tests        跳过测试"
    echo "  --no-verify         跳过部署验证"
    echo "  --force             强制重新安装"
    echo ""
    echo "示例:"
    echo "  $0                  # 标准安装"
    echo "  $0 --debug          # 调试模式安装"
    echo "  $0 --skip-tests     # 跳过测试的安装"
    echo "  $0 --force          # 强制重新安装"
}

# 主函数
main() {
    # 设置错误处理
    trap error_handler ERR
    
    # 解析命令行参数
    local skip_tests=false
    local no_verify=false
    local force=false
    local quiet=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            --skip-tests)
                skip_tests=true
                shift
                ;;
            --no-verify)
                no_verify=true
                shift
                ;;
            --force)
                force=true
                shift
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 显示横幅
    if [ "$quiet" != "true" ]; then
        show_banner
    fi
    
    # 检查是否强制重新安装
    if [ "$force" = "true" ] && [ -f "docker-compose.yml" ]; then
        log_warning "强制重新安装模式"
        docker-compose down -v 2>/dev/null || true
        docker system prune -f 2>/dev/null || true
    fi
    
    # 执行安装步骤
    check_system_requirements
    check_port_availability
    setup_environment
    start_services
    
    if [ "$no_verify" != "true" ]; then
        verify_deployment
    fi
    
    if [ "$skip_tests" != "true" ]; then
        run_tests
    fi
    
    show_deployment_info
    
    log_success "🎉 安装完成！享受您的认证系统吧！"
}

# 运行主函数
main "$@"