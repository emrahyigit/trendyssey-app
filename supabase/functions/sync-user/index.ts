import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

const allowedTimeframes = new Set(["15m", "30m", "1h", "2h", "4h", "6h", "1d"]);
const allowedMarketStates = new Set([
  "neutral",
  "selling_dominant",
  "seller_impact_fading",
  "buy_side_absorption",
  "bounce_attempt",
  "bullish_confirmation",
  "bullish_momentum",
  "breakdown_risk",
]);

type SyncBody = {
  preferences?: {
    notificationsEnabled: boolean;
    preferredTimeframe: string;
    analysisModelSlug: string;
    minimumScore?: number;
    minimumRegimeScore?: number;
    minimumSignalStrength?: number;
    aplusEntriesOnly?: boolean;
    minimumSuccessRate?: number;
    minimumReadinessScore?: number;
    minimumBreakoutQualityScore?: number;
    minimumConfirmationScore?: number;
    maximumRisk: number;
    minimumVolumeRatio: number;
    minimumQuoteVolume24h?: number;
    minimumStateScore?: number;
    alertScope: "favorites" | "all";
    preferredLanguage: "en" | "tr";
    marketStates?: string[];
  };
  watchlist?: string[];
  device?: {
    token: string;
    identifier: string;
    environment: "development" | "production";
  };
};

