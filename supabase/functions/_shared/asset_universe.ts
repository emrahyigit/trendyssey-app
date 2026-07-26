const EXCLUDED_BASE_ASSETS = new Set([
  "AED", "ARS", "AUD", "BIDR", "BRL", "COP", "CZK", "EUR", "GBP", "GHS",
  "HKD", "HUF", "IDRT", "INR", "JPY", "KES", "KZT", "MXN", "NGN", "NZD",
  "PEN", "PHP", "PLN", "RON", "RUB", "SAR", "TRY", "UAH", "UGX", "VND",
  "ZAR", "AEUR", "BUSD", "CRVUSD", "DAI", "EURI", "EURS", "EURC", "FDUSD",
  "FRAX", "GHO", "GUSD", "LUSD", "PYUSD", "RLUSD", "SUSD", "TUSD", "USD1",
  "USDC", "USDP", "USDS", "UST", "USTC", "XUSD", "DGX", "PAXG", "PMGT", "XAUT",
]);

export function includesCryptoBaseAsset(value: string): boolean {
  const asset = value.toUpperCase();
  if (asset.includes("USD")) return false;
  if (EXCLUDED_BASE_ASSETS.has(asset)) return false;
  return !["UP", "DOWN", "BULL", "BEAR"].some((suffix) =>
    asset.length >= 5 && asset.length > suffix.length && asset.endsWith(suffix)
  );
}
