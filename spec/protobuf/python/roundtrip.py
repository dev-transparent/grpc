"""Randomized cross-implementation round-trip helper for the Crystal protobuf specs.

Usage:
  roundtrip.py GEN_DIR gen MESSAGE SEED COUNT OUT [single]
      Writes COUNT random, fully populated messages (length-prefixed with a
      4-byte big-endian length) to OUT. With "single", maps have at most one
      entry so that serialization is deterministic.
  roundtrip.py GEN_DIR check MESSAGE ORIGINAL CRYSTAL
      Parses both files and checks that every message parsed from CRYSTAL is
      equal to the corresponding original message.
  roundtrip.py GEN_DIR gen-json MESSAGE SEED COUNT OUT
      Like gen, but writes each message as Python's JSON (UTF-8, framed the
      same way), printing default values and original field names for
      about half of them.
  roundtrip.py GEN_DIR diff MESSAGE INPUTS RESULTS
      Differential decoding: INPUTS holds (possibly invalid) encoded
      messages; RESULTS holds, for each, Crystal's result: a 0 byte if
      Crystal rejected it, or a 1 byte followed by Crystal's re-encoding.
      Prints a MISMATCH line for every input where Python disagrees.
  roundtrip.py GEN_DIR check-json MESSAGE ORIGINAL CRYSTAL_JSON
      Parses ORIGINAL (binary) and CRYSTAL_JSON (JSON documents) and checks
      that they hold equal messages.

MESSAGE is "proto3" (TestAllTypesProto3) or "proto2" (TestAllTypesProto2).
GEN_DIR contains the Python code generated for the conformance protos under
the `conformance` package.
"""

import math
import random
import struct
import sys

GEN_DIR = sys.argv[1]
sys.path.insert(0, GEN_DIR)

from google.protobuf import descriptor as _descriptor  # noqa: E402
from google.protobuf import json_format  # noqa: E402
from conformance import test_messages_proto2_pb2, test_messages_proto3_pb2  # noqa: E402

FD = _descriptor.FieldDescriptor
MESSAGES = {
    "proto3": test_messages_proto3_pb2.TestAllTypesProto3,
    "proto2": test_messages_proto2_pb2.TestAllTypesProto2,
}

INT_RANGES = {
    FD.TYPE_INT32: (-(2**31), 2**31 - 1),
    FD.TYPE_SINT32: (-(2**31), 2**31 - 1),
    FD.TYPE_SFIXED32: (-(2**31), 2**31 - 1),
    FD.TYPE_INT64: (-(2**63), 2**63 - 1),
    FD.TYPE_SINT64: (-(2**63), 2**63 - 1),
    FD.TYPE_SFIXED64: (-(2**63), 2**63 - 1),
    FD.TYPE_UINT32: (0, 2**32 - 1),
    FD.TYPE_FIXED32: (0, 2**32 - 1),
    FD.TYPE_UINT64: (0, 2**64 - 1),
    FD.TYPE_FIXED64: (0, 2**64 - 1),
}

CHARS = "abcXYZ019 _-éüж中€\U0001f600\U00010348"


def is_repeated(field):
    value = getattr(field, "is_repeated", None)
    if value is None:
        return field.label == FD.LABEL_REPEATED
    return value() if callable(value) else value


def is_map(field):
    return (field.type == FD.TYPE_MESSAGE and is_repeated(field)
            and field.message_type.GetOptions().map_entry)


def closed_enum(enum_type):
    value = getattr(enum_type, "is_closed", None)
    if value is not None:
        return value
    return enum_type.file.syntax == "proto2"


def random_int(rng, field_type):
    lo, hi = INT_RANGES[field_type]
    choice = rng.random()
    if choice < 0.15:
        return rng.choice([lo, hi, 0, 1, -1 if lo < 0 else 2])
    if choice < 0.5:
        return max(lo, min(hi, rng.randint(-300, 300)))
    return rng.randint(lo, hi)


