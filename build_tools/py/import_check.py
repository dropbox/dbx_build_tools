import argparse


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("imports", nargs="*", help="imports to check")
    ARGS = p.parse_args()

    for arg in ARGS.imports:
        __import__(arg)


if __name__ == "__main__":
    main()
