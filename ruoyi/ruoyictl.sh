#!/bin/bash

# =============================================
# Ruoyi 应用管理脚本 (优化版)
# 版本: 2.0
# 路径: /home/ruoyi/sbin/ruoyictl
# =============================================

# 基础配置
BASE_DIR="/home/ruoyi"
APPS_DIR="$BASE_DIR/apps"       # 运行目录
BAK_DIR="$BASE_DIR/apps_bak"    # 备份目录
LOG_DIR="$BASE_DIR/logs"        # 日志目录
JAR_NAME="ruoyi.jar"
JDK_HOME="$BASE_DIR/software/jdk21"  # JDK 安装目录
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
# 优化JVM参数：增加内存设置、GC优化、JFR监控
DEFAULT_JVM_OPTS="-Xms512m -Xmx1024m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Duser.timezone=Asia/Shanghai -Dserver.port=7188 -Dfile.encoding=UTF-8"
# 日志文件路径
APP_LOG="$LOG_DIR/ruoyi.log"
GC_LOG="$LOG_DIR/gc.log"

# 创建必要的目录结构
mkdir -p "$APPS_DIR" "$BAK_DIR" "$LOG_DIR"

# 检查JDK是否存在
if [ ! -d "$JDK_HOME" ]; then
    echo "❌ 错误：JDK未安装在此路径 $JDK_HOME"
    exit 1
fi

# 设置Java路径
JAVA_CMD="$JDK_HOME/bin/java"

# =============================================
# 功能函数
# =============================================

# 功能: 打印帮助信息
print_help() {
    echo "Ruoyi 应用管理脚本"
    echo "用法: $0 [command] [args]"
    echo ""
    echo "可用命令:"
    echo "  start      - 启动应用（如果存在新版本则先部署）"
    echo "  stop       - 停止应用"
    echo "  status     - 查看应用状态"
    echo "  health     - 检查应用健康状态"
    echo "  deploy     - 部署并启动新版本"
    echo "  restart    - 重启当前版本"
    echo "  rollback   - 回滚到指定版本"
    echo "  list       - 列出可用备份"
    echo "  logs       - 查看应用日志"
    echo "  help       - 显示帮助信息"
    echo ""
    echo "参数说明:"
    echo "  rollback 命令需要指定备份时间戳"
    echo "  logs 命令可指定行数，例如: $0 logs 100"
    echo "  可以添加额外的JVM参数，例如:"
    echo "    $0 deploy \"-Xmx512m -Xms256m\""
    echo "    $0 rollback 20240101_123456 \"-Dspring.profiles.active=prod\""
    echo ""
    echo "备份命名格式: ruoyi.jar.YYYYMMDD_HHMMSS"
    echo "日志文件位置: $LOG_DIR/ruoyi.log"
    echo "GC日志位置: $LOG_DIR/gc.log"
}

# 功能: 获取应用PID
get_app_pid() {
    pgrep -f "$JAR_NAME"
}

# 功能: 检查应用健康状态
check_health() {
    local pid=$(get_app_pid)
    if [ -z "$pid" ]; then
        echo "⭕ 应用未运行"
        return 1
    fi
    
    # 检查端口是否监听
    local port=$(echo "$DEFAULT_JVM_OPTS" | grep -o 'server.port=[0-9]*' | cut -d'=' -f2)
    if [ -n "$port" ] && netstat -tuln 2>/dev/null | grep -q ":$port "; then
        echo "✅ 应用健康运行 (PID: $pid, Port: $port)"
        return 0
    else
        echo "⚠️  应用进程存在但端口未监听 (PID: $pid)"
        return 2
    fi
}

# 功能: 检查应用状态
check_status() {
    local pid=$(get_app_pid)
    if [ -n "$pid" ]; then
        echo "✅ 应用正在运行 (PID: $pid)"
        return 0
    else
        echo "⭕ 应用未运行"
        return 1
    fi
}

# 功能: 停止应用
stop_application() {
    local pid=$(get_app_pid)

    if [ -z "$pid" ]; then
        echo "⭕ 应用未运行"
        return 0
    fi

    echo "🛑 正在停止应用 (PID: $pid)..."

    # 尝试优雅停止
    kill $pid

    # 等待最多10秒
    local timeout=10
    while [ $timeout -gt 0 ]; do
        if ! ps -p $pid > /dev/null; then
            echo "✅ 应用已停止"
            return 0
        fi
        sleep 1
        timeout=$((timeout-1))
    done

    # 强制停止
    if ps -p $pid > /dev/null; then
        echo "⚡ 强制停止..."
        kill -9 $pid
        sleep 1
    fi

    # 最终检查
    if ps -p $pid > /dev/null; then
        echo "⚠️  警告：未能完全停止应用 (PID: $pid)"
        return 1
    else
        echo "✅ 应用已停止"
        return 0
    fi
}

# 功能: 备份当前应用
backup_current_jar() {
    if [ -f "$APPS_DIR/$JAR_NAME" ]; then
        echo "💾 备份当前运行的应用..."
        BACKUP_NAME="${JAR_NAME}.$TIMESTAMP"
        mv -v "$APPS_DIR/$JAR_NAME" "$BAK_DIR/$BACKUP_NAME"
        echo "✅ 已备份至: $BAK_DIR/$BACKUP_NAME"
        
        # 清理旧备份，只保留最近10个
        cleanup_old_backups
        return 0
    fi
    return 1
}

