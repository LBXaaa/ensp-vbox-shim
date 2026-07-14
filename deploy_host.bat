@echo off
chcp 65001 >nul
REM Host deployment script - must run as Administrator
REM Deploys fixed VBox52.dll + restores original NGFW_Plugin.dll

set ENSP=C:\Program Files\Huawei\eNSP
set SRC=f:\各种项目\逆向ensp\ensp-vbox-shim\build\VBox52.dll

echo === Stopping eNSP processes ===
taskkill /F /IM eNSP_Client.exe 2>nul
taskkill /F /IM eNSP_VBoxServer.exe 2>nul
taskkill /F /IM VBoxSVC.exe 2>nul
taskkill /F /IM VBoxManage.exe 2>nul
taskkill /F /IM VBoxHeadless.exe 2>nul
timeout /t 2 /nobreak >nul

echo === Restoring original NGFW_Plugin.dll (critical: patch version causes error 45 crash) ===
copy /Y "%ENSP%\plugin\ngfw\NGFW_Plugin.dll.bak" "%ENSP%\plugin\ngfw\NGFW_Plugin.dll"
if errorlevel 1 (echo FAILED to restore NGFW_Plugin.dll & pause & exit /b 1)
echo NGFW_Plugin.dll restored to original

echo === Deploying new VBox52.dll to 4 locations ===
copy /Y "%SRC%" "%ENSP%\VBox52.dll"
copy /Y "%SRC%" "%ENSP%\tools\VBox52.dll"
copy /Y "%SRC%" "%ENSP%\vboxserver\VBox52.dll"
copy /Y "%SRC%" "%ENSP%\plugin\ngfw\tools\ngfw\VBox52.dll"
if errorlevel 1 (echo FAILED to copy VBox52.dll & pause & exit /b 1)

echo === Verifying hashes ===
certutil -hashfile "%ENSP%\VBox52.dll" SHA256
certutil -hashfile "%ENSP%\tools\VBox52.dll" SHA256
certutil -hashfile "%ENSP%\vboxserver\VBox52.dll" SHA256
certutil -hashfile "%ENSP%\plugin\ngfw\tools\ngfw\VBox52.dll" SHA256
echo Expected: 29CB4D29F8F55F093E39D78F55D34DD3227F465429B19062CEFFDE6A6D07F60B

echo === Clearing logs ===
del /Q "C:\ProgramData\ensp-vbox-shim\*.log" 2>nul

echo.
echo === Deployment complete ===
echo Now start eNSP, create topology with USG6000V, and start FW1.
echo Check C:\ProgramData\ensp-vbox-shim\vbox52_proxy.log for shim activity.
pause
