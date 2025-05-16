import asyncthreadpool
when not defined(ChronosAsync):
  import std/asyncdispatch
else:
  import pkg/chronos
import std/os

proc bar(x: int) =
  doAssert x == 1
  sleep(10)

proc foo(pool: ThreadPool, x: int) {.async.} =
  await pool.spawn bar(x)

proc foo {.async.} =
  var pool = newThreadPool(4)
  var s = newSeq[Future[void]]()
  for _ in 0 ..< 16:
    s.add foo(pool, 1)
  for f in s:
    await f

for _ in 0 ..< 100:  # running once it hangs sometimes
  waitFor foo()
echo "ok"
