import { createClient } from "npm:@supabase/supabase-js@2";

export function adminClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const keysJSON = Deno.env.get("SUPABASE_SECRET_KEYS");
  const fallback = Deno.env.get("SUPABASE_SECRET_KEY");
  const key = keysJSON ? JSON.parse(keysJSON).default : fallback;
  if (!url || !key) throw new Error("Supabase admin yapılandırması eksik.");
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
