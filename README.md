# asyncthreadpool [![Build Status](https://github.com/yglukhov/asyncthreadpool/workflows/CI/badge.svg?branch=main)](https://github.com/yglukhov/asyncthreadpool/actions?query=branch%3Amain)
Awaitable threadpool in nim

## Differences from built-in threadpool
* There is no global threadpool, threadpools must be created explicitly
* `spawn` returns `Future[T]` instead of `FlowVar[T]`. The thread that owns the threadpool must have a running `asyncdispatch` runloop for the futures to be awaitable.
* There is an overloaded `spawn` statement that doesn't take a threadpool as an argument. It effectively means "run the task on a temporary background thread".
* Backpressure (task queue limit) is not supported, the queues are of "infinite" capacity. Consequently there are no `try*` statements, as spawning a task will never fail. Despite how this sounds, it is not necessarily an advantage.
* There is no `sync()` operation, it should not be needed if futures are used.
* Async threadpools introduce a notion of thread context. It is a generic type parameter to the pool. An instance of this type will be created in every thread, and tasks can access it.

## Usage example
```nim
import asyncthreadpool, asyncdispatch
proc myTask(a, b: int): int = a + b
let t = newThreadPool()
let r = waitFor t.spawn myTask(3, 2)
assert(r == 5)
```
Note: in `async` functions you should use `await` instead of `waitFor`.

## Spawning a task without a threadpool
```nim
import asyncthreadpool, asyncdispatch
proc myTask(a, b: int): int = a + b
let r = waitFor spawn myTask(2, 3)
assert(r == 5)
```
Note: in `async` functions you should use `await` instead of `waitFor`.

## Thread context usage
Threadpools allow to have thread specific contexts of arbitrary type, specified upon pool creation. These contexts may later be accessed by the tasks. This can be useful in some cases, like a thread-pooled http client that has one socket per thread, and keeps the sockets open in between the tasks (http requests).
In the following example there are two tasks: `myTask`, and `getContext`. `myTask` increments the thread-local context, and `getContext` just returns it's value to the owning thread thread. The tasks can accept the context as a (optionally `var`) argument. The context is reffered to with a magic keyword `threadContext` which is awailable only within the `spawn` statement.
```nim
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
```
Note: in `async` functions you should use `await` instead of `waitFor`.
