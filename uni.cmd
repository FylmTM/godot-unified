@echo off
rem uni, the unified CLI (src/cli/SPEC.md, Bootstrap): runs the binary .out\cli\current names, building one first
rem when there is none. Odin is the release pins.cfg pins: the odin on PATH when it is that commit, else that
rem release, downloaded once into %LOCALAPPDATA%\unified\odin\<tag> (checked against its SHA-256), first on PATH.
setlocal
set "root=%~dp0"
set "cli=%root%.out\cli"
set "pins=%root%pins.cfg"
rem a game repo: unified is its submodule
if not exist "%pins%" set "pins=%root%unified\pins.cfg"
set "sec="
set "tag="
set "commit="
set "sha="
rem The [odin] pins, read without starting a process; the loop stops at the next section.
for /f "usebackq eol=; tokens=1,2 delims== " %%a in ("%pins%") do (
	if "%%b"=="" if defined sec goto pinned
	if "%%a"=="[odin]" set "sec=1"
	if defined sec if "%%a"=="tag" set "tag=%%~b"
	if defined sec if "%%a"=="commit" set "commit=%%~b"
	if defined sec if "%%a"=="sha256_windows_x64" set "sha=%%~b"
)
:pinned
if not defined tag (
	echo uni: %pins%: no [odin] tag 1>&2
	exit /b 1
)
set "odin=%LOCALAPPDATA%\unified\odin\%tag%"
if exist "%odin%\odin.exe" goto downloaded
rem the odin on PATH, found without starting a process
set "found="
for %%x in (odin.exe) do set "found=%%~$PATH:x"
set "ok="
if exist "%cli%\odin-on-path" set /p ok=<"%cli%\odin-on-path"
if "%ok%"=="%commit% %found%" goto odin
call :resolve
if errorlevel 1 exit /b 1
goto odin
:downloaded
set "PATH=%odin%;%PATH%"
:odin
set "name="
if exist "%cli%\current" set /p name=<"%cli%\current"
if defined name if exist "%cli%\%name%" goto run
set "src=%root%src"
if exist "%root%unified\src\cli" set "src=%root%unified\src"
if not exist "%cli%" mkdir "%cli%"
odin build "%root%tools" "-collection:unified=%src%" -o:minimal "-out:%cli%\uni-bootstrap.exe" -export-dependencies:json "-export-dependencies-file:%cli%\uni-bootstrap.deps.json"
if errorlevel 1 exit /b 1
set "name=uni-bootstrap.exe"
:run
"%cli%\%name%" %*
exit /b %errorlevel%

rem No download for this tag, and the stamp doesn't name the odin on PATH: that odin if it reports the pinned commit
rem ("odin version <tag>:<commit>"; stamped), else the pinned release, downloaded.
:resolve
set "have="
set "hash="
if defined found for /f "tokens=3" %%v in ('odin version 2^>nul') do set "have=%%v"
if defined have for /f "tokens=2 delims=:" %%h in ("%have%") do set "hash=%%h"
if defined hash echo %commit%| findstr /b /l /c:"%hash%" >nul && goto on_path
if not defined sha (
	echo uni: %pins%: no [odin] sha256_windows_x64 1>&2
	exit /b 1
)
set "asset=odin-windows-amd64-%tag%.zip"
set "dl=%odin%.tmp-%RANDOM%"
if exist "%dl%" rmdir /s /q "%dl%"
mkdir "%dl%" || exit /b 1
echo uni: no odin on PATH is the pinned %tag% ^(pins.cfg^): downloading that release once, into %odin% 1>&2
"%SystemRoot%\System32\curl.exe" -fL --retry 3 --progress-bar -o "%dl%\%asset%" "https://github.com/odin-lang/Odin/releases/download/%tag%/%asset%"
if errorlevel 1 goto failed
set "got="
for /f "skip=1 delims=" %%h in ('certutil -hashfile "%dl%\%asset%" SHA256') do if not defined got set "got=%%h"
rem older Windows print the hash with spaces
if defined got set "got=%got: =%"
if /i not "%got%"=="%sha%" (
	echo uni: %asset%: SHA-256 %got%, pinned %sha% 1>&2
	goto failed
)
rem the system tar (bsdtar) reads zip; Git's GNU tar on PATH does not
"%SystemRoot%\System32\tar.exe" -xf "%dl%\%asset%" -C "%dl%"
if errorlevel 1 goto failed
rem the archive's one top folder
for /d %%d in ("%dl%\*") do if exist "%%d\odin.exe" if not exist "%odin%" move "%%d" "%odin%" >nul
rmdir /s /q "%dl%"
if not exist "%odin%\odin.exe" (
	echo uni: %asset% holds no odin.exe 1>&2
	exit /b 1
)
set "PATH=%odin%;%PATH%"
exit /b 0
:on_path
if not exist "%cli%" mkdir "%cli%"
>"%cli%\odin-on-path" echo %commit% %found%
exit /b 0
:failed
rmdir /s /q "%dl%"
echo uni: cannot install Odin %tag% 1>&2
exit /b 1
