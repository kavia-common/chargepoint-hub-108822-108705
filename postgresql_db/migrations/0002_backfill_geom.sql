-- Backfill geometry point for existing charger_locations where possible
DO $$
BEGIN
  BEGIN
    UPDATE public.charger_locations
    SET geom = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)
    WHERE geom IS NULL;
  EXCEPTION WHEN undefined_function THEN
    -- PostGIS not installed; skip
    NULL;
  END;
END
$$;
