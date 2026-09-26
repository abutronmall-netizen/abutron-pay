$R="C:\Abutron\Jarvis";Set-Location $R;& "$R\.venv\Scripts\python.exe" -m uvicorn app.api.main:app --host 127.0.0.1 --port 8787
