import { json, requireCronSecret } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

let cachedProviderToken: { value: string; expiresAt: number } | null = null;

const JOB_CONCURRENCY = 3;
const LOCAL_APNS_ATTEMPTS = 3;
const APNS_REQUEST_TIMEOUT_MS = 3_500;
const WORKER_BUDGET_MS = 20_000;

type ClaimedJob = {
  job_id: string;
  notification_id: string;
  user_id: string;
  title: string;
  body: string;
  attempt_count: number;
};

type Device = {
  id: string;
  apns_token: string;
  environment: "development" | "production";
};

type Delivery = {
  id: string;
  device_token_id: string;
  status: "pending" | "processing" | "accepted" | "permanent_failure";
  attempt_count: number;
};

type DeliveryResult = "accepted" | "pending" | "permanent_failure";

type APNsResponse = {
  ok: boolean;
  status: number;
  apnsID: string;
  reason?: string;
};

const permanentReasons = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
  "PayloadTooLarge",
  "BadTopic",
  "TopicDisallowed",
]);

function base64URL(value: Uint8Array | string): string {
  const bytes = typeof value === "string"
    ? new TextEncoder().encode(value)
    : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function providerToken(
  keyID: string,
  teamID: string,
  privateKeyPEM: string,
): Promise<string> {
  const now = Math.floor(Date.now() / 1_000);
  if (cachedProviderToken && cachedProviderToken.expiresAt > now + 60) {
    return cachedProviderToken.value;
  }
  const keyBytes = Uint8Array.from(
    atob(
      privateKeyPEM.replace(
        /-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,
        "",
      ),
    ),
    (character) => character.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = base64URL(JSON.stringify({ alg: "ES256", kid: keyID }));
  const claims = base64URL(JSON.stringify({ iss: teamID, iat: now }));
  const input = `${header}.${claims}`;
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(input),
    ),
  );
  const value = `${input}.${base64URL(signature)}`;
  cachedProviderToken = { value, expiresAt: now + 50 * 60 };
  return value;
}

function groupsOf<T>(values: T[], size: number): T[][] {
  const groups: T[][] = [];
  for (let index = 0; index < values.length; index += size) {
    groups.push(values.slice(index, index + size));
  }
  return groups;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object") {
    const value = error as Record<string, unknown>;
    return [value.code, value.message, value.details, value.hint]
      .filter((part) => typeof part === "string" && part.length > 0)
      .join(": ") || JSON.stringify(value);
  }
  return String(error);
}

