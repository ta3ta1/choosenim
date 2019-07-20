import os, strutils, osproc, times

import nimblepkg/[version, cli, tools]
import nimblepkg/common as nimble_common

import cliparams, download, utils, common, switcher, telemetry

proc buildFromCSources(params: CliParams) =
  when defined(windows):
    let arch = getGccArch(params)
    if arch == 32:
      doCmdRaw("build.bat")
    elif arch == 64:
      doCmdRaw("build64.bat")
  else:
    doCmdRaw("sh build.sh")

proc buildCompiler(params: CliParams) =
  ## Assumes that CWD contains the compiler (``build`` should have changed it).
  let binDir = getCurrentDir() / "bin"
  if fileExists(binDir / "nim".addFileExt(ExeExt)):
    display("Compiler: ", "Already built", priority = HighPriority)
    return

  if fileExists(getCurrentDir() / "build.sh"):
    buildFromCSources(params)
  else:
    display("Warning:", "Building from latest C sources. They may not be " &
                        "compatible with the Nim version you have chosen to " &
                        "install.", Warning, HighPriority)
    let path = downloadCSources(params)
    let extractDir = getCurrentDir() / "csources"
    extract(path, extractDir)

    display("Building", "C sources", priority = HighPriority)
    setCurrentDir(extractDir) # cd csources
    buildFromCSources(params) # sh build.sh
    setCurrentDir(extractDir.parentDir()) # cd ..
    when defined(windows):
      display("Building", "koch", priority = HighPriority)
      doCmdRaw("bin/nim.exe c koch")
      display("Building", "Nim", priority = HighPriority)
      doCmdRaw("koch.exe boot -d:release")
    else:
      display("Building", "koch", priority = HighPriority)
      doCmdRaw("./bin/nim c koch")
      display("Building", "Nim", priority = HighPriority)
      doCmdRaw("./koch boot -d:release")

  if not fileExists(binDir / "nim".addFileExt(ExeExt)):
    raise newException(ChooseNimError, "Nim binary is missing. Build failed.")

proc buildTools() =
  ## Assumes that CWD contains the compiler.
  let binDir = getCurrentDir() / "bin"
  # TODO: I guess we should check for the other tools too?
  if fileExists(binDir / "nimble".addFileExt(ExeExt)):
    display("Tools: ", "Already built", priority = HighPriority)
    return

  let msg = "tools (nimble, nimgrep, nimpretty, nimsuggest)"
  display("Building", msg, priority = HighPriority)
  if fileExists(getCurrentDir() / "build.sh"):
    when defined(windows):
      doCmdRaw("bin/nim.exe c koch")
      doCmdRaw("koch.exe tools -d:release")
    else:
      doCmdRaw("./bin/nim c koch")
      doCmdRaw("./koch tools -d:release")
  else:
    when defined(windows):
      doCmdRaw("koch.exe tools -d:release")
    else:
      doCmdRaw("./koch tools -d:release")

proc replaceGccPathForWindows(mingwDir: string) =
  let cfg = getCurrentDir() / "config" / "nim.cfg"
  if not fileExists(cfg):
    return

  var buffer = ""
  for line in cfg.lines:
    if line.contains("#gcc.path"):
      let newLine = line
        .replace("#gcc.path", "gcc.path")
        .replace(r"$nim\dist\mingw\bin", mingwDir)
      buffer.add(newLine & '\x0D' & '\x0A')
    else:
      buffer.add(line & '\x0D' & '\x0A')
  writeFile(cfg, buffer)

proc build*(extractDir: string, version: Version, params: CliParams) =
  # Report telemetry.
  report(initEvent(BuildEvent), params)
  let startTime = epochTime()

  let currentDir = getCurrentDir()
  setCurrentDir(extractDir)
  # Add MingW bin dir to PATH so that `build.bat` script can find gcc.
  let pathEnv = getEnv("PATH")
  when defined(windows):
    if not isDefaultCCInPath(params) and dirExists(params.getMingwBin()):
      putEnv("PATH", params.getMingwBin() & PathSep & pathEnv)
      # modify config\nim.cfg
      replaceGccPathForWindows(params.getMingwBin())
  defer:
    setCurrentDir(currentDir)
    putEnv("PATH", pathEnv)

  display("Building", "Nim " & $version, priority = HighPriority)

  var success = false
  try:
    buildCompiler(params)
    buildTools()
    success = true
  except NimbleError as exc:
    # Display error and output from build separately.
    let (error, hint) = getOutputInfo(exc)
    display("Exception:", error, Error, HighPriority)
    let newError = newException(ChooseNimError, "Build failed")
    newError.hint = hint
    raise newError
  finally:
    if success:
      # Report telemetry.
      report(initEvent(BuildSuccessEvent), params)
      report(initTiming(BuildTime, $version, startTime, $LabelSuccess), params)

    if not success:
      # Perform clean up.
      display("Cleaning", "failed build", priority = HighPriority)
      # TODO: Seems I cannot use a try inside a finally?
      # Getting `no exception to reraise` on the following line.
      try:
        removeDir(extractDir)
      except Exception as exc:
        display("Warning:", "Cleaning failed: " & exc.msg, Warning)

      # Report telemetry.
      report(initEvent(BuildFailureEvent), params)
      report(initTiming(BuildTime, $version, startTime, $LabelFailure), params)
