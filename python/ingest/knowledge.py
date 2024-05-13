import os


def generate_filenames(rootpath: str):
    for dirpath, _, filenames in os.walk(rootpath):
        for file in filenames:
            yield file

