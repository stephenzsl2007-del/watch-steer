#!/usr/bin/env python3
"""WatchSteer: dependency-free, single-process HTTP ingest + SSE relay."""
import argparse
import hashlib
import hmac
import ipaddress
import json
import math
import os
import queue
import re
import secrets
import socket
import ssl
import threading
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

WEB = Path(os.environ.get('WATCHSTEER_WEB_ROOT', str(Path(__file__).resolve().parents[1] / 'web')))
STALE_MS = 500


def equal_secret(a, b):
    return hmac.compare_digest(a.encode('utf-8'), b.encode('utf-8'))


class Relay:
    def __init__(self, token):
        self.token = token
        self.lock = threading.Lock()
        self.clients = set()
        self.last = None
        self.received = 0.0
        self.rate_start = time.monotonic()
        self.rate_count = 0
        self.ingest_hz = 0.0
        self.browser_tickets = {}

    def issue_browser_ticket(self):
        with self.lock:
            now = time.monotonic()
            self.browser_tickets = {k: v for k, v in self.browser_tickets.items() if v > now}
            if len(self.browser_tickets) >= 16:
                return None
            ticket = secrets.token_urlsafe(24)
            self.browser_tickets[ticket] = now + 60
            return ticket

    def redeem_browser_ticket(self, ticket):
        if not isinstance(ticket, str) or not re.fullmatch(r'[A-Za-z0-9_-]{32}', ticket):
            return False
        with self.lock:
            expires = self.browser_tickets.pop(ticket, 0)
            return expires > time.monotonic()

    def browser_cookie(self):
        expires = str(int(time.time()) + 8 * 3600)
        signature = hmac.new(self.token.encode(), ('WatchSteer browser v1:' + expires).encode(), hashlib.sha256).hexdigest()
        return expires + ':' + signature

    def cookie_valid(self, value):
        try:
            expires, signature = value.split(':', 1)
            if not expires.isascii() or not expires.isdigit() or int(expires) <= time.time():
                return False
            expected = hmac.new(self.token.encode(), ('WatchSteer browser v1:' + expires).encode(), hashlib.sha256).hexdigest()
            return equal_secret(signature, expected)
        except (ValueError, OverflowError):
            return False

    def snapshot(self):
        with self.lock:
            return self._snapshot()

    def _snapshot(self):
        age = (time.monotonic() - self.received) * 1000 if self.last else None
        return {'type': 'state', 'sample': self.last, 'serverAgeMs': age,
                'stale': age is None or age > STALE_MS,
                'ingestHz': self.ingest_hz, 'staleAfterMs': STALE_MS}

    def accept(self, sample):
        with self.lock:
            now = time.monotonic()
            if self.last:
                same = self.last['session'] == sample['session']
                if same and sample['seq'] <= self.last['seq']:
                    return False, 'out_of_order'
                if not same and now - self.received < 2:
                    return False, 'another_sender_active'
            self.last, self.received = sample, now
            self.rate_count += 1
            if now - self.rate_start >= 1:
                self.ingest_hz = self.rate_count / (now - self.rate_start)
                self.rate_start, self.rate_count = now, 0
            state = self._snapshot()
            for client in self.clients:
                # One latest value per viewer: never accumulate old steering.
                if client.full():
                    try:
                        client.get_nowait()
                    except queue.Empty:
                        pass
                client.put_nowait(state)
            return True, None


def validate(value):
    if not isinstance(value, dict):
        raise ValueError('expected object')
    session = value.get('session')
    if not isinstance(session, str) or not re.fullmatch(r'[A-Za-z0-9-]{8,64}', session):
        raise ValueError('invalid session')
    seq = value.get('seq')
    if type(seq) is not int or not 0 <= seq <= 2**53 - 1:
        raise ValueError('invalid seq')
    for key, lower, upper in [('steering', -1, 1), ('angleDeg', -180, 180),
                              ('sampleHz', 0, 250), ('sampleAgeMs', 0, 250),
                              ('rttMs', 0, 60000)]:
        v = value.get(key)
        if type(v) not in (float, int) or not math.isfinite(v) or not lower <= v <= upper:
            raise ValueError('invalid ' + key)
    if type(value.get('calibrated')) is not bool:
        raise ValueError('invalid calibrated')
    if not value['calibrated'] and value['steering'] != 0:
        raise ValueError('uncalibrated must be neutral')
    return {k: value[k] for k in ('session', 'seq', 'steering', 'angleDeg',
                                 'sampleHz', 'sampleAgeMs', 'rttMs', 'calibrated')}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def verify_request(self, request, client_address):
        network = getattr(self, 'allowed_network', None)
        if network is None: return True
        address = ipaddress.ip_address(client_address[0].split('%')[0])
        networks = network if isinstance(network, tuple) else (network,)
        return any(address in subnet for subnet in networks)


