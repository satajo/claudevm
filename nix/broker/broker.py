"""Credential broker between the claudevm guest and the Anthropic API.

The guest's Claude Code authenticates with a per-session dummy API key. The
broker listens on 127.0.0.1, accepts only requests that carry that key,
replaces the key with the host's OAuth token and relays each request to the
upstream API, streaming the response back as it arrives. The token is sent
nowhere but upstream.
"""

import argparse
import contextlib
import hmac
import http.client
import http.server
import json
import os
import re
import socketserver
import ssl
import sys
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass
from email.message import Message
from http import HTTPStatus
from pathlib import Path
from typing import NewType

OAUTH_BETA = 'oauth-2025-04-20'
DEFAULT_UPSTREAM = 'https://api.anthropic.com'
DEFAULT_PORTS = {'http': 80, 'https': 443}
LOGIN_HINT = "run 'claudevm login' on the host"

UPSTREAM_CONNECT_TIMEOUT = 30.0
UPSTREAM_READ_TIMEOUT = 600.0
CLIENT_TIMEOUT = 600.0
# Upper bound of one read from the upstream response, and so of one chunk
# relayed to the client.
RELAY_CHUNK_SIZE = 4096
# Upper bound of a request body, which the broker holds in memory whole.
MAX_BODY_SIZE = 64 * 1024 * 1024

VISIBLE_ASCII = re.compile(r'[\x21-\x7e]+')
HTTP_TOKEN = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+")
ORIGIN_FORM = re.compile(r'/[\x21-\x7e]*')
DIGITS = re.compile(r'[0-9]+')
# Header values carry no control characters other than horizontal tab.
CONTROL_CHARACTER = re.compile(r'[\x00-\x08\x0a-\x1f\x7f]')

REQUEST_HEADERS_NOT_FORWARDED = frozenset({
    'host', 'x-api-key', 'authorization', 'content-length',
    'transfer-encoding', 'connection', 'keep-alive', 'proxy-authorization',
    'proxy-connection', 'te', 'trailer', 'upgrade', 'anthropic-beta',
})
RESPONSE_HEADERS_NOT_RELAYED = frozenset({
    'content-length', 'transfer-encoding', 'connection', 'keep-alive',
    'proxy-authenticate', 'proxy-connection', 'te', 'trailer', 'upgrade',
})

GuestKey = NewType('GuestKey', bytes)
Token = NewType('Token', str)


@dataclass(frozen=True)
class Upstream:
    url: str
    host: str
    port: int
    # Present exactly when the upstream speaks https.
    tls: ssl.SSLContext | None

    def connection(self) -> http.client.HTTPConnection:
        if self.tls is None:
            return http.client.HTTPConnection(
                self.host, self.port, timeout=UPSTREAM_CONNECT_TIMEOUT)
        return http.client.HTTPSConnection(
            self.host, self.port, timeout=UPSTREAM_CONNECT_TIMEOUT,
            context=self.tls)


@dataclass(frozen=True)
class Config:
    port_file: Path
    token_file: Path
    guest_key: GuestKey
    upstream: Upstream


@dataclass(frozen=True)
class UpstreamRequest:
    method: str
    target: str
    headers: list[tuple[str, str]]
    body: bytes | None


@dataclass
class Rejection(Exception):
    """A request the broker answers itself, without contacting upstream."""

    status: HTTPStatus
    error_type: str
    message: str


def bad_request(message: str) -> Rejection:
    return Rejection(HTTPStatus.BAD_REQUEST, 'invalid_request_error',
                     f'claudevm broker: {message}')


def log(line: str) -> None:
    sys.stderr.write(line + '\n')


def quoted(value: object) -> str:
    """value as messages show a value from outside the broker. The log
    reaches the terminal only through the launcher, which escapes its
    control characters."""
    return f"'{value}'"


