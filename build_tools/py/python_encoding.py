import io
import tokenize


def decode_python_encoding(source: bytes) -> str:
    """Utility to decode a python source, useful when using typed_ast which does not seem to
    handle bytes correctly like ast does.
    """
    encoding, _ = tokenize.detect_encoding(io.BytesIO(source).readline)
    return source.decode(encoding)
