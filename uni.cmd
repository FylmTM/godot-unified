@echo off
rem uni, the unified CLI (src/cli/SPEC.md, Bootstrap): runs the binary .out\cli\current names, building one first
rem when there is none. Odin is always the release pins.cfg pins, downloaded once into
rem %LOCALAPPDATA%\unified\odin\<tag> (checked against its SHA-256) and put first on PATH.
setlocal
set "root=%~dp0"
set "cli=%root%.out\cli"
set "pins=%root%pins.cfg"
rem a game repo: unified is its submodule
if not exist "%pins%" set "pins=%root%unified\pins.cfg"
set "sec="
set "tag="
set "sha="
rem The [odin] pins, read without starting a process; the loop stops at the next section.
for /f "usebackq eol=; tokens=1,2 delims== " %%a in ("%pins%") do (
	if "%%b"=="" if defined sec goto pinned
	if "%%a"=="[odin]" set "sec=1"
	if defined sec if "%%a"=="tag" set "tag=%%~b"
	if defined sec if "%%a"=="sha256_windows_x64" set "sha=%%~b"
)
:pinned
if not defined tag (
	echo uni: %pins%: no [odin] tag 1>&2
	exit /b 1
)
set "odin=%LOCALAPPDATA%\unified\odin\%tag%"
if exist "%odin%\odin.exe" goto downloaded
call :download
if errorlevel 1 exit /b 1
:downloaded
set "PATH=%odin%;%PATH%"
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

rem The pinned release, downloaded, checked and unpacked into %odin%.
:download
if not defined sha (
	echo uni: %pins%: no [odin] sha256_windows_x64 1>&2
	exit /b 1
)
set "asset=odin-windows-amd64-%tag%.zip"
set "dl=%odin%.tmp-%RANDOM%"
if exist "%dl%" rmdir /s /q "%dl%"
mkdir "%dl%" || exit /b 1
echo uni: downloading Odin %tag% ^(pins.cfg^) once, into %odin% 1>&2
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
rem the archive's one top folder, renamed into place (a virus scanner may still hold a fresh file: one retry)
set "top="
for /d %%d in ("%dl%\*") do if exist "%%d\odin.exe" set "top=%%d"
if defined top if not exist "%odin%" move "%top%" "%odin%" >nul 2>nul
if defined top if not exist "%odin%" (
	ping -n 3 127.0.0.1 >nul
	move "%top%" "%odin%" >nul
)
rmdir /s /q "%dl%"
if not exist "%odin%\odin.exe" (
	echo uni: %asset% holds no odin.exe 1>&2
	exit /b 1
)
exit /b 0
:failed
rmdir /s /q "%dl%"
echo uni: cannot install Odin %tag% 1>&2
exit /b 1
