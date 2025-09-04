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

	log.Println("Auth service starting on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	user, ok := users[req.Username]
	if !ok {
		http.Error(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}

	// 简单密码验证（实际应用中应使用加密密码）
	if req.Password != "password" {
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
		http.Error(w, "Could not generate token", http.StatusInternalServerError)
		return
	}

	response := LoginResponse{
		Token: tokenString,
		User:  user,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func verifyHandler(w http.ResponseWriter, r *http.Request) {
	authHeader := r.Header.Get("Authorization")
	jwtToken := r.Header.Get("X-JWT-Token")

	if authHeader == "" && jwtToken == "" {
		http.Error(w, "Missing authorization header", http.StatusUnauthorized)
		return
	}

	// 如果没有从 Authorization 头获取，则从自定义头获取
	if authHeader == "" && jwtToken != "" {
		authHeader = "Bearer " + jwtToken
	}

	// 提取 token
	tokenString := ""
	if strings.HasPrefix(authHeader, "Bearer ") {
		tokenString = authHeader[7:]
	} else {
		http.Error(w, "Invalid authorization header", http.StatusUnauthorized)
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

	if err != nil || !token.Valid {
		http.Error(w, "Invalid token", http.StatusUnauthorized)
		return
	}

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