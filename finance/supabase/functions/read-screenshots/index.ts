// Reads transaction screenshots for the web app. The app sends the screenshots and its prompt;
// this function checks the caller belongs to a household, asks Claude, and returns the text of
// the answer (a JSON array the app parses).
//
// Needs the secret ANTHROPIC_API_KEY (Supabase dashboard → Edge Functions → Secrets).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MAX_IMAGES = 5;
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif"];

const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const auth = req.headers.get("Authorization") ?? "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: household, error: hhError } = await sb.rpc("app_household");
  if (hhError || !household) return reply(403, { error: "not_a_member" });

  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return reply(503, { error: "no_api_key" });

  let body: { prompt?: string; images?: { type: string; data: string }[] };
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "bad_request" });
  }
  const images = Array.isArray(body.images) ? body.images.slice(0, MAX_IMAGES) : [];
  if (!body.prompt || !images.length) return reply(400, { error: "bad_request" });
  for (const im of images) {
    if (!TYPES.includes(im.type) || typeof im.data !== "string" || im.data.length * 0.75 > MAX_IMAGE_BYTES) {
      return reply(400, { error: "image_rejected" });
    }
  }

  const client = new Anthropic({ apiKey: key });
  try {
    const params = {
      model: "claude-opus-5",
      max_tokens: 16000,
      thinking: { type: "adaptive" },
      output_config: { effort: "low" },
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      messages: [{
        role: "user",
        content: [
          ...images.map((im) => ({
            type: "image",
            source: { type: "base64", media_type: im.type, data: im.data },
          })),
          { type: "text", text: body.prompt },
        ],
      }],
    };
    // deno-lint-ignore no-explicit-any
    const msg = await client.beta.messages.create(params as any);
    if (msg.stop_reason === "refusal") return reply(422, { error: "refused" });
    const text = msg.content.filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("");
    return reply(200, { text, truncated: msg.stop_reason === "max_tokens" });
  } catch (e) {
    if (e instanceof Anthropic.RateLimitError) return reply(429, { error: "rate_limited" });
    if (e instanceof Anthropic.AuthenticationError) return reply(503, { error: "bad_api_key" });
    if (e instanceof Anthropic.BadRequestError) return reply(400, { error: "image_rejected", detail: e.message });
    console.error(e);
    return reply(502, { error: "failed" });
  }
});
