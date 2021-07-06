import macros, cpuinfo, asyncdispatch
import ./private/pipes

when not compileOption("threads"):
  {.error: "ThreadPool requires --threads:on compiler option".}

type
  ThreadPoolBase {.inheritable, pure.} = ref object
    chanTo: ChannelTo # Tasks are added to this channel
    chanFrom: ChannelFrom # Results are read from this channel
    threads: seq[ThreadType]
    maxThreads: int
    notifPipeR, notifPipeW: PipeFd
    pendingJobs: int # Jobs awaiting completion

  ContextThreadPool*[T] = ref object of ThreadPoolBase
  ThreadPool* = ContextThreadPool[EmptyThreadContext]

  MsgTo = object
    action: proc(fut, threadCtx: pointer, notifPipeW: PipeFd, chanFrom: ChannelFromPtr) {.gcsafe.}
    fut: pointer

  MsgFrom = object
    writeResult: proc() {.gcsafe.}

  ChannelTo = Channel[MsgTo]
  ChannelFrom = Channel[MsgFrom]

  ChannelToPtr = ptr ChannelTo
  ChannelFromPtr = ptr ChannelFrom

  ThreadProcArgs = object
    chanTo: ChannelToPtr
    chanFrom: ChannelFromPtr
    notifPipeW: PipeFd

  ThreadType = Thread[ThreadProcArgs]
  EmptyThreadContext = int # This should be an empty tuple, but i don't know how to specify it

proc cleanupAux(tp: ThreadPoolBase) =
  var msg: MsgTo
  for i in 0 ..< tp.threads.len:
    tp.chanTo.send(msg)
  joinThreads(tp.threads)

# XXX: Do the GC_ref GC_unref correctly.
proc sync*(tp: ThreadPoolBase) =
  if tp.threads.len != 0:
    tp.cleanupAux()
    tp.threads.setLen(0)

proc finalizeAux(tp: ThreadPoolBase) =
  if tp.threads.len != 0:
    tp.cleanupAux()
    GC_unref(tp.threads)
  tp.chanTo.close()
  tp.chanFrom.close()
  asyncdispatch.unregister(tp.notifPipeR.AsyncFD)
  tp.notifPipeR.close()
  tp.notifPipeW.close()

proc finalize[TThreadContext](tp: ContextThreadPool[TThreadContext]) =
  finalizeAux(tp)

proc threadProcAux(args: ThreadProcArgs, threadContext: pointer) =
  while true:
    let m = args.chanTo[].recv()
    if m.action.isNil:
      break
    m.action(m.fut, threadContext, args.notifPipeW, args.chanFrom)
  deallocHeap(true, false)

proc threadProc[TThreadContext](args: ThreadProcArgs) {.thread.} =
  var threadContext: TThreadContext
  threadProcAux(args, addr threadContext)

proc startThreads(tp: ThreadPoolBase, threadProc: proc(args: ThreadProcArgs) {.thread.}) =
  assert(tp.threads.len == 0)
  if tp.threads.len == 0:
    tp.threads = newSeq[ThreadType](tp.maxThreads)
    GC_ref(tp.threads)
  else:
    tp.threads.setLen(tp.maxThreads)

  var args = ThreadProcArgs(chanTo: addr tp.chanTo, chanFrom: addr tp.chanFrom, notifPipeW: tp.notifPipeW)
  for i in 0 ..< tp.maxThreads:
    createThread(tp.threads[i], threadProc, args)

proc newThreadPool*(TThreadContext: typedesc, maxThreads: int): ContextThreadPool[TThreadContext] =
  result.new(finalize[TThreadContext])
  result.maxThreads = maxThreads
  result.chanTo.open()#maxMessages)
  result.chanFrom.open()
  let (r, w) = createPipe()
  result.notifPipeR = r
  result.notifPipeW = w

proc newThreadPool*(maxThreads: int, maxMessages: int): ThreadPool =
  newThreadPool(EmptyThreadContext, maxThreads)

proc newThreadPool*(maxThreads: int): ThreadPool {.inline.} =
  newThreadPool(maxThreads, maxThreads * 4)

proc newThreadPool*(): ThreadPool {.inline.} =
  newThreadPool(countProcessors())

proc newSerialThreadPool*(): ThreadPool {.inline.} =
  newThreadPool(1)

proc dispatchLoop(tp: ThreadPoolBase) {.async.} =
  while tp.pendingJobs != 0:
    var dummy: int8
    discard await readInto(tp.notifPipeR, addr dummy, sizeof(dummy))
    let m = tp.chanFrom.tryRecv()
    if m.dataAvailable:
      m.msg.writeResult()
      dec tp.pendingJobs

