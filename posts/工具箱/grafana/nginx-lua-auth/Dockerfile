# 使用 OpenResty 官方镜像作为基础镜像
FROM openresty/openresty:1.21.4.1-alpine

# 维护者信息
LABEL maintainer="nginx-lua-auth"
LABEL description="OpenResty with Lua JWT Authentication for Grafana"

# 安装必要的包和依赖
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
    && rm -rf /var/cache/apk/*

# 设置时区
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 安装 LuaRocks
RUN wget https://luarocks.org/releases/luarocks-3.9.2.tar.gz \
    && tar zxpf luarocks-3.9.2.tar.gz \
    && cd luarocks-3.9.2 \
    && ./configure --prefix=/usr/local/openresty/luajit \
        --with-lua=/usr/local/openresty/luajit/ \
        --lua-suffix=jit \
        --with-lua-include=/usr/local/openresty/luajit/include/luajit-2.1 \
        --lua-version=5.1 \
    && make build \
    && make install \
    && cd .. \
    && rm -rf luarocks-3.9.2 luarocks-3.9.2.tar.gz

# 设置 LuaRocks 路径和配置
ENV PATH="/usr/local/openresty/luajit/bin:$PATH"
ENV LUA_PATH="/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;;"
ENV LUA_CPATH="/usr/local/openresty/luajit/lib/lua/5.1/?.so;;"

# 安装 lua-resty-jwt 模块
RUN luarocks install lua-resty-jwt

# 安装其他有用的 Lua 模块
RUN luarocks install lua-resty-http \
    && luarocks install lua-resty-redis \
    && luarocks install lua-resty-template

# 创建必要的目录
RUN mkdir -p /etc/nginx/lua \
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
COPY nginx/conf/nginx.conf /etc/nginx/nginx.conf
COPY nginx/conf/grafana.conf /etc/nginx/conf.d/grafana.conf

# 复制 Lua 脚本
COPY nginx/lua/ /etc/nginx/lua/

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