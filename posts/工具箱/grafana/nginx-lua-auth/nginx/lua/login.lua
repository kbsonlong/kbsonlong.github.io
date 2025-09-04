-- 登录处理模块
local jwt_lib = require "jwt"
local cjson = require "cjson"

local _M = {}

-- 模拟用户数据库（生产环境应该连接真实数据库）
local users = {
    ["admin"] = {
        username = "admin",
        password = "admin123", -- 生产环境应该使用加密密码
        display_name = "Administrator",
        email = "admin@example.com",
        role = "Admin"
    },
    ["viewer"] = {
        username = "viewer",
        password = "viewer123",
        display_name = "Viewer User",
        email = "viewer@example.com",
        role = "Viewer"
    },
    ["editor"] = {
        username = "editor",
        password = "editor123",
        display_name = "Editor User",
        email = "editor@example.com",
        role = "Editor"
    }
}

-- 验证用户凭据
function _M.authenticate_user(username, password)
    if not username or not password then
        return nil, "Username and password are required"
    end
    
    local user = users[username]
    if not user then
        return nil, "Invalid username or password"
    end
    
    -- 简单密码验证（生产环境应该使用加密验证）
    if user.password ~= password then
        return nil, "Invalid username or password"
    end
    
    -- 返回用户信息（不包含密码）
    return {
        username = user.username,
        display_name = user.display_name,
        email = user.email,
        role = user.role
    }, nil
end

-- 处理登录请求
function _M.handle_login()
    -- 设置响应头
    ngx.header.content_type = "application/json"
    
    -- 只接受POST请求
    if ngx.var.request_method ~= "POST" then
        ngx.status = 405
        ngx.say(cjson.encode({
            success = false,
            message = "Method not allowed"
        }))
        return
    end
    
    -- 读取请求体
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    
    if not body then
        ngx.status = 400
        ngx.say(cjson.encode({
            success = false,
            message = "Request body is required"
        }))
        return
    end
    
    -- 解析JSON数据
    local ok, data = pcall(cjson.decode, body)
    if not ok then
        ngx.status = 400
        ngx.say(cjson.encode({
            success = false,
            message = "Invalid JSON format"
        }))
        return
    end
    
    -- 验证用户
    local user_info, err = _M.authenticate_user(data.username, data.password)
    if not user_info then
        ngx.status = 401
        ngx.say(cjson.encode({
            success = false,
            message = err
        }))
        return
    end
    
    -- 生成JWT Token
    local token = jwt_lib.generate_token(user_info)
    if not token then
        ngx.status = 500
        ngx.say(cjson.encode({
            success = false,
            message = "Failed to generate token"
        }))
        return
    end
    
    -- 设置Cookie
    local host = ngx.var.http_host
    local domain = string.match(host, "([^:]+)")
    jwt_lib.set_auth_cookie(token, domain)
    
    -- 返回成功响应
    ngx.status = 200
    ngx.say(cjson.encode({
        success = true,
        message = "Login successful",
        user = {
            username = user_info.username,
            display_name = user_info.display_name,
            email = user_info.email,
            role = user_info.role
        },
        token = token
    }))
end

-- 处理登出请求
function _M.handle_logout()
    -- 清除认证Cookie
    local host = ngx.var.http_host
    local domain = string.match(host, "([^:]+)")
    jwt_lib.clear_auth_cookie(domain)
    
    -- 设置响应头
    ngx.header.content_type = "application/json"
    
    -- 返回成功响应
    ngx.status = 200
    ngx.say(cjson.encode({
        success = true,
        message = "Logout successful"
    }))
end

-- 获取当前用户信息
function _M.handle_user_info()
    -- 设置响应头
    ngx.header.content_type = "application/json"
    
    -- 提取Token
    local token = jwt_lib.extract_token_from_request()
    if not token then
        ngx.status = 401
        ngx.say(cjson.encode({
            success = false,
            message = "Authentication required"
        }))
        return
    end
    
    -- 验证Token
    local payload, err = jwt_lib.verify_token(token)
    if not payload then
        ngx.status = 401
        ngx.say(cjson.encode({
            success = false,
            message = err or "Invalid token"
        }))
        return
    end
    
    -- 获取用户信息
    local user_info = jwt_lib.get_user_info(payload)
    if not user_info then
        ngx.status = 401
        ngx.say(cjson.encode({
            success = false,
            message = "Invalid user information"
        }))
        return
    end
    
    -- 返回用户信息
    ngx.status = 200
    ngx.say(cjson.encode({
        success = true,
        user = user_info
    }))
end

-- 处理登录页面显示
function _M.show_login_page()
    -- 检查是否已经登录
    local token = jwt_lib.extract_token_from_request()
    if token then
        local payload, err = jwt_lib.verify_token(token)
        if payload then
            -- 已登录，重定向到原始URL或默认页面
            local redirect_url = ngx.var.arg_redirect or "/grafana/"
            ngx.redirect(redirect_url)
            return
        end
    end
    
    -- 显示登录页面
    ngx.header.content_type = "text/html"
    local file = io.open("/usr/local/openresty/nginx/html/login.html", "r")
    if file then
        local content = file:read("*all")
        file:close()
        ngx.say(content)
    else
        ngx.status = 500
        ngx.say("Login page not found")
    end
end

return _M