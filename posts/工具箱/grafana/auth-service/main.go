package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var jwtSecret = []byte("mysecretkey")

type User struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Role  string `json:"role"`
}

type Claims struct {
	UserID int    `json:"user_id"`
	Email  string `json:"email"`
	Name   string `json:"name"`
	jwt.RegisteredClaims
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginResponse struct {
	Token string `json:"token"`
	User  User   `json:"user"`
}

// 模拟用户数据库
var users = map[string]User{
	"admin": {
		ID:    1,
		Name:  "Admin User",
		Email: "admin@example.com",
		Role:  "Admin",
	},
	"editor": {
		ID:    2,
		Name:  "Editor User",
		Email: "editor@example.com",
		Role:  "Editor",
	},
	"viewer": {
		ID:    3,
		Name:  "Viewer User",
		Email: "viewer@example.com",
		Role:  "Viewer",
	},
}

func main() {
	// 从环境变量获取密钥
	if secret := os.Getenv("JWT_SECRET"); secret != "" {
		jwtSecret = []byte(secret)
	}

	http.HandleFunc("/login", loginHandler)
	http.HandleFunc("/verify", verifyHandler)
	http.HandleFunc("/", loginPageHandler)
	http.HandleFunc("/grafana/", grafanaAuthHandler)

	log.Println("Auth service starting on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func loginPageHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	html := `
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Grafana SSO Login</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 400px;
            margin: 100px auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .login-container {
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h2 {
            text-align: center;
            color: #333;
            margin-bottom: 30px;
        }
        .form-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 5px;
            color: #555;
        }
        input {
            width: 100%;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 4px;
            box-sizing: border-box;
        }
        button {
            width: 100%;
            padding: 12px;
            background-color: #337ab7;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 16px;
        }
        button:hover {
            background-color: #286090;
        }
        .message {
            margin-top: 20px;
            padding: 10px;
            border-radius: 4px;
        }
        .error {
            background-color: #f2dede;
            color: #a94442;
            border: 1px solid #ebccd1;
        }
        .success {
            background-color: #dff0d8;
            color: #3c763d;
            border: 1px solid #d6e9c6;
        }
        .hidden {
            display: none;
        }
        .grafana-link {
            text-align: center;
            margin-top: 20px;
        }
        .grafana-link a {
            display: inline-block;
            padding: 10px 20px;
            background-color: #e65252;
            color: white;
            text-decoration: none;
            border-radius: 4px;
        }
        .grafana-link a:hover {
            background-color: #cc3333;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <h2>Grafana SSO Login</h2>
        <form id="loginForm">
            <div class="form-group">
                <label for="username">Username</label>
                <input type="text" id="username" name="username" required>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit">Login</button>
        </form>
        <div id="message" class="message hidden"></div>
        <div id="grafanaLink" class="grafana-link hidden">
            <a href="#" id="grafanaLinkBtn">Access Grafana</a>
        </div>
    </div>

    <script>
        // 页面加载时检查是否有保存的token
        window.addEventListener('DOMContentLoaded', function() {
            const token = localStorage.getItem('grafana_jwt_token');
            if (token) {
                document.getElementById('grafanaLink').classList.remove('hidden');
            }
        });

        document.getElementById('loginForm').addEventListener('submit', function(e) {
            e.preventDefault();
            
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            const messageDiv = document.getElementById('message');
            const grafanaLinkDiv = document.getElementById('grafanaLink');
            
            // 清除之前的消息
            messageDiv.className = 'message hidden';
            
            fetch('/login', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ username, password }),
            })
            .then(response => response.json())
            .then(data => {
                if (data.token) {
                    // 保存 token 到 localStorage
                    localStorage.setItem('grafana_jwt_token', data.token);
                    
                    // 显示成功消息
                    messageDiv.className = 'message success';
                    messageDiv.textContent = 'Login successful! You can now access Grafana.';
                    messageDiv.classList.remove('hidden');
                    
                    // 显示 Grafana 链接
                    grafanaLinkDiv.classList.remove('hidden');
                } else {
                    // 显示错误消息
                    messageDiv.className = 'message error';
                    messageDiv.textContent = 'Login failed: ' + (data.error || 'Unknown error');
                    messageDiv.classList.remove('hidden');
                }
            })
            .catch(error => {
                // 显示错误消息
                messageDiv.className = 'message error';
                messageDiv.textContent = 'Error: ' + error.message;
                messageDiv.classList.remove('hidden');
            });
        });
        
        // 为 Grafana 链接添加事件处理器
        document.getElementById('grafanaLinkBtn').addEventListener('click', function(e) {
            e.preventDefault();
            const token = localStorage.getItem('grafana_jwt_token');
            if (token) {
                // 通过一个中间页面传递 token 到 Grafana
                window.open('/grafana/auth?token=' + encodeURIComponent(token), '_blank');
            } else {
                alert('No token found. Please login first.');
            }
        });
    </script>
</body>
</html>
`
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, html)
}

func grafanaAuthHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("Grafana auth handler called with URL: %s", r.URL.String())
	
	// 从查询参数获取 token
	tokenString := r.URL.Query().Get("token")
	log.Printf("Token from URL query parameter: %s", tokenString)
	
	if tokenString == "" {
		// 如果没有 token，尝试从 Authorization 头获取
		authHeader := r.Header.Get("Authorization")
		log.Printf("Authorization header: %s", authHeader)
		if strings.HasPrefix(authHeader, "Bearer ") {
			tokenString = authHeader[7:]
		}
	}
	
	if tokenString == "" {
		log.Println("No token found in request")
		// 如果仍然没有 token，返回错误页面
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Access Denied</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            margin-top: 100px;
        }
        .error {
            color: #d9534f;
            font-size: 18px;
        }
        .back-link {
            margin-top: 20px;
        }
        .back-link a {
            color: #337ab7;
            text-decoration: none;
        }
    </style>
</head>
<body>
    <div class="error">
        <h2>Access Denied</h2>
        <p>No valid authentication token found.</p>
        <p>Please <a href="/">login</a> first to access Grafana.</p>
    </div>
</body>
</html>
`)
		return
	}
	
	log.Println("Token found, validating...")
	// 验证 token
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return jwtSecret, nil
	})
	
	if err != nil {
		log.Printf("Token parsing error: %v", err)
		// Token 无效，返回错误页面
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Access Denied</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            margin-top: 100px;
        }
        .error {
            color: #d9534f;
            font-size: 18px;
        }
        .back-link {
            margin-top: 20px;
        }
        .back-link a {
            color: #337ab7;
            text-decoration: none;
        }
    </style>
