defmodule ElectricAgentsServer.PublicUiProjectionsTest do
  use ExUnit.Case, async: false

  alias ElectricAgentsServer.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    tenant = "projection-#{System.unique_integer([:positive])}"
    %{tenant: tenant}
  end

  test "runner projections back their exact public rows and remove empty diagnostics", %{
    tenant: tenant
  } do
    sql!(
      "INSERT INTO ea_runners (tenant,runner_id,owner_principal,label,kind,admin_status,wake_stream,inserted_at,updated_at) VALUES ($1,'r1','/user/u','Mine','local','enabled','/wake',now(),now())",
      [tenant]
    )

    assert [["r1", "/user/u"]] =
             rows!("SELECT id,owner_principal FROM runners WHERE tenant_id=$1", [tenant])

    assert [] =
             rows!("SELECT runner_id FROM runner_runtime_diagnostics WHERE tenant_id=$1", [tenant])

    sql!(
      "UPDATE ea_runners SET wake_stream_offset='7', lease_expires_at=now()+interval '1 minute' WHERE tenant=$1",
      [tenant]
    )

    assert [["r1", "7"]] =
             rows!(
               "SELECT runner_id,wake_stream_offset FROM runner_runtime_diagnostics WHERE tenant_id=$1",
               [tenant]
             )

    sql!("DELETE FROM ea_runners WHERE tenant=$1", [tenant])
    assert [] = rows!("SELECT id FROM runners WHERE tenant_id=$1", [tenant])

    assert [] =
             rows!("SELECT runner_id FROM runner_runtime_diagnostics WHERE tenant_id=$1", [tenant])
  end

  test "effective grants follow descendants and reparenting without changing ids", %{
    tenant: tenant
  } do
    entity!(tenant, "root", nil)
    entity!(tenant, "other", nil)
    entity!(tenant, "child", "/agent/root")

    [[root_id]] =
      rows!("SELECT incarnation::text FROM ea_entities WHERE tenant=$1 AND logical_key='root'", [
        tenant
      ])

    [[grant_id]] =
      rows!(
        "INSERT INTO ea_entity_grants (tenant,entity_incarnation,permission,subject_kind,subject_value,propagation,inserted_at,updated_at) VALUES ($1,$2::text::uuid,'read','principal','/user/u','descendants',now(),now()) RETURNING id",
        [tenant, root_id]
      )

    assert [["/agent/child"], ["/agent/root"]] =
             rows!(
               "SELECT entity_url FROM entity_effective_permissions WHERE tenant_id=$1 ORDER BY entity_url",
               [tenant]
             )

    [[stable_id]] =
      rows!(
        "SELECT id FROM entity_effective_permissions WHERE tenant_id=$1 AND entity_url='/agent/child'",
        [tenant]
      )

    sql!(
      "UPDATE ea_entities SET parent='\"/agent/other\"'::jsonb WHERE tenant=$1 AND logical_key='child'",
      [tenant]
    )

    assert [] =
             rows!(
               "SELECT id FROM entity_effective_permissions WHERE tenant_id=$1 AND entity_url='/agent/child'",
               [tenant]
             )

    sql!(
      "UPDATE ea_entities SET parent='\"/agent/root\"'::jsonb WHERE tenant=$1 AND logical_key='child'",
      [tenant]
    )

    assert [[^stable_id]] =
             rows!(
               "SELECT id FROM entity_effective_permissions WHERE tenant_id=$1 AND entity_url='/agent/child'",
               [tenant]
             )

    sql!("DELETE FROM ea_entity_grants WHERE id=$1", [grant_id])
    assert [] = rows!("SELECT id FROM entity_effective_permissions WHERE tenant_id=$1", [tenant])
  end

  test "effective permissions are tenant isolated", %{tenant: tenant} do
    other = tenant <> "-other"
    entity!(tenant, "same", nil)
    entity!(other, "same", nil)
    [[id]] = rows!("SELECT incarnation::text FROM ea_entities WHERE tenant=$1", [tenant])

    sql!(
      "INSERT INTO ea_entity_grants (tenant,entity_incarnation,permission,subject_kind,subject_value,inserted_at,updated_at) VALUES ($1,$2::text::uuid,'write','principal_kind','human',now(),now())",
      [tenant, id]
    )

    assert [[^tenant]] =
             rows!(
               "SELECT tenant_id FROM entity_effective_permissions WHERE entity_url='/agent/same'",
               []
             )
  end

  defp entity!(tenant, key, parent) do
    sql!(
      "INSERT INTO ea_entities (tenant,kind,logical_key,status,tags,parent,streams,spawn_args,created_at,updated_at) VALUES ($1,'agent',$2,'running','{}'::jsonb,$3::jsonb,'{}'::jsonb,'{}'::jsonb,now(),now())",
      [tenant, key, parent]
    )
  end

  defp sql!(statement, params), do: Ecto.Adapters.SQL.query!(Repo, statement, params)
  defp rows!(statement, params), do: sql!(statement, params).rows
end
