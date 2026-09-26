from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    env: str = "production"
    host: str = "127.0.0.1"
    port: int = 8088
    api_token: str = "CHANGE_ME_LONG_RANDOM_TOKEN"
    jwt_secret: str = "CHANGE_ME_JWT_SECRET_AT_LEAST_32_CHARS"
    core_mode: str = "FUSION"
    execution_enabled: bool = False
    decision_db: str = "./data/abutron_decisions.db"
    platform_db_url: str = "sqlite:///./data/abutron_platform.db"
    worker_interval_seconds: int = 30
    symbols: str = "XAUUSD,BTCUSD,EURUSD,GBPUSD,USDJPY,US100,US30,SP500,GER40,USOIL"

    kronos_repo: str = "./vendor/Kronos"
    kronos_model: str = "NeoQuasar/Kronos-small"
    kronos_tokenizer: str = "NeoQuasar/Kronos-Tokenizer-base"
    kronos_device: str = "auto"
    kronos_max_context: int = 512
    kronos_pred_len: int = 12
    kronos_sample_count: int = 3

    min_confidence_flipper: float = 68
    min_confidence_scalper: float = 72
    min_confidence_master: float = 78
    flipper_risk_pct: float = 0.50
    scalper_risk_pct: float = 0.40
    master_risk_pct: float = 0.35
    max_market_age_seconds: int = 120
    max_signal_age_seconds: int = 90
    max_daily_loss_pct: float = 3.0
    max_open_risk_pct: float = 2.0
    max_spread_points: float = 500
    max_positions_per_symbol: int = 4
    emergency_drawdown_pct: float = 8.0

    mt5_url: str = "http://127.0.0.1:8090"
    mt5_token: str = "CHANGE_ME_DIFFERENT_LONG_RANDOM_TOKEN"

    enforce_platform_license: bool = True
    admin_bootstrap_email: str = "admin@localhost"
    admin_bootstrap_password: str = "CHANGE_ME_ADMIN_PASSWORD"

    model_config = SettingsConfigDict(env_file=".env", env_prefix="ABUTRON_", extra="ignore")

    @property
    def symbol_list(self):
        return [x.strip().upper() for x in self.symbols.split(",") if x.strip()]

settings = Settings()