const wait = (milliseconds: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

function retryDelay(localAttempt: number): number {
  const exponential = 250 * 2 ** localAttempt;
  return exponential + Math.floor(Math.random() * 250);
}

async function requestAPNs(
  device: Device,
  delivery: Delivery,
  job: ClaimedJob,
  jwt: string,
  bundleID: string,
): Promise<APNsResponse> {
  const host = device.environment === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  // APNs can advertise only one stream on a fresh token-authenticated HTTP/2
  // connection. A shared fetch pool raced several first streams and Apple
  // rejected them with REFUSED_STREAM. Use one request per explicit client;
  // separate connections still provide concurrency without sharing streams.
  const client = Deno.createHttpClient({
    http1: false,
    http2: true,
    poolMaxIdlePerHost: 0,
    poolIdleTimeout: 0,
  });
  try {
    const response = await fetch(
      `https://${host}/3/device/${device.apns_token}`,
      {
        method: "POST",
        headers: {
          "authorization": `bearer ${jwt}`,
          "apns-topic": bundleID,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-id": delivery.id,
          "apns-expiration": String(
            Math.floor(Date.now() / 1_000) + 6 * 60 * 60,
          ),
          "content-type": "application/json",
        },
        body: JSON.stringify({
          aps: {
            alert: { title: job.title, body: job.body },
            sound: "default",
            badge: 1,
          },
          notificationId: job.notification_id,
        }),
        signal: AbortSignal.timeout(APNS_REQUEST_TIMEOUT_MS),
        client,
      },
    );
    const apnsID = response.headers.get("apns-id") ?? delivery.id;
    if (response.ok) {
      return { ok: true, status: response.status, apnsID };
    }
    const payload = await response.json().catch(() => ({})) as {
      reason?: string;
    };
    return {
      ok: false,
      status: response.status,
      apnsID,
      reason: payload.reason ?? `HTTP ${response.status}`,
    };
  } finally {
    client.close();
  }
}

async function sendDelivery(
  supabase: ReturnType<typeof adminClient>,
  delivery: Delivery,
  device: Device,
  job: ClaimedJob,
  jwt: string,
  bundleID: string,
  deadline: number,
): Promise<DeliveryResult> {
  let latestError = "APNs isteği tamamlanamadı.";

  for (
    let localAttempt = 0;
    localAttempt < LOCAL_APNS_ATTEMPTS;
    localAttempt++
  ) {
    if (Date.now() + 500 >= deadline) {
      latestError = "Worker zaman bütçesi dolmadan APNs isteği tamamlanamadı.";
      break;
    }

    const attempt = delivery.attempt_count + localAttempt + 1;
    const attemptedAt = new Date().toISOString();
    const started = await supabase.from("notification_deliveries").update({
      status: "processing",
      attempt_count: attempt,
      last_attempt_at: attemptedAt,
      updated_at: attemptedAt,
    }).eq("id", delivery.id);
    if (started.error) throw started.error;

    let response: APNsResponse;
    try {
      response = await requestAPNs(device, delivery, job, jwt, bundleID);
    } catch (error) {
      // REFUSED_STREAM and transport timeouts happen before APNs processes the
      // request. Keep the failure on this delivery instead of rejecting the
      // whole Promise.all batch and leaving every queue lease stranded.
      latestError = `APNs transport: ${errorMessage(error)}`;
      if (localAttempt + 1 < LOCAL_APNS_ATTEMPTS) {
        const delay = retryDelay(localAttempt);
        if (Date.now() + delay + 500 < deadline) {
          await wait(delay);
          continue;
        }
      }
      break;
    }

    if (response.ok) {
      const acceptedAt = new Date().toISOString();
      const accepted = await supabase.from("notification_deliveries").update({
        status: "accepted",
        apns_id: response.apnsID,
        accepted_at: acceptedAt,
        last_status_code: response.status,
        last_error: null,
        updated_at: acceptedAt,
      }).eq("id", delivery.id);
      if (accepted.error) throw accepted.error;
      return "accepted";
    }

    const reason = response.reason ?? `HTTP ${response.status}`;
    const permanent = response.status === 410 || permanentReasons.has(reason);
    if (permanent) {
      const failedAt = new Date().toISOString();
      const failed = await supabase.from("notification_deliveries").update({
        status: "permanent_failure",
        apns_id: response.apnsID,
        last_status_code: response.status,
        last_error: reason,
        updated_at: failedAt,
      }).eq("id", delivery.id);
      if (failed.error) throw failed.error;
      const deactivated = await supabase.from("device_tokens").update({
        is_active: false,
        updated_at: failedAt,
      }).eq("id", device.id);
      if (deactivated.error) throw deactivated.error;
      return "permanent_failure";
    }

    latestError = `APNs HTTP ${response.status}: ${reason}`;
    if (localAttempt + 1 < LOCAL_APNS_ATTEMPTS) {
      const delay = retryDelay(localAttempt);
      if (Date.now() + delay + 500 < deadline) {
        await wait(delay);
        continue;
      }
    }
    break;
  }

  const pendingAt = new Date().toISOString();
  const pending = await supabase.from("notification_deliveries").update({
    status: "pending",
    last_error: latestError,
    updated_at: pendingAt,
  }).eq("id", delivery.id);
  if (pending.error) throw pending.error;
  return "pending";
}

Deno.serve(async (req) => {
  const unauthorized = requireCronSecret(req);
  if (unauthorized) return unauthorized;

  const keyID = Deno.env.get("APNS_KEY_ID");
  const teamID = Deno.env.get("APNS_TEAM_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const bundleID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.pulse15.app";
  if (!keyID || !teamID || !privateKey) {
    return json({
      error: { code: "APNS_NOT_CONFIGURED", message: "APNs secrets eksik." },
    }, 503);
  }

  const supabase = adminClient();
  const workerID = crypto.randomUUID();
  const deadline = Date.now() + WORKER_BUDGET_MS;
  let claimedCount = 0;
  let acceptedCount = 0;
  let retriedCount = 0;
  let failedCount = 0;
  let waitingDeviceCount = 0;

  try {
    const jwt = await providerToken(keyID, teamID, privateKey);
    for (let pass = 0; pass < 4 && Date.now() < deadline; pass++) {
      const claimed = await supabase.rpc("claim_notification_jobs", {
        job_limit: 100,
        worker_name: workerID,
      });
      if (claimed.error) throw claimed.error;
      const jobs = (claimed.data ?? []) as ClaimedJob[];
      if (jobs.length === 0) break;
      claimedCount += jobs.length;

      // Six APNs streams at most for the common two-device account. The old
      // worker opened about twenty and Apple regularly returned REFUSED_STREAM.
      for (const batch of groupsOf(jobs, JOB_CONCURRENCY)) {
        await Promise.all(batch.map(async (job) => {
          const deviceResult = await supabase.from("device_tokens")
            .select("id,apns_token,environment")
            .eq("user_id", job.user_id)
            .eq("is_active", true);
          if (deviceResult.error) throw deviceResult.error;
          const devices = (deviceResult.data ?? []) as Device[];

          if (devices.length === 0) {
            const waiting = await supabase.from("notification_queue").update({
              status: "waiting_device",
              claimed_at: null,
              claimed_by: null,
              last_error:
                "Aktif cihaz tokenı yok; kalıcı gelen kutusu kaydı korunuyor.",
            }).eq("id", job.job_id).eq("claimed_by", workerID);
            if (waiting.error) throw waiting.error;
            waitingDeviceCount++;
            return;
          }

          const seed = await supabase.from("notification_deliveries").upsert(
            devices.map((device) => ({
              notification_id: job.notification_id,
              device_token_id: device.id,
            })),
            {
              onConflict: "notification_id,device_token_id",
              ignoreDuplicates: true,
            },
          );
          if (seed.error) throw seed.error;

          const deliveryResult = await supabase.from("notification_deliveries")
            .select("id,device_token_id,status,attempt_count")
            .eq("notification_id", job.notification_id)
            .in("device_token_id", devices.map((device) => device.id));
          if (deliveryResult.error) throw deliveryResult.error;
          const deliveries = (deliveryResult.data ?? []) as Delivery[];

          const results = await Promise.all(deliveries.map(async (delivery) => {
            if (delivery.status === "accepted") return "accepted" as const;
            if (delivery.status === "permanent_failure") {
              return "permanent_failure" as const;
            }
            const device = devices.find((candidate) =>
              candidate.id === delivery.device_token_id
            );
            if (!device) return "permanent_failure" as const;
            return await sendDelivery(
              supabase,
              delivery,
              device,
              job,
              jwt,
              bundleID,
              deadline,
            );
          }));

          acceptedCount += results.filter((result) =>
            result === "accepted"
          ).length;
          const anyAccepted = results.includes("accepted");
          const hasTransient = results.includes("pending");

          if (anyAccepted) {
            const sent = await supabase.from("notifications").update({
              sent_at: new Date().toISOString(),
            }).eq("id", job.notification_id).is("sent_at", null);
            if (sent.error) throw sent.error;
          }

          if (hasTransient && job.attempt_count < 7) {
            const attempts = job.attempt_count + 1;
            const retrySeconds = Math.min(1_800, 15 * 2 ** attempts);
            const retry = await supabase.from("notification_queue").update({
              status: "pending",
              attempt_count: attempts,
              available_at: new Date(Date.now() + retrySeconds * 1_000)
                .toISOString(),
              claimed_at: null,
              claimed_by: null,
              last_error: "Bir veya daha fazla cihaz için geçici APNs hatası.",
            }).eq("id", job.job_id).eq("claimed_by", workerID);
            if (retry.error) throw retry.error;
            retriedCount++;
          } else {
            const status = anyAccepted ? "completed" : "failed";
            const completed = await supabase.from("notification_queue").update({
              status,
              completed_at: new Date().toISOString(),
              claimed_at: null,
              claimed_by: null,
              last_error: anyAccepted
                ? null
                : "Tüm aktif cihaz teslimatları kalıcı olarak başarısız.",
            }).eq("id", job.job_id).eq("claimed_by", workerID);
            if (completed.error) throw completed.error;
            if (!anyAccepted) failedCount++;
          }
        }));
        if (Date.now() >= deadline) break;
      }
      if (jobs.length < 100) break;
    }

    return json({
      data: {
        workerID,
        claimed: claimedCount,
        accepted: acceptedCount,
        retried: retriedCount,
        failed: failedCount,
        waitingDevice: waitingDeviceCount,
      },
    });
  } catch (error) {
    return json({
      error: {
        code: "DISPATCH_FAILED",
        message: errorMessage(error),
        workerID,
      },
    }, 500);
  }
});
