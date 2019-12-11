import argparse

from cffi import FFI

ffibuilder = FFI()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=str, required=True)
    parser.add_argument("--cdef", type=str, required=True)
    parser.add_argument("--ext-name", type=str, required=True)
    parser.add_argument("--source", type=str, required=True)
    args = parser.parse_args()
    with open(args.cdef) as fp:
        ffibuilder.cdef(fp.read())
    with open(args.source) as fp:
        ffibuilder.set_source(args.ext_name, fp.read(), compiler_verbose=False)
    ffibuilder.emit_c_code(args.out)
