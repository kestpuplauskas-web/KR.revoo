/**
 * Yearly lease calendar (Gantt) — one row per unit, one column per MONTH.
 *
 * Long-term rental has no nightly grid: the whole selected year is visible at
 * once. Bars are positioned with day precision inside the month
 * (`monthIndex + (day - 1) / daysInMonth`), so a lease ending mid-month reads
 * correctly without a per-day column.
 *
 * Presentation only — no data fetching. Deliberately NOT draggable: a lease is
 * a financial document, its dates change only through notice / renew /
 * terminate.
 */
import { useMemo, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { ChevronLeft, ChevronRight, CalendarDays, ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { LEASE_STATUSES, formatMoney, type LeaseStatus } from "@/lib/rental";

export type CalendarUnit = {
  id: string;
  name: string;
  unit_number?: string;
  building_name?: string | null;
  status?: string;
};

export type CalendarLease = {
  id: string;
  unit_id: string;
  tenant_id: string;
  start_date: string;
  end_date: string | null;
  monthly_rent: number;
  deposit: number;
  payment_day: number;
  status: string;
  renewal: boolean;
  tenant_name: string;
  unit_name: string;
};

const STATUS_BAR: Record<string, string> = {
  active: "bg-primary text-primary-foreground border-primary",
  ending: "bg-amber-500 text-amber-950 border-amber-600",
  draft: "bg-muted text-foreground border-dashed border-foreground/40",
  expired: "bg-muted-foreground/40 text-foreground border-muted-foreground/50",
  terminated: "bg-destructive/70 text-destructive-foreground border-destructive",
};

const MONTHS = 12;

function daysInMonth(year: number, monthIndex: number) {
  return new Date(year, monthIndex + 1, 0).getDate();
}

/** Position of an ISO date on the 0..12 month axis of `year`. */
function axisPos(iso: string, year: number): number {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  if (!y || !m || !d) return 0;
  if (y < year) return 0;
  if (y > year) return MONTHS;
  const mi = m - 1;
  return mi + (d - 1) / daysInMonth(year, mi);
}

const nextDay = (iso: string) => {
  const d = new Date(`${iso.slice(0, 10)}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
};

export function LeasesYearGantt({
  units,
  leases,
  year,
  onYearChange,
}: {
  units: CalendarUnit[];
  leases: CalendarLease[];
  year: number;
  onYearChange: (year: number) => void;
}) {
  const { t, i18n } = useTranslation();
  const navigate = useNavigate();
  const [selected, setSelected] = useState<CalendarLease | null>(null);

  const monthLabels = useMemo(() => {
    const fmt = new Intl.DateTimeFormat(i18n.language === "en" ? "en" : "lt", { month: "short" });
    return Array.from({ length: MONTHS }, (_, i) => fmt.format(new Date(year, i, 1)));
  }, [i18n.language, year]);

  const byUnit = useMemo(() => {
    const map = new Map<string, CalendarLease[]>();
    for (const l of leases) {
      const arr = map.get(l.unit_id);
      if (arr) arr.push(l);
      else map.set(l.unit_id, [l]);
    }
    return map;
  }, [leases]);

  const now = new Date();
  const todayMarker =
    now.getFullYear() === year
      ? (now.getMonth() + (now.getDate() - 1) / daysInMonth(year, now.getMonth())) / MONTHS
      : null;

  const labelWidth = 200;
  const gridTemplate = `${labelWidth}px repeat(${MONTHS}, minmax(60px, 1fr))`;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Button size="sm" variant="outline" onClick={() => onYearChange(year - 1)}>
            <ChevronLeft className="mr-1 h-4 w-4" />
            {year - 1}
          </Button>
          <Button size="sm" variant="outline" onClick={() => onYearChange(new Date().getFullYear())}>
            <CalendarDays className="mr-1 h-4 w-4" />
            {t("rental.calendar.thisYear")}
          </Button>
          <Button size="sm" variant="outline" onClick={() => onYearChange(year + 1)}>
            {year + 1}
            <ChevronRight className="ml-1 h-4 w-4" />
          </Button>
        </div>
        <div className="text-lg font-semibold">{year}</div>
      </div>

      <div className="flex flex-wrap items-center gap-3 text-xs">
        {LEASE_STATUSES.map((s: LeaseStatus) => (
          <span key={s} className="inline-flex items-center gap-1.5">
            <span className={`h-3 w-3 rounded-sm border ${STATUS_BAR[s]}`} />
            {t(`rental.leaseStatus.${s}`)}
          </span>
        ))}
      </div>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <div className="min-w-[900px]">
          <div
            className="grid border-b bg-muted/50 sticky top-0 z-20"
            style={{ gridTemplateColumns: gridTemplate }}
          >
            <div className="sticky left-0 z-30 border-r bg-muted/80 px-3 py-2 text-xs font-medium">
              {t("rental.nav.units")}
            </div>
            {monthLabels.map((m, i) => (
              <div
                key={i}
                className="border-r py-2 text-center text-xs font-medium capitalize last:border-r-0"
              >
                {m}
              </div>
            ))}
          </div>

          {units.map((u) => {
            const rowLeases = byUnit.get(u.id) ?? [];
            return (
              <div
                key={u.id}
                className="relative grid border-b last:border-b-0"
                style={{ gridTemplateColumns: gridTemplate, minHeight: 48 }}
              >
                <div className="sticky left-0 z-10 flex flex-col justify-center border-r bg-card px-3 py-2 text-sm shadow-[2px_0_4px_-2px_rgba(0,0,0,0.2)]">
                  <Link
                    to="/admin/units/$id"
                    params={{ id: u.id }}
                    className="truncate font-medium hover:underline"
                  >
                    {u.name}
                  </Link>
                  {u.building_name && (
                    <span className="truncate text-xs text-muted-foreground">{u.building_name}</span>
                  )}
                </div>

                {Array.from({ length: MONTHS }, (_, i) => (
                  <button
                    key={i}
                    type="button"
                    onClick={() => navigate({ to: "/admin/units/$id", params: { id: u.id } })}
                    className="border-r transition-colors last:border-r-0 hover:bg-primary/10"
                    aria-label={`${u.name} ${monthLabels[i]} ${year}`}
                  />
                ))}

                {todayMarker !== null && (
                  <div
                    className="pointer-events-none absolute bottom-0 top-0 z-20 w-px bg-destructive"
                    style={{
                      left: `calc(${labelWidth}px + (100% - ${labelWidth}px) * ${todayMarker})`,
                    }}
                  />
                )}

                <div
                  className="pointer-events-none absolute inset-y-0 right-0"
                  style={{ left: labelWidth }}
                >
                  {rowLeases.map((l) => {
                    const start = axisPos(l.start_date, year);
                    const openEnded = !l.end_date;
                    const end = openEnded ? MONTHS : axisPos(nextDay(l.end_date!), year);
                    if (end <= start) return null;
                    const cls = STATUS_BAR[l.status] ?? STATUS_BAR["expired"];
                    return (
                      <button
                        key={l.id}
                        type="button"
                        onClick={() => setSelected(l)}
                        title={`${l.tenant_name} · ${l.start_date} → ${l.end_date ?? t("rental.lease.openEnded")}`}
                        className={`pointer-events-auto absolute inset-y-1 flex items-center gap-1 overflow-hidden rounded border px-2 text-xs font-medium shadow-sm ${cls}`}
                        style={{
                          left: `${(start / MONTHS) * 100}%`,
                          width: `${((end - start) / MONTHS) * 100}%`,
                        }}
                      >
                        <span className="truncate">{l.tenant_name || "—"}</span>
                        {openEnded && <ArrowRight className="h-3 w-3 shrink-0 opacity-80" />}
                      </button>
                    );
                  })}
                </div>
              </div>
            );
          })}

          {units.length === 0 && (
            <div className="p-8 text-center text-muted-foreground">
              {t("rental.calendar.noUnits")}
            </div>
          )}
        </div>
      </div>

      <Dialog open={!!selected} onOpenChange={(o) => !o && setSelected(null)}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>{selected?.unit_name}</DialogTitle>
          </DialogHeader>
          {selected && (
            <div className="space-y-2 text-sm">
              <div>
                <span className="text-muted-foreground">{t("rental.lease.tenant")}:</span>{" "}
                {selected.tenant_name || "—"}
              </div>
              <div>
                <span className="text-muted-foreground">{t("rental.lease.term")}:</span>{" "}
                {selected.start_date} → {selected.end_date ?? t("rental.lease.openEnded")}
              </div>
              <div>
                <span className="text-muted-foreground">{t("rental.lease.status")}:</span>{" "}
                {t(`rental.leaseStatus.${selected.status}`)}
              </div>
              <div>
                <span className="text-muted-foreground">{t("rental.lease.rent")}:</span>{" "}
                <span className="font-semibold text-primary">
                  {formatMoney(Number(selected.monthly_rent))}
                </span>
              </div>
              <div>
                <span className="text-muted-foreground">{t("rental.lease.deposit")}:</span>{" "}
                {formatMoney(Number(selected.deposit))}
              </div>
              <div>
                <span className="text-muted-foreground">{t("rental.lease.paymentDay")}:</span>{" "}
                {t("rental.lease.dayOfMonth", { day: selected.payment_day })}
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setSelected(null)}>
              {t("common.close")}
            </Button>
            {selected && (
              <Button asChild>
                <Link to="/admin/units/$id" params={{ id: selected.unit_id }}>
                  {t("rental.calendar.openUnit")}
                </Link>
              </Button>
            )}
            {selected && (
              <Button variant="secondary" asChild>
                <Link to="/admin/tenants/$id" params={{ id: selected.tenant_id }}>
                  {t("rental.calendar.openTenant")}
                </Link>
              </Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
