#!/usr/bin/env python3

import argparse
import pathlib
import tarfile


EXCLUDED_TREES = {"dev", "proc", "sys"}
EXCLUDED_FILES = {"etc/hostname", "etc/hosts", "etc/resolv.conf"}


def included_members(archive: tarfile.TarFile):
    for member in archive:
        normalized = member.name.removeprefix("./").rstrip("/")
        path = pathlib.PurePosixPath(normalized)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe archive path: {member.name}")
        if normalized in EXCLUDED_FILES:
            continue
        if path.parts and path.parts[0] in EXCLUDED_TREES:
            continue
        yield member


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()

    with tarfile.open(args.archive, "r:gz") as archive:
        archive.extractall(args.destination, members=included_members(archive), numeric_owner=True)


if __name__ == "__main__":
    main()
