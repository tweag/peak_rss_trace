#!/usr/bin/env bash
set -euo pipefail

COLUMNS=${COLUMNS:-80}

# Check required tools are present.
pstree --version
strace --version

# Ensure that we have the expected version of bpftrace.
bpftrace_url="https://github.com/iovisor/bpftrace/releases/download/v0.19.0/bpftrace"
bpftrace_hash="9638838f959cb4e19e948b582a7b348048b3851c6f52c518fc846a2b00554af5"
bpftrace_path="$(dirname $(mktemp -du))/bpftrace.$bpftrace_hash"

bpftrace() {
    checksum="$bpftrace_hash $bpftrace_path"

    sha256sum -c --quiet <<<"$checksum" || {
        rm -f "$bpftrace_path"
        curl -L "$bpftrace_url" --output "$bpftrace_path"

        sha256sum -c --quiet <<<"$checksum" || {
            printf '\e[31mchecksum does not match!\e[0m\n'
            exit 1
        }
    }

    chmod +x "$bpftrace_path"
    (set -x; sudo -b "$bpftrace_path" "$@" 1>/dev/null 2>&1)
}

# Create temporary directory to hold trace logs and database.
trace_dir="$(mktemp -d peak_rss_trace.XXXXXXXX --tmpdir)"

# Start bpftrace to capture events.
mkfifo "$trace_dir/ready"
bpftrace --unsafe -e '

    #include <linux/sched.h>
    #include <linux/sched/task.h>
    #include <linux/mm_types.h>

    BEGIN {
        @peakrss[$1] = 0;
        @tracing[$1] = true;
        system("echo >'"$trace_dir"'/ready");
    }

    tracepoint:sched:sched_process_fork {
        printf("FORK %d %d\n", args.parent_pid, args.child_pid);
        @peakrss[args.child_pid] = @peakrss[args.parent_pid];
        @tracing[args.child_pid] = true;
    }

    tracepoint:syscalls:sys_enter_execve /@tracing[tid]/ {
        printf("EXEC %d ", tid);  // } Race condition: printf and join from different
        join(args.argv, " ");     // } processes can be interleaved on rare occasions.
    }

    rawtracepoint:sys_exit /@tracing[tid]/ {
        @peakrss[tid] = curtask->mm->hiwater_rss;
    }

    tracepoint:sched:sched_process_exit /@tracing[tid]/ {
        printf("EXIT %d %d\n", tid, @peakrss[tid]);
        delete(@peakrss[tid]);
        delete(@tracing[tid]);
    }

    tracepoint:sched:sched_process_exit /tid == $1/ {
        printf("stopping bpftrace");
        exit();
    }

' -o "$trace_dir/bpftrace.log" $$ &
cat "$trace_dir/ready"  # Wait until bpftrace has started.

# Run given command under strace.
# This is necessary to capture the full command line for each process.
# With just bpftrace, we only get the first 16 arguments.
strace -e trace=%process -f -s 65536 -o "$trace_dir/strace.log" "$@" \
    1>"$trace_dir/stdout" 2>"$trace_dir/stderr" &
strace_pid=$!

# Block until interrupted.
while ! read -t 0 _; do
    printf "\e[H\e[2J"
    tail "$trace_dir/stderr" 2>/dev/null | cut -b -$COLUMNS || echo
    printf "\n\e[0;37m"; pstree -a -p $strace_pid
    printf "\n\e[0m<press enter to interrupt> "
    sleep 5
done

rm "$trace_dir/ready"
kill -9 $strace_pid || true

printf '\n\e[37mtrace directory: \e[1m%s\e[0m\n' "$trace_dir"
