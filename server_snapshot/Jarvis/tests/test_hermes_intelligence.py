import pytest

from app.core.policy import Decision, PolicyEngine
from app.integrations import hermes_intelligence as hi


def test_hermes_policy_is_explicitly_allowed():
    policy = PolicyEngine()

    assert (
        policy.decide("query_hermes_intelligence")
        == Decision.ALLOW
    )


def test_hermes_key_file(monkeypatch, tmp_path):
    secret = tmp_path / "hermes_api_key"
    secret.write_text(
        "a" * 64,
        encoding="ascii",
    )

    monkeypatch.setattr(
        hi.settings,
        "hermes_api_key_file",
        str(secret),
    )

    assert hi._read_api_key() == "a" * 64


def test_hermes_rejects_non_loopback(monkeypatch):
    monkeypatch.setattr(
        hi.settings,
        "hermes_api_base_url",
        "http://192.168.1.20:8642",
    )

    with pytest.raises(
        hi.HermesIntelligenceError,
        match="HERMES_API_NOT_LOOPBACK",
    ):
        hi._base_url()