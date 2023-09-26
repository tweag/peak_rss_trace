#!/usr/bin/env bash
set -euo pipefail

COLUMNS=${COLUMNS:-80}

trace_dir="${1?usage: report.sh TRACE-DIRECTORY}"
db_path="$trace_dir/db.sqlite"
rm -f "$db_path"
set -x

# Check required tools are present.
$EXEC_LOG_PARSER --help >/dev/null
sqlite3 --version

# Initialise database.
sqlite3 "$db_path" '
    CREATE TABLE bpftrace (
        idx INTEGER PRIMARY KEY,
        event TEXT,  -- "FORK" | "EXEC" | "EXIT"
        pid TEXT,
        data TEXT    -- Child pid for FORK, partial argv for EXEC, peakrss pages for EXIT
    );

    CREATE TABLE strace (
        idx INTEGER PRIMARY KEY,
        pid TEXT,
        cmdline TEXT
    );

    CREATE TABLE process (
        idx INTEGER PRIMARY KEY,
        pid TEXT,
        ppid TEXT,
        cmdline TEXT,
        peakrss INTEGER
    );

    CREATE TABLE action (
        idx INTEGER PRIMARY KEY,
        mnemonic TEXT,
        cmdline TEXT,
        target TEXT,
        time INTEGER
    );

    CREATE INDEX bpftrace_pid ON bpftrace (pid);
    CREATE INDEX strace_pid ON strace (pid);
    CREATE INDEX process_peakrss ON process (peakrss);
    CREATE INDEX action_cmdline ON action (cmdline);
'

# Ingest bpftrace log into database.
bpftrace_match='^\([A-Z]\+\) \([0-9]\+\) \(.*\)'
bpftrace_insert="INSERT INTO bpftrace (event, pid, data) VALUES ('\1', '\2', '\3');"
(
    exec <"$trace_dir/bpftrace.log"
    printf "BEGIN;\n"
    sed -n "s|'|''|g; s|$bpftrace_match|$bpftrace_insert|p"
    printf "COMMIT;\n"
) | sqlite3 "$db_path"

# Ingest strace log into database.
strace_match='^\([0-9]\+\) execve("[^"]*", \[\(.*\)\], 0x[0-9a-f]\+ .*vars.* = 0$'
strace_insert="INSERT INTO strace (pid, cmdline) VALUES ('\1', '\2');"
(
    exec <"$trace_dir/strace.log"
    printf "BEGIN;\n"
    sed "s|'|''|g" | sed 's|\\n|\\&|g' |  # Escape single quotes and newlines properly.
        sed -n "s|$strace_match|[\"\1\", \2]|p" |  # Extract pid and args as single json array.
        jq -r 'join(" ")' | sed "s|^\([0-9]\+\) \(.*\)|$strace_insert|"  # Transform into sql.
    printf "COMMIT;\n"
) | sqlite3 "$db_path"

## Populate process table by associating events.
sqlite3 "$db_path" '
    INSERT INTO process (pid, ppid, peakrss, cmdline)

    WITH p AS (
        WITH p AS (
            SELECT exit.pid, fork.pid AS ppid,
                   CAST(exit.data AS INTEGER) AS peakrss,
                   fork.idx AS idx1, exit.idx AS idx2,
                   MIN(exit.idx - fork.idx)
            FROM bpftrace AS fork
            JOIN bpftrace AS exit
            ON fork.data = exit.pid
            AND fork.idx < exit.idx
            WHERE fork.event = "FORK"
            AND exit.event = "EXIT"
            GROUP BY fork.idx
        )

        SELECT p.pid, p.ppid, p.peakrss,
               exec.data AS cmdline,
               MIN(exec.idx) AS idx
        FROM p LEFT JOIN bpftrace AS exec
        ON p.pid = exec.pid
        AND exec.event = "EXEC"
        AND p.idx1 < exec.idx
        AND exec.idx < p.idx2
        GROUP BY p.idx1
    )

    SELECT p.pid, p.ppid, p.peakrss,
        COALESCE(strace.cmdline, p.cmdline)
    FROM p LEFT JOIN strace
    ON p.pid = strace.pid
    AND strace.cmdline LIKE p.cmdline || "%"
    WHERE p.cmdline IS NOT NULL;
'

# Emit process tree in graphviz format.
sqlite3 "$db_path" "
    SELECT 'digraph ProcessTree {';
    SELECT '  p' || pid || ' [ label="'"'"' || pid || '\\n' ||
        REPLACE(cmdline, '"'"'"', '\\"'"'"') || '"'"'" ];' FROM process;
    SELECT '  p' || ppid || ' -> p' || pid || ';' FROM process;
    SELECT '}';
" >"$trace_dir/ProcessTree.dot"

# Find execution log.
exec_log_path=$(
    sqlite3 "$db_path" '
        SELECT cmdline FROM strace
        WHERE cmdline LIKE "%experimental_execution_log_file%";
    ' | grep -Pom 1 -- '(?<=--experimental_execution_log_file=)\S+' || true
)
if [[ ! -f "$exec_log_path" ]]; then
    printf '\e[31mcould not find execution log!\e[0m\n'
    printf 'missing `--experimental_execution_log_file=PATH` flag?\n'
    exit 1
fi

# Populate action table by processing execution log.
action_match='\(\S\+\) \(\S\+\) \(\S\+\)  \(.*\)'
action_insert="INSERT INTO action (target, time, mnemonic, cmdline)"
action_values="VALUES ('\1', '\2', '\3', '\4');"
$EXEC_LOG_PARSER --log_path "$exec_log_path" | sed -n '
    s/^command_args: "\(.*\)"$/\1/ ; t do_command_args
    s/^mnemonic: "\(.*\)"$/\1/     ; t do_mnemonic
    s/^  nanos: \(.*\)$/\1/        ; t do_nanos
    s/^target_label: "\(.*\)"$/\1/ ; t do_target_label
    b

    :do_command_args
    s/\\"/"/g
  '"s/'/''/g"'
    H
    b

    :do_mnemonic
    G
    h
    b

    :do_nanos
    G
    h
    b

    :do_target_label
    G
    s/\n/ /g
    s/'"$action_match"'/'"$action_insert $action_values"'/
    p
    z
    x
' | sqlite3 "$db_path"

# Produce memory usage report.
report_path="$trace_dir/report"
sqlite3 -csv -header "$db_path" '
    WITH target_peakrss AS (
        WITH RECURSIVE p(target, mnemonic, peakrss, pid, ppid, cmdline) AS (
            SELECT target, mnemonic, peakrss, pid, ppid, process.cmdline
            FROM process LEFT JOIN action ON process.cmdline = action.cmdline
            WHERE process.cmdline != "" AND action.target IS NOT NULL
            UNION SELECT p.target, p.mnemonic, process.peakrss, process.pid, p.pid, p.cmdline
            FROM p JOIN process ON p.pid = process.ppid
        )
        SELECT target, mnemonic, MAX(peakrss) as peakrss, pid, cmdline
        FROM p GROUP BY target ORDER BY peakrss DESC
    )
    SELECT (peakrss / 256) || "MiB" AS peakrss, mnemonic, target, cmdline
    FROM target_peakrss;
' >"$report_path"
set +x

# Display a preview of memory usage report.
printf "\n\e[37m"; head "$report_path" | cut -b -$COLUMNS
printf '\n\e[1mfull report: \e[1m%s\e[0m\n' "$report_path"