def describe(error: BaseException) -> str:
    """The reason that error gives. An OS error's message comes from the
    system; the text of any other error can come from the other end, such
    as the status line of a malformed response, and appears quoted,
    without the line break that ends a received line."""
    if isinstance(error, OSError) and error.strerror:
        return error.strerror
    text = str(error).rstrip('\r\n')
    if not text:
        return type(error).__name__
    return f'{type(error).__name__} {quoted(text)}'


def parse_upstream(text: str) -> Upstream:
    invalid = ValueError(f'the upstream {quoted(text)} is not an http or '
                         f'https origin such as {DEFAULT_UPSTREAM}')
    try:
        parts = urllib.parse.urlsplit(text)
        explicit_port = parts.port
    except ValueError:
        raise invalid from None
    origin = f'{parts.scheme}://{parts.netloc}'
    if (parts.scheme not in DEFAULT_PORTS or not parts.hostname
            or '@' in parts.netloc or text not in (origin, origin + '/')):
        raise invalid
    return Upstream(
        url=origin,
        host=parts.hostname,
        port=(DEFAULT_PORTS[parts.scheme] if explicit_port is None
              else explicit_port),
        tls=ssl.create_default_context() if parts.scheme == 'https' else None,
    )


def read_secret(path: Path) -> str:
    """The file's content without surrounding whitespace. Raises ValueError
    with the reason unless that is one line of printable ASCII."""
    try:
        text = path.read_bytes().strip().decode('ascii', errors='replace')
    except OSError as error:
        raise ValueError(describe(error)) from None
    if not VISIBLE_ASCII.fullmatch(text):
        raise ValueError('it is empty' if not text
                         else 'it is not one line of printable ASCII')
    return text


def read_guest_key(path: Path) -> GuestKey:
    try:
        return GuestKey(read_secret(path).encode('ascii'))
    except ValueError as error:
        raise ValueError(f'no guest key at {quoted(path)} ({error})') from None


def read_token(path: Path) -> Token:
    try:
        return Token(read_secret(path))
    except ValueError as error:
        raise ValueError(
            f'no token at {quoted(path)} ({error}); {LOGIN_HINT}') from None


def parse_config(argv: list[str]) -> Config:
    parser = argparse.ArgumentParser(
        prog='claudevm-broker', allow_abbrev=False,
        description='Relay Anthropic API requests that carry the session '
        "key, authenticated with the host's OAuth token. Listens on "
        '127.0.0.1 on a free port.')
    parser.add_argument(
        '--port-file', type=Path, required=True, metavar='PATH',
        help='file that receives the bound TCP port once listening')
    parser.add_argument(
        '--token-file', type=Path, required=True, metavar='PATH',
        help='file holding the OAuth token, read for every request')
    parser.add_argument(
        '--guest-key-file', type=Path, required=True, metavar='PATH',
        help='file holding the API key the guest sends')
    parser.add_argument(
        '--upstream', default=DEFAULT_UPSTREAM, metavar='URL',
        help=f'API origin (default: {DEFAULT_UPSTREAM})')
    args = parser.parse_args(argv)
    try:
        upstream = parse_upstream(args.upstream)
        guest_key = read_guest_key(args.guest_key_file)
        read_token(args.token_file)
    except ValueError as error:
        parser.error(str(error))
    return Config(args.port_file, args.token_file, guest_key, upstream)


def carries_key(headers: Message, key: GuestKey) -> bool:
    return hmac.compare_digest(
        headers.get('x-api-key', '').encode('latin-1'), key)


def with_oauth_beta(values: list[str]) -> str:
    betas = [beta.strip()
             for value in values
             for beta in value.split(',') if beta.strip()]
    if OAUTH_BETA not in betas:
        betas.append(OAUTH_BETA)
    return ','.join(betas)


