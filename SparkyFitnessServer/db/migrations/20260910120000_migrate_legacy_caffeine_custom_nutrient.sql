-- Fold a pre-existing "Caffeine" user_custom_nutrients row into the built-in
-- caffeine_mg column (20260905150000_add_caffeine_alcohol_water_and_container_links.sql,
-- #1958).
--
-- BACKGROUND: caffeine_mg did not exist before that migration, so anyone who
-- wanted to track caffeine had to add it themselves via the free-text custom
-- nutrient feature (user_custom_nutrients). That migration registered
-- "Caffeine" in shared/src/nutrients/micronutrientCatalog.ts with
-- fixedField: caffeine_mg, which stops NEW custom "Caffeine" nutrients from
-- being created (customNutrientService.ensureCatalogNutrients resolves the
-- catalog pick onto the column instead) -- but it does nothing for a
-- user_custom_nutrients row that already existed. Left alone, that user now
-- has two parallel caffeine trackers: their old custom nutrient, and the new
-- column, with nothing to connect them.
--
-- WHAT THIS DOES: for every user whose custom nutrient name/alias matches
-- caffeine (case/punctuation-insensitive, same spellings the catalog entry
-- registers), copy the value already stored under that nutrient's name --
-- converted to mg -- into caffeine_mg, wherever caffeine_mg is not already
-- set. Applied to:
--   1. food_variants (the food's own definition) -- so every future log of
--      that food, and Reports going forward, carry caffeine automatically.
--   2. user_goals / goal_presets -- so a caffeine target the user already
--      set under the old nutrient carries over to the new built-in goal.
--
-- WHAT THIS DELIBERATELY DOES NOT DO:
--   - It does NOT touch food_entries or meal_foods. Those are log-time
--     snapshots (see utils/foodEntrySnapshot.ts); rewriting them would mean
--     silently changing a day's already-recorded nutrition totals, which is
--     exactly what this codebase avoids elsewhere (see
--     add_food_water_to_intake's "no existing user's numbers change on
--     upgrade" in the companion migration). A NULL caffeine_mg on an old
--     food_entries row already means "predates this column, treat as 0" --
--     the same convention every other nutrient column on that table uses --
--     so leaving history alone is correct, not a gap.
--   - It does NOT delete or rename the user_custom_nutrients row, and does
--     NOT strip the old key out of any custom_nutrients JSONB. The old
--     custom nutrient keeps showing the user's full historical trend under
--     its original name; only the new, first-class surfaces (the food
--     definition and goals) gain the value. A user who wants the old
--     picker entry gone can still delete it themselves from Settings; doing
--     it here would be destructive and unnecessary for what this migration
--     is for.
--   - It never overwrites an explicit caffeine_mg the user (or a provider
--     import) already set -- only NULL/0 food_variants.caffeine_mg and NULL
--     user_goals.caffeine_mg / goal_presets.caffeine_mg are filled in. That
--     also makes this migration idempotent: run twice, the second run finds
--     nothing left to fill.
--
-- Deliberately data-only: no new column, no RLS change (nothing here is
-- reachable through a new API surface -- it only ever writes a value into a
-- column the owning user could already write to).

-- =============================================================================
-- Step 1: food_variants.caffeine_mg, for each user's own foods
-- =============================================================================
DO $$
DECLARE
  affected integer;
BEGIN
  WITH caffeine_custom_nutrients AS (
    SELECT
      ucn.user_id,
      ucn.name,
      -- mg-per-unit factor for whatever unit the user chose when they created
      -- the nutrient. NULL (and therefore skipped by the join below) for any
      -- unit that isn't a recognised mass unit, rather than guessing at a
      -- conversion.
      CASE lower(btrim(ucn.unit))
        WHEN 'mg' THEN 1
        WHEN 'g' THEN 1000
        WHEN 'gram' THEN 1000
        WHEN 'grams' THEN 1000
        WHEN 'µg' THEN 0.001
        WHEN 'mcg' THEN 0.001
        WHEN 'ug' THEN 0.001
        WHEN 'microgram' THEN 0.001
        WHEN 'micrograms' THEN 0.001
        ELSE NULL
      END AS mg_factor
    FROM public.user_custom_nutrients ucn
    WHERE
      -- Name or alias normalizes (lowercase, non-alphanumeric collapsed to a
      -- single space, trimmed) to one of the spellings
      -- micronutrientCatalog.ts registers for the "caffeine" catalog entry.
      -- Mirrors shared/src/utils/nutrientMatching.ts:normalizeNutrientName.
      btrim(regexp_replace(lower(ucn.name), '[^a-z0-9]+', ' ', 'g')) = 'caffeine'
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(ucn.aliases) AS alias
        WHERE btrim(regexp_replace(lower(alias), '[^a-z0-9]+', ' ', 'g'))
          IN ('caffeine', 'caffeine anhydrous', 'coffee caffeine', 'caffeine 100g')
      )
  )
  UPDATE public.food_variants fv
  SET caffeine_mg = sf_try_numeric(fv.custom_nutrients ->> ccn.name) * ccn.mg_factor
  FROM public.foods f, caffeine_custom_nutrients ccn
  WHERE fv.food_id = f.id
    AND f.user_id = ccn.user_id
    AND ccn.mg_factor IS NOT NULL
    AND fv.custom_nutrients ? ccn.name
    AND sf_try_numeric(fv.custom_nutrients ->> ccn.name) IS NOT NULL
    AND (fv.caffeine_mg IS NULL OR fv.caffeine_mg = 0);

  GET DIAGNOSTICS affected = ROW_COUNT;
  RAISE NOTICE 'migrate_legacy_caffeine_custom_nutrient: backfilled caffeine_mg on % food_variants row(s) from a legacy custom nutrient', affected;
END $$;

-- =============================================================================
-- Step 2: user_goals.caffeine_mg / goal_presets.caffeine_mg
-- =============================================================================
DO $$
DECLARE
  affected_goals integer;
  affected_presets integer;
BEGIN
  WITH caffeine_custom_nutrients AS (
    SELECT
      ucn.user_id,
      ucn.name,
      CASE lower(btrim(ucn.unit))
        WHEN 'mg' THEN 1
        WHEN 'g' THEN 1000
        WHEN 'gram' THEN 1000
        WHEN 'grams' THEN 1000
        WHEN 'µg' THEN 0.001
        WHEN 'mcg' THEN 0.001
        WHEN 'ug' THEN 0.001
        WHEN 'microgram' THEN 0.001
        WHEN 'micrograms' THEN 0.001
        ELSE NULL
      END AS mg_factor
    FROM public.user_custom_nutrients ucn
    WHERE
      btrim(regexp_replace(lower(ucn.name), '[^a-z0-9]+', ' ', 'g')) = 'caffeine'
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(ucn.aliases) AS alias
        WHERE btrim(regexp_replace(lower(alias), '[^a-z0-9]+', ' ', 'g'))
          IN ('caffeine', 'caffeine anhydrous', 'coffee caffeine', 'caffeine 100g')
      )
  )
  UPDATE public.user_goals ug
  SET caffeine_mg = sf_try_numeric(ug.custom_nutrients ->> ccn.name) * ccn.mg_factor
  FROM caffeine_custom_nutrients ccn
  WHERE ug.user_id = ccn.user_id
    AND ccn.mg_factor IS NOT NULL
    AND ug.custom_nutrients ? ccn.name
    AND sf_try_numeric(ug.custom_nutrients ->> ccn.name) IS NOT NULL
    AND ug.caffeine_mg IS NULL;
  GET DIAGNOSTICS affected_goals = ROW_COUNT;

  WITH caffeine_custom_nutrients AS (
    SELECT
      ucn.user_id,
      ucn.name,
      CASE lower(btrim(ucn.unit))
        WHEN 'mg' THEN 1
        WHEN 'g' THEN 1000
        WHEN 'gram' THEN 1000
        WHEN 'grams' THEN 1000
        WHEN 'µg' THEN 0.001
        WHEN 'mcg' THEN 0.001
        WHEN 'ug' THEN 0.001
        WHEN 'microgram' THEN 0.001
        WHEN 'micrograms' THEN 0.001
        ELSE NULL
      END AS mg_factor
    FROM public.user_custom_nutrients ucn
    WHERE
      btrim(regexp_replace(lower(ucn.name), '[^a-z0-9]+', ' ', 'g')) = 'caffeine'
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(ucn.aliases) AS alias
        WHERE btrim(regexp_replace(lower(alias), '[^a-z0-9]+', ' ', 'g'))
          IN ('caffeine', 'caffeine anhydrous', 'coffee caffeine', 'caffeine 100g')
      )
  )
  UPDATE public.goal_presets gp
  SET caffeine_mg = sf_try_numeric(gp.custom_nutrients ->> ccn.name) * ccn.mg_factor
  FROM caffeine_custom_nutrients ccn
  WHERE gp.user_id = ccn.user_id
    AND ccn.mg_factor IS NOT NULL
    AND gp.custom_nutrients ? ccn.name
    AND sf_try_numeric(gp.custom_nutrients ->> ccn.name) IS NOT NULL
    AND gp.caffeine_mg IS NULL;
  GET DIAGNOSTICS affected_presets = ROW_COUNT;

  RAISE NOTICE 'migrate_legacy_caffeine_custom_nutrient: backfilled caffeine_mg on % user_goals row(s) and % goal_presets row(s) from a legacy custom nutrient', affected_goals, affected_presets;
END $$;