def random_float(rng, single):
    choice = rng.random()
    if choice < 0.1:
        return rng.choice([0.0, -0.0, math.inf, -math.inf, 1.0, -1.0])
    value = rng.uniform(-1e6, 1e6) if choice < 0.6 else rng.uniform(-1, 1) * 10 ** rng.randint(-30, 30)
    if single:
        value = struct.unpack("<f", struct.pack("<f", value))[0]
    return value


def random_string(rng):
    return "".join(rng.choice(CHARS) for _ in range(rng.randint(0, 12)))


def random_scalar(rng, field):
    t = field.type
    if t in INT_RANGES:
        return random_int(rng, t)
    if t == FD.TYPE_FLOAT:
        return random_float(rng, True)
    if t == FD.TYPE_DOUBLE:
        return random_float(rng, False)
    if t == FD.TYPE_BOOL:
        return rng.random() < 0.5
    if t == FD.TYPE_STRING:
        return random_string(rng)
    if t == FD.TYPE_BYTES:
        return bytes(rng.randrange(256) for _ in range(rng.randint(0, 12)))
    if t == FD.TYPE_ENUM:
        values = [v.number for v in field.enum_type.values]
        if field.enum_type.full_name == "google.protobuf.NullValue":
            return 0  # always printed as null in JSON
        if not closed_enum(field.enum_type) and rng.random() < 0.1:
            return rng.choice([1234, -5, 2**31 - 1, -(2**31)])
        return rng.choice(values)
    raise ValueError("unexpected type %d" % t)


def random_json_value(rng, value, depth):
    choice = rng.randrange(6 if depth < 2 else 4)
    if choice == 0:
        value.null_value = 0
    elif choice == 1:
        value.number_value = rng.choice([0.0, -1.5, 1e20, rng.uniform(-1e6, 1e6), float(rng.randint(-1000, 1000))])
    elif choice == 2:
        value.string_value = random_string(rng)
    elif choice == 3:
        value.bool_value = rng.random() < 0.5
    elif choice == 4:
        value.struct_value.SetInParent()
        for _ in range(rng.randint(0, 3)):
            random_json_value(rng, value.struct_value.fields[random_string(rng)], depth + 1)
    else:
        value.list_value.SetInParent()
        for _ in range(rng.randint(0, 3)):
            random_json_value(rng, value.list_value.values.add(), depth + 1)


def populate_well_known(rng, message, depth):
    """Fills well-known types with values that have a JSON representation.
    Returns False for other messages."""
    name = message.DESCRIPTOR.full_name
    if name == "google.protobuf.FieldMask":
        for _ in range(rng.randint(0, 3)):
            message.paths.append(rng.choice(["foo", "bar_baz", "a.b_c", "x1", "deep.nested.field_name"]))
    elif name == "google.protobuf.Duration":
        seconds = rng.randint(-315576000000, 315576000000)
        nanos = rng.choice([0, 500000000, 1000, 1, 999999999]) if rng.random() < 0.7 else rng.randint(0, 999999999)
        if seconds < 0:
            nanos = -nanos
        elif seconds == 0 and rng.random() < 0.5:
            nanos = -nanos
        message.seconds, message.nanos = seconds, nanos
    elif name == "google.protobuf.Timestamp":
        message.seconds = rng.randint(-62135596800, 253402300799)
        message.nanos = rng.choice([0, 1000000, 1000, 7]) if rng.random() < 0.7 else rng.randint(0, 999999999)
    elif name == "google.protobuf.Any":
        if rng.random() < 0.5:
            payload = test_messages_proto3_pb2.ForeignMessage(c=random_int(rng, FD.TYPE_INT32))
        else:
            from google.protobuf import duration_pb2
            payload = duration_pb2.Duration()
            populate_well_known(rng, payload, depth + 1)
        message.Pack(payload)
    elif name == "google.protobuf.Value":
        random_json_value(rng, message, 0)
    elif name == "google.protobuf.Struct":
        for _ in range(rng.randint(0, 3)):
            random_json_value(rng, message.fields[random_string(rng)], 1)
    elif name == "google.protobuf.ListValue":
        for _ in range(rng.randint(0, 3)):
            random_json_value(rng, message.values.add(), 1)
    else:
        return False
    return True


