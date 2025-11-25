#!/bin/bash

#######################################
# CVAT 部署脚本 v3.2 (本地构建版)
# 适用于: Debian/Ubuntu + Nginx 反向代理
# 特性: 本地构建镜像 + Docker Secrets
#######################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

generate_password() {
    openssl rand -base64 ${1:-32} | tr -d "=+/" | cut -c1-${1:-32}
}

# 检查权限和依赖
[[ $EUID -ne 0 ]] && { log_error "需要 root 权限"; exit 1; }
command -v docker &>/dev/null || { log_error "Docker 未安装"; exit 1; }

CVAT_DIR="/opt/cvat"
SERVER_IP=$(hostname -I | awk '{print $1}')

# 仓库地址 (修改为你自己的 fork)
CVAT_REPO="https://github.com/ooopus/cvat.git"

echo ""
log_info "=========================================="
log_info "CVAT 部署配置 (Secrets 模式)"
log_info "=========================================="
echo ""

# 收集配置
read -p "CVAT 域名 (留空使用 IP $SERVER_IP): " CVAT_HOST
CVAT_HOST=${CVAT_HOST:-$SERVER_IP}

read -p "是否通过 HTTPS 访问 (Nginx 反代)? [y/N]: " USE_HTTPS
USE_HTTPS=${USE_HTTPS:-n}

read -p "是否启用 Serverless (AI自动标注)? [y/N]: " USE_SERVERLESS
USE_SERVERLESS=${USE_SERVERLESS:-n}


# 构建 CSRF 信任源
if [[ "$USE_HTTPS" =~ ^[Yy]$ ]]; then
    CSRF_ORIGINS="https://$CVAT_HOST"
    PRIMARY_URL="https://$CVAT_HOST"
else
    CSRF_ORIGINS="http://$CVAT_HOST:8080,http://$CVAT_HOST"
    PRIMARY_URL="http://$CVAT_HOST:8080"
fi
CSRF_ORIGINS="$CSRF_ORIGINS,http://localhost:8080,http://127.0.0.1:8080"

echo ""
log_info "配置确认:"
echo "  主机: $CVAT_HOST"
echo "  访问地址: $PRIMARY_URL"
echo "  安全模式: Docker Secrets"
echo ""
read -p "确认? [Y/n]: " CONFIRM
[[ ! "${CONFIRM:-y}" =~ ^[Yy]$ ]] && { log_error "已取消"; exit 1; }

# 准备目录
log_info "准备 CVAT 目录..."
mkdir -p $CVAT_DIR
cd $CVAT_DIR

if [ ! -d ".git" ]; then
    log_info "克隆 CVAT 仓库: $CVAT_REPO"
    git clone "$CVAT_REPO" .
else
    log_info "CVAT 仓库已存在，拉取最新代码..."
    git pull || log_warn "拉取失败，使用现有代码"
fi

# 生成或复用密码
if [ -f .env ] && grep -q "CVAT_POSTGRES_PASSWORD" .env; then
    log_warn ".env 已存在，复用现有密码"
    source .env
else
    log_info "生成安全密码..."
    CVAT_POSTGRES_PASSWORD=$(generate_password 32)
    DJANGO_SECRET_KEY=$(generate_password 50)
fi

CVAT_ADMIN_PASSWORD=$(generate_password 16)

# 创建 .env (敏感信息会通过 secrets 注入，但仍需在环境中定义以供 compose secrets 使用)
log_info "创建环境配置..."
cat > .env <<EOF
# CVAT 环境配置 - $(date '+%Y-%m-%d %H:%M:%S')
# 注意: 敏感信息通过 Docker Secrets 注入容器

CVAT_HOST=$CVAT_HOST
ALLOWED_HOSTS=*
CSRF_TRUSTED_ORIGINS=$CSRF_ORIGINS

# 以下变量用于 Docker Secrets (不会直接暴露给容器)
CVAT_POSTGRES_PASSWORD=$CVAT_POSTGRES_PASSWORD
DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY

# Serverless 标记 (供 cvat.sh 管理脚本使用)
USE_SERVERLESS=$([[ "$USE_SERVERLESS" =~ ^[Yy]$ ]] && echo "true" || echo "false")

COMPOSE_PROJECT_NAME=cvat
EOF

chmod 600 .env

