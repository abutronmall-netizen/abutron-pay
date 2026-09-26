from abutron.security import hash_password,verify_password

def test_password_hashing():
    h=hash_password('StrongPassword123!')
    assert h!='StrongPassword123!'
    assert verify_password('StrongPassword123!',h)
    assert not verify_password('wrong-password',h)
