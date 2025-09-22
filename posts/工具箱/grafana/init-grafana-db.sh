#!/bin/bash
set -e

# 初始化PostgreSQL数据库脚本 - 为Grafana创建所需角色和权限
# 创建日期: 2023-07-25
# 更新日期: 2023-07-26 - 添加表所有权修复功能

echo "正在为Grafana创建数据库角色和权限..."

# 使用postgres用户连接到PostgreSQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- 创建grafana角色（如果不存在）
    DO \$\$ 
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'grafana') THEN
            CREATE ROLE grafana WITH LOGIN PASSWORD '${GRAFANA_PASSWORD:-grafana_password}';
        ELSE
            -- 更新现有角色的密码
            ALTER ROLE grafana WITH LOGIN PASSWORD '${GRAFANA_PASSWORD:-grafana_password}';
        END IF;
    END
    \$\$;

    -- 授予grafana角色对grafana数据库的所有权限
    GRANT ALL PRIVILEGES ON DATABASE grafana TO grafana;
    
    -- 连接到grafana数据库以设置schema权限
    \c grafana
    
    -- 授予grafana角色对public schema的所有权限
    GRANT ALL PRIVILEGES ON SCHEMA public TO grafana;
    
    -- 设置默认权限，使grafana角色成为未来创建的表的所有者
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO grafana;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO grafana;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO grafana;
    
    -- 创建扩展（如果需要）
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    
    -- 可选：为grafana角色设置密码有效期（无限期）
    ALTER ROLE grafana VALID UNTIL 'infinity';
    
    -- 可选：允许grafana角色创建数据库（如果需要）
    -- ALTER ROLE grafana CREATEDB;
    
    -- 可选：为了安全起见，撤销public角色的所有权限
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    REVOKE ALL ON DATABASE grafana FROM PUBLIC;
    
    -- 创建触发器函数，自动将新表的所有权分配给grafana角色
    CREATE OR REPLACE FUNCTION assign_ownership_to_grafana()
    RETURNS event_trigger AS \$\$
    DECLARE
        obj record;
    BEGIN
        FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE command_tag IN ('CREATE TABLE', 'CREATE SEQUENCE')
        LOOP
            IF obj.object_type IN ('table', 'sequence') THEN
                EXECUTE format('ALTER %s %s OWNER TO grafana', obj.object_type, obj.object_identity);
            END IF;
        END LOOP;
    END;
    \$\$ LANGUAGE plpgsql;

    -- 创建事件触发器
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'grafana_ownership_trigger') THEN
            CREATE EVENT TRIGGER grafana_ownership_trigger ON ddl_command_end
            WHEN TAG IN ('CREATE TABLE', 'CREATE SEQUENCE')
            EXECUTE PROCEDURE assign_ownership_to_grafana();
        END IF;
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'Skipping event trigger creation due to insufficient privileges';
    END
    \$\$;
EOSQL

# 等待一段时间，确保PostgreSQL完全初始化
sleep 5

# 修复现有表和序列的所有权
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "grafana" <<-EOSQL
    -- 修复表的所有权
    DO \$\$
    DECLARE
        t record;
    BEGIN
        FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
        LOOP
            EXECUTE 'ALTER TABLE public.' || quote_ident(t.tablename) || ' OWNER TO grafana';
        END LOOP;
    END
    \$\$;

    -- 修复序列的所有权
    DO \$\$
    DECLARE
        s record;
    BEGIN
        FOR s IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public'
        LOOP
            EXECUTE 'ALTER SEQUENCE public.' || quote_ident(s.sequence_name) || ' OWNER TO grafana';
        END LOOP;
    END
    \$\$;

    -- 修复视图的所有权
    DO \$\$
    DECLARE
        v record;
    BEGIN
        FOR v IN SELECT table_name FROM information_schema.views WHERE table_schema = 'public'
        LOOP
            EXECUTE 'ALTER VIEW public.' || quote_ident(v.table_name) || ' OWNER TO grafana';
        END LOOP;
    END
    \$\$;
EOSQL

echo "Grafana数据库角色和权限设置完成！表所有权已修复！"