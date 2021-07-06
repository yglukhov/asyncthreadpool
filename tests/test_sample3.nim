import asyncthreadpool, asyncdispatch
type MyContext = int
proc myTask(a, b: int, ctx: var MyContext): int =
  inc ctx
  a + b
proc getContext(ctx: MyContext): MyContext = ctx
let t = newThreadPool(MyContext, 1) # Create a single-threaded pool
echo waitFor t.spawn myTask(3, 2, threadContext) # Increments thread context
echo waitFor t.spawn myTask(3, 2, threadContext) # Increments thread context
let r = waitFor t.spawn getContext(threadContext)
assert r == 2
