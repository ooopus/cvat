#!/bin/bash

#######################################
# CVAT 管理脚本
# 用法: ./cvat.sh [命令]
#######################################

set -e

CVAT_DIR="/opt/cvat"
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.secrets.yml"

# 检查 serverless 是否启用
if [ -f "$CVAT_DIR/.env" ] && grep -q "USE_SERVERLESS=true" "$CVAT_DIR/.env" 2>/dev/null; then
    COMPOSE_FILES="$COMPOSE_FILES -f components/serverless/docker-compose.serverless.yml"
fi

cd "$CVAT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    echo "CVAT 管理脚本"
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  start        启动所有服务"
    echo "  stop         停止所有服务"
    echo "  restart      重启所有服务"
    echo "  down         停止并删除容器"
    echo "  status       查看服务状态"
    echo "  logs         查看日志 (可选: logs <服务名>)"
    echo "  update       拉取最新镜像并重启"
    echo "  backup       备份数据库"
    echo "  shell        进入 cvat_server 容器"
    echo "  serverless   切换 Serverless (AI标注) 功能"
    echo "  help         显示此帮助"
    echo ""
}

case "${1:-help}" in
    start)
        log_info "启动 CVAT 服务..."
        docker-compose $COMPOSE_FILES up -d
        log_info "服务已启动"
        docker-compose $COMPOSE_FILES ps
        ;;

    stop)
        log_info "停止 CVAT 服务..."
        docker-compose $COMPOSE_FILES stop
        log_info "服务已停止"
        ;;

    restart)
        log_info "重启 CVAT 服务..."
        docker-compose $COMPOSE_FILES restart
        log_info "服务已重启"
        docker-compose $COMPOSE_FILES ps
        ;;

    down)
        log_warn "这将停止并删除所有容器 (数据卷保留)"
        read -p "确认? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            docker-compose $COMPOSE_FILES down
            log_info "容器已删除"
        else
            log_info "已取消"
        fi
        ;;

    status)
        docker-compose $COMPOSE_FILES ps
        echo ""
        log_info "Secrets 状态:"
        docker exec cvat_server test -f /run/secrets/postgres_password 2>/dev/null \
            && echo "  ✓ postgres_password" || echo "  ✗ postgres_password"
        docker exec cvat_server test -f /run/secrets/django_secret_key 2>/dev/null \
            && echo "  ✓ django_secret_key" || echo "  ✗ django_secret_key"
        echo ""
        SERVERLESS_STATUS=$(grep "^USE_SERVERLESS=" "$CVAT_DIR/.env" 2>/dev/null | cut -d= -f2)
        log_info "Serverless: ${SERVERLESS_STATUS:-未配置}"
        if [ "$SERVERLESS_STATUS" = "true" ]; then
            docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "nuclio|serverless" || echo "  (Serverless 容器未运行)"
        fi
        ;;

    logs)
        if [ -n "$2" ]; then
            docker-compose $COMPOSE_FILES logs -f "$2"
        else
            docker-compose $COMPOSE_FILES logs -f cvat_server
        fi
        ;;

    update)
        log_info "拉取最新镜像..."
        docker-compose $COMPOSE_FILES pull
        log_info "重启服务..."
        docker-compose $COMPOSE_FILES up -d
        log_info "更新完成"
        docker-compose $COMPOSE_FILES ps
        ;;

    backup)
        BACKUP_FILE="cvat_backup_$(date +%Y%m%d_%H%M%S).sql"
        log_info "备份数据库到 $BACKUP_FILE..."
        docker exec cvat_db pg_dump -U root cvat > "$BACKUP_FILE"
        log_info "备份完成: $BACKUP_FILE"
        ;;

    shell)
        log_info "进入 cvat_server 容器..."
        docker exec -it cvat_server bash
        ;;

    serverless)
        CURRENT=$(grep "^USE_SERVERLESS=" "$CVAT_DIR/.env" 2>/dev/null | cut -d= -f2)
        echo ""
        echo "Serverless (AI自动标注) 状态: ${CURRENT:-未配置}"
        echo ""
        echo "选项:"
        echo "  1) 启用 Serverless"
        echo "  2) 禁用 Serverless"
        echo "  0) 取消"
        echo ""
        read -p "请选择 [0-2]: " choice

        case "$choice" in
            1)
                log_info "启用 Serverless..."
                sed -i 's/^USE_SERVERLESS=.*/USE_SERVERLESS=true/' "$CVAT_DIR/.env" 2>/dev/null || \
                    echo "USE_SERVERLESS=true" >> "$CVAT_DIR/.env"

                log_warn "需要重建容器以应用更改"
                read -p "现在重建? [Y/n]: " rebuild
                if [[ "${rebuild:-y}" =~ ^[Yy]$ ]]; then
                    # 重新加载 COMPOSE_FILES
                    COMPOSE_FILES="-f docker-compose.yml -f docker-compose.secrets.yml -f components/serverless/docker-compose.serverless.yml"
                    docker-compose $COMPOSE_FILES down
                    docker-compose $COMPOSE_FILES up -d
                    log_info "Serverless 已启用"
                else
                    log_info "请手动运行: ./cvat.sh down && ./cvat.sh start"
                fi
                ;;
            2)
                log_info "禁用 Serverless..."
                sed -i 's/^USE_SERVERLESS=.*/USE_SERVERLESS=false/' "$CVAT_DIR/.env" 2>/dev/null || \
                    echo "USE_SERVERLESS=false" >> "$CVAT_DIR/.env"

                log_warn "需要重建容器以应用更改"
                read -p "现在重建? [Y/n]: " rebuild
                if [[ "${rebuild:-y}" =~ ^[Yy]$ ]]; then
                    # 不包含 serverless compose 文件
                    COMPOSE_FILES="-f docker-compose.yml -f docker-compose.secrets.yml"
                    # 先停止所有（包括可能运行的 serverless 容器）
                    docker-compose -f docker-compose.yml -f docker-compose.secrets.yml -f components/serverless/docker-compose.serverless.yml down 2>/dev/null || true
                    docker-compose $COMPOSE_FILES up -d
                    log_info "Serverless 已禁用"
                else
                    log_info "请手动运行: ./cvat.sh down && ./cvat.sh start"
                fi
                ;;
            *)
                log_info "已取消"
                ;;
        esac
        ;;

    help|--help|-h)
        show_help
        ;;

    *)
        log_error "未知命令: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