def exchange(connection: http.client.HTTPConnection,
             request: UpstreamRequest) -> http.client.HTTPResponse:
    connection.connect()
    connection.sock.settimeout(UPSTREAM_READ_TIMEOUT)
    connection.putrequest(request.method, request.target,
                          skip_accept_encoding=True)
    for name, value in request.headers:
        connection.putheader(name, value)
    connection.endheaders(request.body)
    return connection.getresponse()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    timeout = CLIENT_TIMEOUT
    server: 'Server'

    def __getattr__(self, name: str) -> Callable[[], None]:
        # The base class dispatches a request with method M to do_M; every
        # method is relayed alike.
        if name.startswith('do_'):
            return self.relay
        raise AttributeError(name)

    def relay(self) -> None:
        try:
            self.relay_request()
        except OSError as error:
            # Upstream failures are handled within relay_request, so this
            # is the client connection failing.
            self.close_connection = True
            log(f'claudevm-broker: client connection failed during '
                f'{self.request_name()}: {describe(error)}')

    def relay_request(self) -> None:
        config = self.server.config
        try:
            request = self.parse_client_request(config)
        except Rejection as rejection:
            self.send_error_json(rejection.status, rejection.error_type,
                                 rejection.message)
            return
        with contextlib.closing(config.upstream.connection()) as connection:
            try:
                response = exchange(connection, request)
            except (OSError, http.client.HTTPException) as error:
                reason = f'cannot reach {quoted(config.upstream.url)}: ' \
                    f'{describe(error)}'
                log(f'claudevm-broker: {reason}')
                self.send_error_json(HTTPStatus.BAD_GATEWAY, 'api_error',
                                     f'claudevm broker: {reason}')
                return
            self.relay_response(response)

    def parse_client_request(self, config: Config) -> UpstreamRequest:
        if self.request_version != 'HTTP/1.1':
            raise Rejection(HTTPStatus.HTTP_VERSION_NOT_SUPPORTED,
                            'invalid_request_error',
                            'claudevm broker: only HTTP/1.1 is supported')
        if not carries_key(self.headers, config.guest_key):
            raise Rejection(
                HTTPStatus.UNAUTHORIZED, 'authentication_error',
                'claudevm broker: request did not carry the session key')
        try:
            token = read_token(config.token_file)
        except ValueError as error:
            raise Rejection(HTTPStatus.UNAUTHORIZED, 'authentication_error',
                            f'claudevm broker: {error}') from None
        if not HTTP_TOKEN.fullmatch(self.command):
            raise bad_request('malformed request method')
        if not ORIGIN_FORM.fullmatch(self.path):
            raise bad_request('the request target must be an absolute path')
        for name, value in self.headers.items():
            if CONTROL_CHARACTER.search(value):
                raise bad_request(f'malformed value of header {quoted(name)}')
        body = self.read_body()

        headers = [(name, value) for name, value in self.headers.items()
                   if name.lower() not in REQUEST_HEADERS_NOT_FORWARDED]
        headers += [
            ('Authorization', f'Bearer {token}'),
            ('anthropic-beta',
             with_oauth_beta(self.headers.get_all('anthropic-beta', []))),
        ]
        if body is not None:
            headers.append(('Content-Length', str(len(body))))
        return UpstreamRequest(self.command, self.path, headers, body)

    def read_body(self) -> bytes | None:
        """The request body, or None when the request has none."""
        if 'transfer-encoding' in self.headers:
            raise Rejection(
                HTTPStatus.LENGTH_REQUIRED, 'invalid_request_error',
                'claudevm broker: send the body with Content-Length')
        lengths = self.headers.get_all('content-length', [])
        if not lengths:
            return None
        if len(lengths) != 1 or not DIGITS.fullmatch(lengths[0]):
            raise bad_request('malformed Content-Length')
        # The digit count is compared first because int() refuses very long
        # digit strings.
        if (len(lengths[0]) > len(str(MAX_BODY_SIZE))
                or int(lengths[0]) > MAX_BODY_SIZE):
            raise Rejection(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE, 'request_too_large',
                f'claudevm broker: the request body exceeds {MAX_BODY_SIZE} '
                'bytes')
        body = self.rfile.read(int(lengths[0]))
        if len(body) != int(lengths[0]):
            raise bad_request('the request body ended early')
        return body

    def relay_response(self, response: http.client.HTTPResponse) -> None:
        bodyless = self.command == 'HEAD' or response.status in (204, 304)
        self.send_response_only(response.status, response.reason)
        self.log_request(response.status)
        for name, value in response.getheaders():
            if name.lower() not in RESPONSE_HEADERS_NOT_RELAYED:
                self.send_header(name, value)
        if not bodyless:
            self.send_header('Transfer-Encoding', 'chunked')
        if self.close_connection:
            self.send_header('Connection', 'close')
        self.end_headers()
        if bodyless:
            return

        while True:
            try:
                chunk = response.read1(RELAY_CHUNK_SIZE)
            except (OSError, http.client.HTTPException) as error:
                self.abort_response(describe(error))
                return
            if not chunk:
                break
            self.wfile.write(b'%x\r\n%s\r\n' % (len(chunk), chunk))
            self.wfile.flush()
        # A body framed by Content-Length leaves a remainder when upstream
        # closed early.
        if response.length:
            self.abort_response('the response body ended early')
            return
        self.wfile.write(b'0\r\n\r\n')
        self.wfile.flush()

    def abort_response(self, reason: str) -> None:
        """Ends a response whose headers are sent, so that the client sees
        it incomplete."""
        self.close_connection = True
        log(f'claudevm-broker: upstream failed during '
            f'{self.request_name()}: {reason}')

    def send_error_json(self, status: HTTPStatus, error_type: str,
                        message: str) -> None:
        body = json.dumps({
            'type': 'error',
            'error': {'type': error_type, 'message': message},
        }).encode()
        # The request body may be unread, so the connection cannot carry
        # another request.
        self.close_connection = True
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
            self.wfile.flush()

    def send_error(self, code: int, message: str | None = None,
                   explain: str | None = None) -> None:
        """Answers a request that http.server refuses as the broker answers
        its own rejections. The message of http.server shows the request
        line in Python's repr notation, so the answer gives the status
        phrase in its place and the log names the request as request_name
        does."""
        status = HTTPStatus(code)
        self.send_error_json(status, 'invalid_request_error',
                             f'claudevm broker: {status.phrase}')

    def request_name(self) -> str:
        if self.command:
            return f'{quoted(self.command)} {quoted(self.path)}'
        # http.server sets the request line before it parses it, and an
        # empty one for a request line that is too long.
        if self.requestline:
            return f'the malformed request {quoted(self.requestline)}'
        return 'a malformed request'

    def log_request(self, code: int | str = '-',
                    size: int | str = '-') -> None:
        log(f'{self.request_name()} -> {int(code)}')

    def log_message(self, format: str, *args: object) -> None:
        log('claudevm-broker: ' + format % args)


class Server(http.server.ThreadingHTTPServer):
    def __init__(self, config: Config) -> None:
        self.config = config
        super().__init__(('127.0.0.1', 0), Handler)

    def server_bind(self) -> None:
        # The base class resolves the address to a host name here, which
        # can stall on DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.socket.getsockname()


def write_port_file(path: Path, port: int) -> None:
    """Writes the port so that a reader never sees a partial file."""
    temporary = Path(f'{path}.tmp')
    temporary.write_text(f'{port}\n')
    os.replace(temporary, path)


def main() -> None:
    config = parse_config(sys.argv[1:])
    try:
        server = Server(config)
    except OSError as error:
        sys.exit(f'claudevm-broker: cannot start: {describe(error)}')
    try:
        write_port_file(config.port_file, server.server_port)
    except OSError as error:
        sys.exit(f'claudevm-broker: cannot start: cannot write the port '
                 f'file {quoted(config.port_file)}: {describe(error)}')
    log(f'claudevm-broker: listening on 127.0.0.1 port {server.server_port}, '
        f'relaying to {quoted(config.upstream.url)}')
    server.serve_forever()


if __name__ == '__main__':
    main()
