-- Applied through Supabase migration fix_inventory_decimal_validation.
-- Preserve permissions and existing function logic; accept decimal quantities/costs.
DO $fix$
DECLARE r record; src text;
BEGIN
  FOR r IN SELECT oid FROM pg_proc
    WHERE pronamespace='olimpo_private'::regnamespace
      AND proname IN ('inv_crear_compra','inv_recibir_compra')
  LOOP
    src := pg_get_functiondef(r.oid);
    src := replace(src, chr(92)||chr(92)||'.', '[.]');
    EXECUTE src;
  END LOOP;
END $fix$;
