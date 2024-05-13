import sys

from ingest import generate_filenames


if __name__ == '__main__':
    print(f"Enumerating files under {sys.argv[1]}:")
    for filepath in generate_filenames(sys.argv[1]):
        print(filepath)

