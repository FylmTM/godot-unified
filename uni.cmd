@echo off
rem uni, the unified CLI (src/cli/SPEC.md): runs the binary .out\cli\current names. Only when there is none yet, it
rem builds one with the odin on PATH; from then on the binary keeps itself current.
setlocal
set "root=%~dp0"
set "cli=%root%.out\cli"
set "name="
if exist "%cli%\current" set /p name=<"%cli%\current"
if defined name if exist "%cli%\%name%" goto run
where odin >nul 2>nul
if errorlevel 1 (
	echo uni: odin is not on PATH: install the Odin release pinned in pins.cfg ^(README.md, Requirements^) 1>&2
	exit /b 1
)
set "src=%root%src"
if exist "%root%unified\src\cli" set "src=%root%unified\src"
if not exist "%cli%" mkdir "%cli%"
odin build "%root%tools" "-collection:unified=%src%" -o:minimal "-out:%cli%\uni-bootstrap.exe" -export-dependencies:json "-export-dependencies-file:%cli%\uni-bootstrap.deps.json"
if errorlevel 1 exit /b 1
set "name=uni-bootstrap.exe"
:run
"%cli%\%name%" %*
exit /b %errorlevel%
