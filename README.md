# peak_rss_trace

Scripts for measuring the peak memory usage of Bazel build actions and for
automatically tagging the targets that produced those actions with the measured
values.

## Usage

These commands should be run in the root of your repository.

1. Record trace logs for a build:

```bash
$ bazel clean
$ bazel shutdown
$ ~/git/peak_rss_trace/trace.sh \
    bazel build //... --disk_cache= --remote_cache= \
    --experimental_execution_log_file=/tmp/execlog.bin \

⋮

trace directory: /tmp/peak_rss_trace.OdhDGWws
```

2. Process trace logs to produce report:

```bash
$ export EXEC_LOG_PARSER=~/git/bazel/bazel-bin/src/tools/execlog/parser
$ ~/git/peak_rss_trace/report.sh /tmp/peak_rss_trace.OdhDGWws

⋮

peakrss,mnemonic,target,cmdline
505MiB,CppCompile,//common/src:client,"/usr/bin/gcc -U_FORTIFY_SOURCE‥
182MiB,CppCompile,//common/src:server,"/usr/bin/gcc -U_FORTIFY_SOURCE‥
180MiB,CppCompile,//common/src:net,"/usr/bin/gcc -U_FORTIFY_SOURCE -f‥
161MiB,CppCompile,//common/src:physics,"/usr/bin/gcc -U_FORTIFY_SOURC‥
97MiB,CppCompile,//common/src:zonebuild,"/usr/bin/gcc -U_FORTIFY_SOUR‥
58MiB,CppCompile,//common/src:core,"/usr/bin/gcc -U_FORTIFY_SOURCE -f‥
57MiB,CppArchive,//common/src:script,"/usr/bin/ar @bazel-out/k8-fastb‥
57MiB,CppArchive,//common/src:math,"/usr/bin/ar @bazel-out/k8-fastbui‥
34MiB,PackageZip,//common/data:textures-zip,"bazel-out/k8-opt-exec-2B‥

full report: /tmp/peak_rss_trace.yBQ78g8U/report
```

3. Update Bazel target tags with measured values:

```bash
~/git/peak_rss_trace/update.sh /tmp/peak_rss_trace.yBQ78g8U
``` 
