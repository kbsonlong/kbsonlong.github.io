-- JWT处理模块
-- 依赖: lua-resty-jwt
local jwt = require "resty.jwt"
local cjson = require "cjson"

local _M = {}

-- JWT配置
local JWT_SECRET = os.getenv("JWT_SECRET") or "your-super-secret-key-change-in-production"
local JWT_ALGORITHM = "HS256"
local JWT_EXPIRE_TIME = 3600 * 24 -- 24小时

-- 生成JWT Token
function _M.generate_token(user_info)
    local now = ngx.time()
    local payload = {
        iss = "nginx-lua-auth",
        sub = user_info.username,
        aud = "grafana",
        exp = now + JWT_EXPIRE_TIME,
        iat = now,
        nbf = now,
        user = {
            username = user_info.username,
            display_name = user_info.display_name or user_info.username,
            email = user_info.email,
            role = user_info.role or "Viewer"
        }
    }
    
    local token = jwt:sign(JWT_SECRET, {
        header = {
            typ = "JWT",
            alg = JWT_ALGORITHM
        },
        payload = payload
    })
    
    return token
end

-- 验证JWT Token
function _M.verify_token(token)
    if not token then
        return nil, "Token is missing"
    end
    
    -- 移除Bearer前缀
    token = string.gsub(token, "Bearer ", "")
    
    local jwt_obj = jwt:verify(JWT_SECRET, token)
    
    if not jwt_obj.valid then
        return nil, jwt_obj.reason or "Invalid token"
    end
    
    -- 检查过期时间
    local now = ngx.time()
    if jwt_obj.payload.exp and jwt_obj.payload.exp < now then
        return nil, "Token expired"
    end
    
    return jwt_obj.payload, nil
end

-- 从请求中提取Token
function _M.extract_token_from_request()
    -- 1. 从Authorization头部获取
    local auth_header = ngx.var.http_authorization
    if auth_header then
        local token = string.match(auth_header, "Bearer%s+(.+)")
        if token then
            return token
        end
    end
    
    -- 2. 从Cookie中获取
    local cookie_header = ngx.var.http_cookie
    if cookie_header then
        local token = string.match(cookie_header, "auth_token=([^;]+)")
        if token then
            return token
        end
    end
    
    -- 3. 从查询参数获取
    local args = ngx.req.get_uri_args()
    if args.token then
        return args.token
    end
    
    return nil
end

-- 设置认证Cookie
function _M.set_auth_cookie(token, domain)
    local cookie_options = {
        "auth_token=" .. token,
        "Path=/",
        "HttpOnly",
        "SameSite=Lax",
        "Max-Age=" .. JWT_EXPIRE_TIME
    }
    
    if domain then
        table.insert(cookie_options, "Domain=" .. domain)
    end
    
    -- 如果是HTTPS，添加Secure标志
    if ngx.var.scheme == "https" then
        table.insert(cookie_options, "Secure")
    end
    
    ngx.header["Set-Cookie"] = table.concat(cookie_options, "; ")
end

-- 清除认证Cookie
function _M.clear_auth_cookie(domain)
    local cookie_options = {
        "auth_token=; expires=Thu, 01 Jan 1970 00:00:00 GMT",
        "Path=/",
        "HttpOnly"
    }
    
    if domain then
        table.insert(cookie_options, "Domain=" .. domain)
    end
    
    ngx.header["Set-Cookie"] = table.concat(cookie_options, "; ")
end

-- 获取用户信息
function _M.get_user_info(payload)
    if not payload or not payload.user then
        return nil
    end
    
    return {
        username = payload.user.username,
        display_name = payload.user.display_name,
        email = payload.user.email,
        role = payload.user.role
    }
end

return _M