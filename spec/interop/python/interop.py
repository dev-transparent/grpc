"""Reference gRPC interop server and client using the official grpcio package.

Used to verify that the Crystal implementation interoperates with gRPC
C-core:

    python interop.py server --port 10000
    python interop.py client --port 10000 [--test_case NAME]

Requires: grpcio and the stubs generated into this directory
(see script/interop.sh).
"""

import argparse
import os
import sys
import time
from concurrent import futures

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import grpc  # noqa: E402
from src.proto.grpc.testing import empty_pb2, messages_pb2, test_pb2_grpc  # noqa: E402

ECHO_INITIAL = "x-grpc-test-echo-initial"
ECHO_TRAILING = "x-grpc-test-echo-trailing-bin"


def payload(size):
    return messages_pb2.Payload(type=messages_pb2.COMPRESSABLE, body=b"\x00" * size)


class TestService(test_pb2_grpc.TestServiceServicer):
    def _echo(self, context):
        metadata = dict(context.invocation_metadata())
        if ECHO_INITIAL in metadata:
            context.send_initial_metadata(((ECHO_INITIAL, metadata[ECHO_INITIAL]),))
        if ECHO_TRAILING in metadata:
            context.set_trailing_metadata(((ECHO_TRAILING, metadata[ECHO_TRAILING]),))

    def _status(self, status, context):
        if status.code != 0:
            context.abort(grpc.StatusCode(_code(status.code)), status.message)

    def EmptyCall(self, request, context):
        self._echo(context)
        return empty_pb2.Empty()

    def UnaryCall(self, request, context):
        self._echo(context)
        if request.HasField("response_status"):
            self._status(request.response_status, context)
        if request.response_compressed.value:
            context.set_compression(grpc.Compression.Gzip)
        return messages_pb2.SimpleResponse(payload=payload(request.response_size))

    def StreamingOutputCall(self, request, context):
        self._echo(context)
        for params in request.response_parameters:
            if params.interval_us:
                time.sleep(params.interval_us / 1e6)
            yield messages_pb2.StreamingOutputCallResponse(payload=payload(params.size))
        if request.HasField("response_status"):
            self._status(request.response_status, context)

    def StreamingInputCall(self, request_iterator, context):
        self._echo(context)
        total = sum(len(r.payload.body) for r in request_iterator)
        return messages_pb2.StreamingInputCallResponse(aggregated_payload_size=total)

    def FullDuplexCall(self, request_iterator, context):
        self._echo(context)
        for request in request_iterator:
            if request.HasField("response_status"):
                self._status(request.response_status, context)
            for params in request.response_parameters:
                if params.interval_us:
                    time.sleep(params.interval_us / 1e6)
                yield messages_pb2.StreamingOutputCallResponse(payload=payload(params.size))

    def HalfDuplexCall(self, request_iterator, context):
        requests = list(request_iterator)
        for request in requests:
            for params in request.response_parameters:
                yield messages_pb2.StreamingOutputCallResponse(payload=payload(params.size))


def _code(value):
    for code in grpc.StatusCode:
        if code.value[0] == value:
            return code.value
    return grpc.StatusCode.UNKNOWN.value


CERTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "certs")


def _read(name):
    with open(os.path.join(CERTS, name), "rb") as f:
        return f.read()


def serve(port, use_tls=False):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=16))
    test_pb2_grpc.add_TestServiceServicer_to_server(TestService(), server)
    if use_tls:
        creds = grpc.ssl_server_credentials([(_read("server1.key"), _read("server1.pem"))])
        server.add_secure_port(f"127.0.0.1:{port}", creds)
    else:
        server.add_insecure_port(f"127.0.0.1:{port}")
    server.start()
    print(f"Python interop server listening on {port}", flush=True)
    server.wait_for_termination()


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def expect_code(code, fn):
    try:
        fn()
    except grpc.RpcError as e:
        check(e.code() == code, f"expected {code}, got {e.code()}: {e.details()}")
        return e
    raise Failure(f"expected {code}, call succeeded")


