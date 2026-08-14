// The single entry point for saving a directional call, from either surface:
// the daily game's up/down picker or the coin chat's Holds/Fails bar. Both
// write the same daily_predictions row, so one leaderboard scores every call.
// A chat vote additionally records its journey in signal_predictions, which is
// what the per-user accuracy badge reads.
//
// Every breakout signal is direction 'up', so "holds" means the coin rises and
// "fails" means it does not.
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

type Body = {
  symbol?: string;
  direction?: string;
  journeyId?: string;
  prediction?: string;
  timeframe?: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({
      error: { code: "METHOD_NOT_ALLOWED", message: "POST gerekli." },
    }, 405);
  }

  const token = (req.headers.get("authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  );
  if (!token) {
    return json({
      error: { code: "UNAUTHORIZED", message: "Kullanıcı oturumu gerekli." },
    }, 401);
  }

  const supabase = adminClient();
  const { data: auth, error: authError } = await supabase.auth.getUser(token);
  if (authError || !auth.user || auth.user.is_anonymous) {
    return json({
      error: {
        code: "APPLE_ACCOUNT_REQUIRED",
        message: "Apple hesabı gerekli.",
      },
    }, 403);
  }

  try {
    const body = await req.json() as Body;
    const symbol = String(body.symbol ?? "").trim().toUpperCase();
    const vote = String(body.prediction ?? "").trim().toLowerCase();
    // A chat vote names the outcome; the daily picker names the direction.
    const direction = vote === "holds"
      ? "up"
      : vote === "fails"
      ? "down"
      : String(body.direction ?? "").trim().toLowerCase();
    const journeyID = String(body.journeyId ?? "").trim().toLowerCase();
    const timeframe = String(body.timeframe ?? "15m").trim();
    if (
      !/^[A-Z0-9]{2,20}USDT$/.test(symbol) ||
      !["up", "down"].includes(direction) ||
      (journeyID !== "" && !UUID_PATTERN.test(journeyID))
    ) {
      return json({
        error: { code: "INVALID_PREDICTION", message: "Tahmin geçersiz." },
      }, 400);
    }

    const symbolResult = await supabase.from("symbols")
      .select("id,symbol")
      .eq("symbol", symbol)
      .eq("is_enabled", true)
      .maybeSingle();
    if (symbolResult.error) throw symbolResult.error;
    if (!symbolResult.data) {
      return json({
        error: { code: "SYMBOL_NOT_FOUND", message: "Coin bulunamadı." },
      }, 404);
    }

    const tickerResponse = await fetch(
      `https://data-api.binance.vision/api/v3/ticker/price?symbol=${
        encodeURIComponent(symbol)
      }`,
      { signal: AbortSignal.timeout(8_000) },
    );
    if (!tickerResponse.ok) {
      throw new Error(`Ticker request failed (${tickerResponse.status}).`);
    }
    const ticker = await tickerResponse.json() as { price?: string };
    const entryPrice = Number(ticker.price);
    if (!Number.isFinite(entryPrice) || entryPrice <= 0) {
      throw new Error("Ticker price is invalid.");
    }

    const insert = await supabase.from("daily_predictions").insert({
      user_id: auth.user.id,
      symbol_id: symbolResult.data.id,
      direction,
      entry_price: entryPrice,
    }).select("id,prediction_day,predicted_at,evaluation_ends_at").single();
    if (insert.error?.code === "23505") {
      return json({
        error: {
          code: "ALREADY_PREDICTED_TODAY",
          message: "Bu coin için bugünkü tahminin zaten kaydedildi.",
        },
      }, 409);
    }
    // daily_predictions.user_id points at profiles, which sync-user creates.
    // Say so plainly instead of surfacing a foreign-key error as a 500.
    if (insert.error?.code === "23503") {
      return json({
        error: {
          code: "PROFILE_REQUIRED",
          message: "Profil oluşturulmadan tahmin kaydedilemez.",
        },
      }, 409);
    }
    if (insert.error) throw insert.error;

    // The journey link only feeds the accuracy badge. It must never fail the
    // call that already counts for the leaderboard.
    if (journeyID && vote) {
      const journeyInsert = await supabase.from("signal_predictions").insert({
        user_id: auth.user.id,
        symbol,
        journey_id: journeyID,
        timeframe,
        prediction: vote,
      });
      if (journeyInsert.error && journeyInsert.error.code !== "23505") {
        console.error("journey_prediction_link_failed", journeyInsert.error);
      }
    }

    return json({
      data: {
        ...insert.data,
        symbol,
        direction,
        entryPrice,
      },
    }, 201);
  } catch (error) {
    console.error("daily_prediction_failed", error);
    return json({
      error: {
        code: "PREDICTION_FAILED",
        message: "Tahmin şu anda kaydedilemedi.",
      },
    }, 500);
  }
});
