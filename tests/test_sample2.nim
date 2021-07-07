import asyncthreadpool
when not defined(ChronosAsync):
  import asyncdispatch
else:
  import chronos
proc myTask(a, b: int): int = a + b
let r = waitFor spawn myTask(2, 3)
assert(r == 5)