const validScore = (value: number) =>
  Number.isInteger(value) && value >= 0 && value <= 100;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({
      error: { code: "METHOD_NOT_ALLOWED", message: "POST gerekli." },
    }, 405);
  }
  const authorization = req.headers.get("authorization") ?? "";
  const accessToken = authorization.replace(/^Bearer\s+/i, "");
  if (!accessToken) {
    return json({
      error: { code: "UNAUTHORIZED", message: "Kullanıcı oturumu gerekli." },
    }, 401);
  }

  const supabase = adminClient();
  const { data: auth, error: authError } = await supabase.auth.getUser(
    accessToken,
  );
  if (authError || !auth.user) {
    return json({
      error: { code: "UNAUTHORIZED", message: "Geçersiz kullanıcı oturumu." },
    }, 401);
  }

  try {
    const body = await req.json() as SyncBody;
    const userID = auth.user.id;
    const entitlement = await supabase.from("subscription_entitlements")
      .select("is_active,expires_at").eq("user_id", userID).maybeSingle();
    if (entitlement.error) throw entitlement.error;
    const isPro = !!entitlement.data && entitlement.data.is_active === true &&
      new Date(entitlement.data.expires_at).getTime() > Date.now();
    const rawDisplayName =
      typeof auth.user.user_metadata?.full_name === "string"
        ? auth.user.user_metadata.full_name.trim() || "Anonymous"
        : (auth.user.is_anonymous
          ? "Anonymous"
          : auth.user.email ?? "Apple User");
    const displayName = rawDisplayName.slice(0, 24);

    if (body.preferences) {
      const p = body.preferences;
      const minimumRegime = p.minimumRegimeScore ?? 0;
      const minimumReadiness = p.minimumReadinessScore ?? 0;
      const minimumQuality = p.minimumBreakoutQualityScore ??
        p.minimumScore ?? 0;
      const minimumConfirmation = p.minimumConfirmationScore ?? 0;
      const minimumQuoteVolume24h = p.minimumQuoteVolume24h ?? 0;
      const minimumStateScore = p.minimumStateScore ?? 0;
      if (
        !allowedTimeframes.has(p.preferredTimeframe) ||
        !validScore(minimumRegime) ||
        !validScore(minimumReadiness) ||
        !validScore(minimumQuality) ||
        !validScore(minimumConfirmation) ||
        !validScore(minimumStateScore) ||
        !Number.isInteger(p.maximumRisk) || p.maximumRisk < 0 ||
        p.maximumRisk > 100 ||
        !Number.isFinite(p.minimumVolumeRatio) || p.minimumVolumeRatio < 0 ||
        p.minimumVolumeRatio > 20 ||
        !Number.isFinite(minimumQuoteVolume24h) ||
        minimumQuoteVolume24h < 0 ||
        minimumQuoteVolume24h > 1_000_000_000_000 ||
        !["favorites", "all"].includes(p.alertScope) ||
        !["en", "tr"].includes(p.preferredLanguage)
      ) {
        return json({
          error: {
            code: "INVALID_PREFERENCES",
            message: "Bildirim tercihleri geçersiz.",
          },
        }, 400);
      }
      const { data: requestedModel, error: modelError } = await supabase.from(
        "analysis_models",
      )
        .select("id,slug,required_tier,is_default").eq(
          "slug",
          p.analysisModelSlug,
        )
        .eq("is_active", true).maybeSingle();
      if (modelError) throw modelError;
      if (!requestedModel) {
        return json({
          error: {
            code: "INVALID_ANALYSIS_MODEL",
            message: "Analiz modeli bulunamadı.",
          },
        }, 400);
      }
      if (!isPro && !requestedModel.is_default) {
        return json({
          error: {
            code: "PRO_REQUIRED",
            message: "Analiz modeli seçimi Trendyssey Pro gerektirir.",
          },
        }, 403);
      }
      const { error } = await supabase.from("profiles").upsert({
        id: userID,
        display_name: displayName,
        email: auth.user.email ?? null,
        avatar_key: [
            "orbit",
            "nova",
            "flare",
            "wave",
            "prism",
            "void",
            "builder",
            "medic",
            "reporter",
            "operator",
            "chef",
            "pharmacist",
          ].includes(auth.user.user_metadata?.avatar_key)
          ? auth.user.user_metadata.avatar_key
          : "orbit",
        notifications_enabled: p.notificationsEnabled && isPro,
        preferred_timeframe: p.preferredTimeframe,
        preferred_analysis_model_id: requestedModel.id,
        minimum_breakout_score: minimumQuality,
        minimum_regime_score: minimumRegime,
        minimum_signal_strength: Math.max(
          0,
          Math.min(100, Math.round(p.minimumSignalStrength ?? 0)),
        ),
        aplus_entries_only: false,
        minimum_success_rate: Math.max(
          0,
          Math.min(100, Math.round(p.minimumSuccessRate ?? 0)),
        ),
        minimum_readiness_score: minimumReadiness,
        minimum_breakout_quality_score: minimumQuality,
        minimum_confirmation_score: minimumConfirmation,
        maximum_false_breakout_risk: p.maximumRisk,
        minimum_volume_ratio: p.minimumVolumeRatio,
        minimum_quote_volume_24h: minimumQuoteVolume24h,
        minimum_state_score: minimumStateScore,
        notification_market_states: [
          ...new Set(
            (p.marketStates ?? [...allowedMarketStates]).filter((state) =>
              allowedMarketStates.has(state)
            ),
          ),
        ],
        notification_scope: p.alertScope,
        preferred_language: p.preferredLanguage,
        updated_at: new Date().toISOString(),
      });
      if (error) throw error;
    }

    if (body.watchlist) {
      const requestedSymbols = [
        ...new Set(body.watchlist.map((symbol) => symbol.toUpperCase())),
      ].slice(0, 100);
      let { data: watchlist, error: watchlistError } = await supabase.from(
        "watchlists",
      )
        .select("id").eq("user_id", userID).order("created_at").limit(1)
        .maybeSingle();
      if (watchlistError) throw watchlistError;
      if (!watchlist) {
        const created = await supabase.from("watchlists").insert({
          user_id: userID,
          name: "Takip Listem",
        }).select("id").single();
        if (created.error) throw created.error;
        watchlist = created.data;
      }
      const { error: deleteError } = await supabase.from("watchlist_items")
        .delete().eq("watchlist_id", watchlist.id);
      if (deleteError) throw deleteError;
      if (requestedSymbols.length > 0) {
        const { data: symbols, error: symbolError } = await supabase.from(
          "symbols",
        ).select("id").in("symbol", requestedSymbols).eq("is_enabled", true);
        if (symbolError) throw symbolError;
        if (symbols?.length) {
          const { error: insertError } = await supabase.from("watchlist_items")
            .insert(
              symbols.map((symbol) => ({
                watchlist_id: watchlist.id,
                symbol_id: symbol.id,
              })),
            );
          if (insertError) throw insertError;
        }
      }
    }

    if (body.device) {
      const device = body.device;
      if (
        !/^[0-9a-f]{32,}$/i.test(device.token) || !device.identifier ||
        !["development", "production"].includes(device.environment)
      ) {
        return json({
          error: {
            code: "INVALID_DEVICE",
            message: "APNs cihaz bilgisi geçersiz.",
          },
        }, 400);
      }
      const { error } = await supabase.from("device_tokens").upsert({
        user_id: userID,
        apns_token: device.token.toLowerCase(),
        device_identifier: device.identifier,
        environment: device.environment,
        is_active: true,
        last_seen_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }, { onConflict: "apns_token" });
      if (error) throw error;
      const requeue = await supabase.rpc(
        "requeue_recent_notifications_for_user",
        { target_user_id: userID },
      );
      if (requeue.error) throw requeue.error;
    }

    return json({ data: { synced: true, userId: userID, isPro } });
  } catch (error) {
    return json({
      error: {
        code: "SYNC_FAILED",
        message: error instanceof Error ? error.message : String(error),
      },
    }, 500);
  }
});
