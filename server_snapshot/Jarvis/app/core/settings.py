from pydantic_settings import BaseSettings,SettingsConfigDict
class Settings(BaseSettings):
 model_config=SettingsConfigDict(env_file=".env",extra="ignore")
 jarvis_mode:str="OBSERVE_ONLY"; jarvis_api_token:str="CHANGE_ME"
 kronos_base_url:str="http://127.0.0.1:8001"; kronos_health_path:str="/health"; kronos_ready_path:str="/ready"
 kronos_prod_path:str=r"C:\Abutron\TradingPlatformV4"
 kronos_dev_path:str=r"C:\Abutron\Kronos-Dev"
 kronos_test_path:str=r"C:\Abutron\Kronos-Test"
 kronos_service_name:str="CHANGE_ME"; mt5_process_name:str="terminal64.exe"
 jarvis_state_db:str=r"C:\Abutron\Jarvis\data\jarvis.db"; jarvis_audit_log:str=r"C:\Abutron\Jarvis\logs\audit.jsonl"
 hermes_exe:str="hermes"; hermes_whatsapp_target:str="whatsapp_cloud"
 hermes_api_base_url:str="http://127.0.0.1:8642"
 hermes_api_key_file:str=r"C:\ProgramData\Abutron\Jarvis\secrets\hermes_api_key"
 hermes_api_model:str="hermes-agent"
 hermes_api_timeout_seconds:float=120.0
 hermes_prompt_max_chars:int=8000
 whatsapp_calling_enabled:bool=False
settings=Settings()
