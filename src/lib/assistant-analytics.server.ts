// Server-only: gyvi portfelio skaičiai AI pagalbininkei. Skaitoma su prisijungusio
// vadybininko klientu, todėl RLS taikoma kaip visur kitur. Jokių asmens kodų.
import type { AssistantLang } from "./assistant-knowledge";
import { currentPeriod, daysBetween, todayIso } from "./rental";

type Db = { from: (table: string) => any };

const num = (v: unknown) => (v === null || v === undefined ? 0 : Number(v));
const money = (v: number) => `${Math.round(v).toLocaleString("lt-LT")} €`;
const pct = (v: number) => `${Math.round(v)} %`;

function addDays(iso: string, days: number) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export async function buildBusinessAnalytics(db: Db, lang: AssistantLang): Promise<string> {
  const en = lang === "en";
  const today = todayIso();
  const period = currentPeriod();
  const monthStart = period;
  const yearStart = `${today.slice(0, 4)}-01-01`;

  const [
    unitsRes,
    leasesRes,
    metersRes,
    readingsRes,
    chargesMonthRes,
    chargesAllRes,
    paymentsAllRes,
    paymentsMonthRes,
    issuesRes,
    expensesYearRes,
    inquiriesRes,
  ] = await Promise.all([
    db.from("units").select("id, status, monthly_rent, is_active, is_listed, updated_at"),
    db.from("leases").select("id, status, end_date, monthly_rent, renewal"),
    db.from("meters").select("id").eq("is_active", true),
    db.from("meter_readings").select("id, status").eq("period", period),
    db.from("charges").select("amount").eq("period", period),
    db.from("charges").select("amount").lte("period", period),
    db.from("payments").select("amount"),
    db.from("payments").select("amount").gte("paid_at", monthStart),
    db.from("issues").select("id, status, priority, created_at"),
    db.from("expenses").select("amount").gte("expense_date", yearStart),
    db.from("rental_inquiries").select("id, status, created_at"),
  ]);

  const units = (unitsRes.data ?? []) as Array<Record<string, unknown>>;
  const leases = (leasesRes.data ?? []) as Array<Record<string, unknown>>;
  const readings = (readingsRes.data ?? []) as Array<Record<string, unknown>>;
  const issues = (issuesRes.data ?? []) as Array<Record<string, unknown>>;
  const inquiries = (inquiriesRes.data ?? []) as Array<Record<string, unknown>>;

  const activeUnits = units.filter((u) => u["is_active"]);
  const byStatus = activeUnits.reduce<Record<string, number>>((acc, u) => {
    const s = String(u["status"]);
    acc[s] = (acc[s] ?? 0) + 1;
    return acc;
  }, {});
  const occupied = byStatus["occupied"] ?? 0;
  const vacant = byStatus["vacant"] ?? 0;
  const occupancy = activeUnits.length > 0 ? (occupied / activeUnits.length) * 100 : 0;
  const listed = activeUnits.filter((u) => u["is_listed"]).length;

  const holding = leases.filter((l) => l["status"] === "active" || l["status"] === "ending");
  const rentRoll = holding.reduce((s, l) => s + num(l["monthly_rent"]), 0);

  const expiring = (days: number) =>
    holding.filter((l) => {
      const end = l["end_date"] ? String(l["end_date"]).slice(0, 10) : null;
      return end !== null && end >= today && end <= addDays(today, days);
    }).length;
  const notRenewing = holding.filter((l) => l["renewal"] === false && l["end_date"]).length;

  const metersActive = (metersRes.data ?? []).length as number;
  const approved = readings.filter((r) => r["status"] === "approved").length;
  const submitted = readings.filter((r) => r["status"] === "submitted").length;
  const readingsPct = metersActive > 0 ? ((approved + submitted) / metersActive) * 100 : 0;

  const chargedMonth = ((chargesMonthRes.data ?? []) as Array<Record<string, unknown>>).reduce(
    (s, r) => s + num(r["amount"]),
    0,
  );
  const chargedAll = ((chargesAllRes.data ?? []) as Array<Record<string, unknown>>).reduce(
    (s, r) => s + num(r["amount"]),
    0,
  );
  const paidAll = ((paymentsAllRes.data ?? []) as Array<Record<string, unknown>>).reduce(
    (s, r) => s + num(r["amount"]),
    0,
  );
  const paidMonth = ((paymentsMonthRes.data ?? []) as Array<Record<string, unknown>>).reduce(
    (s, r) => s + num(r["amount"]),
    0,
  );
  const outstanding = Math.max(0, chargedAll - paidAll);
  const debtRatio = chargedMonth > 0 ? (outstanding / chargedMonth) * 100 : 0;

  const openIssues = issues.filter(
    (i) => !["resolved", "rejected"].includes(String(i["status"])),
  );
  const issuesByPriority = openIssues.reduce<Record<string, number>>((acc, i) => {
    const p = String(i["priority"]);
    acc[p] = (acc[p] ?? 0) + 1;
    return acc;
  }, {});
  const oldestIssueDays = openIssues.reduce((max, i) => {
    const created = i["created_at"] ? String(i["created_at"]).slice(0, 10) : today;
    return Math.max(max, daysBetween(created, today));
  }, 0);

  const expensesYear = ((expensesYearRes.data ?? []) as Array<Record<string, unknown>>).reduce(
    (s, r) => s + num(r["amount"]),
    0,
  );

  const newInquiries = inquiries.filter((i) => i["status"] === "new").length;
  const inquiries30 = inquiries.filter((i) => {
    const created = i["created_at"] ? String(i["created_at"]).slice(0, 10) : "";
    return created >= addDays(today, -30);
  }).length;

  const L = (ltText: string, enText: string) => (en ? enText : ltText);

  return [
    `${L("Data", "Date")}: ${today}. ${L("Rodmenų laikotarpis", "Reading period")}: ${period.slice(0, 7)}.`,
    ``,
    L("## Portfelis ir užimtumas", "## Portfolio and occupancy"),
    `- ${L("Aktyvūs vienetai", "Active units")}: ${activeUnits.length} (${L("iš viso", "total")}: ${units.length})`,
    `- ${L("Užimti", "Occupied")}: ${occupied}; ${L("laisvi", "vacant")}: ${vacant}; ${L("rezervuoti", "reserved")}: ${byStatus["reserved"] ?? 0}; ${L("remontas", "renovation")}: ${byStatus["renovation"] ?? 0}`,
    `- ${L("Užimtumas", "Occupancy")}: ${pct(occupancy)}`,
    `- ${L("Skelbiama viešoje svetainėje", "Listed on the public site")}: ${listed}`,
    ``,
    L("## Sutartys", "## Leases"),
    `- ${L("Galiojančios (aktyvios + baigiasi)", "Holding (active + ending)")}: ${holding.length}`,
    `- ${L("Mėnesio nuomos suma (rent roll)", "Monthly rent roll")}: ${money(rentRoll)}`,
    `- ${L("Baigiasi per 30 d.", "Expiring in 30 days")}: ${expiring(30)}; 60 ${L("d.", "days")}: ${expiring(60)}; 90 ${L("d.", "days")}: ${expiring(90)}`,
    `- ${L("Pažymėta „nebus pratęsta“", "Marked as not renewing")}: ${notRenewing}`,
    ``,
    L("## Skaitiklių rodmenys (šis laikotarpis)", "## Meter readings (current period)"),
    `- ${L("Aktyvūs skaitikliai", "Active meters")}: ${metersActive}`,
    `- ${L("Pateikta (laukia patvirtinimo)", "Submitted (awaiting approval)")}: ${submitted}; ${L("patvirtinta", "approved")}: ${approved}`,
    `- ${L("Pateikimo lygis", "Submission rate")}: ${pct(readingsPct)}`,
    ``,
    L("## Pinigai", "## Money"),
    `- ${L("Šio mėnesio priskaitymai", "Charges this month")}: ${money(chargedMonth)}`,
    `- ${L("Šio mėnesio gauti mokėjimai", "Payments received this month")}: ${money(paidMonth)}`,
    `- ${L("Bendra neapmokėta suma (skola)", "Total outstanding (debt)")}: ${money(outstanding)}`,
    `- ${L("Skolos dalis nuo mėnesio priskaitymų", "Debt vs monthly charges")}: ${chargedMonth > 0 ? pct(debtRatio) : L("(nėra priskaitymų)", "(no charges)")}`,
    `- ${L("Šių metų išlaidos", "Expenses this year")}: ${money(expensesYear)}`,
    ``,
    L("## Gedimai", "## Faults"),
    `- ${L("Atviri", "Open")}: ${openIssues.length} (${Object.entries(issuesByPriority)
      .map(([p, c]) => `${p}: ${c}`)
      .join(", ") || "—"})`,
    `- ${L("Seniausias atviras gedimas", "Oldest open fault")}: ${oldestIssueDays} ${L("d.", "days")}`,
    ``,
    L("## Užklausos iš viešos svetainės", "## Public-site inquiries"),
    `- ${L("Naujos (neapdorotos)", "New (unhandled)")}: ${newInquiries}`,
    `- ${L("Per pastarąsias 30 d.", "In the last 30 days")}: ${inquiries30}`,
  ].join("\n");
}