def populate(rng, message, depth):
    descriptor = message.DESCRIPTOR
    if populate_well_known(rng, message, depth):
        return message
    oneof_choice = {}
    for oneof in descriptor.oneofs:
        if len(oneof.fields) > 1:  # skip synthetic proto3 optional oneofs
            oneof_choice[oneof.name] = rng.choice(oneof.fields).name if rng.random() < 0.9 else None
    for field in descriptor.fields:
        oneof = field.containing_oneof
        if oneof is not None and oneof.name in oneof_choice and oneof_choice[oneof.name] != field.name:
            continue
        is_message = field.type in (FD.TYPE_MESSAGE, FD.TYPE_GROUP)
        if is_message and depth >= 3:
            continue
        if is_map(field):
            populate_map(rng, getattr(message, field.name), field, depth)
        elif is_repeated(field):
            container = getattr(message, field.name)
            for _ in range(rng.randint(0, 4)):
                if is_message:
                    populate(rng, container.add(), depth + 1)
                else:
                    container.append(random_scalar(rng, field))
        elif is_message:
            if rng.random() < 0.7 or oneof is not None:
                sub = getattr(message, field.name)
                sub.SetInParent()
                populate(rng, sub, depth + 1)
        else:
            if oneof is None and rng.random() < 0.15:
                continue
            setattr(message, field.name, random_scalar(rng, field))
    if depth == 0 and descriptor.full_name == "protobuf_test_messages.proto2.TestAllTypesProto2":
        populate_extensions(rng, message)
    return message


def populate_extensions(rng, message):
    module = test_messages_proto2_pb2
    if rng.random() < 0.5:
        message.Extensions[module.extension_int32] = random_int(rng, FD.TYPE_INT32)
    if rng.random() < 0.3:
        message.Extensions[module.groupfield].group_int32 = random_int(rng, FD.TYPE_INT32)
    if rng.random() < 0.3:
        sub = message.message_set_correct
        ext = module.TestAllTypesProto2.MessageSetCorrectExtension1.message_set_extension
        sub.Extensions[ext].str = random_string(rng)


MAX_MAP_ENTRIES = [4]


def populate_map(rng, container, field, depth):
    key_field = field.message_type.fields_by_name["key"]
    value_field = field.message_type.fields_by_name["value"]
    for _ in range(rng.randint(0, MAX_MAP_ENTRIES[0])):
        key = random_scalar(rng, key_field)
        if value_field.type == FD.TYPE_MESSAGE:
            entry = container[key]  # creates an empty value
            if depth < 3:
                populate(rng, entry, depth + 1)
        else:
            container[key] = random_scalar(rng, value_field)


def upb_map_entry_divergence(message):
    """True if upb kept a map entry as an unknown field because the entry
    contained unknown fields. C++ (and Crystal) drop the unknown fields of
    the entry and keep the entry; the decoders legitimately differ."""
    from google.protobuf import unknown_fields
    from google.protobuf.message import Message
    descriptor = message.DESCRIPTOR
    map_numbers = set(f.number for f in descriptor.fields if is_map(f))
    if map_numbers:
        for field in unknown_fields.UnknownFieldSet(message):
            if field.field_number in map_numbers:
                return True
    for field, value in message.ListFields():
        if field.type not in (FD.TYPE_MESSAGE, FD.TYPE_GROUP):
            continue
        if is_map(field):
            values = value.values() if field.message_type.fields_by_name["value"].type == FD.TYPE_MESSAGE else []
        elif is_repeated(field):
            values = value
        else:
            values = [value]
        try:
            for element in values:
                if isinstance(element, Message) and upb_map_entry_divergence(element):
                    return True
        except UnicodeDecodeError:
            pass  # proto2 map keys with invalid UTF-8 cannot be iterated in Python
    return False


