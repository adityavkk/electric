defmodule ElectricAgentsServer.Repo.Migrations.AddMissingPublicUiProjections do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE users (
      tenant_id text NOT NULL,
      id text NOT NULL,
      display_name text,
      email text,
      avatar_url text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id)
    )
    """

    execute """
    CREATE TABLE runners (
      tenant_id text NOT NULL,
      id text NOT NULL,
      owner_principal text NOT NULL,
      label text NOT NULL,
      kind text NOT NULL,
      admin_status text NOT NULL,
      wake_stream text NOT NULL,
      sandbox_profiles jsonb NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, id),
      UNIQUE (tenant_id, wake_stream)
    )
    """

    execute "CREATE INDEX runners_owner_idx ON runners (tenant_id, owner_principal)"

    execute """
    CREATE TABLE runner_runtime_diagnostics (
      tenant_id text NOT NULL,
      runner_id text NOT NULL,
      owner_principal text NOT NULL,
      wake_stream_offset text,
      last_seen_at timestamptz NOT NULL,
      liveness_lease_expires_at timestamptz NOT NULL,
      diagnostics jsonb,
      updated_at timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, runner_id)
    )
    """

    execute "CREATE INDEX runner_runtime_diagnostics_owner_idx ON runner_runtime_diagnostics (tenant_id, owner_principal)"

    execute """
    CREATE FUNCTION ea_project_runner() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        DELETE FROM runners WHERE tenant_id=OLD.tenant AND id=OLD.runner_id;
        DELETE FROM runner_runtime_diagnostics WHERE tenant_id=OLD.tenant AND runner_id=OLD.runner_id;
        RETURN OLD;
      END IF;

      INSERT INTO runners (tenant_id,id,owner_principal,label,kind,admin_status,wake_stream,
                           sandbox_profiles,created_at,updated_at)
      VALUES (NEW.tenant,NEW.runner_id,NEW.owner_principal,NEW.label,NEW.kind,NEW.admin_status,
              NEW.wake_stream,to_jsonb(NEW.sandbox_profiles),NEW.inserted_at,NEW.updated_at)
      ON CONFLICT (tenant_id,id) DO UPDATE SET
        owner_principal=EXCLUDED.owner_principal,label=EXCLUDED.label,kind=EXCLUDED.kind,
        admin_status=EXCLUDED.admin_status,wake_stream=EXCLUDED.wake_stream,
        sandbox_profiles=EXCLUDED.sandbox_profiles,updated_at=EXCLUDED.updated_at;

      IF NEW.wake_stream_offset IS NOT NULL OR NEW.lease_expires_at IS NOT NULL OR NEW.diagnostics IS NOT NULL THEN
        INSERT INTO runner_runtime_diagnostics
          (tenant_id,runner_id,owner_principal,wake_stream_offset,last_seen_at,
           liveness_lease_expires_at,diagnostics,updated_at)
        VALUES (NEW.tenant,NEW.runner_id,NEW.owner_principal,NEW.wake_stream_offset,
                NEW.updated_at,COALESCE(NEW.lease_expires_at,NEW.updated_at),NEW.diagnostics,NEW.updated_at)
        ON CONFLICT (tenant_id,runner_id) DO UPDATE SET
          owner_principal=EXCLUDED.owner_principal,wake_stream_offset=EXCLUDED.wake_stream_offset,
          last_seen_at=EXCLUDED.last_seen_at,liveness_lease_expires_at=EXCLUDED.liveness_lease_expires_at,
          diagnostics=EXCLUDED.diagnostics,updated_at=EXCLUDED.updated_at;
      ELSE
        DELETE FROM runner_runtime_diagnostics WHERE tenant_id=NEW.tenant AND runner_id=NEW.runner_id;
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER ea_project_runner_trigger AFTER INSERT OR UPDATE OR DELETE ON ea_runners FOR EACH ROW EXECUTE FUNCTION ea_project_runner()"

    execute """
    CREATE TABLE ea_effective_permission_ids (
      id bigserial PRIMARY KEY,
      tenant text NOT NULL,
      entity_url text NOT NULL,
      source_grant_id bigint NOT NULL,
      UNIQUE (tenant, entity_url, source_grant_id)
    )
    """

    execute """
    CREATE TABLE entity_effective_permissions (
      id bigint PRIMARY KEY,
      tenant_id text NOT NULL,
      entity_url text NOT NULL,
      source_entity_url text NOT NULL,
      source_grant_id bigint NOT NULL,
      permission text NOT NULL,
      subject_kind text NOT NULL,
      subject_value text NOT NULL,
      expires_at timestamptz,
      created_at timestamptz NOT NULL,
      UNIQUE (tenant_id, entity_url, source_grant_id)
    )
    """

    execute "CREATE INDEX entity_effective_permissions_lookup_idx ON entity_effective_permissions (tenant_id, permission, subject_kind, subject_value, entity_url)"

    execute "CREATE INDEX entity_effective_permissions_entity_idx ON entity_effective_permissions (tenant_id, entity_url)"

    # Reconcile only one grant, or only the entity subtree affected by a parent change.
    execute """
    CREATE FUNCTION ea_refresh_effective_permissions(p_tenant text, p_root text DEFAULT NULL,
                                                     p_grant_id bigint DEFAULT NULL)
    RETURNS void LANGUAGE plpgsql AS $$
    BEGIN
      CREATE TEMP TABLE IF NOT EXISTS ea_ep_scope (url text PRIMARY KEY) ON COMMIT DROP;
      TRUNCATE ea_ep_scope;
      IF p_root IS NULL THEN
        INSERT INTO ea_ep_scope SELECT '/'||kind||'/'||logical_key FROM ea_entities WHERE tenant=p_tenant;
      ELSE
        INSERT INTO ea_ep_scope
        WITH RECURSIVE tree(url) AS (
          VALUES (p_root)
          UNION ALL
          SELECT '/'||e.kind||'/'||e.logical_key FROM ea_entities e JOIN tree t
            ON e.tenant=p_tenant AND e.parent #>> '{}'=t.url
        ) SELECT url FROM tree;
      END IF;

      CREATE TEMP TABLE IF NOT EXISTS ea_ep_desired (
        entity_url text, source_entity_url text, source_grant_id bigint, permission text,
        subject_kind text, subject_value text, expires_at timestamptz, created_at timestamptz,
        PRIMARY KEY(entity_url, source_grant_id)) ON COMMIT DROP;
      TRUNCATE ea_ep_desired;
      INSERT INTO ea_ep_desired
      SELECT s.url,'/'||src.kind||'/'||src.logical_key,g.id,g.permission,g.subject_kind,
             g.subject_value,g.expires_at,g.inserted_at
      FROM ea_ep_scope s
      JOIN ea_entities target ON target.tenant=p_tenant AND '/'||target.kind||'/'||target.logical_key=s.url
      JOIN ea_entity_grants g ON g.tenant=p_tenant
      JOIN ea_entities src ON src.tenant=p_tenant AND src.incarnation=g.entity_incarnation
      WHERE (p_grant_id IS NULL OR g.id=p_grant_id)
        AND (src.incarnation=target.incarnation OR
             (g.propagation='descendants' AND EXISTS (
               WITH RECURSIVE descendants(url) AS (
                 SELECT '/'||src.kind||'/'||src.logical_key
                 UNION ALL
                 SELECT '/'||c.kind||'/'||c.logical_key FROM descendants d JOIN ea_entities c
                   ON c.tenant=p_tenant AND (c.parent #>> '{}')=d.url
               ) SELECT 1 FROM descendants WHERE url=s.url AND url<>'/'||src.kind||'/'||src.logical_key
             )));

      INSERT INTO ea_effective_permission_ids (tenant,entity_url,source_grant_id)
        SELECT p_tenant,entity_url,source_grant_id FROM ea_ep_desired ON CONFLICT DO NOTHING;
      INSERT INTO entity_effective_permissions
        (id,tenant_id,entity_url,source_entity_url,source_grant_id,permission,subject_kind,
         subject_value,expires_at,created_at)
      SELECT ids.id,p_tenant,d.entity_url,d.source_entity_url,d.source_grant_id,d.permission,
             d.subject_kind,d.subject_value,d.expires_at,d.created_at
      FROM ea_ep_desired d JOIN ea_effective_permission_ids ids
        ON ids.tenant=p_tenant AND ids.entity_url=d.entity_url AND ids.source_grant_id=d.source_grant_id
      ON CONFLICT (tenant_id,entity_url,source_grant_id) DO UPDATE SET
        source_entity_url=EXCLUDED.source_entity_url,permission=EXCLUDED.permission,
        subject_kind=EXCLUDED.subject_kind,subject_value=EXCLUDED.subject_value,
        expires_at=EXCLUDED.expires_at,created_at=EXCLUDED.created_at;

      DELETE FROM entity_effective_permissions ep WHERE ep.tenant_id=p_tenant
        AND ep.entity_url IN (SELECT url FROM ea_ep_scope)
        AND (p_grant_id IS NULL OR ep.source_grant_id=p_grant_id)
        AND NOT EXISTS (SELECT 1 FROM ea_ep_desired d
                        WHERE d.entity_url=ep.entity_url AND d.source_grant_id=ep.source_grant_id);
    END $$
    """

    execute """
    CREATE FUNCTION ea_project_grant_permissions() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP='DELETE' THEN
        DELETE FROM entity_effective_permissions WHERE tenant_id=OLD.tenant AND source_grant_id=OLD.id;
        RETURN OLD;
      END IF;
      PERFORM ea_refresh_effective_permissions(NEW.tenant,NULL,NEW.id);
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER ea_project_grant_permissions_trigger AFTER INSERT OR UPDATE OR DELETE ON ea_entity_grants FOR EACH ROW EXECUTE FUNCTION ea_project_grant_permissions()"

    execute """
    CREATE FUNCTION ea_project_entity_permissions() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE old_url text; new_url text;
    BEGIN
      old_url := '/'||OLD.kind||'/'||OLD.logical_key;
      IF TG_OP='DELETE' THEN
        DELETE FROM entity_effective_permissions WHERE tenant_id=OLD.tenant AND entity_url=old_url;
        PERFORM ea_refresh_effective_permissions(OLD.tenant,old_url,NULL);
        RETURN OLD;
      END IF;
      new_url := '/'||NEW.kind||'/'||NEW.logical_key;
      IF TG_OP='INSERT' OR NEW.parent IS DISTINCT FROM OLD.parent OR new_url IS DISTINCT FROM old_url THEN
        IF TG_OP='UPDATE' AND new_url IS DISTINCT FROM old_url THEN
          DELETE FROM entity_effective_permissions WHERE tenant_id=OLD.tenant AND entity_url=old_url;
        END IF;
        PERFORM ea_refresh_effective_permissions(NEW.tenant,new_url,NULL);
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER zz_ea_project_entity_permissions_trigger AFTER INSERT OR UPDATE OR DELETE ON ea_entities FOR EACH ROW EXECUTE FUNCTION ea_project_entity_permissions()"

    execute "UPDATE ea_runners SET updated_at=updated_at"

    execute "SELECT ea_refresh_effective_permissions(tenant,NULL,NULL) FROM (SELECT DISTINCT tenant FROM ea_entities) tenants"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS zz_ea_project_entity_permissions_trigger ON ea_entities"
    execute "DROP TRIGGER IF EXISTS ea_project_grant_permissions_trigger ON ea_entity_grants"
    execute "DROP TRIGGER IF EXISTS ea_project_runner_trigger ON ea_runners"
    execute "DROP FUNCTION IF EXISTS ea_project_entity_permissions()"
    execute "DROP FUNCTION IF EXISTS ea_project_grant_permissions()"
    execute "DROP FUNCTION IF EXISTS ea_refresh_effective_permissions(text,text,bigint)"
    execute "DROP FUNCTION IF EXISTS ea_project_runner()"
    execute "DROP TABLE IF EXISTS entity_effective_permissions"
    execute "DROP TABLE IF EXISTS ea_effective_permission_ids"
    execute "DROP TABLE IF EXISTS runner_runtime_diagnostics"
    execute "DROP TABLE IF EXISTS runners"
    execute "DROP TABLE IF EXISTS users"
  end
end
