import http.client
import importlib.util
import json
from pathlib import Path
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location('server', Path(__file__).resolve().parents[1] / 'backend/server.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
TOKEN = 'test-only-01234567890123456789'


class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = module.make_server('127.0.0.1', 0, TOKEN, 'http://localhost')
        cls.port = cls.server.server_port
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()

    def setUp(self):
        self.server.relay = module.Relay(TOKEN)

    def request(self, method, path, data=None, auth=True, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=3)
        h = {'Content-Type': 'application/json'}
        if auth: h['Authorization'] = 'Bearer ' + TOKEN
        h.update(headers or {})
        conn.request(method, path, None if data is None else json.dumps(data), h)
        r = conn.getresponse(); status, response_headers, body = r.status, r.headers, r.read()
        conn.close()
        return status, response_headers, body

    def sample(self, seq=1, **fields):
        sample = dict(session='test-session', seq=seq, steering=.5, angleDeg=31,
                      sampleHz=50, sampleAgeMs=5, rttMs=20, calibrated=True)
        sample.update(fields)
        return sample

    def test_auth_origin_and_static(self):
        self.assertEqual(self.request('GET','/api/state',auth=False)[0],401)
        self.assertEqual(self.request('GET','/')[0],200)
        self.assertEqual(self.request('GET','/../backend/server.py')[0],404)
        self.assertEqual(self.request('POST','/api/steer',self.sample(),headers={'Origin':'https://evil.test'})[0],403)
        self.assertEqual(self.request('POST','/api/login',{'token':'bad'},auth=False)[0],401)

    def test_cookie_readonly(self):
        status, headers, _ = self.request('POST','/api/login',{'token':TOKEN},auth=False)
        self.assertEqual(status,200)
        self.assertIn('HttpOnly', headers['Set-Cookie'])
        cookie = headers['Set-Cookie'].split(';')[0]
        self.assertEqual(self.request('GET','/api/state',auth=False,headers={'Cookie':cookie})[0],200)
        self.assertEqual(self.request('POST','/api/steer',self.sample(),auth=False,headers={'Cookie':cookie})[0],403)

    def test_cookie_expiry_and_unicode_input(self):
        from unittest.mock import patch
        relay = self.server.relay
        cookie = relay.browser_cookie()
        self.assertTrue(relay.cookie_valid(cookie))
        self.assertFalse(relay.cookie_valid(cookie + 'tampered'))
        now = time.time()
        with patch.object(module.time, 'time', return_value=now+28801):
            self.assertFalse(relay.cookie_valid(cookie))
        self.assertEqual(self.request('POST','/api/login',{'token':'无效令牌'},auth=False)[0],401)

    def test_native_browser_ticket_is_single_use_and_readonly(self):
        self.assertEqual(self.request('POST','/api/browser-ticket',{},auth=False)[0],401)
        status, _, body = self.request('POST','/api/browser-ticket',{})
        self.assertEqual(status,200)
        ticket = json.loads(body)['ticket']
        self.assertNotIn(TOKEN,body.decode())
        data = {'ticket':ticket}
        self.assertEqual(self.request('POST','/api/browser-redeem',data,auth=False)[0],403)
        self.assertEqual(self.request('POST','/api/browser-redeem',data,auth=False,headers={'Origin':'https://evil.test'})[0],403)
        status, headers, _ = self.request('POST','/api/browser-redeem',data,auth=False,headers={'Origin':'http://localhost'})
        self.assertEqual(status,200)
        cookie = headers['Set-Cookie'].split(';')[0]
        self.assertIn('HttpOnly',headers['Set-Cookie'])
        self.assertEqual(self.request('GET','/api/state',auth=False,headers={'Cookie':cookie})[0],200)
        self.assertEqual(self.request('POST','/api/steer',self.sample(),auth=False,headers={'Cookie':cookie})[0],403)
        self.assertEqual(self.request('POST','/api/browser-ticket',{},auth=False,headers={'Cookie':cookie})[0],401)
        self.assertEqual(self.request('POST','/api/browser-redeem',data,auth=False,headers={'Origin':'http://localhost'})[0],401)

    def test_browser_ticket_expiry_and_bound(self):
        from unittest.mock import patch
        relay = self.server.relay
        ticket = relay.issue_browser_ticket()
        with patch.object(module.time,'monotonic',return_value=time.monotonic()+61):
            self.assertFalse(relay.redeem_browser_ticket(ticket))
        self.assertFalse(relay.redeem_browser_ticket([]))
        for _ in range(16): self.assertIsNotNone(relay.issue_browser_ticket())
        self.assertIsNone(relay.issue_browser_ticket())

    def test_validation(self):
        for fields in [dict(steering=2),dict(steering=float('nan')),dict(seq=True),
                       dict(sampleAgeMs=251),dict(calibrated=False),dict(session='short')]:
            self.assertEqual(self.request('POST','/api/steer',self.sample(**fields))[0],422)
        self.assertEqual(self.request('POST','/api/steer',['bad'])[0],422)

    def test_order_and_sender_lease(self):
        self.assertEqual(self.request('POST','/api/steer',self.sample(seq=2))[0],200)
        self.assertEqual(self.request('POST','/api/steer',self.sample(seq=1))[0],409)
        self.assertEqual(self.request('POST','/api/steer',self.sample(session='other-session'))[0],409)
        with self.server.relay.lock: self.server.relay.received -= 3
        self.assertEqual(self.request('POST','/api/steer',self.sample(session='other-session'))[0],200)

    def test_sse_and_watchdog(self):
        conn = http.client.HTTPConnection('127.0.0.1',self.port,timeout=3)
        conn.request('GET','/api/events',headers={'Authorization':'Bearer '+TOKEN})
        r = conn.getresponse()
        self.assertEqual(r.status,200)
        initial = json.loads(r.readline().decode().removeprefix('data: ')); r.readline()
        self.assertTrue(initial['stale'])
        self.request('POST','/api/steer',self.sample())
        received = json.loads(r.readline().decode().removeprefix('data: ')); r.readline()
        self.assertEqual(received['sample']['steering'],.5)
        self.assertFalse(received['stale'])
        time.sleep(.6)
        self.assertTrue(self.server.relay.snapshot()['stale'])
        conn.close()

    def test_latest_only(self):
        import queue
        q = queue.Queue(maxsize=1)
        self.server.relay.clients.add(q)
        for seq in range(1,100): self.server.relay.accept(self.sample(seq=seq))
        self.assertEqual(q.qsize(),1)
        self.assertEqual(q.get()['sample']['seq'],99)
        self.server.relay.clients.remove(q)

    def test_lan_source_allowlist(self):
        import ipaddress
        self.server.allowed_network = ipaddress.ip_network('127.0.0.0/8')
        try:
            self.assertTrue(self.server.verify_request(None, ('127.0.0.1', 5000)))
            self.assertFalse(self.server.verify_request(None, ('8.8.8.8', 5000)))
            self.server.allowed_network = (ipaddress.ip_network('2402:f000:2:c801::/64'), ipaddress.ip_network('fe80::/10'))
            self.assertTrue(self.server.verify_request(None, ('2402:f000:2:c801::123', 5000)))
            self.assertTrue(self.server.verify_request(None, ('fe80::abcd%en0', 5000)))
            self.assertFalse(self.server.verify_request(None, ('2001:4860:4860::8888', 5000)))
        finally:
            del self.server.allowed_network


if __name__ == '__main__': unittest.main()