def run_client(port, selected, use_tls=False):
    if use_tls:
        creds = grpc.ssl_channel_credentials(root_certificates=_read("ca.pem"))
        channel = grpc.secure_channel(f"127.0.0.1:{port}", creds,
                                      options=[("grpc.ssl_target_name_override", "foo.test.google.fr")])
    else:
        channel = grpc.insecure_channel(f"127.0.0.1:{port}")
    stub = test_pb2_grpc.TestServiceStub(channel)

    def empty_unary():
        check(stub.EmptyCall(empty_pb2.Empty()) == empty_pb2.Empty(), "unexpected response")

    def large_unary():
        r = stub.UnaryCall(messages_pb2.SimpleRequest(response_size=314159, payload=payload(271828)))
        check(len(r.payload.body) == 314159, "wrong payload size")

    def client_compressed_unary():
        expect_code(grpc.StatusCode.INVALID_ARGUMENT, lambda: stub.UnaryCall(messages_pb2.SimpleRequest(
            expect_compressed=messages_pb2.BoolValue(value=True), response_size=314159, payload=payload(271828))))
        r = stub.UnaryCall(messages_pb2.SimpleRequest(
            expect_compressed=messages_pb2.BoolValue(value=True), response_size=314159, payload=payload(271828)),
            compression=grpc.Compression.Gzip)
        check(len(r.payload.body) == 314159, "wrong payload size")

    def server_compressed_unary():
        for compressed in (True, False):
            r = stub.UnaryCall(messages_pb2.SimpleRequest(
                response_compressed=messages_pb2.BoolValue(value=compressed), response_size=314159,
                payload=payload(271828)))
            check(len(r.payload.body) == 314159, "wrong payload size")

    def client_streaming():
        reqs = (messages_pb2.StreamingInputCallRequest(payload=payload(s)) for s in (27182, 8, 1828, 45904))
        r = stub.StreamingInputCall(reqs)
        check(r.aggregated_payload_size == 74922, f"wrong size {r.aggregated_payload_size}")

    def client_compressed_streaming():
        reqs = (messages_pb2.StreamingInputCallRequest(payload=payload(s)) for s in (27182, 45904))
        r = stub.StreamingInputCall(reqs, compression=grpc.Compression.Gzip)
        check(r.aggregated_payload_size == 73086, f"wrong size {r.aggregated_payload_size}")

    def server_streaming():
        sizes = [31415, 9, 2653, 58979]
        req = messages_pb2.StreamingOutputCallRequest(
            response_parameters=[messages_pb2.ResponseParameters(size=s) for s in sizes])
        got = [len(r.payload.body) for r in stub.StreamingOutputCall(req)]
        check(got == sizes, f"wrong sizes {got}")

    def server_compressed_streaming():
        req = messages_pb2.StreamingOutputCallRequest(response_parameters=[
            messages_pb2.ResponseParameters(size=31415, compressed=messages_pb2.BoolValue(value=True)),
            messages_pb2.ResponseParameters(size=92653, compressed=messages_pb2.BoolValue(value=False))])
        got = [len(r.payload.body) for r in stub.StreamingOutputCall(req)]
        check(got == [31415, 92653], f"wrong sizes {got}")

    def ping_pong():
        import queue
        q = queue.Queue()

        def gen():
            while True:
                item = q.get()
                if item is None:
                    return
                yield item

        pairs = [(27182, 31415), (8, 9), (1828, 2653), (45904, 58979)]
        responses = stub.FullDuplexCall(gen())
        for req_size, resp_size in pairs:
            q.put(messages_pb2.StreamingOutputCallRequest(
                response_parameters=[messages_pb2.ResponseParameters(size=resp_size)], payload=payload(req_size)))
            r = next(responses)
            check(len(r.payload.body) == resp_size, "wrong size")
        q.put(None)
        check(next(responses, None) is None, "expected end of stream")

    def empty_stream():
        check(list(stub.FullDuplexCall(iter([]))) == [], "expected no responses")

    def custom_metadata():
        md = ((ECHO_INITIAL, "test_initial_metadata_value"), (ECHO_TRAILING, b"\xab\xab\xab"))
        _, call = stub.UnaryCall.with_call(
            messages_pb2.SimpleRequest(response_size=314159, payload=payload(271828)), metadata=md)
        check(dict(call.initial_metadata()).get(ECHO_INITIAL) == "test_initial_metadata_value", "initial not echoed")
        check(dict(call.trailing_metadata()).get(ECHO_TRAILING) == b"\xab\xab\xab", "trailing not echoed")
        responses = stub.FullDuplexCall(iter([messages_pb2.StreamingOutputCallRequest(
            response_parameters=[messages_pb2.ResponseParameters(size=314159)], payload=payload(271828))]),
            metadata=md)
        list(responses)
        check(dict(responses.initial_metadata()).get(ECHO_INITIAL) == "test_initial_metadata_value",
              "initial not echoed (stream)")
        check(dict(responses.trailing_metadata()).get(ECHO_TRAILING) == b"\xab\xab\xab",
              "trailing not echoed (stream)")

    def status_code_and_message():
        st = messages_pb2.EchoStatus(code=2, message="test status message")
        e = expect_code(grpc.StatusCode.UNKNOWN, lambda: stub.UnaryCall(messages_pb2.SimpleRequest(response_status=st)))
        check(e.details() == "test status message", f"wrong message {e.details()!r}")
        e = expect_code(grpc.StatusCode.UNKNOWN, lambda: list(stub.FullDuplexCall(
            iter([messages_pb2.StreamingOutputCallRequest(response_status=st)]))))
        check(e.details() == "test status message", f"wrong message {e.details()!r}")

    def special_status_message():
        msg = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP \U0001f608\t\n"
        e = expect_code(grpc.StatusCode.UNKNOWN, lambda: stub.UnaryCall(messages_pb2.SimpleRequest(
            response_status=messages_pb2.EchoStatus(code=2, message=msg))))
        check(e.details() == msg, f"wrong message {e.details()!r}")

    def unimplemented_method():
        expect_code(grpc.StatusCode.UNIMPLEMENTED, lambda: stub.UnimplementedCall(empty_pb2.Empty()))

    def unimplemented_service():
        other = test_pb2_grpc.UnimplementedServiceStub(channel)
        expect_code(grpc.StatusCode.UNIMPLEMENTED, lambda: other.UnimplementedCall(empty_pb2.Empty()))

    def cancel_after_begin():
        future = stub.StreamingInputCall.future(iter(()))
        future.cancel()
        check(future.cancelled(), "not cancelled")

    def cancel_after_first_response():
        import queue
        q = queue.Queue()

        def gen():
            while True:
                item = q.get()
                if item is None:
                    return
                yield item

        responses = stub.FullDuplexCall(gen())
        q.put(messages_pb2.StreamingOutputCallRequest(
            response_parameters=[messages_pb2.ResponseParameters(size=31415)], payload=payload(27182)))
        next(responses)
        responses.cancel()
        q.put(None)
        check(responses.code() == grpc.StatusCode.CANCELLED, f"got {responses.code()}")

    def timeout_on_sleeping_server():
        import threading
        stop = threading.Event()

        def gen():
            # Keep the request stream open, as the official test does.
            yield messages_pb2.StreamingOutputCallRequest(payload=payload(27182))
            stop.wait(5)

        try:
            expect_code(grpc.StatusCode.DEADLINE_EXCEEDED, lambda: list(stub.FullDuplexCall(gen(), timeout=0.001)))
        finally:
            stop.set()

    def large_messages():
        # Several MB in both directions, exercising flow control.
        r = stub.UnaryCall(messages_pb2.SimpleRequest(response_size=3_000_000, payload=payload(3_000_000)))
        check(len(r.payload.body) == 3_000_000, "wrong payload size")

    def concurrent_calls():
        with futures.ThreadPoolExecutor(max_workers=32) as pool:
            results = list(pool.map(lambda i: stub.UnaryCall(messages_pb2.SimpleRequest(
                response_size=i * 10, payload=payload(i))), range(200)))
        check([len(r.payload.body) for r in results] == [i * 10 for i in range(200)], "wrong sizes")

    cases = {name: fn for name, fn in locals().items() if callable(fn) and not name.startswith("_")}
    names = list(cases) if selected == "all" else selected.split(",")
    failures = 0
    for name in names:
        try:
            cases[name]()
            print(f"PASS {name}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"FAIL {name}: {type(e).__name__}: {e}")
    print(f"{len(names) - failures}/{len(names)} interop test cases passed")
    return failures == 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["server", "client"])
    parser.add_argument("--port", type=int, default=10000)
    parser.add_argument("--test_case", default="all")
    parser.add_argument("--use_tls", default="false")
    args = parser.parse_args()
    use_tls = args.use_tls == "true"
    if args.mode == "server":
        serve(args.port, use_tls)
    else:
        sys.exit(0 if run_client(args.port, args.test_case, use_tls) else 1)


if __name__ == "__main__":
    main()
