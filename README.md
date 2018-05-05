# Trash can

[![Build Status](https://travis-ci.org/FreeSlave/trashcan.svg?branch=master)](https://travis-ci.org/FreeSlave/trashcan) [![Windows Build Status](https://ci.appveyor.com/api/projects/status/github/FreeSlave/trashcan?branch=master&svg=true)](https://ci.appveyor.com/project/FreeSlave/trashcan)

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

### [Put to trash can](examples/put.d)

Run to put file or directory to trash can:

    dub examples/put.d path/to/file
