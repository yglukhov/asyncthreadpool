import asyncthreadpool, asyncdispatch
proc myTask(a, b: int): int = a + b
let r = waitFor spawn myTask(2, 3)
assert(r == 5)
