#!/usr/bin/env bash

set -uo pipefail

# ---------------- Настройки: поменяй под себя ----------------
export POSTGRES_PASSWORD="test123"
DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="postgres"
DB_USER="ivy"
CASE_TYPE="Performance1536D50K"
HNSW_M=32
HNSW_EF_CONSTRUCTION=128
HNSW_EF_SEARCH=128
MAINT_WORK_MEM="6GB"
MAX_PARALLEL_WORKERS=6

BUILD_LOAD_RE='^(COPY|INSERT INTO|CREATE TABLE|ALTER TABLE|DROP TABLE)'
BUILD_INDEX_RE='^(CREATE INDEX|DROP INDEX)'
SEARCH_QUERY_RE='^SELECT'
# ---------------------------------------------------------------

OUT_DIR="perf-results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"
echo "Результаты будут в: $OUT_DIR"


CPU_VENDOR="$(grep -m1 -i vendor_id /proc/cpuinfo | awk '{print $NF}')"

if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
  PERF_EVENTS="cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,l2_rqsts.references,l2_rqsts.miss,LLC-loads,LLC-load-misses"
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
  PERF_EVENTS="cycles,instructions,r0729,rE860,r8060,r0864,rff64,rff43"
else
  echo "[WARN] Неизвестный вендор CPU '$CPU_VENDOR', использую generic-события (могут быть не сравнимы между машинами)" >&2
  PERF_EVENTS="cycles,instructions,cache-references,cache-misses"
fi

echo "CPU vendor: $CPU_VENDOR"
echo "perf events: $PERF_EVENTS"

