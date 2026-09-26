from cryptography.fernet import Fernet, InvalidToken
from .config import settings

def _fernet() -> Fernet:
    if not settings.encryption_key:
        raise RuntimeError('CTRADER_ENCRYPTION_KEY_NOT_CONFIGURED')
    return Fernet(settings.encryption_key.encode('ascii'))

def encrypt_secret(value: str) -> str:
    return _fernet().encrypt(value.encode('utf-8')).decode('ascii')

def decrypt_secret(value: str) -> str:
    try:
        return _fernet().decrypt(value.encode('ascii')).decode('utf-8')
    except InvalidToken as exc:
        raise RuntimeError('CTRADER_TOKEN_DECRYPT_FAILED') from exc
