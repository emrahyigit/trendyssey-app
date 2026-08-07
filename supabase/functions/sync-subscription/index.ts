import { Buffer } from "node:buffer";
import {
  Environment,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@3.1.0";
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

const bundleID = "com.pulse15.app";
const productID = "com.pulse15.app.pro.monthly";
const certificateURLs = [
  "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer",
];

type Transaction = {
  originalTransactionId?: string;
  transactionId?: string;
  productId?: string;
  appAccountToken?: string;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
  environment?: string;
};

let certificatePromise: Promise<Buffer[]> | undefined;

function rootCertificates(): Promise<Buffer[]> {
  certificatePromise ??= Promise.all(certificateURLs.map(async (url) => {
    const response = await fetch(url, { signal: AbortSignal.timeout(8_000) });
    if (!response.ok) {
      throw new Error(`Apple root certificate ${response.status}`);
    }
    return Buffer.from(await response.arrayBuffer());
  }));
  return certificatePromise;
}

function environmentHint(jws: string): Environment {
  try {
    const payload = jws.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const decoded = JSON.parse(
      new TextDecoder().decode(
        Uint8Array.from(atob(payload), (value) => value.charCodeAt(0)),
      ),
    );
    return decoded.environment === Environment.PRODUCTION
      ? Environment.PRODUCTION
      : Environment.SANDBOX;
  } catch {
    return Environment.SANDBOX;
  }
}

async function verifier(environment: Environment): Promise<SignedDataVerifier> {
  const appAppleID = Deno.env.get("APPLE_APP_ID");
  if (environment === Environment.PRODUCTION && !appAppleID) {
    throw new Error("APPLE_APP_ID production için gerekli.");
  }
  return new SignedDataVerifier(
    await rootCertificates(),
    false,
    environment,
    bundleID,
    environment === Environment.PRODUCTION ? Number(appAppleID) : undefined,
  );
}

/**
 * Apple has several lifecycle reasons, but product access is binary. Grace
 * period remains active until its expiry; expiry, billing retry without grace,
 * and revocation do not grant access.
 */
function isActiveFor(
  transaction: Transaction,
  notificationStatus?: number,
): boolean {
  if (transaction.revocationDate || notificationStatus === 5) return false;
  if (notificationStatus === 2 || notificationStatus === 3) return false;
  return (transaction.expiresDate ?? 0) > Date.now();
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({
      error: { code: "METHOD_NOT_ALLOWED", message: "POST gerekli." },
    }, 405);
  }
  const supabase = adminClient();

  try {
    const body = await req.json() as {
      signedTransaction?: string;
      signedPayload?: string;
    };
    let transaction: Transaction;
    let notificationStatus: number | undefined;
    let authenticatedUserID: string | undefined;

    if (body.signedTransaction) {
      const accessToken = (req.headers.get("authorization") ?? "").replace(
        /^Bearer\s+/i,
        "",
      );
      const auth = await supabase.auth.getUser(accessToken);
      if (!accessToken || auth.error || !auth.data.user) {
        return json({
          error: {
            code: "UNAUTHORIZED",
            message: "Kullanıcı oturumu gerekli.",
          },
        }, 401);
      }
      authenticatedUserID = auth.data.user.id;
      const appleVerifier = await verifier(
        environmentHint(body.signedTransaction),
      );
      transaction = await appleVerifier.verifyAndDecodeTransaction(
        body.signedTransaction,
      ) as Transaction;
    } else if (body.signedPayload) {
      const appleVerifier = await verifier(environmentHint(body.signedPayload));
      const notification = await appleVerifier.verifyAndDecodeNotification(
        body.signedPayload,
      );
      const signedTransaction = notification.data?.signedTransactionInfo;
      if (!signedTransaction) {
        return json({ data: { accepted: true, ignored: "no_transaction" } });
      }
      transaction = await appleVerifier.verifyAndDecodeTransaction(
        signedTransaction,
      ) as Transaction;
      notificationStatus = typeof notification.data?.status === "number"
        ? notification.data.status
        : undefined;
    } else {
      return json({
        error: {
          code: "INVALID_BODY",
          message: "İmzalı Apple verisi gerekli.",
        },
      }, 400);
    }

    if (
      transaction.productId !== productID ||
      !transaction.originalTransactionId ||
      !transaction.transactionId ||
      !transaction.expiresDate
    ) {
      return json({
        error: {
          code: "INVALID_TRANSACTION",
          message: "Abonelik işlemi Trendyssey Pro ile eşleşmiyor.",
        },
      }, 400);
    }

    let userID = transaction.appAccountToken;
    if (!userID) {
      const existing = await supabase.from("subscription_entitlements")
        .select("user_id")
        .eq("original_transaction_id", transaction.originalTransactionId)
        .maybeSingle();
      if (existing.error) throw existing.error;
      userID = existing.data?.user_id;
    }
    if (!userID || (authenticatedUserID && authenticatedUserID !== userID)) {
      return json({
        error: {
          code: "ACCOUNT_MISMATCH",
          message: "Abonelik kullanıcı hesabıyla eşleşmiyor.",
        },
      }, 403);
    }

    const isActive = isActiveFor(transaction, notificationStatus);
    const expiresAt = new Date(transaction.expiresDate).toISOString();
    const entitlement = await supabase.from("subscription_entitlements").upsert(
      {
        user_id: userID,
        product_id: productID,
        original_transaction_id: transaction.originalTransactionId,
        latest_transaction_id: transaction.transactionId,
        app_account_token: userID,
        environment: transaction.environment ?? Environment.SANDBOX,
        is_active: isActive,
        purchased_at: transaction.purchaseDate
          ? new Date(transaction.purchaseDate).toISOString()
          : null,
        expires_at: expiresAt,
        last_verified_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      },
      { onConflict: "user_id" },
    );
    if (entitlement.error) throw entitlement.error;

    if (!isActive) {
      const profile = await supabase.from("profiles").update({
        notifications_enabled: false,
        updated_at: new Date().toISOString(),
      }).eq("id", userID);
      if (profile.error) throw profile.error;
    }

    return json({ data: { active: isActive, expiresAt } });
  } catch (error) {
    return json({
      error: {
        code: "SUBSCRIPTION_SYNC_FAILED",
        message: error instanceof Error ? error.message : String(error),
      },
    }, 400);
  }
});
