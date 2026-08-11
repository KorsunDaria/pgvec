#!/usr/bin/env python3

import sys
import os
import glob
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PALETTE = {
    "build-load": "tab:red",
    "build-index": "tab:orange",
    "build": "tab:orange",
    "search": "tab:blue",
}

# Уровни кэша: для каждого — список возможных пар (references, misses)
# событий, которые может собрать profile_*.sh в зависимости от вендора
# CPU (Intel / AMD называют события по-разному). Проверяются по порядку,
# берётся первая пара, которая реально есть в CSV.
CACHE_LEVELS = [
    ("L1", [
        ("L1-dcache-loads", "L1-dcache-load-misses"),
        ("r0729", "rE860"),
    ]),
    ("L2", [
        ("l2_rqsts.references", "l2_rqsts.miss"),          # Intel (подтверждено perf list)
        ("L2_RQSTS.REFERENCES", "L2_RQSTS.MISS"),           # Intel, на случай другого регистра
        ("r8060", "r0864"),  # AMD
    ]),
    ("L3 / LLC", [
        ("LLC-loads", "LLC-load-misses"),
        ("rff64", "rff43"),
    ]),
    # Фолбэк для старых прогонов с generic-событиями
    ("cache (generic)", [
        ("cache-references", "cache-misses"),
    ]),
]


def color_for(group_name: str) -> str:
    if group_name in PALETTE:
        return PALETTE[group_name]
    return "tab:gray"


def find_latest_csv():
    base = os.path.expanduser("perf-results")
    dirs = sorted(glob.glob(os.path.join(base, "*")), key=os.path.getmtime)
    for d in reversed(dirs):
        p = os.path.join(d, "metrics.csv")
        if os.path.exists(p):
            return p
    raise FileNotFoundError("Не нашёл metrics.csv в ~/perf-results/*/")


def pick_available_levels(available_events: set):
    """Возвращает список (level_name, ref_event, miss_event) для уровней,
    у которых нашлась хотя бы одна известная пара событий в CSV."""
    picked = []
    for level_name, candidates in CACHE_LEVELS:
        for ref_ev, miss_ev in candidates:
            if ref_ev in available_events and miss_ev in available_events:
                picked.append((level_name, ref_ev, miss_ev))
                break
    return picked