PSQL_BASE=(psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER")

sudo -v
( while true; do sudo -v; sleep 60; done ) &
KEEPALIVE_PID=$!
trap 'kill "$KEEPALIVE_PID" 2>/dev/null' EXIT

COMMON_ARGS=(
  --case-type "$CASE_TYPE"
  --host "$DB_HOST" --port "$DB_PORT" --db-name "$DB_NAME" --user-name "$DB_USER"
  --m "$HNSW_M" --ef-construction "$HNSW_EF_CONSTRUCTION" --ef-search "$HNSW_EF_SEARCH"
  --num-concurrency 1 --concurrency-duration 20
  --maintenance-work-mem "$MAINT_WORK_MEM" --max-parallel-workers "$MAX_PARALLEL_WORKERS"
)

# ---------------------------------------------------------------
# Дерево процессов: находим postmaster и всех его потомков.
# ---------------------------------------------------------------
get_postmaster_pid() {
  local datadir pidfile_pid
  datadir="$("${PSQL_BASE[@]}" -t -A -c "SHOW data_directory;" 2>/dev/null)"
  if [[ -n "$datadir" ]]; then
    pidfile_pid="$(sudo head -n1 "$datadir/postmaster.pid" 2>/dev/null)"
    if [[ "$pidfile_pid" =~ ^[0-9]+$ ]]; then
      echo "$pidfile_pid"
      return 0
    fi
  fi
  # Фолбэк, если не смогли прочитать postmaster.pid (нет прав/пути)
  pgrep -o -x postgres
}

get_descendant_pids() {
  local root="$1"
  local children
  children="$(pgrep -P "$root" 2>/dev/null)"
  local c
  for c in $children; do
    echo "$c"
    get_descendant_pids "$c"
  done
}

POSTMASTER_PID="$(get_postmaster_pid)"
if [[ -z "$POSTMASTER_PID" ]]; then
  echo "Не удалось определить PID postmaster'а, прерываю." >&2
  exit 1
fi
echo "postmaster PID: $POSTMASTER_PID"

# ---------------------------------------------------------------
# Классификация ролей: SQL (query/leader_pid) + cmdline, с кросс-проверкой.
# Заполняет глобальные ассоциативные массивы SQL_ROLE / FINAL_ROLE.
# ---------------------------------------------------------------
classify_all_pids() {
  declare -gA SQL_ROLE=()
  declare -gA FINAL_ROLE=()

  local sql="
    SELECT a.pid,
           a.backend_type,
           CASE WHEN a.leader_pid IS NULL THEN a.query ELSE l.query END AS eff_query
    FROM pg_stat_activity a
    LEFT JOIN pg_stat_activity l ON l.pid = a.leader_pid
    WHERE a.datname = '$DB_NAME'
      AND a.pid <> pg_backend_pid();
  "

  local pid backend_type query query_upper role
  while IFS='|' read -r pid backend_type query; do
    [[ -z "$pid" ]] && continue
    query_upper="${query^^}"
    role="other"
    if [[ "$query_upper" =~ $BUILD_INDEX_RE ]]; then
      role="build-index"
    elif [[ "$query_upper" =~ $BUILD_LOAD_RE ]]; then
      role="build-load"
    elif [[ "$query_upper" =~ $SEARCH_QUERY_RE ]]; then
      role="search"
    fi
    SQL_ROLE["$pid"]="$role"
  done < <("${PSQL_BASE[@]}" -F'|' -t -A -c "$sql" 2>/dev/null)

  # Кандидаты = дерево процессов postmaster'а (надёжный источник "кто есть")
  local worker_re='PARALLEL WORKER FOR PID ([0-9]+)'
  local candidate
  while read -r candidate; do
    [[ -z "$candidate" ]] && continue
    local ps_args ps_args_upper ps_role sql_role leader_from_ps
    ps_args="$(ps -o args= -p "$candidate" 2>/dev/null)"
    ps_args_upper="${ps_args^^}"
    ps_role="other"
    if [[ "$ps_args_upper" =~ CREATE\ INDEX ]]; then
      ps_role="build-index"
    elif [[ "$ps_args_upper" =~ $worker_re ]]; then
      leader_from_ps="${BASH_REMATCH[1]}"
      ps_role="${SQL_ROLE[$leader_from_ps]:-other}"
    elif [[ "$ps_args_upper" =~ ^POSTGRES:.*SELECT ]]; then
      ps_role="search"
    elif [[ "$ps_args_upper" =~ (COPY|INSERT\ INTO|CREATE\ TABLE) ]]; then
      ps_role="build-load"
    fi

    sql_role="${SQL_ROLE[$candidate]:-other}"

    if [[ "$sql_role" == "$ps_role" ]]; then
      FINAL_ROLE["$candidate"]="$sql_role"
    elif [[ "$sql_role" == "other" && "$ps_role" != "other" ]]; then
      FINAL_ROLE["$candidate"]="$ps_role"
    elif [[ "$ps_role" == "other" && "$sql_role" != "other" ]]; then
      FINAL_ROLE["$candidate"]="$sql_role"
    else
      echo "[WARN] pid=$candidate: SQL-роль='$sql_role' vs ps-роль='$ps_role' — конфликт, доверяю SQL" >&2
      FINAL_ROLE["$candidate"]="$sql_role"
    fi
  done < <(get_descendant_pids "$POSTMASTER_PID")
}

# Возвращает (в глобальных переменных TARGET_PID_CSV / TARGET_PIDROLE_CSV)
# pid'ы для текущей фазы $1 ("build" или "search"). "build" ловит ОБА
# подтипа (build-load И build-index) — perf всё равно профилирует
# фазу целиком, а точный подтип каждого pid сохраняется в
# TARGET_PIDROLE_CSV и попадает в metrics.csv как отдельная колонка
# role, по которой потом можно фильтровать build-index отдельно от
# build-load.
get_target_pids() {
  local target_role="$1"
  classify_all_pids
  TARGET_PID_CSV=""
  TARGET_PIDROLE_CSV=""
  local pid r
  for pid in "${!FINAL_ROLE[@]}"; do
    r="${FINAL_ROLE[$pid]}"
    if [[ "$target_role" == "build" && "$r" == build-* ]] || [[ "$r" == "$target_role" ]]; then
      TARGET_PID_CSV+="${TARGET_PID_CSV:+,}$pid"
      TARGET_PIDROLE_CSV+="${TARGET_PIDROLE_CSV:+,}${pid}:${r}"
    fi
  done
}

# ---------------------------------------------------------------
# Профилирование фазы: пока команда работает, раз в секунду сверяем
# набор целевых pid (по роли), при изменении — перезапускаем perf на
# новом наборе, каждый сегмент пишем в CSV (perf -x,) + .meta с
# метаданными (phase/segment/pids-и-роли).
# ---------------------------------------------------------------
profile_phase() {
  local out_prefix="$1"
  local label="$2"       # "build" | "search" — совпадает с ролью цели
  shift 2

  "$@" &
  local main_pid=$!

  local seg=0
  local current_pid_csv=""
  local perf_pid=""

  while kill -0 "$main_pid" 2>/dev/null; do
    get_target_pids "$label"
    if [[ -n "$TARGET_PID_CSV" && "$TARGET_PID_CSV" != "$current_pid_csv" ]]; then
      if [[ -n "$perf_pid" ]]; then
        sudo kill -INT "$perf_pid" 2>/dev/null
        wait "$perf_pid" 2>/dev/null
      fi
      seg=$((seg + 1))
      echo "[$label] Целевые pid изменились: $TARGET_PID_CSV -> сегмент $seg"

      cat > "${out_prefix}.seg${seg}.meta" <<EOF
phase=$label
segment=$seg
start_epoch=$(date +%s)
pids=$TARGET_PIDROLE_CSV
EOF

      sudo perf stat -x, -e "$PERF_EVENTS" \
        -p "$TARGET_PID_CSV" -I 1000 -o "${out_prefix}.seg${seg}.csv" &
      perf_pid=$!
      current_pid_csv="$TARGET_PID_CSV"
    fi
    sleep 1
  done

  wait "$main_pid" 2>/dev/null
  local exit_code=$?

  if [[ -n "$perf_pid" ]]; then
    sudo kill -INT "$perf_pid" 2>/dev/null
    wait "$perf_pid" 2>/dev/null
  fi

  echo "[$label] Готово. Сегментов: $seg (файлы: ${out_prefix}.seg*.csv)"
  return $exit_code
}

# ================= ФАЗА 1: построение индекса =================
echo ""
echo "=== ФАЗА 1: drop_old + load + build index ==="

profile_phase "$OUT_DIR/perf_build" "build" \
  vectordbbench pgvectorhnsw "${COMMON_ARGS[@]}" \
    --drop-old --load --skip-search-serial --skip-search-concurrent \
    > "$OUT_DIR/build_stdout.log" 2>&1

echo "=== ФАЗА 1 завершена ==="

# ================= ФАЗА 2: только поиск =================
echo ""
echo "=== ФАЗА 2: search_serial + search_concurrent (без пересборки) ==="

profile_phase "$OUT_DIR/perf_search" "search" \
  vectordbbench pgvectorhnsw "${COMMON_ARGS[@]}" \
    --skip-drop-old --skip-load --search-serial --search-concurrent \
    > "$OUT_DIR/search_stdout.log" 2>&1

echo "=== ФАЗА 2 завершена ==="

# ================= Сборка итогового CSV =================
echo ""
echo "=== Собираю metrics.csv из всех сегментов ==="

python metrics.py $OUT_DIR

# ================= Итог =================
echo ""
echo "Готово. Файлы:"
echo "  Лог фазы построения:       $OUT_DIR/build_stdout.log"
echo "  Сырые perf-сегменты (CSV): $OUT_DIR/perf_build.seg*.csv (+ .meta)"
echo "  Лог фазы поиска:           $OUT_DIR/search_stdout.log"
echo "  Сырые perf-сегменты (CSV): $OUT_DIR/perf_search.seg*.csv (+ .meta)"
echo "  ИТОГОВЫЙ CSV для графика:  $OUT_DIR/metrics.csv"
echo ""
echo "Стандартные метрики (QPS, recall, latency, insert_duration, optimize_duration, index_size)"
echo "ищи в JSON-файлах здесь:"
echo "  ~/bench-env/lib/python3.14/site-packages/vectordb_bench/results/PgVector/"
echo ""
echo "OUT_DIR=$OUT_DIR"
