from fastapi.testclient import TestClient

from app.main import app

client=TestClient(app)
def test_root():
 r=client.get('/'); assert r.status_code==200
 assert r.json()['message']=='Hello from DevOps Task!'
 assert r.json()['status']=='running'
def test_health(): assert client.get('/health').json()['status']=='healthy'
def test_metrics():
 client.get('/'); r=client.get('/metrics')
 assert r.status_code==200 and 'http_requests_total' in r.text
