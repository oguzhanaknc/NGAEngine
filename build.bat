@echo off

echo [INFO] Sandbox klasorune giriliyor...
pushd Sandbox

echo [INFO] Shaderlar derleniyor...
call glslc shaders/triangle.vert -o shaders/triangle.vert.spv
if %errorlevel% neq 0 (
    echo [HATA] Vertex Shader derlenemedi!
    popd
    exit /b %errorlevel%
)

call glslc shaders/triangle.frag -o shaders/triangle.frag.spv
if %errorlevel% neq 0 (
    echo [HATA] Fragment Shader derlenemedi!
    popd
    exit /b %errorlevel%
)

echo [INFO] Odin calistiriliyor...
odin run . -collection:NGAEngine=../NGAEngine

echo [INFO] Islem tamamlandi, ana klasore donuluyor.
popd
