# 使用 OpenResty 官方镜像作为基础镜像
FROM openresty/openresty:1.21.4.1-alpine

# 维护者信息
LABEL maintainer="nginx-lua-auth"
LABEL description="OpenResty with Lua JWT Authentication for Grafana"

# 安装必要的依赖
RUN apk add --no-cache \
    curl \
    ca-certificates \
    openssl \
    tzdata \
    git \
    gcc \
    musl-dev \
    make \
    unzip \
    perl \
    && rm -rf /var/cache/apk/*

# 设置时区
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 使用 opm 安装 Lua 模块（OpenResty 官方包管理器）
RUN /usr/local/openresty/bin/opm get ledgetech/lua-resty-http \
    && /usr/local/openresty/bin/opm get bungle/lua-resty-template

# 创建简单的JWT模块目录
RUN mkdir -p /usr/local/openresty/site/lualib/resty

# 创建必要的目录
RUN mkdir -p /usr/local/openresty/nginx/conf/conf.d \
    && mkdir -p /etc/nginx/lua \
    && mkdir -p /etc/nginx/html \
    && mkdir -p /etc/nginx/ssl \
    && mkdir -p /var/log/nginx \
    && mkdir -p /var/cache/nginx \
    && mkdir -p /tmp/nginx

# 设置权限
RUN chown -R nobody:nobody /var/log/nginx \
    && chown -R nobody:nobody /var/cache/nginx \
    && chown -R nobody:nobody /tmp/nginx

# 复制配置文件（如果存在）
COPY nginx/conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# 复制 Lua 脚本
COPY nginx/lua/ /etc/nginx/lua/

# 删除系统自带的 resty/jwt 相关文件以避免冲突
RUN rm -rf /usr/local/openresty/lualib/resty/jwt* \
    && rm -rf /usr/local/openresty/site/lualib/resty/jwt*

# 复制静态文件
COPY nginx/html/ /etc/nginx/html/

# 设置 Lua 脚本权限
RUN chmod -R 644 /etc/nginx/lua/*.lua \
    && chmod -R 644 /etc/nginx/html/*

# 创建自签名 SSL 证书（用于开发环境）
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/nginx-selfsigned.key \
    -out /etc/nginx/ssl/nginx-selfsigned.crt \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=Development/OU=IT Department/CN=localhost"

# 设置 SSL 证书权限
RUN chmod 600 /etc/nginx/ssl/nginx-selfsigned.key \
    && chmod 644 /etc/nginx/ssl/nginx-selfsigned.crt

# 环境变量设置
ENV JWT_SECRET=your-super-secret-jwt-key-change-in-production
ENV JWT_EXPIRE=86400
ENV COOKIE_DOMAIN=localhost
ENV COOKIE_SECURE=false
ENV ENVIRONMENT=development

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8080/auth/health || exit 1

# 暴露端口
EXPOSE 80 443 8080

# 启动脚本
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 使用非 root 用户运行（生产环境推荐）
# USER nobody

# 启动 OpenResty
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]