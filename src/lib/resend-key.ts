// Prefer the newest linked connection key if multiple exist.
export function getResendApiKey(): string | undefined {
  return process.env["RESEND_API_KEY_1"] || process.env["RESEND_API_KEY"] || undefined;
}
