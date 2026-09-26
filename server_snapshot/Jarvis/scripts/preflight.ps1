$R="C:\Abutron\Jarvis";Set-Location $R
& "$R\.venv\Scripts\python.exe" --version
git --version
hermes --version
hermes doctor
& "$R\.venv\Scripts\python.exe" -m pytest -q
& "$R\.venv\Scripts\python.exe" -c "from app.api.main import app;print(app.title,app.version)"
