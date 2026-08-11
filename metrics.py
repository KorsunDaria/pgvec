import csv, glob, os, re
import sys

out_dir = sys.argv[1]

event_re = re.compile(r"^[A-Za-z0-9_.\-]+$")
rows = []

for meta_path in sorted(glob.glob(os.path.join(out_dir, "perf_*.seg*.meta"))):
    csv_path = meta_path[:-5] + ".csv"
    if not os.path.exists(csv_path):
        continue

    meta = {}
    pids_field = ""
    with open(meta_path) as mf:
        for line in mf:
            line = line.strip()
            if not line or "=" not in line:
                continue
            k, _, v = line.partition("=")
            if k == "pids":
                pids_field = v
            else:
                meta[k] = v

    # pids_field выглядит как "1234:build-index,1235:build-index" —
    # вытаскиваем точную под-роль (build-load / build-index / search),
    # чтобы можно было сравнивать build-index отдельно от build-load.
    role_names = set()
    for item in pids_field.split(","):
        if ":" in item:
            role_names.add(item.split(":", 1)[1])
    if len(role_names) == 1:
        role_value = next(iter(role_names))
    elif role_names:
        role_value = "mixed(" + "+".join(sorted(role_names)) + ")"
    else:
        role_value = ""

    with open(csv_path, newline="") as cf:
        for raw in cf:
            raw = raw.rstrip("\n")
            if not raw or raw.startswith("#"):
                continue
            fields = raw.split(",")
            # perf stat -x, -I <ms> формат:
            # time,value,unit,event,run_time_ns,pct_time_enabled[,...]
            if len(fields) < 4:
                continue
            timestamp, value, unit, event = fields[0], fields[1], fields[2], fields[3]
            run_ns = fields[4] if len(fields) > 4 else ""
            pct = fields[5] if len(fields) > 5 else ""
            if not event_re.match(event):
                continue
            rows.append({
                "phase": meta.get("phase", ""),
                "role": role_value,
                "segment": meta.get("segment", ""),
                "start_epoch": meta.get("start_epoch", ""),
                "timestamp_sec": timestamp,
                "pids": pids_field,
                "event": event,
                "value": value,
                "unit": unit,
                "run_time_ns": run_ns,
                "pct_time_enabled": pct,
            })

out_csv = os.path.join(out_dir, "metrics.csv")
fieldnames = ["phase", "role", "segment", "start_epoch", "timestamp_sec", "pids",
              "event", "value", "unit", "run_time_ns", "pct_time_enabled"]
with open(out_csv, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()
    w.writerows(rows)

print(f"Итоговый CSV: {out_csv} ({len(rows)} строк)")
