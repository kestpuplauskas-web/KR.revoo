/**
 * Yearly lease calendar. Months, not days: the whole year of every unit at once.
 * Data comes from the existing `listUnits` / `listBuildings` / `listLeases`.
 */
import { createFileRoute } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { listBuildings, listUnits } from "@/lib/units.functions";
import { listLeases } from "@/lib/leases.functions";
import { HOLDING_LEASE_STATUSES, todayIso } from "@/lib/rental";
import { LeasesYearGantt } from "@/components/admin/LeasesYearGantt";

export const Route = createFileRoute("/_authenticated/admin/calendar")({
  component: CalendarPage,
  head: () => ({
    meta: [
      { title: "Nuomos kalendorius — metinis butų vaizdas" },
      {
        name: "description",
        content:
          "Metinis nuomos kalendorius: kiekvieno buto sutartys pagal mėnesius, laisvi periodai ir besibaigiančios sutartys.",
      },
      { property: "og:title", content: "Nuomos kalendorius — metinis butų vaizdas" },
      {
        property: "og:description",
        content: "Visų metų nuomos sutarčių vaizdas pagal butus ir mėnesius.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
});

function CalendarPage() {
  const { t } = useTranslation();
  const fetchUnits = useServerFn(listUnits);
  const fetchBuildings = useServerFn(listBuildings);
  const fetchLeases = useServerFn(listLeases);

  const [year, setYear] = useState(() => new Date().getFullYear());
  const [q, setQ] = useState("");
  const [building, setBuilding] = useState("");
  const [onlyOccupied, setOnlyOccupied] = useState(false);

  const { data: units = [], isLoading: unitsLoading } = useQuery({
    queryKey: ["admin-units"],
    queryFn: () => fetchUnits(),
  });
  const { data: buildings = [] } = useQuery({
    queryKey: ["admin-buildings"],
    queryFn: () => fetchBuildings(),
  });
  const { data: leases = [], isLoading: leasesLoading } = useQuery({
    queryKey: ["admin-leases", "all"],
    queryFn: () => fetchLeases({ data: {} }),
  });

  const yearStart = `${year}-01-01`;
  const yearEnd = `${year}-12-31`;

  const yearLeases = useMemo(
    () =>
      leases.filter(
        (l) => l.start_date <= yearEnd && (!l.end_date || l.end_date >= yearStart),
      ),
    [leases, yearStart, yearEnd],
  );

  const needle = q.trim().toLowerCase();
  const tenantsByUnit = useMemo(() => {
    const map = new Map<string, string[]>();
    for (const l of yearLeases) {
      const arr = map.get(l.unit_id) ?? [];
      arr.push((l.tenant_name || "").toLowerCase());
      map.set(l.unit_id, arr);
    }
    return map;
  }, [yearLeases]);

  const visibleUnits = useMemo(
    () =>
      units.filter((u) => {
        if (building && u.building_id !== building) return false;
        if (onlyOccupied && !(tenantsByUnit.get(u.id)?.length ?? 0)) return false;
        if (!needle) return true;
        if (
          `${u.name} ${u.unit_number} ${u.building_name ?? ""}`.toLowerCase().includes(needle)
        )
          return true;
        return (tenantsByUnit.get(u.id) ?? []).some((n) => n.includes(needle));
      }),
    [units, building, onlyOccupied, needle, tenantsByUnit],
  );

  const today = todayIso();
  const occupiedToday = useMemo(
    () =>
      new Set(
        leases
          .filter(
            (l) =>
              HOLDING_LEASE_STATUSES.includes(l.status as never) &&
              l.start_date <= today &&
              (!l.end_date || l.end_date >= today),
          )
          .map((l) => l.unit_id),
      ).size,
    [leases, today],
  );
  const endingThisYear = useMemo(
    () => leases.filter((l) => l.end_date && l.end_date >= yearStart && l.end_date <= yearEnd).length,
    [leases, yearStart, yearEnd],
  );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">{t("rental.calendar.title")}</h1>
        <p className="text-sm text-muted-foreground">
          {unitsLoading || leasesLoading
            ? t("common.loading")
            : t("rental.calendar.summary", {
                occupied: occupiedToday,
                total: units.length,
                ending: endingThisYear,
                year,
              })}
        </p>
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <div className="relative">
          <Search className="absolute left-2 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder={t("rental.calendar.searchPlaceholder")}
            className="w-64 pl-8"
          />
        </div>
        <select
          value={building}
          onChange={(e) => setBuilding(e.target.value)}
          className="h-9 rounded-md border bg-background px-2 text-sm"
        >
          <option value="">{t("rental.units.allBuildings")}</option>
          {buildings.map((b) => (
            <option key={b.id} value={b.id}>
              {b.name}
            </option>
          ))}
        </select>
        <label className="flex items-center gap-2 text-sm">
          <Switch checked={onlyOccupied} onCheckedChange={setOnlyOccupied} />
          {t("rental.calendar.onlyOccupied")}
        </label>
        {(q || building || onlyOccupied) && (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              setQ("");
              setBuilding("");
              setOnlyOccupied(false);
            }}
          >
            <X className="mr-1 h-4 w-4" />
            {t("common.cancel")}
          </Button>
        )}
      </div>

      <LeasesYearGantt
        units={visibleUnits}
        leases={yearLeases}
        year={year}
        onYearChange={setYear}
      />
    </div>
  );
}
