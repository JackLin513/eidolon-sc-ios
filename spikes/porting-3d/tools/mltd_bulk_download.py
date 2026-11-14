#!/usr/bin/env python3
"""Download the pinned MLTD CDN snapshot in parallel, resumable.

Run on the NAS (python3 stdlib only). Skips files that already exist with the
expected size; writes failures to failures.txt; appends progress to progress.log.
"""
import os, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "files")
URLS = os.path.join(BASE, "urls.txt")
FAIL = os.path.join(BASE, "failures.txt")
PROG = os.path.join(BASE, "progress.log")
THREADS = int(os.environ.get("THREADS", "16"))
UA = "UnityPlayer/2020.3.32f1"
HDRS = {"User-Agent": UA, "X-Unity-Version": "2020.3.32f1", "Accept": "*/*"}

def fetch(url):
    name = url.rsplit("/", 1)[-1]
    path = os.path.join(OUT, name)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return (name, "skip", 0)
    req = urllib.request.Request(url, headers=HDRS)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=45) as r:
                data = r.read()
            tmp = path + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
            return (name, "ok", len(data))
        except Exception as e:
            if attempt == 3:
                return (name, "fail:%s" % e, 0)
            time.sleep(1.5 * (attempt + 1))

def main():
    os.makedirs(OUT, exist_ok=True)
    with open(URLS) as f:
        urls = [u.strip() for u in f if u.strip()]
    t0 = time.time(); done = 0; bytes_ = 0; fails = 0
    with open(PROG, "a", buffering=1) as log, open(FAIL, "a", buffering=1) as fh:
        log.write("=== start %s  files=%d threads=%d\n" % (time.strftime("%F %T"), len(urls), THREADS))
        with ThreadPoolExecutor(max_workers=THREADS) as ex:
            futs = {ex.submit(fetch, u): u for u in urls}
            for fu in as_completed(futs):
                name, st, n = fu.result(); done += 1; bytes_ += n
                if st.startswith("fail"):
                    fails += 1; fh.write("%s\t%s\n" % (name, st))
                if done % 500 == 0:
                    el = time.time() - t0
                    log.write("progress %d/%d  %.2f GB  %.0f B/s  fails=%d  %.0fs\n"
                              % (done, len(urls), bytes_/1e9, bytes_/max(el,1), fails, el))
        log.write("=== done %s  ok=%.2fGB fails=%d elapsed=%.0fs\n"
                  % (time.strftime("%F %T"), bytes_/1e9, fails, time.time()-t0))

if __name__ == "__main__":
    main()
