#!/bin/sh

# OpenResty 启动脚本
# 用于初始化环境变量和配置

set -e

echo "[INFO] Starting OpenResty with Lua JWT Authentication..."

# 检查必要的环境变量
if [ -z "$JWT_SECRET" ] || [ "$JWT_SECRET" = "your-super-secret-jwt-key-change-in-production" ]; then
    echo "[WARNING] JWT_SECRET is not set or using default value. Please set a secure JWT secret in production!"
fi

# 设置默认环境变量
export JWT_SECRET=${JWT_SECRET:-"your-super-secret-jwt-key-change-in-production"}
export JWT_EXPIRE=${JWT_EXPIRE:-86400}
export COOKIE_DOMAIN=${COOKIE_DOMAIN:-"localhost"}
export COOKIE_SECURE=${COOKIE_SECURE:-"false"}
export ENVIRONMENT=${ENVIRONMENT:-"development"}

echo "[INFO] Environment Configuration:"
echo "  - JWT_EXPIRE: $JWT_EXPIRE seconds"
echo "  - COOKIE_DOMAIN: $COOKIE_DOMAIN"
echo "  - COOKIE_SECURE: $COOKIE_SECURE"
echo "  - ENVIRONMENT: $ENVIRONMENT"

# 检查配置文件
if [ ! -f "/usr/local/openresty/nginx/conf/nginx.conf" ]; then
    echo "[ERROR] nginx.conf not found!"
    exit 1
fi

# grafana.conf is now integrated into main nginx.conf
# No separate grafana.conf file needed

# 检查 Lua 脚本
for lua_file in "jwt.lua" "auth.lua" "login.lua"; do
    if [ ! -f "/etc/nginx/lua/$lua_file" ]; then
        echo "[ERROR] Lua script $lua_file not found!"
        exit 1
    fi
done

echo "[INFO] All configuration files and Lua scripts found."

# 测试 Nginx 配置
echo "[INFO] Testing Nginx configuration..."
/usr/local/openresty/bin/openresty -t

if [ $? -ne 0 ]; then
    echo "[ERROR] Nginx configuration test failed!"
    exit 1
fi

echo "[INFO] Nginx configuration test passed."

# 创建必要的目录和设置权限
mkdir -p /var/log/nginx
mkdir -p /var/cache/nginx
mkdir -p /tmp/nginx

# 如果是开发环境，显示更多调试信息
if [ "$ENVIRONMENT" = "development" ]; then
    echo "[DEBUG] Development mode enabled."
    echo "[DEBUG] Available Lua modules:"
    /usr/local/openresty/luajit/bin/luarocks list | grep -E "(jwt|http|redis|template)" || true
fi

# 检查 SSL 证书
if [ -f "/etc/nginx/ssl/nginx-selfsigned.crt" ] && [ -f "/etc/nginx/ssl/nginx-selfsigned.key" ]; then
    echo "[INFO] SSL certificates found."
else
    echo "[WARNING] SSL certificates not found. HTTPS may not work properly."
fi

# 启动前的最后检查
echo "[INFO] Starting OpenResty..."

# 如果传入了参数，执行传入的命令
if [ $# -gt 0 ]; then
    exec "$@"
else
    # 默认启动 OpenResty
    exec /usr/local/openresty/bin/openresty -g "daemon off;"
fi