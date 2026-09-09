export function getResendApiKey(): string | undefined {
  return process.env["RESEND_API_KEY"] || process.env["RESEND_API_KEY_1"] || undefined;
}
