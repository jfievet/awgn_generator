@echo off
setlocal
pushd "%~dp0"
if errorlevel 1 exit /b 1
echo Compiling fixed-point Box-Muller generator...
gcc -std=c11 -O2 -Wall -Wextra -Wpedantic main.c fixed_math.c prng.c cordic_log.c cordic_trig.c sqrt_fixed.c box_muller.c statistics.c -lm -o box_muller.exe
if errorlevel 1 goto compile_failed
box_muller.exe
set "bm_exit_code=%errorlevel%"
goto finish
:compile_failed
set "bm_exit_code=%errorlevel%"
echo Compilation failed. The program was not launched.
:finish
popd
exit /b %bm_exit_code%