class ServerV6(Server):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # Tokens, cookies, and motion values never enter access logs.

    def headers_common(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")

    def respond(self, status, data, content_type='application/json', extra=None):
        body = data if isinstance(data, bytes) else json.dumps(data, allow_nan=False).encode()
        self.send_response(status)
        self.headers_common()
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def origin_ok(self):
        # Exact configured origin, no wildcard CORS or trusted forwarded Host.
        origin = self.headers.get('Origin')
        return origin is None or origin == self.server.origin

    def authorized(self):
        bearer = self.headers.get('Authorization', '')
        if equal_secret(bearer, 'Bearer ' + self.server.relay.token):
            return True
        try:
            jar = cookies.SimpleCookie(self.headers.get('Cookie', ''))
            c = jar.get('watchsteer')
            return c is not None and self.server.relay.cookie_valid(c.value)
        except cookies.CookieError:
            return False

    def read_json(self):
        self.connection.settimeout(3)
        if self.headers.get('Transfer-Encoding'):
            raise ValueError('chunked requests unsupported')
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 2048:
            raise ValueError('body must be 1..2048 bytes')
        if self.headers.get_content_type() != 'application/json':
            raise ValueError('use application/json')
        return json.loads(self.rfile.read(size))

    def login_browser(self):
        secure = '; Secure' if self.server.origin.startswith('https:') else ''
        cookie = 'watchsteer=' + self.server.relay.browser_cookie() + '; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800' + secure
        return self.respond(200, {'ok': True}, extra={'Set-Cookie': cookie})

    def do_POST(self):
        if not self.origin_ok():
            self.close_connection = True
            return self.respond(403, {'error': 'origin_denied'})
        path = urlsplit(self.path).path
        try:
            value = self.read_json()
        except (ValueError, TimeoutError, OSError):
            self.close_connection = True
            return self.respond(400, {'error': 'invalid_json_or_size'})
        if path in ('/api/browser-ticket', '/api/browser-redeem'):
            if not ipaddress.ip_address(self.client_address[0].split('%')[0]).is_loopback:
                return self.respond(403, {'error': 'local_browser_only'})
            if path == '/api/browser-ticket':
                if not equal_secret(self.headers.get('Authorization', ''), 'Bearer ' + self.server.relay.token):
                    return self.respond(401, {'error': 'bearer_required'})
                ticket = self.server.relay.issue_browser_ticket()
                return self.respond(200 if ticket else 429, {'ticket': ticket, 'expiresIn': 60})
            if self.headers.get('Origin') != self.server.origin:
                return self.respond(403, {'error': 'origin_required'})
            if not isinstance(value, dict) or not self.server.relay.redeem_browser_ticket(value.get('ticket')):
                return self.respond(401, {'error': 'invalid_or_expired_ticket'})
            return self.login_browser()
        if path == '/api/login':
            token = value.get('token', '') if isinstance(value, dict) else ''
            if not isinstance(token, str) or not equal_secret(token, self.server.relay.token):
                return self.respond(401, {'error': 'bad_token'})
            return self.login_browser()
        if not self.authorized():
            return self.respond(401, {'error': 'unauthorized'})
        if path != '/api/steer':
            return self.respond(404, {'error': 'not_found'})
        # Only native bearer holders may publish; browser cookie is read-only.
        if not equal_secret(self.headers.get('Authorization', ''), 'Bearer ' + self.server.relay.token):
            return self.respond(403, {'error': 'bearer_required'})
        try:
            sample = validate(value)
        except ValueError as e:
            return self.respond(422, {'error': str(e)})
        accepted, error = self.server.relay.accept(sample)
        return self.respond(200 if accepted else 409, {'ok': accepted, 'seq': sample['seq'], 'error': error})

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/healthz':
            return self.respond(200, {'ok': True})
        if path in ('/api/state', '/api/ping', '/api/events'):
            if not self.origin_ok() or not self.authorized():
                return self.respond(401, {'error': 'unauthorized'})
            if path == '/api/ping':
                return self.respond(200, {'ok': True})
            if path == '/api/state':
                return self.respond(200, self.server.relay.snapshot())
            return self.events()
        files = {'/': ('index.html', 'text/html; charset=utf-8'),
                 '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
                 '/brand/mark.svg': ('brand/mark.svg', 'image/svg+xml'),
                 '/brand/app-icon.svg': ('brand/app-icon.svg', 'image/svg+xml'),
                 '/style.css': ('style.css', 'text/css; charset=utf-8')}
        if path not in files:
            return self.respond(404, {'error': 'not_found'})
        name, mime = files[path]
        self.respond(200, (WEB / name).read_bytes(), mime)

    def events(self):
        relay = self.server.relay
        client = queue.Queue(maxsize=1)
        with relay.lock:
            if len(relay.clients) >= 8:
                return self.respond(503, {'error': 'too_many_viewers'})
            relay.clients.add(client)
            initial = relay._snapshot()
        try:
            self.connection.settimeout(3)
            self.send_response(200)
            self.headers_common()
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('X-Accel-Buffering', 'no')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            state = initial
            while True:
                if not self.authorized():
                    break
                self.wfile.write(('data: ' + json.dumps(state, allow_nan=False) + '\n\n').encode())
                self.wfile.flush()
                try:
                    state = client.get(timeout=0.25)
                except queue.Empty:
                    state = relay.snapshot()  # Watchdog updates even without samples.
        except (OSError, TimeoutError):
            pass
        finally:
            with relay.lock:
                relay.clients.discard(client)


def make_server(host, port, token, origin):
    server = (ServerV6 if ":" in host else Server)((host, port), Handler)
    server.relay = Relay(token)
    server.origin = origin
    return server


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--host', default='127.0.0.1')
    p.add_argument('--port', default=8765, type=int)
    p.add_argument('--origin', default='http://127.0.0.1:8765', help='exact browser origin, e.g. https://steer.example.com')
    p.add_argument('--cert')
    p.add_argument('--key')
    p.add_argument('--lan-host', help='optional explicit interface IP for local HTTPS ingest')
    p.add_argument('--lan-port', type=int, default=8766)
    p.add_argument('--lan-network', help='allowed source CIDR for that LAN listener')
    p.add_argument('--lan-cert')
    p.add_argument('--lan-key')
    p.add_argument('--lan-ipv6-network', help='optional allowed local IPv6 source CIDR')
    args = p.parse_args()
    token = os.environ.get('WATCHSTEER_TOKEN') or secrets.token_urlsafe(24)
    if len(token) < 24 or not token.isascii():
        p.error('WATCHSTEER_TOKEN must contain at least 24 ASCII characters')
    if bool(args.cert) != bool(args.key):
        p.error('--cert and --key must be supplied together')
    server = make_server(args.host, args.port, token, args.origin.rstrip('/'))
    lan = None
    lan6 = None
    if args.lan_host:
        if not all((args.lan_cert, args.lan_key, args.lan_network)):
            p.error('LAN listener requires --lan-cert, --lan-key and --lan-network')
        allowed = ipaddress.ip_network(args.lan_network, strict=False)
        if ipaddress.ip_address(args.lan_host) not in allowed:
            p.error('LAN interface must be within --lan-network')
        lan = make_server(args.lan_host, args.lan_port, token, args.origin.rstrip('/'))
        lan.relay = server.relay
        lan.allowed_network = allowed
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.lan_cert, args.lan_key)
        lan.socket = context.wrap_socket(lan.socket, server_side=True)
        threading.Thread(target=lan.serve_forever, daemon=True).start()
        print(f'LAN HTTPS active on {args.lan_host}:{args.lan_port}, source allowlist {allowed}', flush=True)
        if args.lan_ipv6_network:
            lan6 = make_server('::', args.lan_port, token, args.origin.rstrip('/'))
            lan6.relay = server.relay
            lan6.allowed_network = (ipaddress.ip_network(args.lan_ipv6_network, strict=False),
                                    ipaddress.ip_network('fe80::/10'), ipaddress.ip_network('::1/128'))
            lan6.socket = context.wrap_socket(lan6.socket, server_side=True)
            threading.Thread(target=lan6.serve_forever, daemon=True).start()
            print('LAN IPv6 HTTPS active, sources restricted to configured prefix and link-local', flush=True)
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print('WatchSteer listening at ' + args.origin, flush=True)
    print('Pairing token (enter on watch and browser): ' + token, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if lan6:
            lan6.shutdown(); lan6.server_close()
        if lan:
            lan.shutdown()
            lan.server_close()


if __name__ == '__main__':
    main()
