import asyncdispatch, os

# This code is stripped down (and specialized) version of https://github.com/cheatfate/asynctools/blob/master/asynctools/asyncpipe.nim

when defined(windows):
  import winlean
  type
    PipeFd* = distinct Handle

  proc QueryPerformanceCounter(res: var int64)
        {.importc: "QueryPerformanceCounter", stdcall, dynlib: "kernel32".}
  proc connectNamedPipe(hNamedPipe: Handle, lpOverlapped: pointer): WINBOOL
        {.importc: "ConnectNamedPipe", stdcall, dynlib: "kernel32".}
  proc getCurrentProcessId(): DWORD {.stdcall, dynlib: "kernel32",
                                    importc: "GetCurrentProcessId".}

  const
    pipeHeaderName = r"\\.\pipe\nimtp_"

  const
    DEFAULT_PIPE_SIZE = 65536'i32
    FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000'i32
    PIPE_WAIT = 0x00000000'i32
    PIPE_TYPE_BYTE = 0x00000000'i32
    PIPE_READMODE_BYTE = 0x00000000'i32
    ERROR_PIPE_CONNECTED = 535
    ERROR_PIPE_BUSY = 231
    ERROR_BROKEN_PIPE = 109
    ERROR_PIPE_NOT_CONNECTED = 233

  proc createPipe*(): tuple[readFd, writeFd: PipeFd] =
    var number = 0'i64
    var pipeName: WideCString
    var readFd: Handle
    var writeFd: Handle
    var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                  lpSecurityDescriptor: nil, bInheritHandle: 1)
    let pid = getCurrentProcessId()

    while true:
      QueryPerformanceCounter(number)
      let p = pipeHeaderName & $pid & "_" & $number
      pipeName = newWideCString(p)
      var openMode = FILE_FLAG_FIRST_PIPE_INSTANCE or FILE_FLAG_OVERLAPPED or
                      PIPE_ACCESS_INBOUND
      var pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT
      readFd = createNamedPipe(pipeName, openMode, pipeMode, 1'i32,
                                DEFAULT_PIPE_SIZE, DEFAULT_PIPE_SIZE,
                                1'i32, addr sa)
      if readFd == INVALID_HANDLE_VALUE:
        let err = osLastError()
        if err.int32 != ERROR_PIPE_BUSY:
          raiseOsError(err)
      else:
        break

    var openMode = (FILE_WRITE_DATA or SYNCHRONIZE)
    writeFd = createFileW(pipeName, openMode, 0, addr(sa), OPEN_EXISTING,
                          0, 0)
    if writeFd == INVALID_HANDLE_VALUE:
      let err = osLastError()
      discard closeHandle(readFd)
      raiseOsError(err)

    result = (readFd.PipeFd, writeFd.PipeFd)

    var ovl = OVERLAPPED()
    let res = connectNamedPipe(readFd, cast[pointer](addr ovl))
    if res == 0:
      let err = osLastError()
      if err.int32 == ERROR_PIPE_CONNECTED:
        discard
      elif err.int32 == ERROR_IO_PENDING:
        var bytesRead = 0.Dword
        if getOverlappedResult(readFd, addr ovl, bytesRead, 1) == 0:
          let oerr = osLastError()
          discard closeHandle(readFd)
          discard closeHandle(writeFd)
          raiseOsError(oerr)
      else:
        discard closeHandle(readFd)
        discard closeHandle(writeFd)
        raiseOsError(err)

    register(AsyncFD(readFd))

  proc close*(pipeFd: PipeFd) =
    if closeHandle(pipeFd.Handle) == 0:
      raiseOsError(osLastError())

  proc write*(pipeFd: PipeFd, data: pointer, nbytes: int) =
    let pipeFd = pipeFd.Handle
    if not writeFile(pipeFd, data, nbytes.int32, nil, nil).bool:
      raiseOsError(osLastError())

  proc readInto*(pipeFd: PipeFd, data: pointer, nbytes: int): Future[int] =
    let pipeFd = PipeFd.Handle
    var retFuture = newFuture[int]()
    var ol = PCustomOverlapped()

    GC_ref(ol)
    ol.data = CompletionData(fd: AsyncFD(pipeFd), cb:
      proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            assert(bytesCount > 0 and bytesCount <= nbytes.int32)
            retFuture.complete(bytesCount)
          else:
            if errcode.int32 in {ERROR_BROKEN_PIPE,
                                  ERROR_PIPE_NOT_CONNECTED}:
              retFuture.complete(bytesCount)
            else:
              retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )
    let res = readFile(pipeFd, data, nbytes.int32, nil,
                        cast[POVERLAPPED](ol)).bool
    if not res:
      let err = osLastError()
      if err.int32 in {ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED}:
        GC_unref(ol)
        retFuture.complete(0)
      elif err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    return retFuture

else:
  import posix
  type
    PipeFd* = cint

  proc setNonBlocking(fd: cint) {.inline.} =
    var x = fcntl(fd, F_GETFL, 0)
    if x == -1:
      raiseOSError(osLastError())
    else:
      var mode = x or O_NONBLOCK
      if fcntl(fd, F_SETFL, mode) == -1:
        raiseOSError(osLastError())

  proc createPipe*(): tuple[readFd, writeFd: PipeFd] =
    var fds: array[2, cint]
    if posix.pipe(fds) == -1:
      raiseOSError(osLastError())
    setNonBlocking(fds[0])
    register(AsyncFD(fds[0]))
    (fds[0].PipeFd, fds[1].PipeFd)

  proc close*(pipeFd: PipeFd) =
    discard posix.close(pipeFd.cint)

  proc write*(pipeFd: PipeFd, data: pointer, nbytes: int) =
    let pipeFd = pipeFd.cint
    if posix.write(pipeFd, data, nbytes) != nbytes:
      raiseOSError(osLastError())

  proc readInto*(pipeFd: PipeFd, data: pointer, nbytes: int): Future[int] =
    let pipeFd = pipeFd.cint
    var retFuture = newFuture[int]()
    proc cb(fd: AsyncFD): bool =
      result = true
      let res = posix.read(pipeFd, data, cint(nbytes))
      if res < 0:
        let err = osLastError()
        if err.int32 != EAGAIN:
          retFuture.fail(newException(OSError, osErrorMsg(err)))
        else:
          result = false # We still want this callback to be called.
      elif res == 0:
        retFuture.complete(0)
      else:
        retFuture.complete(res)

    if not cb(AsyncFD(pipeFd)):
      addRead(AsyncFD(pipeFd), cb)
    return retFuture