# 创建共享目录
mkdir -p /mnt/cvat_share

# 构建 compose 命令 (使用 secrets overlay)
COMPOSE_CMD="docker-compose -f docker-compose.yml -f docker-compose.secrets.yml"

if [[ "$USE_SERVERLESS" =~ ^[Yy]$ ]]; then
    COMPOSE_CMD="$COMPOSE_CMD -f components/serverless/docker-compose.serverless.yml"
    log_info "已启用 Serverless"
fi

# 构建并启动服务
log_info "构建 CVAT 镜像 (首次构建需要较长时间)..."
$COMPOSE_CMD build

log_info "启动 CVAT 服务 (使用 Docker Secrets)..."
$COMPOSE_CMD up -d

# 等待服务就绪 (健康检查)
wait_for_service() {
    local max_attempts=120
    local attempt=1
    log_info "等待服务就绪 (最长 ${max_attempts} 秒)..."

    while [ $attempt -le $max_attempts ]; do
        if docker exec cvat_server python3 manage.py check &>/dev/null; then
            log_info "服务已就绪 (耗时 ${attempt} 秒)"
            return 0
        fi
        printf "\r  检查中... %d/%d 秒" $attempt $max_attempts
        sleep 1
        ((attempt++))
    done

    echo ""
    log_error "服务启动超时"
    return 1
}

wait_for_service || { log_error "CVAT 启动失败，请检查日志: docker logs cvat_server"; exit 1; }

# 验证 secrets 注入
log_info "验证 Secrets 配置..."
if docker exec cvat_server test -f /run/secrets/postgres_password 2>/dev/null; then
    log_info "✓ postgres_password secret 已注入"
else
    log_warn "✗ postgres_password secret 未找到"
fi

if docker exec cvat_server test -f /run/secrets/django_secret_key 2>/dev/null; then
    log_info "✓ django_secret_key secret 已注入"
else
    log_warn "✗ django_secret_key secret 未找到"
fi

# 创建管理员
log_info "创建管理员账户..."
docker exec cvat_server bash -c "
    python3 manage.py createsuperuser --noinput --username admin --email admin@localhost 2>/dev/null || true
    echo \"from django.contrib.auth import get_user_model; User = get_user_model(); u = User.objects.get(username='admin'); u.set_password('$CVAT_ADMIN_PASSWORD'); u.save()\" | python3 manage.py shell
"

# 保存凭证 (仅管理员密码，其他敏感信息在 .env 中)
CREDENTIALS_FILE="$CVAT_DIR/credentials.txt"
cat > $CREDENTIALS_FILE <<EOF
========================================
CVAT 部署凭证
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
安全模式: Docker Secrets
========================================

访问地址: $PRIMARY_URL

管理员账户:
  用户名: admin
  密码: $CVAT_ADMIN_PASSWORD

敏感信息存储: .env (chmod 600)
Secrets 挂载点: /run/secrets/

========================================
EOF
chmod 600 $CREDENTIALS_FILE

# 完成
echo ""
log_info "=========================================="
log_info "CVAT 部署完成! (Docker Secrets 模式)"
log_info "=========================================="
echo ""
log_info "访问地址: $PRIMARY_URL"
log_info "用户名: admin"
log_info "密码: $CVAT_ADMIN_PASSWORD"
echo ""
log_info "凭证文件: $CREDENTIALS_FILE"
echo ""

if [[ "$USE_HTTPS" =~ ^[Yy]$ ]]; then
    log_warn "请配置 Nginx 反向代理，参考: $CVAT_DIR/nginx.conf.example"
fi

log_info "安全说明:"
echo "  - 敏感信息通过 Docker Secrets 注入 (/run/secrets/)"
echo "  - 容器内无法通过环境变量查看密码"
echo "  - .env 文件权限已设为 600"
echo ""

# 设置管理脚本权限
chmod +x "$CVAT_DIR/cvat.sh"

log_info "管理命令:"
echo "  ./cvat.sh start    - 启动服务"
echo "  ./cvat.sh stop     - 停止服务"
echo "  ./cvat.sh restart  - 重启服务"
echo "  ./cvat.sh status   - 查看状态"
echo "  ./cvat.sh logs     - 查看日志"
echo "  ./cvat.sh help     - 更多命令"
echo ""
