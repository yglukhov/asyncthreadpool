import asyncthreadpool
when not defined(ChronosAsync):
  import std/asyncdispatch
else:
  import pkg/chronos

proc bar(x: int) =
  doAssert x == 1

proc foo(x: int) {.async.} =
  await spawn bar(x)

proc foo {.async.} =
  for _ in 0 .. 100:
    await foo(1)

waitFor foo()