def unknown_sets_equivalent(a, b):
    """Compares unknown field sets, with varints compared on their low 32
    bits: for unknown values of closed enums in packed fields, upb stores
    the value as a uint32 while C++ (and Crystal) store a sign-extended
    int32."""
    from google.protobuf import unknown_fields
    a, b = list(a), list(b)
    if len(a) != len(b):
        return False
    for x, y in zip(a, b):
        if x.field_number != y.field_number or x.wire_type != y.wire_type:
            return False
        if x.wire_type == 0:
            if (x.data & 0xFFFFFFFF) != (y.data & 0xFFFFFFFF):
                return False
        elif x.wire_type == 3:
            if not unknown_sets_equivalent(x.data, y.data):
                return False
        elif x.data != y.data:
            return False
    return True


def upb_enum_divergence(expected, actual):
    """True if *expected* and *actual* only differ by the int32/uint32
    representation of unknown closed enum values (see above)."""
    from google.protobuf import unknown_fields
    from google.protobuf.message import Message
    if not unknown_sets_equivalent(unknown_fields.UnknownFieldSet(expected), unknown_fields.UnknownFieldSet(actual)):
        return False
    a = expected.__class__()
    a.CopyFrom(expected)
    b = actual.__class__()
    b.CopyFrom(actual)
    a.DiscardUnknownFields()
    b.DiscardUnknownFields()
    if a.SerializeToString(deterministic=True) != b.SerializeToString(deterministic=True):
        return False
    for (fa, va), (fb, vb) in zip(expected.ListFields(), actual.ListFields()):
        if fa.type not in (FD.TYPE_MESSAGE, FD.TYPE_GROUP) or is_map(fa):
            continue
        pairs = zip(va, vb) if is_repeated(fa) else [(va, vb)]
        for x, y in pairs:
            if not upb_enum_divergence(x, y):
                return False
    return True


def same_value(a, b):
    if isinstance(a, float) and isinstance(b, float) and math.isnan(a) and math.isnan(b):
        return struct.pack("<d", a) == struct.pack("<d", b)
    return a == b


def describe_difference(original, parsed, path=""):
    """Describes the innermost fields (and extensions) that differ."""
    from google.protobuf.message import Message
    a = dict((f.full_name, (f, v)) for f, v in original.ListFields())
    b = dict((f.full_name, (f, v)) for f, v in parsed.ListFields())
    for name in sorted(set(a) | set(b)):
        va = a.get(name, (None, None))[1]
        vb = b.get(name, (None, None))[1]
        if same_value(va, vb):
            continue
        here = "%s/%s" % (path, name.split(".")[-1])
        if isinstance(va, Message) and isinstance(vb, Message):
            return describe_difference(va, vb, here)
        if va is not None and vb is not None and hasattr(va, "keys") and hasattr(vb, "keys"):
            for key in set(va.keys()) | set(vb.keys()):
                if key not in va or key not in vb:
                    return "%s[%r]: only in %s" % (here, key, "original" if key in va else "parsed")
                if va[key] != vb[key]:
                    if isinstance(va[key], Message):
                        return describe_difference(va[key], vb[key], "%s[%r]" % (here, key))
                    return "%s[%r]: %r != %r" % (here, key, va[key], vb[key])
        if va is not None and vb is not None and not isinstance(va, (str, bytes)) and hasattr(va, "__len__") and len(va) == len(vb):
            for i, (x, y) in enumerate(zip(va, vb)):
                if not same_value(x, y):
                    if isinstance(x, Message):
                        return describe_difference(x, y, "%s[%d]" % (here, i))
                    return "%s[%d]: %r != %r" % (here, i, x, y)
            continue
        return "%s: %r != %r" % (here, va, vb)
    return "%s: unknown fields differ" % path


def write_messages(path, payloads):
    with open(path, "wb") as f:
        for payload in payloads:
            f.write(struct.pack(">I", len(payload)))
            f.write(payload)


