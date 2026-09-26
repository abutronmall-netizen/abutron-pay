from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', env_prefix='CTRADER_', extra='ignore')
    host: str = '127.0.0.1'
    port: int = 8091
    public_base_url: str = 'https://api.abutronfx.online'
    redirect_uri: str = 'https://api.abutronfx.online/v1/ctrader/oauth/callback'
    oauth_scope: str = 'trading'
    oauth_authorize_url: str = 'https://id.ctrader.com/my/settings/openapi/grantingaccess/'
    oauth_token_url: str = 'https://openapi.ctrader.com/apps/token'
    client_id: str = ''
    client_secret: str = ''
    internal_api_key: str = 'CHANGE_ME_GENERATED_BY_INSTALLER'
    encryption_key: str = ''
    database_path: str = './data/ctrader_gateway.db'
    log_dir: str = './logs'
    max_command_age_seconds: int = 30
    worker_timeout_seconds: int = 15
    link_ticket_ttl_seconds: int = 600
    allowed_broker_markers: str = 'ICMARKETS,RAWTRADING'
    enable_demo_connection: bool = True
    enable_live_connection: bool = False
    demo_execution_enabled: bool = False
    live_money_authorized: bool = False
    kill_switch: bool = True
    step21c_demo_lifecycle_enabled: bool = False
    step21c_require_real_oauth_pass: bool = True
    step21c_spot_max_age_seconds: int = 10
    step21c_reconcile_timeout_seconds: int = 15
    step21d_read_retry_enabled: bool = True
    step21d_worker_restart_wait_seconds: int = 12
    step21d_order_history_lookback_seconds: int = 86400
    step21d_recovery_enabled: bool = True

    @property
    def credentials_configured(self) -> bool:
        return bool(self.client_id.strip() and self.client_secret.strip())

    @property
    def secrets_configured(self) -> bool:
        return bool(self.encryption_key.strip() and self.internal_api_key and not self.internal_api_key.startswith('CHANGE_ME'))

settings = Settings()
Path(settings.log_dir).mkdir(parents=True, exist_ok=True)
