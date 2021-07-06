import asyncthreadpool, asyncdispatch
proc myTask(a, b: int): int = a + b
let t = newThreadPool()
let r = waitFor t.spawn myTask(3, 2)
assert(r == 5)