def read_messages(path):
    result = []
    with open(path, "rb") as f:
        data = f.read()
    pos = 0
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        pos += 4
        result.append(data[pos:pos + length])
        pos += length
    return result


def main():
    command = sys.argv[2]
    cls = MESSAGES[sys.argv[3]]
    if command == "gen":
        seed, count, out = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
        if len(sys.argv) > 7 and sys.argv[7] == "single":
            MAX_MAP_ENTRIES[0] = 1
        rng = random.Random(seed)
        payloads = [populate(rng, cls(), 0).SerializeToString() for _ in range(count)]
        write_messages(out, payloads)
        print("generated %d" % count)
    elif command == "gen-json":
        seed, count, out = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
        rng = random.Random(seed)
        payloads = []
        for i in range(count):
            message = populate(rng, cls(), 0)
            kwargs = {}
            if i % 2 == 1:
                kwargs["preserving_proto_field_name"] = True
                kwargs["always_print_fields_with_no_presence"] = True
            payloads.append(json_format.MessageToJson(message, **kwargs).encode("utf-8"))
            payloads.append(message.SerializeToString())
        write_messages(out, payloads)
        print("generated %d" % count)
    elif command == "check-json":
        originals = read_messages(sys.argv[4])
        crystal = read_messages(sys.argv[5])
        if len(originals) != len(crystal):
            print("count mismatch: %d != %d" % (len(originals), len(crystal)))
            return 1
        for i, (a, b) in enumerate(zip(originals, crystal)):
            original = cls.FromString(a)
            parsed = json_format.Parse(b.decode("utf-8"), cls())
            if original != parsed:
                print("message %d differs:\n%s" % (i, describe_difference(original, parsed)))
                return 1
        print("ok %d" % len(originals))
    elif command == "diff":
        inputs = read_messages(sys.argv[4])
        results = read_messages(sys.argv[5])
        unanalyzable = 0
        for i, (data, result) in enumerate(zip(inputs, results)):
            try:
                expected = cls.FromString(data)
                python_ok = True
            except Exception as error:  # noqa: BLE001 - DecodeError and friends
                python_ok = False
                python_error = str(error)
            crystal_ok = result[:1] == b"\x01"
            if python_ok != crystal_ok:
                detail = "" if python_ok else python_error
                print("MISMATCH %d python=%s crystal=%s %s" % (i, "ok" if python_ok else "error",
                                                             "ok" if crystal_ok else "error", detail))
                continue
            if not python_ok:
                continue
            try:
                actual = cls.FromString(result[1:])
            except Exception as error:  # noqa: BLE001
                print("MISMATCH %d crystal output does not parse: %s" % (i, error))
                continue
            if expected.SerializeToString(deterministic=True) == actual.SerializeToString(deterministic=True):
                continue
            try:
                if upb_map_entry_divergence(expected) or upb_enum_divergence(expected, actual):
                    continue
                detail = describe_difference(expected, actual)
            except UnicodeDecodeError:
                # proto2 map keys with invalid UTF-8 cannot be inspected in
                # Python, so known divergences cannot be ruled out.
                unanalyzable += 1
                continue
            print("MISMATCH %d decoded messages differ: %s" % (i, detail))
        print("done %d (%d unanalyzable)" % (len(inputs), unanalyzable))
    elif command == "check":
        originals = read_messages(sys.argv[4])
        crystal = read_messages(sys.argv[5])
        if len(originals) != len(crystal):
            print("count mismatch: %d != %d" % (len(originals), len(crystal)))
            return 1
        for i, (a, b) in enumerate(zip(originals, crystal)):
            original = cls.FromString(a)
            parsed = cls.FromString(b)
            if original != parsed or (original.SerializeToString(deterministic=True)
                                      != parsed.SerializeToString(deterministic=True)):
                print("message %d differs:\n--- original\n%s\n--- crystal\n%s" % (i, original, parsed))
                return 1
        print("ok %d" % len(originals))
    else:
        print("unknown command %s" % command)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
