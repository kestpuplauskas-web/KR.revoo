import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { listIssues, signIssuePhoto, updateIssue } from "@/lib/issues.functions";
import { listUnits } from "@/lib/units.functions";
import { ISSUE_PRIORITIES, ISSUE_STATUSES, daysBetween, todayIso } from "@/lib/rental";
import type { IssuePriority, IssueStatus } from "@/lib/rental";

const OPEN_STATUSES = ["new", "acknowledged", "in_progress", "waiting"];
const PRIORITY_RANK: Record<string, number> = { urgent: 0, high: 1, normal: 2, low: 3 };

type IssuesSearch = { status?: "open" | "all" | (typeof ISSUE_STATUSES)[number]; priority?: string };

export const Route = createFileRoute("/_authenticated/admin/issues")({
  component: IssuesPage,
  validateSearch: (s: Record<string, unknown>): IssuesSearch => {
    const out: IssuesSearch = {};
    if (s["status"] === "all" || ISSUE_STATUSES.includes(s["status"] as never))
      out.status = s["status"] as IssuesSearch["status"];
    if (ISSUE_PRIORITIES.includes(s["priority"] as never)) out.priority = s["priority"] as string;
    return out;
  },
  head: () => ({
    meta: [
      { title: "Gedimai — nuomos administravimas" },
      { name: "description", content: "Visų butų atviri gedimai pagal prioritetą ir amžių." },
    ],
  }),
});

const priorityClass: Record<string, string> = {
  urgent: "bg-destructive/15 text-destructive",
  high: "bg-orange-100 text-orange-800",
  normal: "bg-sky-100 text-sky-800",
  low: "bg-muted text-muted-foreground",
};

type IssueRow = Awaited<ReturnType<typeof listIssues>>[number];

