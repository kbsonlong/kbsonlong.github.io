#!/bin/bash

# 设置颜色
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m" # 无颜色

echo -e "${GREEN}=== Pgpool-II 监控系统部署脚本 ===${NC}"
echo -e "${YELLOW}此脚本将部署完整的 Pgpool-II 监控环境，包括 Prometheus、Grafana 和 Loki${NC}"

# 检查 Docker 和 Docker Compose 是否已安装
if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: Docker 未安装. 请先安装 Docker.${NC}"
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}错误: Docker Compose 未安装. 请先安装 Docker Compose.${NC}"
    exit 1
fi

# 创建工作目录
MONITOR_DIR="pgpool-monitoring"
echo -e "${GREEN}创建工作目录: $MONITOR_DIR${NC}"
mkdir -p $MONITOR_DIR
cd $MONITOR_DIR

# 下载配置文件
echo -e "${GREEN}下载配置文件...${NC}"

# 复制当前目录下的配置文件
cp ../docker-compose-pgpool-monitoring.yml ./docker-compose.yml
cp ../prometheus-pgpool-config.yml ./
cp ../grafana-datasources.yml ./
cp ../grafana-dashboards.yml ./
cp ../pgpool-dashboard.json ./
cp ../promtail-config.yml ./

echo -e "${GREEN}配置文件准备完成${NC}"

# 创建必要的目录
echo -e "${GREEN}创建日志目录...${NC}"
mkdir -p logs/pgpool
mkdir -p logs/postgresql

# 启动服务
echo -e "${GREEN}启动监控服务...${NC}"
docker-compose up -d

# 检查服务状态
echo -e "${GREEN}检查服务状态...${NC}"
docker-compose ps

echo -e "${GREEN}=== 部署完成 ===${NC}"
echo -e "${YELLOW}Grafana 访问地址: http://localhost:3000 (用户名: admin, 密码: admin)${NC}"
echo -e "${YELLOW}Prometheus 访问地址: http://localhost:9090${NC}"
echo -e "${YELLOW}Pgpool-II 连接地址: localhost:5432${NC}"

echo -e "${GREEN}提示: 首次登录 Grafana 后，请修改默认密码${NC}"