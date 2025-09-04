-- 认证中间件模块
-- 用于处理Nginx auth_request的认证验证
local jwt_lib = require "jwt"
local cjson = require "cjson"

local _M = {}

-- 认证验证处理
function _M.verify_auth()
    -- 提取Token
    local token = jwt_lib.extract_token_from_request()
    
    if not token then
        ngx.log(ngx.ERR, "No authentication token found")
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({
            error = "Authentication required",
            message = "No valid authentication token found"
        }))
        return
    end
    
    -- 验证Token
    local payload, err = jwt_lib.verify_token(token)
    if not payload then
        ngx.log(ngx.ERR, "Token verification failed: ", err)
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({
            error = "Authentication failed",
            message = err or "Invalid token"
        }))
        return
    end
    
    -- 获取用户信息
    local user_info = jwt_lib.get_user_info(payload)
    if not user_info then
        ngx.log(ngx.ERR, "Failed to extract user info from token")
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({
            error = "Authentication failed",
            message = "Invalid user information in token"
        }))
        return
    end
    
    -- 设置用户信息头部，供后端服务使用
    ngx.header["X-WEBAUTH-USER"] = user_info.username
    ngx.header["X-WEBAUTH-NAME"] = user_info.display_name
    ngx.header["X-WEBAUTH-EMAIL"] = user_info.email or ""
    ngx.header["X-WEBAUTH-ROLE"] = user_info.role or "Viewer"
    
    -- 记录认证成功日志
    ngx.log(ngx.INFO, "Authentication successful for user: ", user_info.username)
    
    -- 返回200状态码表示认证成功
    ngx.status = 200
    ngx.say("OK")
end

-- 处理认证失败的重定向
function _M.handle_auth_redirect()
    -- 获取原始请求URL
    local original_uri = ngx.var.request_uri or "/"
    local scheme = ngx.var.scheme or "http"
    local host = ngx.var.http_host or "localhost"
    local original_url = scheme .. "://" .. host .. original_uri
    
    -- 构建登录URL
    local login_url = "/auth/login?redirect=" .. ngx.escape_uri(original_url)
    
    -- 记录重定向日志
    ngx.log(ngx.INFO, "Redirecting unauthenticated request to login: ", login_url)
    
    -- 重定向到登录页面
    ngx.redirect(login_url)
end

-- 检查用户权限
function _M.check_permission(required_role)
    -- 提取Token
    local token = jwt_lib.extract_token_from_request()
    if not token then
        return false, "No authentication token"
    end
    
    -- 验证Token
    local payload, err = jwt_lib.verify_token(token)
    if not payload then
        return false, err or "Invalid token"
    end
    
    -- 获取用户信息
    local user_info = jwt_lib.get_user_info(payload)
    if not user_info then
        return false, "Invalid user information"
    end
    
    -- 角色权限映射
    local role_levels = {
        ["Viewer"] = 1,
        ["Editor"] = 2,
        ["Admin"] = 3
    }
    
    local user_level = role_levels[user_info.role] or 0
    local required_level = role_levels[required_role] or 0
    
    if user_level >= required_level then
        return true, user_info
    else
        return false, "Insufficient permissions"
    end
end

-- 处理权限检查
function _M.verify_permission(required_role)
    local has_permission, result = _M.check_permission(required_role)
    
    if not has_permission then
        ngx.log(ngx.WARN, "Permission denied: ", result)
        ngx.status = 403
        ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({
            error = "Permission denied",
            message = result
        }))
        return
    end
    
    -- 设置用户信息头部
    local user_info = result
    ngx.header["X-WEBAUTH-USER"] = user_info.username
    ngx.header["X-WEBAUTH-NAME"] = user_info.display_name
    ngx.header["X-WEBAUTH-EMAIL"] = user_info.email or ""
    ngx.header["X-WEBAUTH-ROLE"] = user_info.role or "Viewer"
    
    ngx.status = 200
    ngx.say("OK")
end

-- 健康检查端点
function _M.health_check()
    ngx.header.content_type = "application/json"
    ngx.status = 200
    ngx.say(cjson.encode({
        status = "healthy",
        service = "nginx-lua-auth",
        timestamp = ngx.time()
    }))
end

-- 获取认证状态
function _M.auth_status()
    ngx.header.content_type = "application/json"
    
    -- 提取Token
    local token = jwt_lib.extract_token_from_request()
    
    if not token then
        ngx.status = 200
        ngx.say(cjson.encode({
            authenticated = false,
            message = "No authentication token found"
        }))
        return
    end
    
    -- 验证Token
    local payload, err = jwt_lib.verify_token(token)
    if not payload then
        ngx.status = 200
        ngx.say(cjson.encode({
            authenticated = false,
            message = err or "Invalid token"
        }))
        return
    end
    
    -- 获取用户信息
    local user_info = jwt_lib.get_user_info(payload)
    if not user_info then
        ngx.status = 200
        ngx.say(cjson.encode({
            authenticated = false,
            message = "Invalid user information"
        }))
        return
    end
    
    -- 返回认证状态
    ngx.status = 200
    ngx.say(cjson.encode({
        authenticated = true,
        user = user_info,
        expires_at = payload.exp
    }))
end

return _M