def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else find_latest_csv()
    out_dir = os.path.dirname(os.path.abspath(csv_path))
    df = pd.read_csv(csv_path)

    for col in ("start_epoch", "timestamp_sec", "value", "segment"):
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    df = df.dropna(subset=["value"])

    # абсолютное время = начало сегмента + смещение внутри сегмента,
    # т.к. таймер perf обнуляется при каждом перезапуске сегмента
    df["abs_time"] = df["start_epoch"] + df["timestamp_sec"]
    t0 = df["abs_time"].min()
    df["t_rel"] = df["abs_time"] - t0

    # группируем по "role" (build-load/build-index/search), если есть и
    # непустая — иначе по старой "phase" для совместимости
    if "role" in df.columns and df["role"].fillna("").astype(str).str.len().gt(0).any():
        group_col = "role"
        df[group_col] = df[group_col].fillna(df.get("phase", ""))
    else:
        group_col = "phase"
    groups = [g for g in df[group_col].dropna().unique().tolist() if g]

    available_events = set(df["event"].dropna().unique().tolist())
    levels = pick_available_levels(available_events)
    has_ipc = {"instructions", "cycles"}.issubset(available_events)

    if not levels:
        print("В CSV не найдено ни одной известной пары cache-событий "
              "(L1/L2/LLC или generic cache-references/cache-misses) — нечего рисовать.")
        return

    pivot = df.pivot_table(
        index=[group_col, "segment", "timestamp_sec", "t_rel"],
        columns="event", values="value", aggfunc="first"
    ).reset_index()

    # ---------- 1) сырые счётчики по времени (все события, что есть) ----------
    raw_events = [ev for lvl, ref, miss in levels for ev in (ref, miss)]
    if has_ipc:
        raw_events += ["instructions", "cycles"]
    raw_events = [e for e in raw_events if e in available_events]

    fig, axes = plt.subplots(len(raw_events), 1, figsize=(11, 2.6 * len(raw_events)), sharex=True)
    if len(raw_events) == 1:
        axes = [axes]
    for ax, ev in zip(axes, raw_events):
        sub_ev = df[df["event"] == ev]
        for g in groups:
            sub = sub_ev[sub_ev[group_col] == g].sort_values("t_rel")
            if sub.empty:
                continue
            ax.plot(sub["t_rel"], sub["value"], label=g, color=color_for(g),
                     marker=".", linewidth=1, markersize=3)
        ax.set_ylabel(ev, fontsize=9)
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8, loc="upper right")
    axes[-1].set_xlabel("время от начала теста, сек")
    fig.suptitle(f"perf-счётчики по времени (по {group_col})")
    fig.tight_layout()
    raw_path = os.path.join(out_dir, "metrics_raw.png")
    fig.savefig(raw_path, dpi=130)
    plt.close(fig)

    # ---------- 2) производные метрики: miss-rate всех уровней на ОДНОМ графике + IPC ----------
    for level_name, ref_ev, miss_ev in levels:
        pivot[f"miss_rate__{level_name}"] = (
            pivot[miss_ev] / pivot[ref_ev].replace(0, pd.NA)
        ) * 100

    LEVEL_COLORS = {
        "L1": "tab:green",
        "L2": "tab:orange",
        "L3 / LLC": "tab:red",
        "cache (generic)": "tab:purple",
    }
    ROLE_STYLES = {
        "build-load": "dotted",
        "build-index": "dashed",
        "build": "dashed",
        "search": "solid",
    }

    n_panels = 2 if has_ipc else 1
    fig2, axes2 = plt.subplots(n_panels, 1, figsize=(11, 5.5 if has_ipc else 4.5),
                                sharex=True, squeeze=False)
    axes2 = axes2[:, 0]
    ax1 = axes2[0]

    for level_name, ref_ev, miss_ev in levels:
        col = f"miss_rate__{level_name}"
        color = LEVEL_COLORS.get(level_name, "tab:gray")
        for g in groups:
            sub = pivot[pivot[group_col] == g].sort_values("t_rel")
            if sub[col].dropna().empty:
                continue
            ax1.plot(sub["t_rel"], sub[col],
                     label=f"{level_name} — {g}",
                     color=color,
                     linestyle=ROLE_STYLES.get(g, "solid"),
                     marker=".", linewidth=1.3, markersize=3)

    ax1.set_ylabel("cache miss-rate, %")
    ax1.set_ylim(0, 100)
    ax1.grid(True, alpha=0.3)
    ax1.legend(fontsize=8, loc="upper right", ncol=2)

    if has_ipc:
        ax_ipc = axes2[1]
        pivot["ipc"] = pivot["instructions"] / pivot["cycles"].replace(0, pd.NA)
        for g in groups:
            sub = pivot[pivot[group_col] == g].sort_values("t_rel")
            ax_ipc.plot(sub["t_rel"], sub["ipc"], label=g, color=color_for(g),
                        marker=".", linewidth=1, markersize=3)
        ax_ipc.set_ylabel("IPC\n(instr/cycle)", fontsize=9)
        ax_ipc.grid(True, alpha=0.3)
        ax_ipc.legend(fontsize=8, loc="upper right")

    axes2[-1].set_xlabel("время от начала теста, сек")
    level_names_str = " / ".join(name for name, _, _ in levels)
    fig2.suptitle(f"Miss-rate по уровням кэша ({level_names_str}, цвет = уровень, стиль линии = фаза)"
                  + (" + IPC" if has_ipc else ""))
    fig2.tight_layout()
    derived_path = os.path.join(out_dir, "metrics_derived.png")
    fig2.savefig(derived_path, dpi=130)
    plt.close(fig2)

    print(f"Сохранено:\n  {raw_path}\n  {derived_path}")
    print(f"Уровни кэша, найденные в CSV: {level_names_str}")


if __name__ == "__main__":
    main()