# 功能: 清理旧备份文件
cleanup_old_backups() {
    local backup_count=$(ls -1 "$BAK_DIR" | grep "ruoyi\.jar\..*$" | wc -l)
    if [ "$backup_count" -gt 10 ]; then
        echo "🧹 清理旧备份文件..."
        ls -1t "$BAK_DIR"/ruoyi.jar.* | tail -n +11 | while read backup_file; do
            echo "🗑️  删除旧备份: $(basename "$backup_file")"
            rm -f "$backup_file"
        done
        echo "✅ 备份清理完成，保留最新10个备份"
    fi
}

# 功能: 回滚到指定版本
rollback_to_version() {
    local timestamp=$1
    BACKUP_JAR="$BAK_DIR/$JAR_NAME.$timestamp"

    if [ ! -f "$BACKUP_JAR" ]; then
        echo "❌ 错误：备份文件 $BACKUP_JAR 不存在！"
        list_backups
        return 1
    fi

    echo "🔄 回滚到 $timestamp 版本..."

    # 直接替换当前版本（不再创建额外备份）
    mv -fv "$BACKUP_JAR" "$APPS_DIR/$JAR_NAME"
    return $?
}

# 功能: 列出可用备份
list_backups() {
    echo "📋 可用备份:"
    ls -1 "$BAK_DIR" | grep "ruoyi\.jar\..*$" | cut -d'.' -f3- | sort -r
}

# 功能: 查看应用日志
view_logs() {
    local lines=${1:-50}  # 默认显示最后50行
    
    if [ ! -f "$APP_LOG" ]; then
        echo "⚠️  日志文件不存在: $APP_LOG"
        return 1
    fi
    
    echo "📄 应用日志 (最后 $lines 行):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    tail -n "$lines" "$APP_LOG"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "💡 实时查看日志: tail -f $APP_LOG"
    echo "💡 查看GC日志: tail -f $GC_LOG"
}

# 功能: 部署新版本
deploy_new_version() {
    if [ ! -f "$BASE_DIR/$JAR_NAME" ]; then
        echo "❌ 错误：找不到可部署的JAR文件！"
        return 1
    fi

    echo "🚀 发现新版本，正在部署..."
    mv -v "$BASE_DIR/$JAR_NAME" "$APPS_DIR/$JAR_NAME"
    return $?
}

# 功能: 启动应用
start_application() {
    local pid=$(get_app_pid)

    if [ -n "$pid" ]; then
        echo "⚠️  应用已在运行 (PID: $pid)"
        return 0
    fi

    # 检查JAR文件是否存在
    if [ ! -f "$APPS_DIR/$JAR_NAME" ]; then
        echo "❌ 错误：找不到可执行的JAR文件！"
        return 1
    fi

    echo "🚀 启动应用..."
    echo "☕ 使用JDK路径: $JDK_HOME"
    echo "📦 JAR文件路径: $APPS_DIR/$JAR_NAME"
    echo "📝 应用日志: $APP_LOG"
    echo "🗑️  GC日志: $GC_LOG"
    
    # 构建完整的JVM参数
    local full_jvm_opts="$DEFAULT_JVM_OPTS $extra_opts -Xloggc:$GC_LOG -XX:+PrintGCDetails -XX:+PrintGCTimeStamps"
    echo "⚙️  启动命令: $JAVA_CMD $full_jvm_opts -jar $JAR_NAME"

    cd "$APPS_DIR"
    # 重定向输出到日志文件
    nohup $JAVA_CMD $full_jvm_opts -jar "$JAR_NAME" > "$APP_LOG" 2>&1 &
    PID=$!
    echo "🔄 等待应用启动..."
    sleep 3  # 等待应用启动

    # 验证进程是否在运行
    if ps -p $PID > /dev/null; then
        echo "✅ 应用启动成功！PID: $PID"
        # 等待端口监听
        local port=$(echo "$DEFAULT_JVM_OPTS" | grep -o 'server.port=[0-9]*' | cut -d'=' -f2)
        if [ -n "$port" ]; then
            echo "⏳ 等待端口 $port 启动..."
            local count=0
            while [ $count -lt 30 ]; do  # 最多等待30秒
                if netstat -tuln 2>/dev/null | grep -q ":$port "; then
                    echo "🌐 端口 $port 已启动，应用就绪！"
                    return 0
                fi
                sleep 1
                count=$((count+1))
            done
            echo "⚠️  应用已启动但端口未就绪，请检查日志: $APP_LOG"
        fi
        return 0
    else
        echo "❌ 应用启动失败"
        echo "💡 请检查日志: tail -f $APP_LOG"
        return 1
    fi
}

# =============================================
# 主程序逻辑
# =============================================

case "$1" in
    start)
        # 默认启动模式：部署目录中有新版本则部署，没有则直接启动
        if [ -f "$BASE_DIR/$JAR_NAME" ]; then
            stop_application
            backup_current_jar
            deploy_new_version
        fi

        # 检查应用是否已在运行
        if check_status >/dev/null; then
            echo "✅ 应用已在运行中"
        else
            start_application "$2"
        fi
        ;;

    stop)
        stop_application
        ;;

    status)
        check_status
        ;;

    deploy)
        stop_application
        backup_current_jar
        deploy_new_version || exit 1
        start_application "$2"
        ;;

    restart)
        stop_application
        start_application "$2"
        ;;

    rollback)
        if [ -z "$2" ]; then
            echo "⚠️  请指定要回滚的备份时间戳（格式：YYYYMMDD_HHMMSS）"
            list_backups
            exit 1
        fi

        stop_application || exit 1
        rollback_to_version "$2" || exit 1
        start_application "$3"
        ;;

    list)
        list_backups
        ;;

    health)
        check_health
        ;;

    logs)
        view_logs $2
        ;;

    help|"")
        print_help
        ;;

    *)
        echo "❌ 未知命令: $1"
        echo "💡 使用 $0 help 查看可用命令"
        print_help
        exit 1
        ;;
esac

exit $?