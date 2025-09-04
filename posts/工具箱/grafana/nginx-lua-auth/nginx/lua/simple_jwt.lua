-- 简单的JWT实现，避免复杂依赖
local cjson = require "cjson"
local ngx_encode_base64 = ngx.encode_base64
local ngx_decode_base64 = ngx.decode_base64

-- 简单的十六进制转换函数
local function to_hex(str)
    return (str:gsub('.', function (c)
        return string.format('%02x', string.byte(c))
    end))
end

-- 简单的HMAC-SHA256实现（使用OpenResty内置函数）
local function hmac_sha256(key, message)
    -- 直接使用OpenResty内置的hmac_sha256函数
    return ngx.hmac_sha256(key, message)
end

local _M = {}

-- Base64 URL编码
local function base64url_encode(str)
    local encoded = ngx_encode_base64(str)
    return encoded:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
end

-- Base64 URL解码
local function base64url_decode(str)
    -- 补齐padding
    local padding = 4 - (#str % 4)
    if padding ~= 4 then
        str = str .. string.rep("=", padding)
    end
    str = str:gsub("-", "+"):gsub("_", "/")
    return ngx_decode_base64(str)
end

-- 生成JWT token
function _M.sign(payload, secret)
    local header = {
        typ = "JWT",
        alg = "HS256"
    }
    
    local header_json = cjson.encode(header)
    local payload_json = cjson.encode(payload)
    
    local header_b64 = base64url_encode(header_json)
    local payload_b64 = base64url_encode(payload_json)
    
    local message = header_b64 .. "." .. payload_b64
    local signature = hmac_sha256(secret, message)
    local signature_b64 = base64url_encode(signature)
    
    return message .. "." .. signature_b64
end

-- 验证JWT token
function _M.verify(token, secret)
    if not token then
        return nil, "no token provided"
    end
    
    local parts = {}
    for part in token:gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    
    if #parts ~= 3 then
        return nil, "invalid token format"
    end
    
    local header_b64, payload_b64, signature_b64 = parts[1], parts[2], parts[3]
    
    -- 验证签名
    local message = header_b64 .. "." .. payload_b64
    local expected_signature = hmac_sha256(secret, message)
    local expected_signature_b64 = base64url_encode(expected_signature)
    
    if signature_b64 ~= expected_signature_b64 then
        return nil, "invalid signature"
    end
    
    -- 解码payload
    local payload_json = base64url_decode(payload_b64)
    if not payload_json then
        return nil, "invalid payload encoding"
    end
    
    local payload = cjson.decode(payload_json)
    if not payload then
        return nil, "invalid payload json"
    end
    
    -- 检查过期时间
    if payload.exp and payload.exp < ngx.time() then
        return nil, "token expired"
    end
    
    return payload
end

return _M