proc dispatchMessage(tp: ThreadPoolBase, m: MsgTo, threadProc: proc(args: ThreadProcArgs) {.thread.}) =
  if tp.threads.len == 0:
    tp.startThreads(threadProc)
  inc tp.pendingJobs
  if tp.pendingJobs == 1:
    asyncCheck dispatchLoop(tp)
  tp.chanTo.send(m)

proc notifyDataAvailable(notifPipeW: PipeFd) =
  var dummy = 0'i8
  write(notifPipeW, addr dummy, sizeof(dummy))

proc sendBack[T](v: T, notifPipeW: PipeFd, c: ChannelFromPtr, fut: pointer) {.gcsafe.} =
  var msg: MsgFrom
  msg.writeResult = proc() =
    let fut = cast[Future[T]](fut)
    when T is void:
      fut.complete()
    else:
      fut.complete(v)
    GC_unref(fut)
  c[].send(msg)
  notifyDataAvailable(notifPipeW)

const threadContextArgName = "threadContext"

macro partial(e: untyped, TThreadContext: typed): untyped =
  let par = newNimNode(nnkTupleConstr)
  proc skipHidden(n: NimNode): NimNode =
    result = n
    while result.kind in {nnkHiddenStdConv}:
      result = result[^1]

  let argsIdent = ident"args"
  let threadContextIdent = ident(threadContextArgName)

  let transformedCall = newCall(e[0])
  var j = 0
  for i in 1 ..< e.len:
    if e[i].kind in {nnkIdent, nnkSym} and $e[i] == threadContextArgName:
      transformedCall.add(threadContextIdent)
    else:
      par.add(skipHidden(e[i]))
      transformedCall.add(newNimNode(nnkBracketExpr).add(argsIdent, newLit(j)))
      inc j

  let resultProc = newProc(params = [ident"auto", newIdentDefs(threadContextIdent, newTree(nnkVarTy, TThreadContext))], body = transformedCall, procType = nnkLambda)
  resultProc.addPragma(ident"gcsafe")

  let wrapperIdent = ident"tmpWrapper"

  let wrapperProc = newProc(wrapperIdent, params = [ident"auto", newIdentDefs(argsIdent, ident"auto")], body = resultProc)
  wrapperProc.addPragma(ident"inline")

  result = newTree(nnkStmtList, wrapperProc, newCall(wrapperIdent, par))

  # echo repr result

proc setAction(m: var MsgTo, a: proc(fut, threadCtx: pointer, notifPipeW: PipeFd, chanFrom: ChannelFromPtr) {.gcsafe.}) {.inline.} =
  m.action = a

proc dummyThreadContext[TThreadContext](): var TThreadContext =
  # This proc should only be needed for type inference in compile time
  var p: ptr TThreadContext
  p[]

macro getCallableResultType(e: untyped, TThreadContext: typed) =
  let e = copyNimTree(e)
  for i in 1 ..< e.len:
    if e[i].kind in {nnkIdent, nnkSym} and $e[i] == threadContextArgName:
      e[i] = quote do: dummyThreadContext[`TThreadContext`]()
  e

template expressionRetType(e: untyped): typedesc =
  when compiles(typeof(e)):
    typeof(e)
  else:
    void

template spawn*[TThreadContext](tp: ContextThreadPool[TThreadContext], e: untyped{nkCall | nkCommand}): untyped =
  block:
    type RetType = expressionRetType(getCallableResultType(e, TThreadContext))
    var m: MsgTo
    proc setup(m: var MsgTo, pe: proc) {.inline, nimcall.} =
      setAction(m) do(fut, threadCtxPtr: pointer, notifPipeW: PipeFd, chanFrom: ChannelFromPtr):
        template threadContext: TThreadContext  = cast[ptr TThreadContext](threadCtxPtr)[]
        sendBack(pe(threadContext), notifPipeW, chanFrom, fut)
    setup(m, partial(e, TThreadContext))
    let fut = newFuture[RetType]()
    m.fut = cast[pointer](fut)
    mixin dispatchMessage
    tp.dispatchMessage(m, threadProc[TThreadContext])
    fut

template spawn*(e: untyped{nkCall | nkCommand}): untyped =
  block:
    let tp = newSerialThreadPool()
    let f = spawn(tp, e)
    f.addCallback() do():
      tp.sync()
    f
