/**
 * The bindings the platform injects at deploy.
 *
 * These are NOT declared by this repo's `wrangler.jsonc` in production — the
 * deploy generates an authoritative config from `app.manifest.json` plus the app
 * row and ignores the committed one. Keep this interface in step with the
 * manifest: turning on `db` / `r2` / `kv` there adds `DB` / `STORAGE` / `KV`
 * here.
 */
export interface Env {
  /** Static client files (dist/client), served asset-first. */
  ASSETS: Fetcher;
  /** One Durable Object instance per room — `app.manifest.json` → durableObject. */
  ROOMS: DurableObjectNamespace;
  /** "dev" | "prod" — the CODE's environment label. Storage is shared, not split. */
  HF_ENV?: string;
  /** This app's subdomain label. */
  APP_SLUG?: string;
}