</head>
<body>
    <div class="error">
        <h2>Access Denied</h2>
        <p>Invalid or expired authentication token.</p>
        <p>Please <a href="/">login</a> again to access Grafana.</p>
    </div>
</body>
</html>
`)
		return
	}
	
	if !token.Valid {
		log.Println("Token is invalid")
		// Token 无效，返回错误页面
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Access Denied</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            margin-top: 100px;
        }
        .error {
            color: #d9534f;
            font-size: 18px;
        }
        .back-link {
            margin-top: 20px;
        }
        .back-link a {
            color: #337ab7;
            text-decoration: none;
        }
    </style>
</head>
<body>
    <div class="error">
        <h2>Access Denied</h2>
        <p>Invalid or expired authentication token.</p>
        <p>Please <a href="/">login</a> again to access Grafana.</p>
    </div>
</body>
</html>
`)
		return
	}
	
	log.Printf("Token is valid for user: %s", claims.Subject)
	
	// Token 有效，设置认证 cookie 并重定向到 Grafana
	// 修复 cookie 设置，确保路径和域正确
	cookie := &http.Cookie{
		Name:     "grafana_jwt_token",
		Value:    tokenString,
		Path:     "/",  // 更改路径为根路径，确保所有路径都能访问
		Domain:   "",   // 空字符串表示当前域
		HttpOnly: false, // 设置为 false 以便 JavaScript 可以访问
		MaxAge:   86400, // 24小时
		SameSite: http.SameSiteLaxMode,
	}
	http.SetCookie(w, cookie)
	
	log.Printf("Cookie set: %+v", cookie)
	
	// 重定向到 Grafana
	// 使用 JavaScript 重定向，确保 cookie 被正确设置
	htmlResponse := fmt.Sprintf(`
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Redirecting...</title>
</head>
<body>
    <p>Authentication successful. Redirecting to Grafana...</p>
    <script>
        // 确保 cookie 已设置
        document.cookie = "grafana_jwt_token=%s; path=/; max-age=86400; sameSite=Lax";
        // 重定向到 Grafana
        window.location.href = "http://localhost/grafana/";
    </script>
</body>
</html>
`, tokenString)
	
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, htmlResponse)
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("Login handler called with method: %s", r.Method)
	
	if r.Method != http.MethodPost {
		log.Printf("Invalid method: %s", r.Method)
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("Error decoding request body: %v", err)
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	log.Printf("Login request for user: %s", req.Username)
	
	user, ok := users[req.Username]
	if !ok {
		log.Printf("User not found: %s", req.Username)
		http.Error(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}

	// 简单密码验证（实际应用中应使用加密密码）
	if req.Password != "password" {
		log.Printf("Invalid password for user: %s", req.Username)
		http.Error(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}

	// 生成 JWT token
	expirationTime := time.Now().Add(24 * time.Hour)
	claims := &Claims{
		UserID: user.ID,
		Email:  user.Email,
		Name:   user.Name,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(expirationTime),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			Subject:   req.Username,
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	tokenString, err := token.SignedString(jwtSecret)
	if err != nil {
		log.Printf("Error generating token: %v", err)
		http.Error(w, "Could not generate token", http.StatusInternalServerError)
		return
	}

	log.Printf("Token generated successfully for user: %s", req.Username)
	
	response := LoginResponse{
		Token: tokenString,
		User:  user,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func verifyHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("Verify handler called with method: %s", r.Method)
	log.Printf("Request headers: Authorization=%s, X-JWT-Token=%s", 
		r.Header.Get("Authorization"), r.Header.Get("X-JWT-Token"))
	
	// 记录所有 cookies
	log.Printf("All cookies:")
	for _, cookie := range r.Cookies() {
		log.Printf("  Cookie %s=%s", cookie.Name, cookie.Value)
	}
	
	// 首先尝试从 cookie 获取 token
	tokenString := ""
	if cookie, err := r.Cookie("grafana_jwt_token"); err == nil {
		tokenString = cookie.Value
		log.Printf("Token found in cookie: %s", tokenString)
	} else {
		log.Printf("No grafana_jwt_token cookie found: %v", err)
	}
	
	// 如果 cookie 中没有 token，则尝试从 header 获取
	if tokenString == "" {
		authHeader := r.Header.Get("Authorization")
		jwtToken := r.Header.Get("X-JWT-Token")

		log.Printf("Headers - Authorization: %s, X-JWT-Token: %s", authHeader, jwtToken)

		if authHeader == "" && jwtToken == "" {
			log.Println("Missing authorization header")
			http.Error(w, "Missing authorization header", http.StatusUnauthorized)
			return
		}

		// 如果没有从 Authorization 头获取，则从自定义头获取
		if authHeader == "" && jwtToken != "" {
			authHeader = "Bearer " + jwtToken
		}

		// 提取 token
		if strings.HasPrefix(authHeader, "Bearer ") {
			tokenString = authHeader[7:]
			log.Printf("Token extracted from header: %s", tokenString)
		} else {
			log.Println("Invalid authorization header format")
			http.Error(w, "Invalid authorization header", http.StatusUnauthorized)
			return
		}
	}

	if tokenString == "" {
		log.Println("No token found in request")
		http.Error(w, "No token provided", http.StatusUnauthorized)
		return
	}

	// 解析和验证 token
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return jwtSecret, nil
	})

	if err != nil {
		log.Printf("Token parsing error: %v", err)
		http.Error(w, "Invalid token", http.StatusUnauthorized)
		return
	}

	if !token.Valid {
		log.Println("Token is invalid")
		http.Error(w, "Invalid token", http.StatusUnauthorized)
		return
	}

	log.Printf("Token verified successfully for user: %s", claims.Subject)
	
	// 设置认证用户信息头部
	w.Header().Set("X-Auth-User", claims.Subject)
	w.Header().Set("X-Auth-Name", claims.Name)
	w.WriteHeader(http.StatusOK)
}

func calculateHMAC(message, secret []byte) string {
	h := hmac.New(sha256.New, secret)
	h.Write(message)
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}