function IssuesPage() {
  const { t } = useTranslation();
  const navigate = useNavigate({ from: Route.fullPath });
  const search = Route.useSearch();
  const status = search.status ?? "open";
  const fetchIssues = useServerFn(listIssues);
  const fetchUnits = useServerFn(listUnits);
  const [selected, setSelected] = useState<IssueRow | null>(null);

  const { data: issues = [], isLoading } = useQuery({
    queryKey: ["admin-issues"],
    queryFn: () => fetchIssues({ data: {} }),
  });
  const { data: units = [] } = useQuery({ queryKey: ["admin-units"], queryFn: () => fetchUnits() });
  const unitName = useMemo(() => new Map(units.map((u) => [u.id, u.name])), [units]);

  // Keep the open dialog in sync after status/priority/cost updates.
  useEffect(() => {
    if (!selected) return;
    const fresh = issues.find((i) => i.id === selected.id);
    if (fresh && fresh !== selected) setSelected(fresh);
  }, [issues, selected]);

  const rows = useMemo(() => {
    const today = todayIso();
    return issues
      .filter((i) =>
        status === "all" ? true : status === "open" ? OPEN_STATUSES.includes(i.status) : i.status === status,
      )
      .filter((i) => (search.priority ? i.priority === search.priority : true))
      .map((i) => ({ ...i, age: daysBetween(i.created_at.slice(0, 10), today) }))
      .sort(
        (a, b) =>
          (PRIORITY_RANK[a.priority] ?? 9) - (PRIORITY_RANK[b.priority] ?? 9) ||
          a.created_at.localeCompare(b.created_at),
      );
  }, [issues, status, search.priority]);

  const setSearch = (patch: IssuesSearch) =>
    navigate({
      search: (prev) => {
        const next = { ...prev, ...patch };
        if (next.status === "open") delete next.status;
        if (!next.priority) delete next.priority;
        return next;
      },
      replace: true,
    });

  return (
    <div>
      <h1 className="text-2xl font-semibold">{t("rental.issuesList.title")}</h1>
      <p className="text-sm text-muted-foreground">{t("rental.issuesList.count", { count: rows.length })}</p>

      <div className="mt-4 flex flex-wrap items-center gap-2">
        {(["open", "all"] as const).map((f) => (
          <Button
            key={f}
            size="sm"
            variant={status === f ? "default" : "outline"}
            onClick={() => setSearch({ status: f })}
          >
            {t(`rental.issuesList.filter.${f}`)}
          </Button>
        ))}
        <select
          value={ISSUE_STATUSES.includes(status as never) ? status : ""}
          onChange={(e) => setSearch({ status: (e.target.value || "open") as IssuesSearch["status"] })}
          className="h-9 rounded-md border bg-background px-3 text-sm"
          aria-label={t("rental.issues.status")}
        >
          <option value="">{t("rental.issuesList.anyStatus")}</option>
          {ISSUE_STATUSES.map((s) => (
            <option key={s} value={s}>
              {t(`rental.issueStatus.${s}`)}
            </option>
          ))}
        </select>
        <select
          value={search.priority ?? ""}
          onChange={(e) => setSearch({ priority: e.target.value || undefined })}
          className="h-9 rounded-md border bg-background px-3 text-sm"
          aria-label={t("rental.issues.priority")}
        >
          <option value="">{t("rental.issuesList.anyPriority")}</option>
          {ISSUE_PRIORITIES.map((p) => (
            <option key={p} value={p}>
              {t(`rental.issuePriority.${p}`)}
            </option>
          ))}
        </select>
      </div>

      <div className="mt-4 overflow-x-auto rounded-lg border">
        <table className="w-full min-w-[800px] text-sm">
          <thead className="bg-muted text-left">
            <tr>
              <th className="p-2">{t("rental.issues.priority")}</th>
              <th className="p-2">{t("rental.issues.title")}</th>
              <th className="p-2">{t("rental.units.colUnit")}</th>
              <th className="p-2">{t("rental.issues.category")}</th>
              <th className="p-2">{t("rental.issues.status")}</th>
              <th className="p-2">{t("rental.issuesList.createdAt")}</th>
              <th className="p-2">{t("rental.issuesList.age")}</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && (
              <tr>
                <td className="p-3 text-muted-foreground" colSpan={7}>
                  {t("common.loading")}
                </td>
              </tr>
            )}
            {!isLoading && rows.length === 0 && (
              <tr>
                <td className="p-3 text-muted-foreground" colSpan={7}>
                  {t("rental.issues.empty")}
                </td>
              </tr>
            )}
            {rows.map((i) => (
              <tr key={i.id} className="border-t align-top">
                <td className="p-2">
                  <span className={`inline-block rounded px-2 py-0.5 text-xs ${priorityClass[i.priority] ?? ""}`}>
                    {t(`rental.issuePriority.${i.priority}`)}
                  </span>
                </td>
                <td className="p-2">
                  <button
                    type="button"
                    onClick={() => setSelected(i)}
                    className="text-left font-medium text-primary hover:underline"
                  >
                    {i.title}
                  </button>
                  <div className="text-xs text-muted-foreground">{i.reporter_name}</div>
                </td>
                <td className="p-2">{unitName.get(i.unit_id) ?? "—"}</td>
                <td className="p-2">{t(`rental.issueCategory.${i.category}`)}</td>
                <td className="p-2">{t(`rental.issueStatus.${i.status}`)}</td>
                <td className="p-2 tabular-nums">{new Date(i.created_at).toLocaleDateString()}</td>
                <td className="p-2 tabular-nums">{t("rental.issuesList.days", { count: i.age })}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <IssueDialog issue={selected} unitName={selected ? unitName.get(selected.unit_id) : undefined} onClose={() => setSelected(null)} />
    </div>
  );
}

function IssueDialog({
  issue,
  unitName,
  onClose,
}: {
  issue: IssueRow | null;
  unitName?: string;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const update = useServerFn(updateIssue);
  const sign = useServerFn(signIssuePhoto);
  const [photoUrls, setPhotoUrls] = useState<{ path: string; url: string }[]>([]);
  const [costDraft, setCostDraft] = useState("");

  useEffect(() => {
    setCostDraft(issue?.cost != null ? String(issue.cost) : "");
  }, [issue]);

  const patch = useMutation({
    mutationFn: (v: { id: string; status?: IssueStatus; priority?: IssuePriority; cost?: number | null }) =>
      update({ data: v }),
    onSuccess: () => {
      toast.success(t("rental.issues.updated"));
      queryClient.invalidateQueries({ queryKey: ["admin-issues"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const photos = useMemo(
    () => (Array.isArray(issue?.photo_paths) ? (issue.photo_paths as string[]) : []),
    [issue],
  );

  useEffect(() => {
    setPhotoUrls([]);
    if (!issue || photos.length === 0) return;
    let cancelled = false;
    Promise.all(
      photos.map(async (path) => {
        const { url } = await sign({ data: { path } });
        return { path, url };
      }),
    )
      .then((urls) => {
        if (!cancelled) setPhotoUrls(urls);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [issue, photos, sign]);

  return (
    <Dialog open={!!issue} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-2xl">
        {issue && (
          <>
            <DialogHeader>
              <DialogTitle>{issue.title}</DialogTitle>
            </DialogHeader>
            <div className="space-y-4 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <span className={`inline-block rounded px-2 py-0.5 text-xs ${priorityClass[issue.priority] ?? ""}`}>
                  {t(`rental.issuePriority.${issue.priority}`)}
                </span>
                <span className="rounded bg-muted px-2 py-0.5 text-xs">
                  {t(`rental.issueCategory.${issue.category}`)}
                </span>
                {unitName && <span className="rounded bg-muted px-2 py-0.5 text-xs">{unitName}</span>}
              </div>

              <dl className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <div>
                  <dt className="text-xs text-muted-foreground">{t("rental.issuesList.reportedBy")}</dt>
                  <dd>{issue.reporter_name || "—"}</dd>
                </div>
                <div>
                  <dt className="text-xs text-muted-foreground">{t("rental.issuesList.createdAt")}</dt>
                  <dd>{new Date(issue.created_at).toLocaleString()}</dd>
                </div>
              </dl>

              {issue.description && (
                <div>
                  <p className="text-xs text-muted-foreground">{t("rental.issues.description")}</p>
                  <p className="mt-1 whitespace-pre-wrap">{issue.description}</p>
                </div>
              )}

              <div>
                <p className="text-xs text-muted-foreground">{t("rental.issuesList.photos")}</p>
                {photos.length === 0 ? (
                  <p className="mt-1 text-muted-foreground">{t("rental.issuesList.noPhotos")}</p>
                ) : (
                  <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
                    {photos.map((p) => {
                      const signed = photoUrls.find((u) => u.path === p)?.url;
                      return signed ? (
                        <a key={p} href={signed} target="_blank" rel="noopener noreferrer">
                          <img
                            src={signed}
                            alt={issue.title}
                            className="h-32 w-full rounded-md border object-cover"
                          />
                        </a>
                      ) : (
                        <div key={p} className="h-32 animate-pulse rounded-md border bg-muted" />
                      );
                    })}
                  </div>
                )}
              </div>

              <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                <div>
                  <label className="text-xs text-muted-foreground" htmlFor="issue-status">
                    {t("rental.issues.status")}
                  </label>
                  <select
                    id="issue-status"
                    value={issue.status}
                    disabled={patch.isPending}
                    onChange={(e) => patch.mutate({ id: issue.id, status: e.target.value as IssueStatus })}
                    className="mt-1 h-10 w-full rounded-md border bg-background px-3 text-sm"
                  >
                    {ISSUE_STATUSES.map((s) => (
                      <option key={s} value={s}>
                        {t(`rental.issueStatus.${s}`)}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="text-xs text-muted-foreground" htmlFor="issue-priority">
                    {t("rental.issues.priority")}
                  </label>
                  <select
                    id="issue-priority"
                    value={issue.priority}
                    disabled={patch.isPending}
                    onChange={(e) => patch.mutate({ id: issue.id, priority: e.target.value as IssuePriority })}
                    className="mt-1 h-10 w-full rounded-md border bg-background px-3 text-sm"
                  >
                    {ISSUE_PRIORITIES.map((p) => (
                      <option key={p} value={p}>
                        {t(`rental.issuePriority.${p}`)}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="text-xs text-muted-foreground" htmlFor="issue-cost">
                    Preliminari remonto kaina su PVM
                  </label>
                  <input
                    id="issue-cost"
                    type="number"
                    min="0"
                    step="0.01"
                    inputMode="decimal"
                    value={costDraft}
                    disabled={patch.isPending}
                    onChange={(e) => setCostDraft(e.target.value)}
                    onBlur={() => {
                      const next = costDraft.trim() === "" ? null : Number(costDraft);
                      if (Number.isNaN(next as number)) return;
                      if (next !== (issue.cost ?? null)) patch.mutate({ id: issue.id, cost: next });
                    }}
                    className="mt-1 h-10 w-full rounded-md border bg-background px-3 text-sm"
                  />
                </div>
              </div>
            </div>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
