-- Registers Double Bottom and Double Top as backend analysis models.
--
-- Until these rows exist, the app can run both patterns on the device but the
-- backend cannot raise alerts for them: notifications are generated per
-- analysis model, and there is no model row to attach a journey event to.
--
-- Slugs must match JourneyModel.serverSlug in the app
-- (Trendyssey/Domain/Models/JourneyAnalysis.swift). Change one and you must
-- change the other, otherwise the app silently falls back to the EMA model.
--
-- About scoring_configuration_id: it is NOT NULL and UNIQUE
-- (analysis_models_scoring_configuration_id_key), so every model needs a
-- configuration row of its own — two models cannot share one, and none can go
-- without. This migration therefore copies the EMA model's configuration once
-- per new model.
--
-- The copy never names a column of scoring_configurations. That table is not
-- readable from outside the database, so its shape is unknown here; the copy
-- goes through to_jsonb/jsonb_populate_record, and any UNIQUE text column is
-- given a distinct value per copy so the second one cannot collide.
--
-- Safe to run repeatedly: nothing is created when a row with the slug already
-- exists, and existing rows are refreshed in place.

begin;

do $$
declare
    source_config uuid;
    source_row jsonb;
    unique_text_columns text[];
    target record;
    new_config uuid;
    patch jsonb;
    column_name text;
begin
    select am.scoring_configuration_id
      into source_config
      from public.analysis_models am
     where am.slug = 'gpt-5-6-sol-v1';

    if source_config is null then
        raise exception
            'No scoring configuration found on gpt-5-6-sol-v1 to copy. '
            'Create a configuration for each new model manually, then re-run.';
    end if;

    select to_jsonb(sc) into source_row
      from public.scoring_configurations sc
     where sc.id = source_config;

    -- Text columns carrying their own UNIQUE index: each copy needs its own
    -- value, or the second insert collides.
    select coalesce(array_agg(distinct a.attname::text), '{}')
      into unique_text_columns
      from pg_index i
      join pg_attribute a
        on a.attrelid = i.indrelid
       and a.attnum = any (i.indkey)
     where i.indrelid = 'public.scoring_configurations'::regclass
       and i.indisunique
       and a.attname <> 'id'
       and a.atttypid in ('text'::regtype, 'varchar'::regtype);

    for target in
        select *
          from (values
                    ('double-bottom-v1',
                     '56000000-0000-4000-8000-000000000002'::uuid,
                     'Çift Dip',
                     'Benzer seviyedeki iki dibi bulur ve aralarındaki boyun çizgisinin yukarı kırılmasını izler; kırılım sürecini (bekleniyor, kırılım, retest, onay) aynı aşamalarla raporlar.',
                     20),
                    ('double-top-v1',
                     '56000000-0000-4000-8000-000000000003'::uuid,
                     'Çift Tepe',
                     'Benzer seviyedeki iki tepeyi bulur ve aralarındaki boyun çizgisinin aşağı kırılmasını izler. Düşüş yönlü bir modeldir: kırılım aşağı yönde tamamlanır.',
                     30)
               ) as t(slug, model_id, display_name, description, sort_order)
    loop
        if exists (select 1 from public.analysis_models where slug = target.slug) then
            update public.analysis_models
               set display_name = target.display_name,
                   description = target.description,
                   provider = 'Pulse',
                   authoring_model = 'trendyssey-double-pattern',
                   required_tier = 'pro',
                   is_active = true,
                   sort_order = target.sort_order,
                   updated_at = now()
             where slug = target.slug;
            continue;
        end if;

        new_config := gen_random_uuid();
        patch := jsonb_build_object('id', new_config);
        foreach column_name in array unique_text_columns loop
            patch := patch || jsonb_build_object(
                column_name,
                coalesce(source_row ->> column_name, 'config') || '-' || target.slug
            );
        end loop;

        insert into public.scoring_configurations
        select (jsonb_populate_record(
                    null::public.scoring_configurations,
                    source_row || patch
                )).*;

        insert into public.analysis_models (
            id, slug, display_name, provider, authoring_model, version,
            description, required_tier, scoring_configuration_id,
            is_active, is_default, sort_order
        ) values (
            target.model_id,
            target.slug,
            target.display_name,
            'Pulse',
            'trendyssey-double-pattern',
            1,
            target.description,
            'pro',
            new_config,
            true,
            false,
            target.sort_order
        );
    end loop;
end $$;

commit;

-- Verify: three models, each with its own configuration, all active.
-- select slug, display_name, is_active, scoring_configuration_id, sort_order
--   from public.analysis_models order by sort_order;
