import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

type Body = { symbol?: string; direction?: string };

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
    const direction = String(body.direction ?? "").trim().toLowerCase();
    if (
      !/^[A-Z0-9]{2,20}USDT$/.test(symbol) ||
      !["up", "down"].includes(direction)
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
    if (insert.error) throw insert.error;

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
