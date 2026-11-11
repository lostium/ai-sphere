#!/usr/bin/env python3
"""Copy a .prg to GARMIN/Apps on a USB-connected Garmin watch, using libmtp directly.

libmtp's mtp-sendfile cannot resolve Garmin's folders by path, so this script looks up the
GARMIN/Apps folder id and passes it to LIBMTP_Send_File_From_File.

Usage: scripts/mtp_send.py bin/AISphere.prg      (requires `brew install libmtp`; quit Garmin Express/OpenMTP)
"""
import ctypes as C
import os
import sys

LIB_PATHS = ["/opt/homebrew/lib/libmtp.dylib", "/usr/local/lib/libmtp.dylib"]
FILETYPE_UNKNOWN = 44


class Folder(C.Structure):
    pass


Folder._fields_ = [
    ("folder_id", C.c_uint32), ("parent_id", C.c_uint32), ("storage_id", C.c_uint32),
    ("name", C.c_char_p), ("sibling", C.POINTER(Folder)), ("child", C.POINTER(Folder)),
]


class File(C.Structure):
    pass


File._fields_ = [
    ("item_id", C.c_uint32), ("parent_id", C.c_uint32), ("storage_id", C.c_uint32),
    ("filename", C.c_void_p), ("filesize", C.c_uint64), ("modificationdate", C.c_long),
    ("filetype", C.c_int), ("next", C.POINTER(File)),
]


def find(folder, name, parent_id=None):
    """Depth-first search for a folder by name (case-insensitive), optionally under a parent id."""
    while folder:
        f = folder.contents
        if f.name and f.name.decode(errors="replace").lower() == name.lower() and \
                (parent_id is None or f.parent_id == parent_id):
            return f
        if f.child:
            hit = find(f.child, name, parent_id)
            if hit:
                return hit
        folder = f.sibling
    return None


def main(path):
    lib = next((C.CDLL(p) for p in LIB_PATHS if os.path.exists(p)), None)
    if lib is None:
        sys.exit("libmtp not found (brew install libmtp)")
    libc = C.CDLL(None)
    libc.strdup.restype = C.c_void_p
    libc.strdup.argtypes = [C.c_char_p]

    lib.LIBMTP_Get_First_Device.restype = C.c_void_p
    lib.LIBMTP_Get_Folder_List.restype = C.POINTER(Folder)
    lib.LIBMTP_Get_Folder_List.argtypes = [C.c_void_p]
    lib.LIBMTP_new_file_t.restype = C.POINTER(File)
    lib.LIBMTP_Send_File_From_File.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(File), C.c_void_p, C.c_void_p]
    lib.LIBMTP_Dump_Errorstack.argtypes = [C.c_void_p]
    lib.LIBMTP_Release_Device.argtypes = [C.c_void_p]
    lib.LIBMTP_Get_Storage.argtypes = [C.c_void_p, C.c_int]

    lib.LIBMTP_Init()
    device = lib.LIBMTP_Get_First_Device()
    if not device:
        sys.exit("no MTP device found (is the watch connected and Garmin Express closed?)")
    try:
        lib.LIBMTP_Get_Storage(device, 0)
        folders = lib.LIBMTP_Get_Folder_List(device)
        garmin = find(folders, "GARMIN")
        apps = find(folders, "Apps", garmin.folder_id) if garmin else None
        if not apps:
            sys.exit("GARMIN/Apps not found on the watch")
        print(f"GARMIN/Apps: folder {apps.folder_id}, storage {apps.storage_id:#x}")

        meta = lib.LIBMTP_new_file_t()
        meta.contents.parent_id = apps.folder_id
        meta.contents.storage_id = apps.storage_id
        meta.contents.filename = libc.strdup(os.path.basename(path).encode())
        meta.contents.filesize = os.path.getsize(path)
        meta.contents.filetype = FILETYPE_UNKNOWN
        rc = lib.LIBMTP_Send_File_From_File(device, path.encode(), meta, None, None)
        if rc != 0:
            lib.LIBMTP_Dump_Errorstack(device)
            sys.exit(f"send failed (rc={rc})")
        print(f"sent {os.path.basename(path)} ({os.path.getsize(path)} bytes) as item {meta.contents.item_id}")
    finally:
        lib.LIBMTP_Release_Device(device)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.path.isfile(sys.argv[1]):
        sys.exit(__doc__)
    main(sys.argv[1])
