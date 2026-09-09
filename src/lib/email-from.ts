import { PLATFORM_NAME } from "@/lib/brand";

/**
 * Grąžina siuntėjo adresą su rodomu vardu, pvz. `Deerva <nuoma@kr.revoo.site>`.
 * Jei RESEND_FROM_EMAIL jau turi vardą (`Vardas <adresas>`), jis paliekamas.
 */
export function resolveFromAddress(): string {
  const raw = (process.env["RESEND_FROM_EMAIL"] ?? "nuoma@kr.revoo.site").trim();
  if (raw.includes("<")) return raw;
  return `${PLATFORM_NAME} <${raw}>`;
}
