# Trash can

[![Build Status](https://travis-ci.org/MyLittleRobo/trashcan.svg?branch=master)](https://travis-ci.org/MyLittleRobo/trashcan)

Move files and directories to trash can (Recycle bin) in D programming language. 
Currently it contains only one function **moveToTrash** which places passed file or directory to trash can.

## Platform support

On Freedesktop environments (e.g. GNU/Linux) the library will follow [Trash Can Specification](https://www.freedesktop.org/wiki/Specifications/trash-spec/).

On Windows [SHFileOperation](https://msdn.microsoft.com/en-us/library/windows/desktop/bb762164(v=vs.85).aspx) is used.

On OSX FSMoveObjectToTrashSync is used.

Other platforms are not supported.

## Future improvements:

* Interface for observing the trash can contents (something like VFS).
* Ability to restore deleted files.

## Examples

### [Put to trash can](examples/put/source/app.d)

Run to put file or directory to trash can:

    dub run :put -- path/to/file
