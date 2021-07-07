# Package

version       = "0.1.0"
author        = "Yuriy Glukhov"
description   = "Awaitable threadpool"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["tests"]

# Dependencies

requires "nim >= 1.4.2"
if getEnv("ASYNCTHREADPOOLS_WITH_CHRONOS") == "YES":
  requires "chronos"
