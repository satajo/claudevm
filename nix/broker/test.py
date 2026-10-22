"""Behaviour test of claudevm-broker against a fake upstream on loopback.

Usage: claudevm-broker-test BROKER_EXECUTABLE
"""

import faulthandler
import http.client
import http.server
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

GUEST_KEY = 'sk-ant-api03-claudevm-session-key'
TOKEN = 'sk-ant-oat01-host-token'
OAUTH_BETA = 'oauth-2025-04-20'
MAX_BODY_SIZE = 64 * 1024 * 1024
TIMEOUT = 20.0
# The fake upstream holds back the rest of a gated stream for at most this
# long; it is shorter than TIMEOUT so that a broker that buffers fails an
# assertion instead of timing out the client.
GATE_TIMEOUT = 5.0
# A test run that takes longer than this has hung.
WATCHDOG_SECONDS = 300
SSE_EVENTS = [b'event: ping\ndata: {"n": %d}\n\n' % n for n in range(6)]
TRUNCATED_BODY = b'the first part'

BROKER_EXECUTABLE = ''
# Holds every file of the run, so that broker logs outlast the tests.
WORK_DIRECTORY = Path()
broker_logs: list[Path] = []


def new_directory() -> Path:
    return Path(tempfile.mkdtemp(dir=WORK_DIRECTORY))


def error_body(error_type: str, message: str) -> object:
    return {'type': 'error', 'error': {'type': error_type, 'message': message}}


MISSING_KEY_BODY = error_body(
    'authentication_error',
    'claudevm broker: request did not carry the session key')


@dataclass(frozen=True)
class Received:
    method: str
    target: str
    headers: list[tuple[str, str]]
    body: bytes

    def header(self, name: str) -> list[str]:
        return [value for key, value in self.headers
                if key.lower() == name.lower()]


class FakeUpstream(http.server.ThreadingHTTPServer):
    def __init__(self) -> None:
        super().__init__(('127.0.0.1', 0), FakeUpstreamHandler)
        self.lock = threading.Lock()
        self.received: list[Received] = []
        # When set, the /v1/messages stream sends its first event and then
        # waits for this event before sending the rest.
        self.stream_gate: threading.Event | None = None
        self.gate_released: list[bool] = []

    @property
    def address(self) -> str:
        return f'127.0.0.1:{self.server_address[1]}'

    def requests(self) -> list[Received]:
        with self.lock:
            return list(self.received)


class FakeUpstreamHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server: FakeUpstream

    def __getattr__(self, name: str) -> Callable[[], None]:
        if name.startswith('do_'):
            return self.respond
        raise AttributeError(name)

    def respond(self) -> None:
        length = int(self.headers.get('content-length', '0'))
        received = Received(self.command, self.path,
                            list(self.headers.items()),
                            self.rfile.read(length))
        with self.server.lock:
            self.server.received.append(received)
        path = self.path.split('?', 1)[0]
        if path == '/v1/messages':
            self.stream_events()
        elif path == '/echo':
            self.send_body(200, 'application/json', json.dumps({
                'headers': received.headers,
                'body': received.body.decode(),
            }).encode())
        elif path == '/status/418':
            self.send_body(418, 'text/plain', b'short and stout')
        elif path == '/truncated/length':
            self.send_response(200)
            self.send_header('content-length', str(len(TRUNCATED_BODY) * 2))
            self.end_headers()
            self.wfile.write(TRUNCATED_BODY)
            self.close_connection = True
        elif path == '/truncated/chunked':
            self.send_response(200)
            self.send_header('transfer-encoding', 'chunked')
            self.end_headers()
            self.wfile.write(
                b'%x\r\n%s\r\n' % (len(TRUNCATED_BODY), TRUNCATED_BODY))
            self.close_connection = True
        else:
            self.send_body(404, 'text/plain', b'not found')

    def send_body(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header('content-type', content_type)
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stream_events(self) -> None:
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.send_header('x-test', 'upstream')
        self.send_header('transfer-encoding', 'chunked')
        self.end_headers()
        gate = self.server.stream_gate
        for index, event in enumerate(SSE_EVENTS):
            if index == 1 and gate is not None:
                released = gate.wait(GATE_TIMEOUT)
                with self.server.lock:
                    self.server.gate_released.append(released)
            self.wfile.write(b'%x\r\n%s\r\n' % (len(event), event))
            self.wfile.flush()
        self.wfile.write(b'0\r\n\r\n')
        self.wfile.flush()

    def log_message(self, format: str, *args: object) -> None:
        pass


class Broker:
    def __init__(self, upstream: str) -> None:
        directory = new_directory()
        key_file = directory / 'guest-key'
        key_file.write_text(GUEST_KEY + '\n')
        self.token_file = directory / 'token'
        self.token_file.write_text(TOKEN + '\n')
        self.port_file = directory / 'broker.port'
        self.log_path = directory / 'broker.log'
        broker_logs.append(self.log_path)
        with self.log_path.open('wb') as log:
            self.process = subprocess.Popen(
                [BROKER_EXECUTABLE,
                 '--port-file', str(self.port_file),
                 '--token-file', str(self.token_file),
                 '--guest-key-file', str(key_file),
                 '--upstream', upstream],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        self.port = self.wait_for_port()

    def wait_for_port(self) -> int:
        deadline = time.monotonic() + TIMEOUT
        while not self.port_file.exists():
            if self.process.poll() is not None:
                raise RuntimeError('the broker exited before writing its '
                                   'port file')
            if time.monotonic() > deadline:
                raise RuntimeError('the broker wrote no port file within '
                                   f'{TIMEOUT} s')
            time.sleep(0.01)
        return int(self.port_file.read_text())

    def stop(self) -> None:
        self.process.terminate()
        self.process.wait(TIMEOUT)

    def connection(self) -> http.client.HTTPConnection:
        return http.client.HTTPConnection('127.0.0.1', self.port,
                                          timeout=TIMEOUT)

    def request(self, method: str, target: str, body: bytes | None = None,
                headers: dict[str, str] | None = None
                ) -> tuple[http.client.HTTPResponse, bytes]:
        connection = self.connection()
        try:
            connection.request(method, target, body, headers or {})
            response = connection.getresponse()
            return response, response.read()
        finally:
            connection.close()

    def raw_exchange(self, request: bytes) -> tuple[int, object]:
        """Sends request bytes as they are and returns the status and the
        JSON body of the reply, which ends with the connection."""
        with socket.create_connection(('127.0.0.1', self.port),
                                      TIMEOUT) as client:
            client.sendall(request)
            reply = b''
            while piece := client.recv(65536):
                reply += piece
        head, _, body = reply.partition(b'\r\n\r\n')
        return int(head.split()[1]), json.loads(body)


class BrokerTest(unittest.TestCase):
    upstream: FakeUpstream
    broker: Broker

    @classmethod
    def setUpClass(cls) -> None:
        cls.upstream = FakeUpstream()
        threading.Thread(target=cls.upstream.serve_forever,
                         daemon=True).start()
        cls.broker = Broker(f'http://{cls.upstream.address}')

    @classmethod
    def tearDownClass(cls) -> None:
        cls.broker.stop()
        cls.upstream.shutdown()
        cls.upstream.server_close()

    def setUp(self) -> None:
        self.upstream.stream_gate = None
        with self.upstream.lock:
            self.upstream.gate_released.clear()
        self.broker.token_file.write_text(TOKEN + '\n')

    def session_headers(self, **extra: str) -> dict[str, str]:
        return {'x-api-key': GUEST_KEY, **extra}

    def last_received(self) -> Received:
        return self.upstream.requests()[-1]

    def test_relays_a_streamed_request_with_the_token_in_place_of_the_key(
            self) -> None:
        body = json.dumps({'model': 'claude', 'stream': True}).encode()
        self.upstream.stream_gate = threading.Event()
        connection = self.broker.connection()
        connection.request('POST', '/v1/messages?beta=true', body, {
            'x-api-key': GUEST_KEY,
            'anthropic-beta': 'claude-code-20250219,effort-2025-11-24',
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
        })
        response = connection.getresponse()
        first = b''
        while len(first) < len(SSE_EVENTS[0]):
            piece = response.read1(65536)
            self.assertTrue(piece, 'the stream should not end before the '
                            'first event arrives')
            first += piece
        self.upstream.stream_gate.set()
        rest = response.read()
        connection.close()

        self.assertEqual(self.upstream.gate_released, [True],
                         'the client should receive the first event while '
                         'the upstream still holds back the rest, because '
                         'the broker streams instead of buffering')
        self.assertEqual(response.status, 200,
                         'the client should get the upstream status 200')
        self.assertEqual(response.getheader('x-test'), 'upstream',
                         'the client should get the upstream headers')
        self.assertEqual(response.getheader('content-type'),
                         'text/event-stream',
                         'the client should get the upstream content type')
        self.assertEqual(first + rest, b''.join(SSE_EVENTS),
                         'the client should get the full upstream body')

        received = self.last_received()
        self.assertEqual(received.method, 'POST',
                         'upstream should receive the client method')
        self.assertEqual(received.target, '/v1/messages?beta=true',
                         'upstream should receive the client path and query')
        self.assertEqual(received.body, body,
                         'upstream should receive the client body')
        self.assertEqual(received.header('content-length'), [str(len(body))],
                         'upstream should receive the body length')
        self.assertEqual(received.header('authorization'),
                         [f'Bearer {TOKEN}'],
                         'upstream should receive the token as a bearer '
                         'credential')
        self.assertEqual(received.header('x-api-key'), [],
                         'upstream should not receive the session key')
        self.assertEqual(
            received.header('anthropic-beta'),
            [f'claude-code-20250219,effort-2025-11-24,{OAUTH_BETA}'],
            'upstream should receive the client betas plus the OAuth beta')
        self.assertEqual(received.header('host'), [self.upstream.address],
                         'upstream should receive its own host as Host')
        self.assertEqual(received.header('anthropic-version'), ['2023-06-01'],
                         'upstream should receive the other client headers')

    def test_adds_the_oauth_beta_exactly_once(self) -> None:
        cases = {
            'no betas': ({}, OAUTH_BETA),
            'other betas': ({'anthropic-beta': 'claude-code-20250219'},
                            f'claude-code-20250219,{OAUTH_BETA}'),
            'the OAuth beta': (
                {'anthropic-beta': f'{OAUTH_BETA},claude-code-20250219'},
                f'{OAUTH_BETA},claude-code-20250219'),
        }
        for case, (headers, expected) in cases.items():
            with self.subTest(case):
                response, _ = self.broker.request(
                    'POST', '/echo', b'{}', self.session_headers(**headers))
                self.assertEqual(response.status, 200,
                                 f'a request with {case} should succeed')
                self.assertEqual(
                    self.last_received().header('anthropic-beta'),
                    [expected],
                    f'a request with {case} should reach upstream with '
                    'the OAuth beta once')

    def test_rejects_unsupported_requests_without_contacting_upstream(
            self) -> None:
        key = f'x-api-key: {GUEST_KEY}\r\n'
        cases = {
            'a wrong session key': (
                'POST /v1/messages HTTP/1.1\r\nx-api-key: wrong\r\n'
                'content-length: 2\r\n\r\n{}',
                401, MISSING_KEY_BODY),
            'no session key': (
                'POST /v1/messages HTTP/1.1\r\ncontent-length: 2\r\n\r\n{}',
                401, MISSING_KEY_BODY),
            'a chunked body': (
                f'POST /v1/messages HTTP/1.1\r\n{key}'
                'transfer-encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n',
                411, error_body(
                    'invalid_request_error',
                    'claudevm broker: send the body with Content-Length')),
            # The body is never sent, so a broker that tried to read it
            # would not answer.
            'a body above the size limit': (
                f'POST /v1/messages HTTP/1.1\r\n{key}'
                f'content-length: {MAX_BODY_SIZE + 1}\r\n\r\n',
                413, error_body(
                    'request_too_large',
                    'claudevm broker: the request body exceeds '
                    f'{MAX_BODY_SIZE} bytes')),
            'a request line that http.server refuses': (
                'GET /a b c HTTP/1.1\r\n\r\n',
                400, error_body('invalid_request_error',
                                'claudevm broker: Bad Request')),
            'HTTP/1.0': (
                f'POST /v1/messages HTTP/1.0\r\n{key}'
                'content-length: 2\r\n\r\n{}',
                505, error_body(
                    'invalid_request_error',
                    'claudevm broker: only HTTP/1.1 is supported')),
        }
        for case, (request, status, body) in cases.items():
            with self.subTest(case):
                before = len(self.upstream.requests())
                self.assertEqual(
                    self.broker.raw_exchange(request.encode()),
                    (status, body),
                    f'a request with {case} should get {status} with the '
                    'Anthropic error shape')
                self.assertEqual(len(self.upstream.requests()), before,
                                 f'a request with {case} should not reach '
                                 'upstream')

    def test_reads_the_token_file_for_every_request(self) -> None:
        self.broker.token_file.unlink()
        before = len(self.upstream.requests())
        response, body = self.broker.request('POST', '/v1/messages', b'{}',
                                             self.session_headers())
        self.assertEqual(response.status, 401,
                         'a request without a stored token should get 401')
        self.assertEqual(json.loads(body), error_body(
            'authentication_error',
            f"claudevm broker: no token at '{self.broker.token_file}' (No "
            "such file or directory); run 'claudevm login' on the host"),
            'the rejection should tell how to store a token')
        self.assertEqual(len(self.upstream.requests()), before,
                         'a request without a stored token should not reach '
                         'upstream')

        self.broker.token_file.write_text(f'  \n {TOKEN}-renewed \t\n\n')
        response, _ = self.broker.request('POST', '/v1/messages', b'{}',
                                          self.session_headers())
        self.assertEqual(response.status, 200,
                         'a request should succeed once a token is stored')
        self.assertEqual(self.last_received().header('authorization'),
                         [f'Bearer {TOKEN}-renewed'],
                         'upstream should receive the stored token without '
                         'surrounding whitespace')

    def test_passes_the_upstream_status_through(self) -> None:
        response, body = self.broker.request('GET', '/status/418',
                                             headers=self.session_headers())
        self.assertEqual(response.status, 418,
                         'the client should get the upstream status')
        self.assertEqual(body, b'short and stout',
                         'the client should get the upstream body')

    def test_ends_the_response_incomplete_when_upstream_ends_early(
            self) -> None:
        for path in ('/truncated/length', '/truncated/chunked'):
            with self.subTest(path):
                connection = self.broker.connection()
                try:
                    connection.request('GET', path,
                                       headers=self.session_headers())
                    response = connection.getresponse()
                    with self.assertRaises(
                            http.client.IncompleteRead,
                            msg='the client should see the body end '
                            'incomplete, not cleanly') as caught:
                        response.read()
                finally:
                    connection.close()
                self.assertEqual(response.status, 200,
                                 'the client should get the upstream status')
                self.assertEqual(caught.exception.partial, TRUNCATED_BODY,
                                 'the client should get the bytes upstream '
                                 'sent')

    def test_answers_502_when_upstream_is_unreachable(self) -> None:
        with socket.socket() as closed:
            # A bound socket that does not listen refuses connections and
            # keeps its port from being reused.
            closed.bind(('127.0.0.1', 0))
            url = f'http://127.0.0.1:{closed.getsockname()[1]}'
            broker = Broker(url)
            try:
                response, body = broker.request(
                    'POST', '/v1/messages', b'{}', self.session_headers())
            finally:
                broker.stop()
        self.assertEqual(response.status, 502,
                         'an unreachable upstream should give 502')
        self.assertEqual(json.loads(body), error_body(
            'api_error',
            f"claudevm broker: cannot reach '{url}': Connection refused"),
            'the 502 should name the unreachable upstream')

    def test_quotes_the_status_line_of_a_malformed_upstream_response(
            self) -> None:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            url = f'http://127.0.0.1:{listener.getsockname()[1]}'

            def answer() -> None:
                connection, _ = listener.accept()
                with connection:
                    connection.recv(65536)
                    connection.sendall(b"HTTP/1.1 2\x1b[31mOK it's\r\n\r\n")

            threading.Thread(target=answer, daemon=True).start()
            broker = Broker(url)
            try:
                response, body = broker.request(
                    'POST', '/v1/messages', b'{}', self.session_headers())
            finally:
                broker.stop()
        self.assertEqual(response.status, 502,
                         'a malformed upstream response should give 502')
        reason = (f"cannot reach '{url}': BadStatusLine "
                  "'HTTP/1.1 2\x1b[31mOK it's'")
        self.assertEqual(json.loads(body),
                         error_body('api_error', f'claudevm broker: {reason}'),
                         'the 502 should quote the status line')
        self.assertIn(f'claudevm-broker: {reason}\n',
                      broker.log_path.read_text(),
                      'the log should quote the status line on one line')

    def test_logs_a_refused_request_line_quoted(self) -> None:
        self.broker.raw_exchange(b'GET /a b \x1b HTTP/1.1\r\n\r\n')
        log = self.broker.log_path.read_text()
        self.assertIn("the malformed request 'GET /a b \x1b HTTP/1.1' -> 400",
                      log, 'the log should quote the refused request line')
        self.assertNotIn('Bad request syntax', log,
                         "the log should not carry http.server's message")

    def test_serves_sequential_requests_on_one_keep_alive_connection(
            self) -> None:
        connection = self.broker.connection()
        try:
            connection.request('POST', '/v1/messages', b'{}',
                               self.session_headers())
            first = connection.getresponse()
            first_body = first.read()
            first_socket = connection.sock
            self.assertIsNotNone(first_socket,
                                 'the connection should stay open after '
                                 'the first response')
            connection.request('GET', '/echo',
                               headers=self.session_headers())
            second = connection.getresponse()
            second.read()
            self.assertIs(connection.sock, first_socket,
                          'the second request should reuse the connection')
        finally:
            connection.close()
        self.assertEqual(first.status, 200,
                         'the first request should succeed')
        self.assertEqual(first_body, b''.join(SSE_EVENTS),
                         'the first response should be complete')
        self.assertEqual(second.status, 200,
                         'the second request should succeed')

    def test_publishes_the_bound_port_and_listens_on_loopback_only(
            self) -> None:
        self.assertEqual(self.broker.port_file.read_text(),
                         f'{self.broker.port}\n',
                         'the port file should hold the port as one line')
        with socket.create_connection(('127.0.0.1', self.broker.port),
                                      TIMEOUT):
            pass
        with socket.socket() as control:
            control.bind(('0.0.0.0', 0))
            control.listen()
            with socket.create_connection(
                    ('127.0.0.2', control.getsockname()[1]), TIMEOUT):
                pass
        with self.assertRaises(ConnectionRefusedError,
                               msg='the broker should not accept '
                               'connections on addresses other than '
                               '127.0.0.1'):
            socket.create_connection(('127.0.0.2', self.broker.port),
                                     TIMEOUT).close()

    def test_forwards_end_to_end_headers_and_drops_credentials(
            self) -> None:
        response, body = self.broker.request('GET', '/echo', headers={
            'x-api-key': GUEST_KEY,
            'authorization': 'Bearer guest-supplied',
            'proxy-authorization': 'Basic guest-supplied',
            'x-custom': 'kept',
        })
        self.assertEqual(response.status, 200, 'the request should succeed')
        received = self.last_received()
        self.assertEqual(received.header('authorization'),
                         [f'Bearer {TOKEN}'],
                         'upstream should receive only the host token')
        self.assertEqual(received.header('proxy-authorization'), [],
                         'upstream should not receive proxy credentials')
        self.assertEqual(received.header('x-custom'), ['kept'],
                         'upstream should receive end-to-end headers')
        self.assertEqual(received.header('content-length'), [],
                         'a bodyless request should reach upstream without '
                         'a body')
        self.assertEqual(json.loads(body)['body'], '',
                         'the client should get the upstream body')

    def test_refuses_to_start_without_usable_arguments(self) -> None:
        directory = new_directory()
        port_file = directory / 'port'
        missing = directory / 'missing'
        key = directory / 'key'
        key.write_text(GUEST_KEY)
        token = directory / 'token'
        token.write_text(TOKEN)
        empty = directory / 'empty'
        empty.write_text(' \n')
        two_words = directory / 'two-words'
        two_words.write_text('two words\n')
        base = {'--port-file': str(port_file), '--token-file': str(token),
                '--guest-key-file': str(key)}

        def arguments(changes: dict[str, str | None]) -> list[str]:
            options = {**base, **changes}
            return [part for option, value in options.items()
                    if value is not None for part in (option, value)]

        login = "run 'claudevm login' on the host"
        cases = {
            'no guest key file': (
                arguments({'--guest-key-file': None}), 2,
                'the following arguments are required: --guest-key-file'),
            'a guest key on the command line': (
                arguments({'--guest-key': GUEST_KEY}), 2,
                'unrecognized arguments: --guest-key'),
            'a missing guest key file': (
                arguments({'--guest-key-file': str(missing)}), 2,
                f"no guest key at '{missing}' (No such file or directory)"),
            'an empty guest key file': (
                arguments({'--guest-key-file': str(empty)}), 2,
                f"no guest key at '{empty}' (it is empty)"),
            'an upstream that is not http or https': (
                arguments({'--upstream': 'ftp://h'}), 2,
                "the upstream 'ftp://h' is not an http or https origin"),
            'an upstream with a path': (
                arguments({'--upstream': 'http://h/v1'}), 2,
                "the upstream 'http://h/v1' is not an http or https origin"),
            'a missing token file': (
                arguments({'--token-file': str(missing)}), 2,
                f"no token at '{missing}' (No such file or directory); "
                f'{login}'),
            'an empty token file': (
                arguments({'--token-file': str(empty)}), 2,
                f"no token at '{empty}' (it is empty); {login}"),
            'a token that is not one line of printable ASCII': (
                arguments({'--token-file': str(two_words)}), 2,
                f"no token at '{two_words}' (it is not one line of printable "
                f'ASCII); {login}'),
            'a port file in a missing directory': (
                arguments({'--port-file': str(missing / 'port')}), 1,
                'claudevm-broker: cannot start: cannot write the port file '
                f"'{missing / 'port'}': No such file or directory"),
        }
        for case, (argv, status, message) in cases.items():
            with self.subTest(case):
                result = subprocess.run(
                    [BROKER_EXECUTABLE, *argv], capture_output=True,
                    stdin=subprocess.DEVNULL, timeout=TIMEOUT, text=True)
                self.assertEqual(result.returncode, status,
                                 f'the broker should exit {status} on {case}')
                self.assertIn(message, result.stderr,
                              f'the broker should explain {case}')
                self.assertFalse(port_file.exists(),
                                 f'the broker should not start on {case}')


def main() -> int:
    global BROKER_EXECUTABLE, WORK_DIRECTORY
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    BROKER_EXECUTABLE = sys.argv[1]
    faulthandler.dump_traceback_later(WATCHDOG_SECONDS, exit=True)
    with tempfile.TemporaryDirectory() as work_directory:
        WORK_DIRECTORY = Path(work_directory)
        result = unittest.main(argv=sys.argv[:1], exit=False,
                               verbosity=2).result
        if result.wasSuccessful():
            return 0
        for log_path in broker_logs:
            print(f'--- broker log {log_path}', file=sys.stderr)
            print(log_path.read_text(errors='replace'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
