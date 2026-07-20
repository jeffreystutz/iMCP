#!/usr/bin/env python3
"""Exercise elicitation correlation through the production stdio proxy."""

import json
import os
import socket
import subprocess
import sys


def send_line(stream, value):
    stream.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    stream.flush()


def read_line(stream):
    line = stream.readline()
    if not line:
        raise RuntimeError("proxy connection closed")
    return json.loads(line)


def expect(value, key, expected):
    actual = value.get(key)
    if actual != expected:
        raise AssertionError(f"expected {key}={expected!r}, got {actual!r}")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_elicitation_proxy.py /path/to/imcp-server")

    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)

    environment = os.environ.copy()
    environment["IMCP_TEST_PORT"] = str(listener.getsockname()[1])
    product_directory = os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1]))))
    )
    environment["DYLD_FRAMEWORK_PATH"] = os.path.join(product_directory, "PackageFrameworks")
    process = subprocess.Popen(
        [sys.argv[1]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )

    try:
        connection, _ = listener.accept()
        connection.settimeout(10)
        app = connection.makefile("rwb", buffering=0)

        send_line(
            process.stdin,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"elicitation": {"form": {}}},
                    "clientInfo": {"name": "proxy-round-trip-test", "version": "1"},
                },
            },
        )
        expect(read_line(app), "method", "initialize")
        send_line(
            app,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "test-app", "version": "1"},
                },
            },
        )
        expect(read_line(process.stdout), "id", 1)

        send_line(process.stdin, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        send_line(
            process.stdin,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "round_trip_test", "arguments": {}},
            },
        )
        expect(read_line(app), "method", "notifications/initialized")
        expect(read_line(app), "id", 2)

        send_line(
            app,
            {
                "jsonrpc": "2.0",
                "id": 100,
                "method": "elicitation/create",
                "params": {
                    "mode": "form",
                    "message": "Confirm the test operation",
                    "requestedSchema": {
                        "type": "object",
                        "properties": {"confirmed": {"type": "boolean"}},
                        "required": ["confirmed"],
                    },
                },
            },
        )
        elicitation = read_line(process.stdout)
        expect(elicitation, "id", 100)
        expect(elicitation, "method", "elicitation/create")

        send_line(
            process.stdin,
            {
                "jsonrpc": "2.0",
                "id": 100,
                "result": {"action": "accept", "content": {"confirmed": True}},
            },
        )
        expect(read_line(app), "id", 100)

        send_line(
            app,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "result": {
                    "content": [{"type": "text", "text": "originating-call-resumed"}],
                    "isError": False,
                },
            },
        )
        call_result = read_line(process.stdout)
        expect(call_result, "id", 2)
        content = call_result["result"]["content"]
        if content[0]["text"] != "originating-call-resumed":
            raise AssertionError("tool result did not return to its originating call")
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
        listener.close()


if __name__ == "__main__":
    main()
